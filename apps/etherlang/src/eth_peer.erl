-module(eth_peer).
-behaviour(gen_server).

%% Peer manager: TCP listener for inbound RLPx, dial API for outbound,
%% one eth_peer_conn per connection (monitored). Opt-in via RLPX_ENABLED;
%% auto-dial from the discv4 table and the eth capability arrive in
%% increment 3, so dial/3 is manual for now.

-export([start_link/1, dial/3, dial/4, status/0, status/1, peers/0, peers/1,
         get_headers/4, get_headers/5, get_bodies/1, get_bodies/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(st, {priv,
             node_id,
             client_id,
             listen_port,
             lsock,
             peers = #{}}).

start_link(Cfg) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Cfg, []).

dial(IP, Port, RemoteID) -> dial(?MODULE, IP, Port, RemoteID).
dial(Server, IP, Port, RemoteID) ->
    gen_server:call(Server, {dial, IP, Port, RemoteID}).

status() -> status(?MODULE).
status(Name) -> gen_server:call(Name, status).

peers() -> peers(?MODULE).
peers(Name) -> gen_server:call(Name, peers).

%% Fetch headers via the first eth-ready peer. Ref is {hash, H32} |
%% {number, N}; Reverse is boolean.
get_headers(Ref, Max, Skip, Reverse) -> get_headers(?MODULE, Ref, Max, Skip, Reverse).
get_headers(Name, Ref, Max, Skip, Reverse) ->
    case eth_ready_peer(Name) of
        {ok, Pid} ->
            gen_server:call(Pid, {get_headers, Ref, Max, Skip, Reverse}, 20000);
        {error, _} = E ->
            E
    end.

%% Fetch bodies via the first eth-ready peer. Hashes is [H32].
get_bodies(Hashes) -> get_bodies(?MODULE, Hashes).
get_bodies(Name, Hashes) ->
    case eth_ready_peer(Name) of
        {ok, Pid} ->
            gen_server:call(Pid, {get_bodies, Hashes}, 20000);
        {error, _} = E ->
            E
    end.

eth_ready_peer(Name) ->
    case gen_server:call(Name, peers) of
        Infos when is_list(Infos) ->
            case [Pid || {Pid, Info} <- Infos, is_map(Info),
                         maps:get(eth, Info, false) =/= false] of
                [Pid | _] -> {ok, Pid};
                [] -> {error, no_eth_peers}
            end;
        {error, _} = E ->
            E
    end.

init(Cfg) ->
    Priv = maps:get(privkey, Cfg),
    Port = maps:get(port, Cfg, 30303),
    NodeID = eth_ecies:pubkey(Priv),
    case gen_tcp:listen(Port, [binary, {packet, raw}, {active, false},
                               {reuseaddr, true}, {nodelay, true}]) of
        {ok, LSock} ->
            {ok, Actual} = inet:port(LSock),
            logger:notice("etherlang: rlpx listening on tcp ~p id=~s",
                          [Actual, binary:encode_hex(binary:part(NodeID, 0, 8))]),
            self() ! accept,
            {ok, #st{priv = Priv, node_id = NodeID, client_id = client_id(),
                     listen_port = Actual, lsock = LSock}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call({dial, IP, Port, RemoteID}, _From, S) ->
    Args = conn_args(S, RemoteID),
    case eth_peer_conn:start_initiator(self(), {IP, Port}, Args) of
        {ok, Pid} ->
            Ref = monitor(process, Pid),
            {reply, {ok, Pid}, S#st{peers = (S#st.peers)#{Pid => #{ref => Ref}}}};
        {error, _} = E ->
            {reply, E, S}
    end;
handle_call(status, _From, S) ->
    {reply, #{node_id => S#st.node_id, port => S#st.listen_port,
              peers => maps:size(S#st.peers)}, S};
handle_call(peers, _From, S) ->
    Infos = [{Pid, peer_status(Pid)} || Pid <- maps:keys(S#st.peers)],
    {reply, Infos, S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(accept, S) ->
    case gen_tcp:accept(S#st.lsock, 1000) of
        {ok, Sock} ->
            case eth_peer_conn:start_recipient(self(), Sock, conn_args(S, undefined)) of
                {ok, Pid} ->
                    %% Hand the socket to the conn: the acceptor (us) must
                    %% not own peer sockets, and a short-lived owner would
                    %% take the socket down with it on exit.
                    ok = gen_tcp:controlling_process(Sock, Pid),
                    Ref = monitor(process, Pid),
                    Peers = (S#st.peers)#{Pid => #{ref => Ref}},
                    self() ! accept,
                    {noreply, S#st{peers = Peers}};
                {error, _} ->
                    (try gen_tcp:close(Sock) catch _:_ -> ok end),
                    self() ! accept,
                    {noreply, S}
            end;
        {error, timeout} ->
            self() ! accept,
            {noreply, S};
        {error, closed} ->
            {stop, listener_closed, S};
        {error, Reason} ->
            logger:warning("etherlang: rlpx accept failed (~p)", [Reason]),
            self() ! accept,
            {noreply, S}
    end;
handle_info({peer_up, Pid, RemoteID, Hello}, S) ->
    case maps:find(Pid, S#st.peers) of
        {ok, Info} ->
            Split = erlang:monotonic_time(millisecond),
            Peers = (S#st.peers)#{Pid => Info#{remote => RemoteID,
                                               hello => Hello,
                                               since => Split}},
            logger:notice("etherlang: rlpx peer up ~s", [id8(RemoteID)]),
            {noreply, S#st{peers = Peers}};
        error ->
            %% Unknown pid (should not happen); drop it.
            exit(Pid, kill),
            {noreply, S}
    end;
handle_info({'DOWN', _Ref, process, Pid, Reason}, S) ->
    case maps:take(Pid, S#st.peers) of
        {_, Peers} ->
            case Reason of
                normal -> ok;
                _ -> logger:notice("etherlang: rlpx peer down (~p)", [Reason])
            end,
            {noreply, S#st{peers = Peers}};
        error ->
            {noreply, S}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    (try gen_tcp:close(S#st.lsock) catch _:_ -> ok end),
    ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ---------------------------------------------------------------------------

conn_args(S, RemoteID) ->
    #{privkey => S#st.priv, node_id => S#st.node_id,
      client_id => S#st.client_id, caps => eth_eth:caps(),
      listen_port => S#st.listen_port,
      remote_id => RemoteID, timeout => 10000}.

client_id() -> <<"etherlang/0.1.0">>.

peer_status(Pid) ->
    try gen_server:call(Pid, status, 2000)
    catch _:_ -> {error, down}
    end.

id8(ID) when byte_size(ID) >= 8 -> binary:encode_hex(binary:part(ID, 0, 8));
id8(_) -> <<"?">>.
