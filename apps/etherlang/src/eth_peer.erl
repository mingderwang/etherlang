-module(eth_peer).
-behaviour(gen_server).

%% Peer manager: TCP listener for inbound RLPx, manual dial API plus
%% auto-dial from a discv4 table (bonded nodes, target count, backoff).
%% One eth_peer_conn per connection (monitored). Opt-in via RLPX_ENABLED;
%% auto-dial additionally needs DISCV4_ENABLED as the peer source.

-export([start_link/1, dial/3, dial/4, status/0, status/1, peers/0, peers/1,
         get_headers/4, get_headers/5, get_bodies/1, get_bodies/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(DIAL_TIMEOUT, 30000).
-define(MAX_BACKOFF_MS, 300000).
-define(FAILURE_TTL_MS, 3600000).
-define(TRIM_SLACK, 5).

-record(st, {priv,
             node_id,
             client_id,
             listen_port,
             lsock,
             peers = #{},
             disc,
             chain,
             target = 10,
             interval = 10000,
             dialing = #{},
             failures = #{}}).

start_link(Cfg) ->
    Name = maps:get(name, Cfg, ?MODULE),
    gen_server:start_link({local, Name}, ?MODULE, Cfg, []).

dial(IP, Port, RemoteID) -> dial(?MODULE, IP, Port, RemoteID).
dial(Server, IP, Port, RemoteID) ->
    gen_server:call(Server, {dial, IP, Port, RemoteID}, 30000).

status() -> status(?MODULE).
status(Name) -> gen_server:call(Name, status).

peers() -> peers(?MODULE).
peers(Name) -> gen_server:call(Name, peers).

%% Fetch headers via the first eth-ready peer. Ref is {hash, H32} |
%% {number, N}; Reverse is boolean.
get_headers(Ref, Max, Skip, Reverse) -> get_headers(?MODULE, Ref, Max, Skip, Reverse).
get_headers(Name, Ref, Max, Skip, Reverse) when is_atom(Name) ->
    case eth_ready_peer(Name) of
        {ok, Pid} ->
            get_headers(Pid, Ref, Max, Skip, Reverse);
        {error, _} = E ->
            E
    end;
get_headers(Pid, Ref, Max, Skip, Reverse) when is_pid(Pid) ->
    gen_server:call(Pid, {get_headers, Ref, Max, Skip, Reverse}, 20000).

%% Fetch bodies via the first eth-ready peer. Hashes is [H32].
get_bodies(Hashes) -> get_bodies(?MODULE, Hashes).
get_bodies(Name, Hashes) when is_atom(Name) ->
    case eth_ready_peer(Name) of
        {ok, Pid} ->
            get_bodies(Pid, Hashes);
        {error, _} = E ->
            E
    end;
get_bodies(Pid, Hashes) when is_pid(Pid) ->
    gen_server:call(Pid, {get_bodies, Hashes}, 20000).

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
            Disc = maps:get(disc, Cfg, undefined),
            Target = maps:get(target, Cfg, 10),
            Interval = maps:get(interval, Cfg, 10000),
            Chain = maps:get(chain, Cfg, eth_chain),
            case Disc of
                undefined -> ok;
                _ -> erlang:send_after(Interval, self(), dial_tick)
            end,
            {ok, #st{priv = Priv, node_id = NodeID, client_id = client_id(),
                     listen_port = Actual, lsock = LSock,
                     disc = Disc, chain = Chain,
                     target = Target, interval = Interval}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call({dial, IP, Port, RemoteID}, _From, S) ->
    Args = conn_args(S, RemoteID),
    case eth_peer_conn:start_initiator_unlinked(self(), {IP, Port}, Args) of
        {ok, Pid} ->
            Ref = monitor(process, Pid),
            {reply, {ok, Pid}, S#st{peers = (S#st.peers)#{Pid => #{ref => Ref}}}};
        {error, _} = E ->
            {reply, E, S}
    end;
handle_call(status, _From, S) ->
    {reply, #{node_id => S#st.node_id, port => S#st.listen_port,
              peers => maps:size(S#st.peers),
              target => S#st.target,
              dialing => maps:size(S#st.dialing)}, S};
handle_call(peers, _From, S) ->
    Infos = [{Pid, peer_status(Pid)} || Pid <- maps:keys(S#st.peers)],
    {reply, Infos, S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(accept, S) ->
    case gen_tcp:accept(S#st.lsock, 1000) of
        {ok, Sock} ->
            case eth_peer_conn:start_recipient_unlinked(self(), Sock, conn_args(S, undefined)) of
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
    Peers = ensure_peer(S#st.peers, Pid),
    Split = erlang:monotonic_time(millisecond),
    Peers1 = Peers#{Pid := (maps:get(Pid, Peers))#{remote => RemoteID,
                                                   hello => Hello,
                                                   since => Split}},
    logger:notice("etherlang: rlpx peer up ~s", [id8(RemoteID)]),
    {noreply, S#st{peers = Peers1}};
handle_info({dial_result, Ref, Res}, S) ->
    case maps:take(Ref, S#st.dialing) of
        {{ID, _Addr, _Mon}, Dialing} ->
            S1 = S#st{dialing = Dialing},
            case Res of
                {ok, Pid} ->
                    Peers = ensure_peer(S1#st.peers, Pid),
                    {noreply, S1#st{peers = Peers}};
                {error, Reason} ->
                    logger:debug("etherlang: rlpx auto-dial failed (~p)", [Reason]),
                    {noreply, record_failure(S1, ID)}
            end;
        error ->
            {noreply, S}
    end;
handle_info({'DOWN', MRef, process, Pid, Reason}, S) ->
    case maps:take(Pid, S#st.peers) of
        {_, Peers} ->
            case Reason of
                normal -> ok;
                _ -> logger:notice("etherlang: rlpx peer down (~p)", [Reason])
            end,
            {noreply, S#st{peers = Peers}};
        error ->
            %% Maybe a dead auto-dial spawner whose result never arrived.
            case take_dialing_mon(S#st.dialing, MRef) of
                {{ID, _}, Dialing} ->
                    {noreply, record_failure(S#st{dialing = Dialing}, ID)};
                error ->
                    {noreply, S}
            end
    end;
handle_info(dial_tick, S) ->
    erlang:send_after(S#st.interval, self(), dial_tick),
    {noreply, maintain(S)};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(Reason, S) ->
    case Reason of
        normal -> ok;
        shutdown -> ok;
        _ -> logger:warning("etherlang: rlpx manager stopping (~p)", [Reason])
    end,
    (try gen_tcp:close(S#st.lsock) catch _:_ -> ok end),
    ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ---------------------------------------------------------------------------

conn_args(S, RemoteID) ->
    #{privkey => S#st.priv, node_id => S#st.node_id,
      client_id => S#st.client_id, caps => eth_eth:caps(),
      listen_port => S#st.listen_port, chain => S#st.chain,
      remote_id => RemoteID, timeout => 10000}.

%% Monitored peer entry (peer_up may arrive before dial_result).
ensure_peer(Peers, Pid) ->
    case maps:find(Pid, Peers) of
        {ok, _} -> Peers;
        error -> Peers#{Pid => #{ref => monitor(process, Pid)}}
    end.

%% Periodic maintenance: trim surplus, dial toward target.
maintain(S) ->
    S1 = S#st{failures = prune_failures(S#st.failures)},
    S2 = trim_surplus(S1),
    dial_toward_target(S2).

trim_surplus(S) ->
    Over = maps:size(S#st.peers) - S#st.target - ?TRIM_SLACK,
    case Over > 0 of
        false -> S;
        true ->
            Ups = [{Since, Pid} || {Pid, #{since := Since}} <- maps:to_list(S#st.peers)],
            Victims = [Pid || {_, Pid} <- lists:sublist(
                                lists:reverse(lists:sort(Ups)), Over)],
            lists:foreach(fun(Pid) -> gen_server:cast(Pid, {graceful_stop, 4}) end,
                          Victims),
            S
    end.

dial_toward_target(#st{disc = undefined} = S) -> S;
dial_toward_target(S) ->
    Known = connected_ids(S#st.peers),
    InFlight = [ID || {ID, _, _} <- maps:values(S#st.dialing)],
    Cands = candidates(S, Known, InFlight),
    Want = S#st.target - maps:size(S#st.peers) - maps:size(S#st.dialing),
    lists:foldl(fun(Node, Acc) -> auto_dial(Acc, Node) end, S,
                lists:sublist(shuffle(Cands), max(Want, 0))).

connected_ids(Peers) ->
    [R || #{remote := R} <- maps:values(Peers)].

candidates(S, Known, InFlight) ->
    Nodes = (try eth_discv4:peers(S#st.disc) catch _:_ -> [] end),
    Now = erlang:monotonic_time(millisecond),
    [N || N = #{id := ID, ip := _, udp := _, tcp := Port} <- Nodes,
          Port =/= 0,
          maps:get(bonded, N, false),
          ID =/= S#st.node_id,
          not lists:member(ID, Known),
          not lists:member(ID, InFlight),
          backoff_ok(S#st.failures, ID, Now)].

backoff_ok(Failures, ID, Now) ->
    case maps:find(ID, Failures) of
        {ok, {_, NotBefore}} -> Now >= NotBefore;
        error -> true
    end.

auto_dial(S, #{id := ID, ip := IP, tcp := Port} = _Node) ->
    Manager = self(),
    Args = conn_args(S, ID),
    Ref = make_ref(),
    {_, Mon} = spawn_monitor(
                 fun() ->
                     Res = eth_peer_conn:start_initiator_unlinked(Manager, {IP, Port}, Args),
                     Manager ! {dial_result, Ref, Res}
                 end),
    S#st{dialing = (S#st.dialing)#{Ref => {ID, {IP, Port}, Mon}}}.

take_dialing_mon(Dialing, Mon) ->
    case [{R, V} || {R, {_, _, M} = V} <- maps:to_list(Dialing), M =:= Mon] of
        [{Ref, {ID, Addr, _}}] ->
            {{ID, Addr}, maps:remove(Ref, Dialing)};
        [] ->
            error
    end.

record_failure(S, ID) ->
    Now = erlang:monotonic_time(millisecond),
    Fails = case maps:find(ID, S#st.failures) of
                {ok, {F, _}} -> F + 1;
                error -> 1
            end,
    Delay = min(?MAX_BACKOFF_MS, 5000 * Fails * Fails),
    S#st{failures = (S#st.failures)#{ID => {Fails, Now + Delay}}}.

prune_failures(Failures) ->
    Now = erlang:monotonic_time(millisecond),
    maps:filter(fun(_, {_, NotBefore}) ->
        NotBefore + ?FAILURE_TTL_MS > Now
    end, Failures).

shuffle(L) ->
    Tagged = [{rand:uniform(), X} || X <- L],
    [X || {_, X} <- lists:sort(Tagged)].

client_id() -> <<"etherlang/0.1.0">>.

peer_status(Pid) ->
    try gen_server:call(Pid, status, 2000)
    catch _:_ -> {error, down}
    end.

id8(ID) when byte_size(ID) >= 8 -> binary:encode_hex(binary:part(ID, 0, 8));
id8(_) -> <<"?">>.
