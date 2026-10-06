-module(eth_peer_conn).
-behaviour(gen_server).

%% One RLPx peer connection: owns its passive socket, runs the handshake in
%% init, exchanges Hellos, then polls for inbound p2p messages (answers Ping
%% with Pong) and sends periodic Pings. Any framing/auth failure stops the
%% process; the eth_peer manager drops it via monitor.

-export([start_initiator/3, start_recipient/3]).
-export([start_initiator_unlinked/3, start_recipient_unlinked/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(PING_MS, 15000).
-define(POLL_MS, 1000).
-define(IDLE_TIMEOUT_MS, 120000).
%% Shorter than the 2000 ms timeout the peer manager used to give up at, so a window in
%% which that call would have timed out is guaranteed to contain a report.
-define(DIAG_MS, 1000).

-record(st, {sock,
             sess,
             manager,
             hello,
             eth,
             chain,
             pool,
             store,
             fetching = false,
             last_in,
             %% Wall-clock cost of the last `handle_msg/3', in milliseconds.
             %%
             %% This is the number the open item turns on. `peer_status/1' reaches this
             %% process with `gen_server:call(Pid, status, 2000)', and a conn executing a
             %% `handle_msg' cannot answer inside that window -- so it is reported as
             %% **dead** while it is alive and working. `eth_peer:peers/0' then hands
             %% `eth_ready_peer/1' a non-map, that answers `{error, no_eth_peers}', and
             %% `eth_sync' never engages. See the `diag' tick for why the measurement has
             %% to live in here.
             handle_ms = 0}).

%% Args: #{privkey, remote_id, node_id, client_id, caps, listen_port,
%%         chain}. The _link variants link to the caller (tests); the
%% plain variants are for the manager, which monitors instead so a
%% crashing handshake cannot take the manager down with it.
start_initiator(Manager, {Host, Port}, Args) ->
    gen_server:start_link(?MODULE, {initiator, Manager, Host, Port, Args}, []).

start_initiator_unlinked(Manager, {Host, Port}, Args) ->
    gen_server:start(?MODULE, {initiator, Manager, Host, Port, Args}, []).

%% Args: same as above minus remote_id; Sock is the accepted socket.
start_recipient(Manager, Sock, Args) ->
    gen_server:start_link(?MODULE, {recipient, Manager, Sock, Args}, []).

start_recipient_unlinked(Manager, Sock, Args) ->
    gen_server:start(?MODULE, {recipient, Manager, Sock, Args}, []).

init({initiator, Manager, Host, Port, Args}) ->
    #{privkey := Priv, remote_id := RemoteID} = Args,
    case gen_tcp:connect(Host, Port,
                         [binary, {packet, raw}, {active, false},
                          {nodelay, true}, {send_timeout, 10000}], 10000) of
        {ok, Sock} ->
            case eth_rlpx:initiator(Sock, Priv, RemoteID, 10000) of
                {ok, Sess} -> finish_init(Manager, Sock, Args, Sess);
                {error, Reason} ->
                    logger:notice("etherlang: rlpx outbound handshake failed (~p)", [Reason]),
                    {stop, Reason}
            end;
        {error, Reason} ->
            {stop, Reason}
    end;
init({recipient, Manager, Sock, Args}) ->
    #{privkey := Priv} = Args,
    case eth_rlpx:recipient(Sock, Priv, 10000) of
        {ok, Sess} -> finish_init(Manager, Sock, Args, Sess);
        {error, Reason} ->
            logger:notice("etherlang: rlpx inbound handshake failed (~p)", [Reason]),
            {stop, Reason}
    end.

finish_init(Manager, Sock, Args, Sess) ->
    case eth_rlpx:hello(Sess, Sock, Args) of
        {ok, Sess1, Hello} ->
            S = #st{sock = Sock, sess = Sess1, manager = Manager,
                    hello = Hello, eth = undefined,
                    chain = maps:get(chain, Args, eth_chain),
                    pool = maps:get(pool, Args, eth_txpool),
                    store = maps:get(store, Args, eth_statestore),
                    last_in = erlang:monotonic_time(millisecond)},
            case maybe_eth(S, Args, Hello) of
                {ok, S1} ->
                    erlang:send_after(?POLL_MS, self(), poll),
                    erlang:send_after(?PING_MS, self(), ping),
                    erlang:send_after(?DIAG_MS, self(), diag),
                    %% **`eth' travels with `peer_up' now.** It used to be fetched later,
                    %% by the manager calling into this process -- and this process spends
                    %% up to 15 s inside `fetch_request/6' (`handle_call({get_headers,
                    %% ...})' owns `recv' for that whole window, and a `gen_server' handles
                    %% one message at a time), so the manager's 2 s `gen_server:call' timed
                    %% out and the peer was reported **dead while it was working**. The
                    %% value is fixed once the handshake is done and this message is sent
                    %% after `maybe_eth' has already succeeded, so sending it costs
                    %% nothing and removes the only reason the manager had to call in.
                    %% **`eth_ready(S1)', not `S1#st.eth'.** The first version sent the raw
                    %% negotiated value, which is `undefined' when no eth capability was
                    %% shared -- and the consumers test `maps:get(eth, Info, false)
                    %% =/= false', so `undefined' passes that test. **A peer with no eth
                    %% capability would have counted as eth-ready**, which is the opposite
                    %% of the filter's intent. `eth_ready/1' is the one definition of
                    %% "eth-capable" and it answers `false' rather than `undefined', and it
                    %% is the same value `handle_call(status, ...)' reports, so the manager
                    %% and a direct query cannot disagree.
                    %%
                    %% **The two forms cannot differ on any path that exists today**, and
                    %% that is worth saying rather than implying a test holds this: the
                    %% `peer_up' send is inside `maybe_eth''s `{ok, S1}' branch, so by the
                    %% time it happens `S1#st.eth' is already a map and `eth_ready/1'
                    %% returns a map too. The reason to use `eth_ready/1' anyway is that the
                    %% `undefined' form is what a future path would send -- a peer that
                    %% completes RLPx without sharing `eth' -- and it **passes**
                    %% `maps:get(eth, Info, false) =/= false`. So this is "correct by the
                    %% specification and unobservable here", which are two different
                    %% sentences, and both belong here: the next reader will otherwise
                    %% assume something is holding `eth_ready/1' in place and may move it.
                    Manager ! {peer_up, self(), eth_rlpx:remote_id(Sess1), Hello,
                               eth_ready(S1)},
                    {ok, S1};
                {error, Reason} ->
                    logger:notice("etherlang: rlpx eth handshake failed (~p)", [Reason]),
                    {stop, Reason}
            end;
        {error, Reason} ->
            logger:notice("etherlang: rlpx hello failed (~p)", [Reason]),
            {stop, Reason}
    end.

%% eth capability handshake after Hello: negotiate, send our Status, await
%% and check theirs. No shared eth → stay p2p-only.
maybe_eth(S, _Args, Hello) ->
    Caps = eth_eth:negotiate_caps(eth_eth:caps(), maps:get(caps, Hello, [])),
    case maps:find(eth, Caps) of
        error ->
            {ok, S};
        {ok, Neg} ->
            case eth_eth:status_data(S#st.chain) of
                {error, _} = E ->
                    E;
                {ok, Our} ->
                    case eth_rlpx:send(S#st.sess, S#st.sock,
                                       eth_eth:msg_status(Neg),
                                       eth_rlp:encode(eth_eth:encode_status(Our))) of
                        {ok, Sess1} ->
                            await_status(S#st{sess = Sess1}, Neg, Our,
                                         maps:find(snap, Caps));
                        {error, _} = E ->
                            E
                    end
            end
    end.

await_status(S, #{base := Base} = Neg, Our, SnapOpt) ->
    case eth_rlpx:recv(S#st.sess, S#st.sock, 10000) of
        {ok, Code, Data, Sess1} when Code =:= Base ->
            case eth_eth:decode_status_bin(Data) of
                {ok, Their} ->
                    case eth_eth:check_status(Our, Their) of
                        ok ->
                            Eth = case SnapOpt of
                                      {ok, Snap} -> Neg#{status => Their,
                                                         snap => Snap};
                                      error -> Neg#{status => Their}
                                  end,
                            {ok, S#st{sess = Sess1, eth = Eth}};
                        {error, _} = E ->
                            E
                    end;
                {error, _} = E ->
                    E
            end;
        {ok, _, _, _} ->
            {error, expected_status};
        {error, _} = E ->
            E
    end.

handle_call(status, _From, S) ->
    Base = #{remote => eth_rlpx:remote_id(S#st.sess),
             hello => S#st.hello,
             eth => eth_ready(S),
             last_in_ms_ago => erlang:monotonic_time(millisecond) - S#st.last_in},
    %% **Whether this line is reached is the measurement.** `peer_status/1' answers
    %% `{error, down}' from a bare `catch _:_', which merges three things that have
    %% nothing in common: the call never arrived, it arrived and this handler raised,
    %% and it timed out. This log says which of them happened.
    %%
    %%   this line appears   the call arrived and the handler answered
    %%   neither appears     the call did not arrive, so the Pid the manager holds is
    %%                       not this process
    %%
    %% At notice rather than info, because the release prints notice and above.
    logger:notice("etherlang: rlpx conn status self=~p eth_ready=~p",
                  [self(), eth_ready(S)]),
    {reply, Base, S};
handle_call({get_headers, Ref, Max, Skip, Reverse}, _From, S) ->
    case S#st.eth of
        undefined ->
            {reply, {error, no_eth}, S};
        #{base := Base} ->
            %% Suspend the poll loop while the blocking fetch owns recv.
            Req = eth_eth:encode_get_headers(Ref, Max, Skip, Reverse),
            Verify = fun(Term) -> eth_eth:verify_chain(Term, not Reverse, to_skip(Skip)) end,
            T0 = erlang:monotonic_time(millisecond),
            {Reply, S1} = fetch_request(S#st{fetching = true}, Base + 3,
                                        eth_rlp:encode(Req), Base + 4,
                                        fun eth_eth:decode_headers_bin/1, Verify),
            %% **How long one `get_headers' call occupied this process, and what it got back.**
            %%
            %% A `gen_server' cannot process a message while it is inside `handle_call/3',
            %% so the gap between two `?DIAG_MS` diagnostic lines *is* the length of the
            %% block. Measured that way the block is ~19 s on a node whose fetch deadline is
            %% 15,000 ms and whose caller's budget is 20,000 ms, and the request-side work
            %% (RLP decode 4 ms, `eth_eth:verify_chain/3' 289 ms over 192 linked headers)
            %% accounts for about 0.3 s of it. So roughly 3.7 s is unattributed, and the
            %% gap cannot distinguish "one call overran its deadline" from "`eth_sync'
            %% issued two calls back to back and the second waited behind the first".
            %%
            %% **This line is what separates those two**, because `n' is the call's ordinal
            %% within this process: consecutive n' values mean separate calls, and a single
            %% n' with a 19 s `ms' means one call that blocked for 19 s.
            logger:notice("etherlang: get_headers n=~p ms=~p want=~p max=~p skip=~p rev=~p "
                          "-> ~p",
                          [get_headers_n(), erlang:monotonic_time(millisecond) - T0,
                           short_ref(Ref), Max, Skip, Reverse, tag_reply(Reply)]),
            S2 = S1#st{fetching = false},
            erlang:send_after(?POLL_MS, self(), poll),
            {reply, Reply, S2}
    end;
handle_call({get_bodies, Hashes}, _From, S) ->
    case S#st.eth of
        undefined ->
            {reply, {error, no_eth}, S};
        #{base := Base} ->
            Req = eth_eth:encode_get_bodies(Hashes),
            {Reply, S1} = fetch_request(S#st{fetching = true}, Base + 5,
                                        eth_rlp:encode(Req), Base + 6,
                                        fun eth_eth:decode_bodies_bin/1,
                                        fun(_) -> ok end),
            S2 = S1#st{fetching = false},
            erlang:send_after(?POLL_MS, self(), poll),
            {reply, Reply, S2}
    end;
handle_call({get_receipts, Hashes}, _From, S) ->
    case S#st.eth of
        undefined ->
            {reply, {error, no_eth}, S};
        #{base := Base} ->
            Req = eth_eth:encode_get_receipts(Hashes),
            {Reply, S1} = fetch_request(S#st{fetching = true}, Base + 15,
                                        eth_rlp:encode(Req), Base + 16,
                                        fun eth_eth:decode_receipts_bin/1,
                                        fun(_) -> ok end),
            S2 = S1#st{fetching = false},
            erlang:send_after(?POLL_MS, self(), poll),
            {reply, Reply, S2}
    end;
handle_call({snap_account_range, Root, Origin, Limit}, _From, S) ->
    snap_call(S, 0, 1,
              eth_rlp:encode(eth_snap:encode_account_req(Root, Origin, Limit)));
handle_call({snap_storage_range, Root, Account, Origin, Limit}, _From, S) ->
    snap_call(S, 2, 3,
              eth_rlp:encode(
                eth_snap:encode_storage_req(Root, Account, Origin, Limit)));
handle_call({snap_bytecodes, Hashes}, _From, S) ->
    snap_call(S, 4, 5,
              eth_rlp:encode(eth_snap:encode_bytecodes_req(Hashes)));
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({graceful_stop, Reason}, S) ->
    %% Spec-friendly trim: send Disconnect, give the peer 2s, then stop.
    _ = eth_rlpx:send(S#st.sess, S#st.sock, 1, eth_rlp:encode([Reason])),
    erlang:send_after(2000, self(), graceful_timeout),
    {noreply, S};
handle_cast({broadcast_hashes, Hashes}, S) ->
    case S#st.eth of
        #{base := Base} ->
            case eth_rlpx:send(S#st.sess, S#st.sock, Base + 8,
                               eth_rlp:encode(eth_eth:encode_hashes(Hashes))) of
                {ok, Sess1} -> {noreply, S#st{sess = Sess1}};
                {error, Reason} -> {stop, Reason, S}
            end;
        _ ->
            {noreply, S}
    end;
handle_cast(_Msg, S) -> {noreply, S}.

handle_info(poll, #st{fetching = true} = S) ->
    %% A get_headers call owns recv right now; skip this round.
    erlang:send_after(?POLL_MS, self(), poll),
    {noreply, S};
handle_info(poll, S) ->
    case eth_rlpx:recv(S#st.sess, S#st.sock, ?POLL_MS) of
        {ok, Code, Data, Sess1} ->
            S1 = S#st{sess = Sess1,
                      last_in = erlang:monotonic_time(millisecond)},
            T0 = erlang:monotonic_time(millisecond),
            R = handle_msg(Code, Data, S1),
            S2 = S1#st{handle_ms = erlang:monotonic_time(millisecond) - T0},
            case R of
                {ok, S3} ->
                    check_idle(reschedule_poll(S3));
                {stop, Reason} ->
                    {stop, Reason, S2}
            end;
        {error, timeout} ->
            check_idle(reschedule_poll(S));
        {error, closed} ->
            {stop, normal, S};
        {error, Reason} ->
            {stop, Reason, S}
    end;
%% **What this conn is doing, from inside, where the answer cannot be blocked by the
%% thing being diagnosed.**
%%
%% `eth_peer:peers/0' answers `{error, down}' for this process -- which `peer_status/1'
%% produces when its 2 s `gen_server:call' times out -- while `eth_peer:status/0' counts
%% it, the manager monitors it, and it never terminates. **No outside observer can settle
%% that**, because every route in goes through `eth_peer:peers/1', which is the call that
%% times out. Two attempts to watch it from outside produced nothing: one fixture did not
%% reproduce the defect, and the second was cancelled before printing a line.
handle_info(diag, S) ->
    erlang:send_after(?DIAG_MS, self(), diag),
    %% **The remote id comes from `#st.hello', not from `eth_rlpx:remote_id/1'.** The
    %% latter takes the *args map* the conn was started with (`node_id = maps:get(...)
    %% in its own state at eth_rlpx.erl:231), and handing it the session record instead
    %% is a `badarg' -- which is how this line was caught: three tests failed with
    %% `exception error: bad argument' and the reported position was the argument, not
    %% the shape mismatch.
    %% **`notice' and not `info'.** The release's logger prints notice and above --
    %% every line in the running node's log is a `NOTICE REPORT' or a `WARNING REPORT' --
    %% so an `info' line here would be filtered out of exactly the place this has to be
    %% seen. That is not a guess about levels: it is what the log contains.
    %% **`self=~p' is in this line for a measured reason.** The conn is provably idle
    %% (`handle_ms=0', `q=0') and yet `eth_peer:peers/0' answers `{error, down}' for the
    %% entry it holds. A live, idle gen_server cannot fail a `gen_server:call/3' with a
    %% 2 s timeout, so the remaining explanation is that **the Pid in the manager's map is
    %% not this process** -- and the only way to see that is to print both.
    logger:notice("etherlang: rlpx conn diag self=~p remote=~s handle_ms=~p q=~p calls=~p fetching=~p base=~p doing=~s",
                [self(), id8(maps:get(node_id, S#st.hello, undefined)),
                 S#st.handle_ms, queue_len(), queued_calls(),
                   S#st.fetching, eth_base(S#st.eth), doing()]),
    {noreply, S};
handle_info(ping, S) ->
    erlang:send_after(?PING_MS, self(), ping),
    case eth_rlpx:send(S#st.sess, S#st.sock, 2, eth_rlp:encode([])) of
        {ok, Sess1} -> {noreply, S#st{sess = Sess1}};
        {error, Reason} -> {stop, Reason, S}
    end;
handle_info(graceful_timeout, S) ->
    {stop, normal, S};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(Reason, S) ->
    case Reason of
        normal -> ok;
        shutdown -> ok;
        _ ->
            %% **The port's own account of itself, at the moment it is being closed.**
            %%
            %% A connection here dies with `{error, enotconn}' out of `poll' ->
            %% `eth_rlpx:recv' -> `gen_tcp:recv', which says the socket is *not
            %% connected* -- while `lsof' still lists the connection as ESTABLISHED.
            %% Those two facts cannot both be about the same socket, and which of them
            %% is wrong decides where the defect is:
            %%
            %%   connected => true   the handle is a connected socket, so `enotconn'
            %%                        did not come from this port's state and the cause
            %%                        is upstream of the port
            %%   connected => false  this port is not the connected socket -- the fd was
            %%                        reused, or the socket was moved out from under
            %%                        the conn
            %%   undefined          the port is already gone
            %%
            %% It is here rather than in a probe because it is the only place the answer
            %% exists: the conn dies within about a second of `peer_up', and every
            %% external observer loses the race. Two attempts to watch it from outside
            %% produced nothing -- one fixture did not reproduce the defect at all, and
            %% the second was cancelled before it printed a line, because
            %% `eth_peer:peers/1' blocks for up to two seconds per stuck connection,
            %% which is the same slowness `net_peerCount' was measured at (2.1-3.5 s).
            %% **An observer with the defect it is observing does not get an answer.**
            logger:notice("etherlang: rlpx conn terminating (~p) eth=~p "
                          "port_connected=~p port_id=~p",
                          [Reason, S#st.eth =/= undefined,
                           port_connected(S#st.sock), port_id(S#st.sock)])
    end,
    (try gen_tcp:close(S#st.sock) catch _:_ -> ok end),
    ok.

%% `erlang:port_info/2' rather than `inet:getstat/1': it answers for the port term this
%% process holds, with no name lookup and no DNS, and it cannot block.
port_connected(Sock) ->
    try erlang:port_info(Sock, connected) catch _:_ -> {error, not_a_port} end.

%% The OS-level port number, which is what makes an fd-reuse diagnosis possible: two
%% conns reporting the same number while only one connection exists is the signature.
port_id(Sock) ->
    try erlang:port_info(Sock, port) catch _:_ -> {error, not_a_port} end.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% Queue depth and executing function. `current_stacktrace' rather than
%% `current_function', because the interesting case is a *deep* call -- a
%% `serve_headers_req' three frames down inside a DETS read -- and the top frame alone
%% reports `erlang:apply/2' for every one of them.
queue_len() ->
    case erlang:process_info(self(), message_queue_len) of
        {message_queue_len, N} -> N;
        _ -> -1
    end.

%% **How many of the queued messages are unanswered calls.**
%%
%% `queue_len/0' alone cannot say whether a backlog matters, because the messages in it are
%% not interchangeable. A `poll' costs this process up to `?POLL_MS' of blocking and is then
%% consumed instantly; a `'$gen_call'' sits behind whatever is already in flight and its
%% caller is counting the seconds. **A backlog of 20 that is 20 polls is a healthy
%% connection, and a backlog of 20 that is 18 calls is the sync failure -- and both print the
%% same number.**
%%
%% This is the number that decides between the two readings of a 20,000 ms call timeout, and
%% it is here because neither can be taken from outside the process any more: `net_peerCount'
%% answers from the manager and deliberately does not call the conn.
queued_calls() ->
    case erlang:process_info(self(), messages) of
        {messages, Msgs} -> length([M || M <- Msgs, is_gen_call(M)]);
        _ -> -1
    end.

is_gen_call({'$gen_call', _, _}) -> true;
is_gen_call(_) -> false.

%% A per-process counter, so the log says *which* call was long rather than how long the
%% conn was busy. It is in the process dictionary on purpose: it exists only for this log
%% line and threading an N through `handle_call/3' would change a signature for a message.
%% `{hash, <<32,186,185,102,240,97,35,140,...>>}' is 130-odd characters and the logger
%% wraps the line in the middle of it, so the *result* of the call ends up on a continuation
%% line and the whole entry becomes unmeasurable with a single grep. Printing the first 4
%% bytes is enough to tell one request from another.
%% **The negotiated message-code base, which decides whether a request is recognised at all.**
%% `get_headers' is sent as `Base + 3' and the receiver dispatches on the code *it*
%% negotiated, so two nodes that picked different forks cannot read each other's requests.
%% Measured on the pair in `tools/two-node-p2p.sh': `serve_headers_req ENTER' is logged
%% **zero** times on both nodes, so neither has ever seen a `get_headers' request. This is the
%% number that says whether the code or the wire is at fault.
eth_base(undefined) -> none;
eth_base(#{base := B}) -> B;
eth_base(_) -> '?'.

short_ref({hash, H}) when is_binary(H), byte_size(H) >= 4 -> {hash, binary:part(H, 0, 4)};
short_ref({number, N}) -> {number, N};
short_ref(Other) -> Other.

get_headers_n() ->
    N = case get(get_headers_n) of undefined -> 0; V -> V end,
    put(get_headers_n, N + 1),
    N.

%% `{ok, [H1, H2, ...]}' is 192 items long and erl_logger truncates it, so the shape is
%% reported and not the payload. `ok' is kept distinct from an error: "the peer answered and
%% the chain does not link" and "the peer never answered" have nothing in common, and a log
%% line that prints both as a term has already thrown one of them away.
tag_reply({ok, Hs}) when is_list(Hs) -> {ok, length(Hs)};
tag_reply({ok, Other}) -> {ok, Other};
tag_reply({error, _} = E) -> E;
tag_reply(Other) -> Other.

doing() ->
    case erlang:process_info(self(), current_stacktrace) of
        %% **The fourth element is the arity, an integer, not an argument list.**
        %% `length(A)' here is `length(0)' -- `exception error: bad argument' with
        %% `called as length(0)' -- and it was copied out of a scratch probe rather than
        %% written from the shape of the term. The stacktrace frame is `{M, F, Arity,
        %% Location}'.
        {current_stacktrace, [{M, F, Arity, _} | _]} ->
            lists:flatten(io_lib:format("~p:~p/~p", [M, F, Arity]));
        {current_stacktrace, []} ->
            "idle";
        _ ->
            "?"
    end.

id8(ID) when is_binary(ID), byte_size(ID) >= 8 ->
    binary:encode_hex(binary:part(ID, 0, 8));
id8(_) -> <<"?">>.

%% ---------------------------------------------------------------------------

reschedule_poll(S) ->
    erlang:send_after(?POLL_MS, self(), poll),
    S.

check_idle(S) ->
    case erlang:monotonic_time(millisecond) - S#st.last_in > ?IDLE_TIMEOUT_MS of
        true -> {stop, idle, S};
        false -> {noreply, S}
    end.

%% p2p messages: 0x01 disconnect, 0x02 ping, 0x03 pong. eth messages
%% (when negotiated) are matched first: GetBlockHeaders is served from the
%% local chain; anything else without a shared capability is ignored.
handle_msg(1, _Data, _S) ->
    {stop, remote_disconnect};
handle_msg(Code, Data, #st{eth = #{base := Base}} = S)
  when Code =:= Base + 3 ->
    serve_headers_req(Data, S);
handle_msg(Code, Data, #st{eth = #{base := Base}} = S)
  when Code =:= Base + 5 ->
    serve_bodies_req(Data, S);
handle_msg(Code, Data, #st{eth = #{base := Base}} = S)
  when Code =:= Base + 15 ->
    serve_receipts_req(Data, S);
handle_msg(Code, Data, #st{eth = #{base := Base}} = S)
  when Code =:= Base + 8 ->
    handle_pooled_hashes(Data, S);
handle_msg(Code, Data, #st{eth = #{base := Base}} = S)
  when Code =:= Base + 9 ->
    serve_pooled(Data, S);
handle_msg(Code, Data, #st{eth = #{snap := Snap}} = S) ->
    Base = maps:get(base, Snap),
    if Code =:= Base + 0 -> serve_account_range(Data, S, Snap);
       Code =:= Base + 2 -> serve_storage_range(Data, S, Snap);
       Code =:= Base + 4 -> serve_bytecodes(Data, S, Snap);
       true -> {ok, S}
    end;
handle_msg(2, _Data, S) ->
    case eth_rlpx:send(S#st.sess, S#st.sock, 3, eth_rlp:encode([])) of
        {ok, Sess1} -> {ok, S#st{sess = Sess1}};
        {error, Reason} -> {stop, Reason}
    end;
handle_msg(3, _Data, S) ->
    {ok, S};
handle_msg(_Code, _Data, S) ->
    {ok, S}.

serve_headers_req(Data, S) ->
    #{base := Base} = S#st.eth,
    case eth_eth:decode_get_headers_bin(Data) of
        {ok, Ref, Max, Skip, Reverse} ->
            case eth_eth:serve_headers(S#st.chain, Ref, Max, Skip, Reverse) of
                {ok, Headers} ->
                    case eth_rlpx:send(S#st.sess, S#st.sock,
                                       Base + 4, eth_rlp:encode(Headers)) of
                        {ok, Sess1} -> {ok, S#st{sess = Sess1}};
                        {error, Reason} -> {stop, Reason}
                    end;
                {error, _} ->
                    {ok, S}
            end;
        {error, _} ->
            {ok, S}
    end.

serve_bodies_req(Data, S) ->
    #{base := Base} = S#st.eth,
    case eth_eth:decode_get_bodies_bin(Data) of
        {ok, Hashes} ->
            case eth_eth:serve_bodies(S#st.chain, Hashes) of
                {ok, Bodies} ->
                    case eth_rlpx:send(S#st.sess, S#st.sock,
                                       Base + 6, eth_rlp:encode(Bodies)) of
                        {ok, Sess1} -> {ok, S#st{sess = Sess1}};
                        {error, Reason} -> {stop, Reason}
                    end;
                {error, _} ->
                    {ok, S}
            end;
        {error, _} ->
            {ok, S}
    end.

%% Snap serving from the leaf store. Proofs are empty: the store keeps
%% leaves, not inner trie nodes, so strict requesters will reject these
%% ranges (documented; full proof serving needs inner-node retention).
serve_account_range(Data, S, Snap) ->
    case eth_snap:decode_account_req_bin(Data) of
        {ok, _Root, Origin, Limit} ->
            {ok, Items} = store_account_range(S, Origin, Limit),
            Reply = [[H || {H, _} <- Items], [A || {_, A} <- Items], []],
            send_snap(S, Snap, 1, Reply);
        {error, _} ->
            {ok, S}
    end.

serve_storage_range(Data, S, Snap) ->
    case eth_snap:decode_storage_req_bin(Data) of
        {ok, _Root, Account, Origin, Limit} ->
            {ok, Items} = store_storage_range(S, Account, Origin, Limit),
            Reply = [[H || {H, _} <- Items], [V || {_, V} <- Items], []],
            send_snap(S, Snap, 3, Reply);
        {error, _} ->
            {ok, S}
    end.

serve_bytecodes(Data, S, Snap) ->
    case eth_snap:decode_bytecodes_bin(Data) of
        {ok, Codes} ->
            Reply = [store_code(S, H) || H <- Codes],
            send_snap(S, Snap, 5, Reply);
        {error, _} ->
            {ok, S}
    end.

send_snap(S, Snap, Offset, Term) ->
    Code = maps:get(base, Snap) + Offset,
    case eth_rlpx:send(S#st.sess, S#st.sock, Code, eth_rlp:encode(Term)) of
        {ok, Sess1} -> {ok, S#st{sess = Sess1}};
        {error, Reason} -> {stop, Reason, S}
    end.

store_account_range(S, Origin, Limit) ->
    Store = store_name(S),
    try eth_statestore:account_range(Store, Origin, Limit, 131072) of
        {ok, Items} -> {ok, Items}
    catch _:_ ->
        {ok, []}
    end.

store_storage_range(S, Account, Origin, Limit) ->
    Store = store_name(S),
    try eth_statestore:storage_range(Store, Account, Origin, Limit, 131072) of
        {ok, Items} -> {ok, Items}
    catch _:_ ->
        {ok, []}
    end.

store_code(S, H) ->
    Store = store_name(S),
    case try eth_statestore:get_code(Store, H) catch _:_ -> not_found end of
        {ok, Code} -> Code;
        _ -> <<>>
    end.

store_name(S) ->
    case S#st.store of
        undefined -> eth_statestore;
        Name -> Name
    end.

serve_receipts_req(Data, S) ->
    #{base := Base} = S#st.eth,
    case eth_eth:decode_get_receipts_bin(Data) of
        {ok, Hashes} ->
            case eth_eth:serve_receipts(S#st.chain, Hashes) of
                {ok, Receipts} ->
                    case eth_rlpx:send(S#st.sess, S#st.sock,
                                       Base + 16, eth_rlp:encode(Receipts)) of
                        {ok, Sess1} -> {ok, S#st{sess = Sess1}};
                        {error, Reason} -> {stop, Reason}
                    end;
                {error, _} ->
                    {ok, S}
            end;
        {error, _} ->
            {ok, S}
    end.

%% Inbound pooled-tx announcements: fetch the unknown ones and ingest
%% them into the pool (validation inside). Best-effort; failures drop.
handle_pooled_hashes(Data, S) ->
    #{base := Base} = S#st.eth,
    case eth_eth:decode_hashes_bin(Data) of
        {ok, Hashes} ->
            Wanted = [H || H <- Hashes, not pool_has(S, H)],
            case Wanted of
                [] ->
                    {ok, S};
                _ ->
                    Req = eth_rlp:encode(
                            eth_eth:encode_hashes(lists:sublist(Wanted, 128))),
                    case eth_rlpx:send(S#st.sess, S#st.sock, Base + 9, Req) of
                        {ok, Sess1} ->
                            await_pooled(S#st{sess = Sess1}, Base);
                        {error, Reason} ->
                            {stop, Reason, S}
                    end
            end;
        {error, _} ->
            {ok, S}
    end.

await_pooled(S, Base) ->
    case eth_rlpx:recv(S#st.sess, S#st.sock, 10000) of
        {ok, Code, Data, Sess1} when Code =:= Base + 10 ->
            S1 = S#st{sess = Sess1,
                      last_in = erlang:monotonic_time(millisecond)},
            case eth_eth:decode_pooled_bin(Data) of
                {ok, Txs} ->
                    lists:foreach(fun(T) -> ingest_pooled(S1, T) end, Txs),
                    {ok, S1};
                {error, _} ->
                    {ok, S1}
            end;
        {ok, _, _, Sess1} ->
            {ok, S#st{sess = Sess1}};
        {error, timeout} ->
            {ok, S};
        {error, Reason} ->
            {stop, Reason, S}
    end.

ingest_pooled(S, T) ->
    Bin = case T of
              B when is_binary(B) -> B;
              L when is_list(L) -> eth_rlp:encode(L)
          end,
    case (try eth_txpool:add_raw(pool_name(S), Bin) catch _:_ -> {error, no_pool} end) of
        {ok, _} -> ok;
        {error, _} -> ok
    end.

pool_has(S, H) ->
    Hex = <<"0x", (string:lowercase(binary:encode_hex(H)))/binary>>,
    try eth_txpool:has(pool_name(S), Hex)
    catch _:_ -> true
    end.

pool_name(S) ->
    case S#st.pool of
        undefined -> eth_txpool;
        Name -> Name
    end.

%% Serve our pooled transactions by hash (empty element when unknown).
serve_pooled(Data, S) ->
    #{base := Base} = S#st.eth,
    case eth_eth:decode_hashes_bin(Data) of
        {ok, Hashes} ->
            Txs = [pooled_term(S, H) || H <- Hashes],
            case eth_rlpx:send(S#st.sess, S#st.sock, Base + 10,
                               eth_rlp:encode(Txs)) of
                {ok, Sess1} -> {ok, S#st{sess = Sess1}};
                {error, Reason} -> {stop, Reason, S}
            end;
        {error, _} ->
            {ok, S}
    end.

pooled_term(S, H) ->
    Hex = <<"0x", (string:lowercase(binary:encode_hex(H)))/binary>>,
    case try eth_txpool:get(pool_name(S), Hex) catch _:_ -> not_found end of
        {ok, #{tx := Tx}} ->
            case eth_tx:to_rlp(Tx) of
                {ok, <<T, _/binary>> = Enc} when T =:= 16#01; T =:= 16#02; T =:= 16#03 ->
                    Enc;
                {ok, Enc} ->
                    case eth_rlp:decode(Enc) of
                        {ok, Term, <<>>} -> Term;
                        _ -> []
                    end;
                {error, _} ->
                    []
            end;
        _ ->
            []
    end.

%% Snap request/response round trip returning the decoded reply term
%% (verification is the caller's job). Offsets relative to snap base.
snap_call(S, SendOff, ExpectOff, EncReq) ->
    case S#st.eth of
        #{snap := Snap} ->
            Base = maps:get(base, Snap),
            Decode = fun(Data) ->
                case eth_rlp:decode(Data) of
                    {ok, Term, _} -> {ok, Term};
                    {error, _} = E -> E
                end
            end,
            {Reply, S1} = fetch_request(S#st{fetching = true}, Base + SendOff,
                                        EncReq, Base + ExpectOff,
                                        Decode, fun(_) -> ok end),
            S2 = S1#st{fetching = false},
            erlang:send_after(?POLL_MS, self(), poll),
            {reply, Reply, S2};
        _ ->
            {reply, {error, no_snap}, S}
    end.

%% Outbound request/response round trip: send a request and block in the
%% call while waiting for the matching response code (Ping is answered
%% inline, Disconnect stops). Decode/Verify decode and check the body.
%% Returns {Reply, State} so framing state survives.
fetch_request(S, SendCode, EncReq, ExpectCode, Decode, Verify) ->
    case eth_rlpx:send(S#st.sess, S#st.sock, SendCode, EncReq) of
        {ok, Sess1} ->
            fetch_wait(S#st{sess = Sess1}, ExpectCode, Decode, Verify,
                       erlang:monotonic_time(millisecond) + 15000);
        {error, _} = E ->
            {E, S}
    end.

fetch_wait(S, ExpectCode, Decode, Verify, Deadline) ->
    Timeout = max(1, Deadline - erlang:monotonic_time(millisecond)),
    case eth_rlpx:recv(S#st.sess, S#st.sock, Timeout) of
        {ok, Code, Data, Sess1} when Code =:= ExpectCode ->
            S1 = S#st{sess = Sess1,
                      last_in = erlang:monotonic_time(millisecond)},
            case Decode(Data) of
                {ok, Term} ->
                    case Verify(Term) of
                        ok -> {{ok, Term}, S1};
                        {error, _} = E -> {E, S1}
                    end;
                {error, _} = E ->
                    {E, S1}
            end;
        {ok, 2, _, Sess1} ->
            S1 = S#st{sess = Sess1,
                      last_in = erlang:monotonic_time(millisecond)},
            case eth_rlpx:send(Sess1, S#st.sock, 3, eth_rlp:encode([])) of
                {ok, Sess2} -> fetch_wait(S1#st{sess = Sess2}, ExpectCode, Decode, Verify, Deadline);
                {error, _} = E -> {E, S1}
            end;
        {ok, 1, _, Sess1} ->
            {{error, remote_disconnect}, S#st{sess = Sess1}};
        {ok, Other, Data, Sess1} ->
            %% **A fetch must not make this process deaf.**
            %%
            %% Anything that is not the awaited response used to be **discarded**, and
            %% `handle_info(poll, #st{fetching = true}, ...)` does not read the socket at all
            %% while a fetch owns it. So for the whole 15,000 ms of a fetch this process
            %% answered nobody -- and on two nodes that fetch from each other, neither one
            %% ever sees the other's request.
            %%
            %% **Measured, on the pair in `tools/two-node-p2p.sh`.** Both nodes logged
            %% `get_headers n=.. ms=15002..15006 -> {error, ..}` over and over, to the
            %% millisecond of the fetch deadline, with **one success in thirteen at 13 ms**.
            %% That 13 ms is the whole finding: it is the only moment either side was not
            %% inside a fetch, and the only request either side answered. The failures were
            %% never a slow peer. They were a deaf one.
            %%
            %% The Ping clause two cases above already replies inline, so this is that same
            %% treatment extended to every code -- which is what a devp2p peer must do:
            %% serving a peer while fetching is normal, not an exception.
            S1a = S#st{sess = Sess1, last_in = erlang:monotonic_time(millisecond)},
            %% **Proof that the deafness is gone.** This line only exists when a frame
            %% arrived *during* a fetch and was served inline, which is the whole point:
            %% `handle_info(poll, #st{fetching = true}, ...)' still does not read the socket,
            %% so a zero here means the conn is answering nobody and the peer is being
            %% starved by its own outbound request.
            logger:notice("etherlang: fetch_wait served an unrequested frame code=~p "
                          "bytes=~p", [Other, byte_size(Data)]),
            case handle_msg(Other, Data, S1a) of
                {ok, S2} -> fetch_wait(S2, ExpectCode, Decode, Verify, Deadline);
                {stop, Reason} -> {{error, Reason}, S1a}
            end;
        {error, timeout} ->
            case Deadline > erlang:monotonic_time(millisecond) of
                true -> fetch_wait(S, ExpectCode, Decode, Verify, Deadline);
                false -> {{error, timeout}, S}
            end;
        {error, _} = E ->
            {E, S}
    end.

to_skip(Skip) ->
    case Skip of
        I when is_integer(I) -> I;
        _ -> 0
    end.

eth_ready(#st{eth = undefined}) -> false;
eth_ready(#st{eth = #{version := V, status := Their} = Eth}) ->
    #{version => V, head => maps:get(best, Their, undefined),
      snap => maps:is_key(snap, Eth)}.
