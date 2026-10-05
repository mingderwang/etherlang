-module(eth_peer).
-behaviour(gen_server).

%% Peer manager: TCP listener for inbound RLPx, manual dial API plus
%% auto-dial from a discv4 table (bonded nodes, target count, backoff).
%% One eth_peer_conn per connection (monitored). Opt-in via RLPX_ENABLED;
%% auto-dial additionally needs DISCV4_ENABLED as the peer source.

-export([start_link/1, dial/3, dial/4, status/0, status/1, peers/0, peers/1,
         get_headers/4, get_headers/5, get_bodies/1, get_bodies/2,
         get_receipts/1, get_receipts/2, broadcast/1, broadcast/2,
         eth_peer_count/0, eth_peer_count/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(DIAL_TIMEOUT, 30000).
-define(MAX_BACKOFF_MS, 300000).
-define(FAILURE_TTL_MS, 3600000).
-define(TRIM_SLACK, 5).

%% How long the manager waits before re-probing its listen socket. `accept/2` with
%% a zero timeout is what keeps `handle_info/2' from blocking the manager; this is
%% only the idle re-poll. See the comment on `handle_info(accept, S)'.
-define(ACCEPT_POLL_MS, 100).

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
             failures = #{},
             accepting = #{},
             pool}).

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

%% Fetch receipts via the first eth-ready peer. Hashes is [H32].
get_receipts(Hashes) -> get_receipts(?MODULE, Hashes).
get_receipts(Name, Hashes) when is_atom(Name) ->
    case eth_ready_peer(Name) of
        {ok, Pid} ->
            get_receipts(Pid, Hashes);
        {error, _} = E ->
            E
    end;
get_receipts(Pid, Hashes) when is_pid(Pid) ->
    gen_server:call(Pid, {get_receipts, Hashes}, 20000).

%% Announce pooled tx hashes to all connected peers (best-effort).
broadcast(Hashes) -> broadcast(?MODULE, Hashes).
broadcast(Name, Hashes) ->
    try gen_server:cast(Name, {broadcast, Hashes})
    catch _:_ -> ok
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
            Disc = maps:get(disc, Cfg, undefined),
            Target = maps:get(target, Cfg, 10),
            Interval = maps:get(interval, Cfg, 10000),
            Chain = maps:get(chain, Cfg, eth_chain),
            Pool = maps:get(pool, Cfg, eth_txpool),
            case Disc of
                undefined -> ok;
                _ -> erlang:send_after(Interval, self(), dial_tick)
            end,
            {ok, #st{priv = Priv, node_id = NodeID, client_id = client_id(),
                     listen_port = Actual, lsock = LSock,
                     disc = Disc, chain = Chain, pool = Pool,
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
%% **Answered from this manager's own state, never by calling the peer.**
%%
%% It used to be `[{Pid, peer_status(Pid)}]', one `gen_server:call(Pid, status, 2000)' per
%% peer. That was wrong for a reason that is not about error handling: a
%% `eth_peer_conn' executing `fetch_request/6' inside `handle_call({get_headers, ...})'
%% **cannot answer any other message for up to 15 seconds**, because it owns `recv' and a
%% `gen_server' handles one message at a time. So a peer doing exactly the work this node
%% wants from it was reported `{error, down}' -- and `eth_ready_peer/1' filters on
%% `is_map(Info)', so `eth_sync' was told there were no eth peers and never started.
%%
%% Measured consequences of the old form: `peers/0' answered `{error, down}' for a
%% connection that was provably alive (`peer_up` = 1, never terminated, per-second
%% diagnostics rising), `net_peerCount' alternated `0x1' and `0x0' on a stable connection,
%% 22 `status' calls were logged against 40 `net_peerCount' samples -- so roughly half were
%% never processed at all -- and `net_peerCount' cost **2.1-3.5 s** because each busy peer
%% consumed the full 2 s timeout.
%%
%% Everything `peers/0' reports is now known here: `remote' and `hello' arrive with
%% `peer_up', `eth' now arrives with it, and a `'DOWN'' removes the entry. So the answer is
%% a lookup, and the cost is O(1) in the number of peers rather than O(peers x 2s).
handle_call(peers, _From, S) ->
    {reply, [{Pid, maps:get(Pid, S#st.peers)} || Pid <- maps:keys(S#st.peers)], S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({broadcast, Hashes}, S) ->
    lists:foreach(fun(Pid) ->
        try gen_server:cast(Pid, {broadcast_hashes, Hashes})
        catch _:_ -> ok end
    end, maps:keys(S#st.peers)),
    {noreply, S};
handle_cast(_Msg, S) -> {noreply, S}.

%% **The manager never blocks in `accept/2' or in a handshake.** Both used to.
%%
%% `gen_tcp:accept(S#st.lsock, 1000)' ran inside this callback, so with no
%% connection anywhere the manager was unreachable for a one-second slice at a
%% time, forever: measured over 20 idle calls, `status' took 798 ms to 1004 ms,
%% median 1001 ms. `eth_sync:eth_ready_peers/1' (eth_sync.erl:454) and
%% `eth_statesync:snap_peer/1' (eth_statesync.erl:109) both poll `eth_peer:peers/1',
%% so that was not a theoretical stall.
%%
%% And `gen_server:start/3' does not return until `init/1' has acked, where
%% `init/1' for an inbound connection is `eth_rlpx:recipient/3' with a ten-second
%% timeout. So one TCP connection that had sent nothing at all took the manager
%% down for ten seconds: no `dial_tick', no `DOWN' handling, no `peer_up'.
%% Measured: unreachable at t=2.2, 4.4, 6.6 and 8.8 s, answering again only once
%% the handshake logged its own failure.
%%
%% Two changes. `accept/2` is called with a **zero** timeout and the manager
%% re-probes on a `?ACCEPT_POLL_MS' timer, so the callback returns in
%% microseconds instead of holding the process. And the handshake is spawned the
%% way `auto_dial/2' has always done it, which is why the conn pid comes back as a
%% message rather than as a return value.
%%
%% **Why the socket stays owned by the manager.** The obvious alternative is a
%% dedicated acceptor process, which is what `ranch' does and what removes the
%% poll as well. It needs the acceptor to hand each socket to the conn, and
%% `gen_tcp:controlling_process/2' may only be called by the current owner -- so
%% the acceptor would have to spawn the conn, wait for a `gen_server:start/3' that
%% cannot return until `init/1' has already run the handshake, and only then
%% transfer. The bridge is possible and it is not free, and it would change who
%% owns a peer socket. `gen_tcp:recv/3' and `send/2' do *not* require ownership
%% (only setting `{active, ...}' does, and nothing in `eth_rlpx' sets it), so the
%% handshake can run before the transfer below exactly as it always did. A
%% 10-per-second poll on an idle listener is the cheap half of a fix whose
%% expensive half is a socket-ownership change this module does not otherwise
%% make.
%%
%% `{active, once}' on the listen socket is NOT the alternative, and it was tried:
%% it makes no difference, because `{tcp_passive, _}' is the re-arm message for
%% an *established* socket. Measured on OTP 29 -- `{active, once}', `{active, 1}'
%% and `{active, true}' on a `gen_tcp:listen/2' socket each delivered no message
%% at all while a client connected and `accept/2' succeeded. Adopting it would have
%% produced a node that never accepts an inbound connection and reports itself
%% perfectly responsive.
handle_info(accept, S) ->
    case gen_tcp:accept(S#st.lsock, 0) of
        {ok, Sock} ->
            Manager = self(),
            Args = conn_args(S, undefined),
            Ref = make_ref(),
            {_, Mon} =
                spawn_monitor(
                  fun() ->
                      Manager ! {accepted, Ref,
                                 eth_peer_conn:start_recipient_unlinked(
                                   Manager, Sock, Args)}
                  end),
            self() ! accept,
            {noreply, S#st{accepting = (S#st.accepting)#{Ref => {Mon, Sock}}}};
        {error, timeout} ->
            erlang:send_after(?ACCEPT_POLL_MS, self(), accept),
            {noreply, S};
        {error, closed} ->
            {stop, listener_closed, S};
        {error, Reason} ->
            logger:warning("etherlang: rlpx accept failed (~p)", [Reason]),
            erlang:send_after(?ACCEPT_POLL_MS, self(), accept),
            {noreply, S}
    end;
handle_info({accepted, Ref, Res}, S) ->
    case maps:take(Ref, S#st.accepting) of
        {{Mon, Sock}, Accepting} ->
            _ = demonitor(Mon, [flush]),
            case Res of
                {ok, Pid} ->
                    %% Hand the socket to the conn: the acceptor (us) must not
                    %% own peer sockets, and a short-lived owner would take the
                    %% socket down with it on exit.
                    ok = gen_tcp:controlling_process(Sock, Pid),
                    MRef = monitor(process, Pid),
                    {noreply, S#st{accepting = Accepting,
                                   peers = (S#st.peers)#{Pid => #{ref => MRef}}}};
                {error, _} ->
                    (try gen_tcp:close(Sock) catch _:_ -> ok end),
                    {noreply, S#st{accepting = Accepting}}
            end;
        error ->
            {noreply, S}
    end;
handle_info({peer_up, Pid, RemoteID, Hello, Eth}, S) ->
    Peers = ensure_peer(S#st.peers, Pid),
    Split = erlang:monotonic_time(millisecond),
    Peers1 = Peers#{Pid := (maps:get(Pid, Peers))#{remote => RemoteID,
                                                   hello => Hello,
                                                   eth => Eth,
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
      pool => S#st.pool,
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

%% **Connected, eth-capable peers.** Exported because this is the manager's knowledge
%% and the RPC handler should not be the only thing able to ask.
%%
%% The predicate is `eth_ready_peer/1's, verbatim, so this number and the peer the node
%% would actually sync from cannot disagree. `status/0' would be cheaper -- it is a map
%% size -- and it is the wrong number: it counts conns that have not finished
%% handshaking and conns that are dead. **Measured on two live nodes: `status/0' said
%% `peers => 1' while `peers/0' said `{error, down}' for that one entry.**
%%
%% **This is O(1) in the number of peers, and that is the point.** It used to reach into
%% each conn with `gen_server:call(Pid, status, 2000)' and so cost **2091-3525 ms** on the
%% pair in `tools/two-node-status.sh' -- a conn executing `fetch_request/6' cannot answer
%% for up to 15 s, so each one consumed the full timeout. `peers/0' now answers from this
%% manager's own state, and nothing here calls a peer at all.
eth_peer_count() -> eth_peer_count(?MODULE).

eth_peer_count(Name) ->
    try
        length([P || {P, Info} <- peers(Name),
                      is_map(Info), maps:get(eth, Info, false) =/= false])
    catch _:_ -> 0
    end.

id8(ID) when byte_size(ID) >= 8 -> binary:encode_hex(binary:part(ID, 0, 8));
id8(_) -> <<"?">>.
