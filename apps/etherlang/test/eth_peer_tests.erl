-module(eth_peer_tests).

-include_lib("eunit/include/eunit.hrl").

z0() -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>.

%% Full loopback: discA bonds discB over UDP, peerA auto-dials B over TCP
%% from discA's table, both sides complete the eth handshake. peerB stays
%% passive (target 0) so exactly one connection forms.
autodial_test_() ->
    {timeout, 90, fun autodial/0}.

autodial() ->
    eth_rpc_client:init(#{url => "http://127.0.0.1:1", timeout_ms => 1000,
                          retries => 0, backoff_ms => 10}),
    Dir = eth_test_util:tmp_dir(),
    {ok, _} = eth_chain:start_link(chain_ad_ab, Dir),
    try
        {_, Blocks} = eth_test_util:make_blocks(0, 3, z0(), 0),
        ok = eth_chain:append(chain_ad_ab, pair(Blocks)),
        PrivA = eth_secp256k1:generate_key(),
        PrivB = eth_secp256k1:generate_key(),
        %% B uses one fixed port for UDP discovery and TCP RLPx (the
        %% production shape: a single enode port serves both).
        BPort = eth_test_util:free_port(),
        {ok, _} = eth_discv4:start_link(#{name => disc_ad_b, port => BPort,
                                          privkey => PrivB, bootnodes => []}),
        #{port := UdpB, id := IDB} = eth_discv4:status(disc_ad_b),
        EnodeB = lists:flatten(io_lib:format("enode://~s@127.0.0.1:~p",
                                             [binary_to_list(binary:encode_hex(IDB)),
                                              UdpB])),
        {ok, _} = eth_discv4:start_link(#{name => disc_ad_a, port => 0,
                                          privkey => PrivA,
                                          bootnodes => [EnodeB]}),
        %% A's own discovery id: `peer_ad_b' needs it to be told *which* accepted
        %% connection is the one it should be reporting.
        #{id := IDA} = eth_discv4:status(disc_ad_a),
        {ok, _} = eth_peer:start_link(#{name => peer_ad_b, port => BPort,
                                        privkey => PrivB, disc => disc_ad_b,
                                        target => 0, interval => 200,
                                        chain => chain_ad_ab}),
        {ok, _} = eth_peer:start_link(#{name => peer_ad_a, port => 0,
                                        privkey => PrivA, disc => disc_ad_a,
                                        target => 2, interval => 200,
                                        chain => chain_ad_ab}),
        try
            ok = wait_eth_peer(peer_ad_a, IDB, 200),
            %% Exactly one connection to B (no duplicate dials).
            ?assertEqual(1, count_remote(peer_ad_a, IDB)),
                          %% **Both sides count the peer, and the two sides are not interchangeable.**
              %%
              %% `peer_ad_b' has `target => 0', so it never dials: its only entry comes
              %% from the **accept** path. `peer_ad_a' dials, so its entry comes from the
              %% **dial** path, and the two paths used to build that entry differently.
              %%
              %% This is the positive assertion that was recorded here as unwritable, and
              %% it is now writable for two separate reasons -- both had to be fixed, and
              %% either one alone leaves it red:
              %%
              %%   * `wait_eth_peer/3' polls `peers/0', which used to call into each conn
              %%     with a 2 s timeout. Asserting a count right after proved the peer
              %%     existed and then got 0 microseconds later, because the conn was inside
              %%     `fetch_request/6' and could not answer. **That was not the connection
              %%     dying, as the comment here used to say**: `peers/0' now answers from
              %%     the manager's own state, so there is nothing to time out.
              %%   * `peer_ad_b' is where the real defect was. `handle_info({accepted,
              %%     ...})' **replaced** the peer entry with `#{ref => MRef}' *after*
              %%     `peer_up' had already put `remote', `hello' and `eth' in it, so the
              %%     accepted peer held none of the three. `wait_eth_peer(peer_ad_b, ...)'
              %%     could never succeed at all, and no positive assertion on the
              %%     accepting side was possible.
              %%
              %% Both sides are asserted, and `peer_ad_b` is the one that bites on the
              %% second. The negative case is covered separately
              %% (`net_peer_count_is_zero_when_there_are_no_peers_test_'), so what is added
              %% here is that a *non-zero* count is distinguishable from a hardcoded `0x0'.
              ok = wait_eth_peer(peer_ad_b, IDA, 200),
              ?assertEqual(1, count_remote(peer_ad_b, IDA)),
              ?assertEqual(1, eth_peer:eth_peer_count(peer_ad_a)),
              ?assertEqual(1, eth_peer:eth_peer_count(peer_ad_b)),
            %% Headers flow over the auto-dialed connection.
            {ok, Hdrs} = eth_peer:get_headers(peer_ad_a, {number, 0}, 2, 0, false),
            ?assertEqual([0, 1], [header_num(H) || H <- Hdrs]),
            %% **A peer that cannot answer a message is still a peer.**
            %%
            %% This is the defect, stated as an assertion. `eth_peer:peers/0' used to be
            %% `[{Pid, peer_status(Pid)}]' -- one `gen_server:call(Pid, status, 2000)' per
            %% peer -- and a conn executing `fetch_request/6' inside
            %% `handle_call({get_headers, ...})' owns `recv' for up to **15 seconds**, so it
            %% could answer nothing in that window. `peer_status/1' gave up after 2 and
            %% answered `{error, down}', `eth_ready_peer/1' filters on `is_map(Info)', and
            %% `eth_sync' -- whose gate that is -- never started.
            %%
            %% `sys:suspend/1' makes the case deterministic instead of racy: the conn is
            %% provably unable to answer anything, and the answer must not change.
            %%
            %% Injecting the `gen_server:call' back into `handle_call(peers, ...)' turns
            %% this red with `{error, down}'.
            {ConnPid, Info0} = hd(eth_peer:peers(peer_ad_a)),
            ?assertEqual(true, maps:get(eth, Info0) =/= false),
            ok = sys:suspend(ConnPid),
            try
                [{ConnPid, Info1} | _] = eth_peer:peers(peer_ad_a),
                ?assertEqual(true, maps:get(eth, Info1) =/= false),
                %% `eth_peer_count/1' uses `eth_ready_peer/1's predicate verbatim, and
                %% `eth_sync' gates on that, so this is the number that starts the sync.
                ?assertEqual(1, eth_peer:eth_peer_count(peer_ad_a))
            after
                ok = sys:resume(ConnPid)
            end
        after
            stop(peer_ad_a), stop(peer_ad_b),
            stop(disc_ad_a), stop(disc_ad_b)
        end
    after
        (try gen_server:stop(chain_ad_ab) catch _:_ -> ok end)
    end.

%% No discovery source: no tick, no dials, listener still works.
no_disc_test() ->
    {ok, _} = eth_peer:start_link(#{name => peer_nodisc, port => 0,
                                    privkey => eth_secp256k1:generate_key()}),
    try
        timer:sleep(300),
        #{peers := 0} = eth_peer:status(peer_nodisc)
    after
        stop(peer_nodisc)
    end.

wait_eth_peer(_Name, _ID, 0) -> error(autodial_timeout);
wait_eth_peer(Name, ID, N) ->
    Infos = eth_peer:peers(Name),
    case [P || {P, I} <- Infos, is_map(I),
               maps:get(eth, I, false) =/= false,
               maps:get(remote, I, undefined) =:= ID] of
        [_ | _] -> ok;
        [] -> timer:sleep(100), wait_eth_peer(Name, ID, N - 1)
    end.

count_remote(Name, ID) ->
    Infos = eth_peer:peers(Name),
    length([P || {P, I} <- Infos, is_map(I),
                 maps:get(remote, I, undefined) =:= ID]).

header_num(H) ->
    case lists:nth(9, H) of
        I when is_integer(I) -> I;
        B when is_binary(B) -> binary:decode_unsigned(B)
    end.

pair(Blocks) ->
    [{eth_hex:decode(maps:get(<<"number">>, B)), B, true} || B <- Blocks].

stop(Name) -> (try gen_server:stop(Name) catch _:_ -> ok end).

%% ---------------------------------------------------------------------------
%% D-15: an inbound connection that stalls in the handshake must not stall the
%% peer manager
%% ---------------------------------------------------------------------------
%%
%% `handle_info(accept, S)' called `eth_peer_conn:start_recipient_unlinked/3'
%% inline, and `gen_server:start/3' does not return until `init/1' has acked --
%% so the manager sat inside `eth_rlpx:recipient/3' for its full ten-second
%% timeout. One TCP connection that sent nothing at all took the manager with it:
%% no `dial_tick', no `DOWN' handling, no `peer_up', and `eth_peer:peers/0' --
%% which `eth_sync:eth_ready_peers/1' and `eth_statesync:snap_peer/1' both poll --
%% blocked behind it.
%%
%% **The tell is the number.** A blocking `gen_tcp:accept/2' answers within its own
%% one-second timeout, so "the manager is slow" is not the claim. "The manager is
%% unreachable for longer than any accept timeout it has" is, and 3 s sits
%% comfortably outside one second and inside the handshake's ten.
%%
%% Measured on the unfixed tree: `timed_out' at t=2.2, 4.4, 6.6 and 8.8 s, with
%% `rlpx inbound handshake failed (timeout)' logged at t≈11 s -- the manager
%% answering again only once that landed.
%%
%% The teardown is a hard kill **because the failure mode is a process that cannot
%% be stopped politely**. `gen_server:stop/1' goes through `sys:send_system_msg'
%% with a five-second timeout, and against a manager that is by construction stuck
%% in `init/1' it times out too -- so the first version of this test was *cancelled*
%% in cleanup rather than failing on its assertion, which is a worse report of the
%% same fact.
inbound_handshake_does_not_block_the_peer_manager_test_() ->
    {timeout, 60, fun inbound_handshake_does_not_block_the_peer_manager/0}.

inbound_handshake_does_not_block_the_peer_manager() ->
    Priv = eth_secp256k1:generate_key(),
    Cfg = #{name => d15_peer, port => 0, privkey => Priv,
            target => 0, interval => 60000},
    {ok, Pid} = eth_peer:start_link(Cfg),
    %% The link is not what this test is about, and keeping it would mean the hard
    %% kill in the teardown takes the test process down with the manager -- which
    %% reads as "unexpected termination" rather than as the assertion it is.
    unlink(Pid),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, d15_port(Pid),
                                 [binary, {active, false}], 2000),
    try
        timer:sleep(500),
        ?assertEqual(answered, d15_ask(Pid, status, 3000)),
        %% And again, so one fast answer is not mistaken for a fix.
        ?assertEqual(answered, d15_ask(Pid, status, 3000))
    after
        (try gen_tcp:close(Sock) catch _:_ -> ok end),
        (try gen_server:stop(Pid, kill, 1000) catch _:_ -> ok end)
    end.

d15_port(Pid) -> maps:get(port, gen_server:call(Pid, status, 2000)).

d15_ask(Pid, Req, Timeout) ->
    try gen_server:call(Pid, Req, Timeout) of
        _ -> answered
    catch
        exit:{timeout, _} -> timed_out
    end.

%% ---------------------------------------------------------------------------
%% D-15 (second half): a peer manager with no connections at all answers at once
%% ---------------------------------------------------------------------------
%%
%% The other half of the same defect, and the half that is *always* present. The
%% fixed `handle_info(accept, S)' used to call `gen_tcp:accept(S#st.lsock, 1000)',
%% so with nothing connecting the manager sat inside that call for a one-second
%% slice at a time, forever, and every other message -- including a
%% `gen_server:call' -- waited behind the current slice.
%%
%% Measured on the unfixed tree over 20 idle calls: **798 ms min, 1001 ms median,
%% 1004 ms max**. After the fix: **1 us min, 2 us median, 67 us max**. The two
%% ranges do not come close, which is what lets the threshold below be a
%% separator rather than a tolerance -- and it is also why this is worth a test
%% rather than a note: nothing about a node with no peers looks slow until you
%% time a call on it.
%%
%% 300 ms sits below the unfixed *minimum* (798 ms) and far above the fixed
%% maximum (67 us), so the assertion separates the two behaviours with room on
%% both sides rather than racing a load spike. It is checked against **every**
%% call, not the median, because the old behaviour was a slice boundary rather
%% than a constant delay: a single lucky call is not evidence of a fix.
%%
%% This is the production path, not a mock: `eth_sync:eth_ready_peers/1'
%% (eth_sync.erl:454) and `eth_statesync:snap_peer/1' (eth_statesync.erl:109) both
%% poll `eth_peer:peers/1', which is one `gen_server:call' into this process.
-define(IDLE_BUDGET_MS, 300).

with_no_connections_the_peer_manager_answers_every_call_test_() ->
    {timeout, 60, fun with_no_connections_the_peer_manager_answers_every_call/0}.

with_no_connections_the_peer_manager_answers_every_call() ->
    Priv = eth_secp256k1:generate_key(),
    {ok, Pid} = eth_peer:start_link(#{name => d15_idle, port => 0, privkey => Priv,
                                      target => 0, interval => 60000}),
    unlink(Pid),
    try
        timer:sleep(200),
        Times = [d15_time_a_call(Pid) || _ <- lists:seq(1, 20)],
        ?assertEqual([], [T || T <- Times, T >= ?IDLE_BUDGET_MS])
    after
        (try gen_server:stop(Pid, kill, 1000) catch _:_ -> ok end)
    end.

d15_time_a_call(Pid) ->
    T0 = erlang:monotonic_time(millisecond),
    _ = gen_server:call(Pid, status, 5000),
    erlang:monotonic_time(millisecond) - T0.
