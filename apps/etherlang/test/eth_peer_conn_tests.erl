-module(eth_peer_conn_tests).

%% The stub pool at the bottom of this file is a real `gen_server', so its
%% callbacks are looked up by the framework rather than called from here --
%% which the compiler reports as unused unless they are exported.
-export([init/1, handle_call/3, handle_cast/2]).

%% Remote-input survival for `eth_peer_conn'.
%%
%% `handle_msg/3' dispatches on a message code the remote peer chooses, and every
%% one of its eight handlers is reached from `handle_info(poll, S)' with no error
%% boundary around the dispatch. `eth_discv4' had exactly that shape and it was a
%% remote crash (D-14/F13): `handle_findnode/5' fed a two-element FindNode target
%% to `crypto:exor/2' through `distance/2' and six packets in ten seconds took the
%% application down.
%%
%% These tests are the answer to the question that finding raised about *this*
%% dispatch point: **can a remote peer kill a connection here?** The answer, as of
%% 2026-10-03, is no -- and that is a measurement, not an assurance. Twenty-one
%% hostile payloads across all seven dispatched codes left the connection up and
%% answering every time (a wider 49-payload probe found the same). The reason is
%% that the surface really is guarded, in four places that are easy to miss and
%% easy to break:
%%
%%   * `eth_snappy:decompress/1' is total. `get_varint/3' answers the atom `error'
%%     rather than raising, every `decode/3' clause ends in `{error, _}', and
%%     `do_copy/5' range-checks the offset before `append_copy/4' indexes with it.
%%   * `eth_eth:decode_get_headers_bin/1', `decode_get_bodies_bin/1' and
%%     `decode_pooled_bin/1' each wrap their `eth_rlp:decode/1' in a `try' **and**
%%     validate the decoded shape -- `wellformed_pooled/1' is the only thing
%%     stopping a peer handing `ingest_pooled/2' an RLP integer, which that
%%     function's two-clause `case' cannot match. The guard is load-bearing: it
%%     lives in the decoder, not at the use site.
%%   * `eth_rlpx:recv_frame_header/5' and `recv_frame_body/6' answer
%%     `bad_header_mac', `bad_frame_mac', `frame_too_large', `short_header' and
%%     `bad_rlp', and `to_int/1' has a catch-all.
%%   * `eth_eth:walk/6' guards `Num >= 0' and wraps the chain read, so an
%%     arbitrary `Skip' walks off the end instead of looping.
%%
%% So there is no error boundary here because nothing needed one, and adding one
%% now would be defence-in depth against a crash this file cannot reproduce --
%% which is a gap to record, not a fix to claim. What *is* worth pinning is the
%% property itself, so that a future change which removes one of those four
%% guards fails here instead of in production.
%%
%% **What this file does NOT cover, stated because a sweep that reports only "0
%% crashes" is indistinguishable from one that tested nothing.** Every payload
%% here goes out through `eth_rlpx:send/4', which compresses correctly and
%% unconditionally, so **a malformed snappy stream cannot be produced by this
%% harness** -- the peer would have to hand `eth_snappy:decompress/1' bytes that
%% `eth_snappy:compress/1' would never emit. Injecting a raise into
%% `eth_snappy:get_varint/3''s catch-all and re-running this file changes
%% nothing, for exactly that reason; injecting one into `serve_headers_req/2' or
%% into `handle_msg/3''s dispatch arm does fail it. That input is the one every
%% remote message passes through *first*, and the harness cannot reach it:
%% `send_frame/4' is not exported and `send/4' always compresses, so reaching it
%% means reimplementing the AES-CTR framing, which is a second copy of the code
%% under test and worse than the gap it would close. `eth_snappy:decompress/1''s
%% totality therefore rests on reading it, not on this test, and that is the
%% honest position.
%%
%% **The control is a separate test, not a counter inside the sweep.** "No
%% payload crashed anything" is also what a sweep reports when every payload was
%% rejected before dispatch, so `cases/0' includes `huge-max-skip' -- a
%% *well-formed* GetBlockHeaders/GetBlockBodies/GetBlockReceipts body with
%% `Max = Skip = 255' and an unknown block reference, which is decoded,
%% dispatched and actually served -- and
%% `a_well_formed_request_is_answered_so_the_sweep_is_not_vacuous/0' asserts one
%% such reply explicitly. A sweep whose payloads all bounce in the decoder passes
%% the survival assertion while testing nothing.

-include_lib("eunit/include/eunit.hrl").
-behaviour(gen_server).

%% ---------------------------------------------------------------------------
%% A pool that knows about no hashes.
%% ---------------------------------------------------------------------------
%% `eth_peer_conn:pool_has/2' maps an unreachable pool to `true', so with no
%% txpool running every announced hash reads as "already known" and the
%% pooled-fetch path is never entered. Answering `false' is what reaches it, and
%% the second test needs it.

init(_) -> {ok, #{}}.
handle_call({has, _}, _F, S) -> {reply, false, S};
handle_call({add_raw, _}, _F, S) -> {reply, {ok, stub}, S};
handle_call(_, _F, S) -> {reply, {error, unknown}, S}.
handle_cast(_, S) -> {noreply, S}.

%% No `handle_info/2' clause on purpose: nothing sends this process a plain
%% message, and an unused callback is a build failure here.

%% ---------------------------------------------------------------------------
%% Test 1: hostile payloads do not bring the connection down
%% ---------------------------------------------------------------------------

hostile_payloads_do_not_bring_down_a_peer_connection_test_() ->
    {timeout, 180, fun hostile_payloads_do_not_bring_down_a_peer_connection/0}.

hostile_payloads_do_not_bring_down_a_peer_connection() ->
    Peer = start_victim("h1"),
    Conn = maps:get(conn, Peer),
    Sock = maps:get(sock, Peer),
    MRef = monitor(process, Conn),
    try
        {_Sess, Results} =
            lists:foldl(
              fun({Code, Body}, {S, Acc}) ->
                  {ok, S1} = eth_rlpx:send(S, Sock, Code, Body),
                  timer:sleep(250),
                  %% Drain every frame the connection sends. This is not
                  %% housekeeping: the session's AES/MAC state advances on both
                  %% sides, so a frame left unread makes the *next* `recv' decrypt
                  %% with stale state and report `bad_frame_mac' -- which reads as
                  %% the node rejecting a payload it actually answered.
                  {S2, _Replied} = drain(S1, Sock, 0),
                  Down = down(MRef),
                  Reply = call_conn(Conn),
                  {S2, [{Code, Down, Reply} | Acc]}
              end, {maps:get(sess, Peer), []}, cases()),
        Results1 = lists:reverse(Results),
        %% Any payload that brought the connection down, named by code.
        ?assertEqual([], [C || {C, Down, _R} <- Results1, Down =/= still_up]),
        %% Every payload: the connection answered a status call.
        ?assertEqual([], [{C, Rep} || {C, still_up, Rep} <- Results1,
                                      Rep =/= responsive]),
        io:format("~n  ~p hostile payloads, connection up and answering after each~n",
                  [length(Results1)])
    after
        cleanup(Peer, MRef)
    end.

%% The control, as its own step. A sweep in which every payload bounced in the
%% decoder would pass "nothing crashed" while testing nothing, so one
%% **well-formed** request is sent and the reply is awaited explicitly. Without
%% it this file could go on reporting 0 crashes while proving less each time a
%% decoder grew a stricter check.
%%
%% `huge-max-skip' is `[[[0xff, 0xff, 0xff]], 255, 255, 1]' -- a valid
%% GetBlockHeaders body naming three unknown blocks, 255 headers and a skip of
%% 255. It decodes, dispatches, reaches `eth_eth:serve_headers/5' and produces a
%% Headers reply at code 20 (eth base + 4). Code 16 is `Status' and 19 is
%% `GetBlockHeaders', so seeing 20 can only mean the payload was served.
a_well_formed_request_is_answered_so_the_sweep_is_not_vacuous_test_() ->
    {timeout, 60, fun a_well_formed_request_is_answered_so_the_sweep_is_not_vacuous/0}.

a_well_formed_request_is_answered_so_the_sweep_is_not_vacuous() ->
    Peer = start_victim("h3"),
    try
        {Sess, Sock} = {maps:get(sess, Peer), maps:get(sock, Peer)},
        {ok, S1} = eth_rlpx:send(Sess, Sock, 16 + 3,
                                 eth_rlp:encode([[[16#ff, 16#ff, 16#ff]], 255, 255, 1])),
        {_S2, SawHeaders} = drain_until(S1, Sock, 16 + 4, 6000),
        ?assertEqual(true, SawHeaders)
    after
        cleanup(Peer, undefined)
    end.

%% ---------------------------------------------------------------------------
%% Test 2: a pooled-hash announcement stalls its own connection and nothing else
%% ---------------------------------------------------------------------------
%% Measured 2026-10-03, before this test existed. One
%% `NewPooledTransactionHashes' (eth base + 8) carrying a single hash the pool
%% does not have sends `handle_msg/3' into `handle_pooled_hashes/2', which asks
%% for the transactions and then blocks in `await_pooled/2' -- a
%% `gen_tcp:recv' with a **ten-second** timeout -- on the connection's own
%% process, inside the poll handler. Measured: the peer answered with code 25
%% (`GetPooledTransactions', so the path definitely ran), a `status' call timed
%% out at 1500 ms, and a second one was answered 8497 ms later.
%%
%% **This is D-15's shape one layer down, and it is not the same severity**, which
%% is the thing worth pinning. D-15 blocked `eth_peer' -- one process shared by
%% every peer -- so a single connection took down `eth_peer:peers/0' for
%% everybody. Here the blocked process is per-connection, so a peer can only
%% stall its own connection. The manager stays answerable throughout, and that
%% difference is the whole of the severity claim; if someone ever shares the
%% reader between connections, this test is what notices.
%%
%% It also is not permanent: the ten-second deadline is inside `await_pooled/2',
%% so the connection comes back. Pinning the recovery matters as much as pinning
%% the stall -- an *unbounded* wedge would be a different and much worse finding,
%% and nothing else in the suite would notice it.

a_pooled_hash_announcement_stalls_only_its_own_connection_test_() ->
    {timeout, 120, fun a_pooled_hash_announcement_stalls_only_its_own_connection/0}.

a_pooled_hash_announcement_stalls_only_its_own_connection() ->
    Peer = start_victim("h2"),
    Mgr = maps:get(mgr, Peer),
    Conn = maps:get(conn, Peer),
    Sock = maps:get(sock, Peer),
    try
        {ok, S1} = eth_rlpx:send(maps:get(sess, Peer), Sock, 16 + 8,
                                 eth_rlp:encode([[<<2:256>>]])),
        %% Wait for the request to be **on the wire**, rather than hoping the
        %% connection's poll timer has fired. `?POLL_MS' is 1000, so a fixed sleep
        %% is a race -- and a race that reads as "the stall is gone" when it wins.
        %% Code 25 is `GetPooledTransactions' (eth base + 9), so seeing it is also
        %% the control for this test: it says the pooled path really ran.
        {_, SawGet} = drain_until(S1, Sock, 16 + 9, 6000),
        ?assertEqual(true, SawGet),
        %% The manager -- shared by every peer -- is unaffected.
        ?assertEqual(responsive, call_mgr(Mgr)),
        %% The connection itself is not answering.
        ?assertEqual(wedged, call_conn(Conn)),
        %% And it comes back: the deadline is inside await_pooled/2.
        ?assertEqual(responsive, call_conn_slow(Conn, 13000))
    after
        cleanup(Peer, undefined)
    end.

%% ---------------------------------------------------------------------------
%% Harness: a real eth_peer, and this process as its handshaked remote peer
%% ---------------------------------------------------------------------------
%%
%% `eth_peer_tests:autodial/0' already builds two of these against each other,
%% but a test that wants to send *arbitrary* frames needs to be the remote side,
%% so it does the handshake itself. `eth_rlpx:dial/5', `hello/3', `send/4' and
%% `recv/3' are all exported, which is enough to be a peer.

start_victim(Tag) ->
    %% **This must be pinned, and it is not hygiene -- it is load-bearing.**
    %% `eth_eth:status_data/1' calls `total_difficulty/0', which is a live
    %% `eth_rpc_client:call(<<"eth_getBlockByNumber">>, [<<"latest">>, false])'.
    %% `eth_peer_conn:maybe_eth/3' calls `status_data/1' *inside the p2p
    %% handshake*, so with the RPC client pointed anywhere reachable -- and under
    %% `rebar3 eunit' the application is started, so it is -- the victim's Status
    %% arrives **6 seconds** late and this harness times out before it does.
    %% Measured: `status_data/1' took 6059 ms and 6004 ms on two consecutive runs,
    %% and the same code outside eunit returns instantly because the client is not
    %% initialised and the call exits `noproc' immediately.
    %% Unreachable loopback with no retries is the same fixture `eth_peer_tests'
    %% uses, and it turns the fetch into an immediate failure so
    %% `total_difficulty/0' takes its `?FALLBACK_TD' branch.
    ok = eth_rpc_client:init(#{url => "http://127.0.0.1:1", timeout_ms => 1000,
                               retries => 0, backoff_ms => 10}),
    Priv = eth_secp256k1:generate_key(),
    NodeID = eth_ecies:pubkey(Priv),
    Chain = chain_name(Tag),
    Peer = peer_name(Tag),
    Pool = pool_name(Tag),
    Dir = eth_test_util:tmp_dir(),
    {ok, _} = eth_chain:start_link(Chain, Dir),
    {_, Blocks} = eth_test_util:make_blocks(0, 3, z0(), 0),
    ok = eth_chain:append(Chain, [{eth_hex:decode(maps:get(<<"number">>, B)),
                                   B, true} || B <- Blocks]),
    {ok, _} = gen_server:start_link({local, Pool}, ?MODULE, [], []),
    {ok, Mgr} = eth_peer:start_link(#{name => Peer, port => 0, privkey => Priv,
                                       target => 0, interval => 60000,
                                       chain => Chain, pool => Pool}),
    %% The link is not what these tests are about, and keeping it would mean the
    %% hard kill in `cleanup/2' takes the test process down with the manager --
    %% which eunit reports as "unexpected termination of test process" rather than
    %% as the assertion it is.
    unlink(Mgr),
    #{port := Port} = gen_server:call(Mgr, status),
    MyPriv = eth_secp256k1:generate_key(),
    {ok, S0, Sock} = eth_rlpx:dial({127, 0, 0, 1}, Port, MyPriv, NodeID, 5000),
    {ok, S1, _TheirHello} =
        eth_rlpx:hello(S0, Sock, #{node_id => eth_ecies:pubkey(MyPriv),
                                   caps => [{"eth", 68}, {"snap", 1}],
                                   listen_port => 0}),
    %% Their Status. A `{error, timeout}' here is not a framing problem: it is
    %% the upstream fetch in `total_difficulty/0' that the note above pins, and it
    %% arrives six seconds late.
    {ok, Code, Data, S2} = eth_rlpx:recv(S1, Sock, 5000),
    {ok, TheirStatus} = eth_eth:decode_status_bin(Data),
    %% Send their own status back. `check_status/2' compares network id, genesis
    %% and fork id against our own head, so echoing what they sent satisfies all
    %% three by construction -- which is the only way to get a working harness
    %% without reimplementing the node's fork-id state.
    {ok, S3} = eth_rlpx:send(S2, Sock, Code,
                             eth_rlp:encode(eth_eth:encode_status(TheirStatus))),
    timer:sleep(300),
    [{Conn, _St}] = eth_peer:peers(Peer),
    #{mgr => Mgr, conn => Conn, sock => Sock, sess => S3,
      chain => Chain, peer => Peer, pool => Pool}.

z0() -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>.

chain_name(T) -> list_to_atom("pc_chain_" ++ T).
peer_name(T) -> list_to_atom("pc_peer_" ++ T).
pool_name(T) -> list_to_atom("pc_pool_" ++ T).

cleanup(Peer, MRef) ->
    (case MRef of
         undefined -> ok;
         _ -> (try demonitor(MRef, [flush]) catch _:_ -> ok end)
     end),
    (try gen_server:stop(maps:get(mgr, Peer), kill, 1000) catch _:_ -> ok end),
    ok.

%% ---------------------------------------------------------------------------
%% Cases
%% ---------------------------------------------------------------------------
%% Eth sits at base 16 and snap at base 33 once both capabilities are shared
%% (`eth_eth:negotiate_caps/2' sorts by name and starts at 16). The three shapes
%% per code are chosen to be three different things:
%%
%%   * `garbage-empty' -- zero bytes of payload.
%%   * `huge-max-skip' -- **well formed**, so it is decoded, dispatched and
%%     served. This is the control; without it the sweep proves nothing.
%%   * `huge-string' -- an RLP long-string prefix claiming 1,032,440 bytes with
%%     none present, which is what a peer sends to make a decoder work.

cases() ->
    Eth = 16,
    Snap = 33,
    [{Code, Body}
     || Code <- [Eth + 3, Eth + 5, Eth + 15, Eth + 9,
                 Snap + 0, Snap + 2, Snap + 4],
        Body <- [<<>>,
                  eth_rlp:encode([[[16#ff, 16#ff, 16#ff]], 255, 255, 1]),
                  <<16#b9, 16#3f, 16#f8>>]].

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

drain(S, Sock, N) when N < 50 ->
    case eth_rlpx:recv(S, Sock, 200) of
        {ok, _, _, S1} -> drain(S1, Sock, N + 1);
        {error, _} -> {S, N}
    end;
drain(S, _Sock, N) -> {S, N}.

%% Read frames until one carries `Want' or the budget runs out. Returns whether
%% it was seen, so a caller can assert on the request rather than on a delay.
drain_until(S, Sock, Want, Budget) ->
    T0 = erlang:monotonic_time(millisecond),
    drain_until(S, Sock, Want, Budget, T0, false).

drain_until(S, Sock, Want, Budget, T0, Seen) ->
    Left = Budget - (erlang:monotonic_time(millisecond) - T0),
    if
        Left =< 0 -> {S, Seen};
        true ->
            case eth_rlpx:recv(S, Sock, min(Left, 400)) of
                {ok, Want, _, S1} -> drain_until(S1, Sock, Want, Budget, T0, true);
                {ok, _, _, S1} -> drain_until(S1, Sock, Want, Budget, T0, Seen);
                %% A timeout is the *expected* answer here most of the time: the
                %% connection polls once a second, so most 400 ms windows are
                %% empty. Only a framing or transport error ends the wait.
                {error, timeout} ->
                    drain_until(S, Sock, Want, Budget, T0, Seen);
                {error, _} ->
                    {S, Seen}
            end
    end.

down(MRef) ->
    receive {'DOWN', MRef, _, _, R} -> R after 0 -> still_up end.

call_conn(Pid) -> call_with(Pid, 1000).

%% `await_pooled/2' blocks for ten seconds, so recovering needs more than the
%% one-second bound the survival test uses.
call_conn_slow(Pid, T) -> call_with(Pid, T).

call_with(Pid, Timeout) ->
    try gen_server:call(Pid, status, Timeout) of
        _ -> responsive
    catch
        exit:{timeout, _} -> wedged
    end.

call_mgr(Mgr) -> call_with(Mgr, 1000).