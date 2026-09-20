-module(eth_sync_tests).

-include_lib("eunit/include/eunit.hrl").

z0() -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>.

sync_test_() ->
    {"sync: gap sync from genesis, live follow, and reorg handling",
     {timeout, 60000, fun sync_full/0}}.

sync_full() ->
    ok = eth_test_util:start_apps(),

    Mock = 'mock_sync',
    Chain = 'chain_sync',
    Sync = 'sync_engine',
    Dir = eth_test_util:tmp_dir(),

    {ok, _} = eth_mock_node:start_link(Mock),
    {ok, _} = eth_chain:start_link(Chain, Dir),
    eth_rpc_client:init(#{url => eth_mock_node:url(Mock), timeout_ms => 10000}),

    {_, Blocks} = eth_test_util:make_blocks(0, 25, z0(), 0),
    eth_mock_node:set_chain(Mock, Blocks),

    %% --- phase 1: gap sync from genesis -----------------------------------
    {ok, _} = eth_sync:start_link(Sync, #{chain => Chain,
                                          concurrency => 4,
                                          body_window => 100,
                                          poll_interval_ms => 50,
                                          sync_retry_ms => 50,
                                          max_reorg_depth => 128,
                                          sync_budget => 2048,
                                          start_block => 0}),

    ok = wait_head(Mock, Chain, 24, 30000),
    ?assertEqual(false, (try eth_sync:status(Sync) catch _:_ -> error end)),

    {ok, B17, Full} = eth_chain:get_by_number(Chain, 17),
    ?assertEqual(<<"0x11">>, maps:get(<<"number">>, B17)),
    ?assert(Full),
    {ok, B0, _} = eth_chain:get_by_number(Chain, 0),
    ?assertEqual(<<"0x0">>, maps:get(<<"number">>, B0)),

    %% --- phase 2: live follow (upstream extends) --------------------------
    eth_mock_node:extend(Mock, 5, 0),
    ok = wait_head(Mock, Chain, 29, 30000),

    %% --- phase 2b: finalized checkpoint is fetched and recorded ------------
    eth_mock_node:set_finalized(Mock, 20),
    ok = eth_test_util:wait_until(fun() -> eth_chain:finalized(Chain) =:= 20 end,
                                  50, 30000),

    %% --- phase 2c: finalized AHEAD of the local head is ignored ------------
    %% Regression: blindly recording an ahead checkpoint bricked sync — every
    %% later rewind below the overshoot floor was refused and the head stalled
    %% forever (live incident: finalized 11740998 vs head 11729363).
    eth_mock_node:set_finalized(Mock, 40),
    timer:sleep(500),
    ?assertEqual(20, eth_chain:finalized(Chain)),

    %% --- phase 3: upstream reorg ------------------------------------------
    %% Upstream replaces blocks 23..30 (still linked to our block 22) with a
    %% different, taller fork (salt 1).
    eth_mock_node:fork_at(Mock, 22, 8, 1),
    ok = wait_head(Mock, Chain, 30, 30000),

    %% The new canonical block 23 must equal what the mock now serves.
    MockChain = eth_mock_node:chain(Mock),
    ?assertEqual(31, length(MockChain)),
    ?assertEqual(maps:get(<<"hash">>, lists:nth(24, MockChain)),
                 maps:get(<<"hash">>, element(2, eth_chain:get_by_number(Chain, 23)))),
    %% old block 23 (salt 0) is gone
    ?assertNotEqual(maps:get(<<"hash">>, lists:nth(24, Blocks)),   % old block 23
                    maps:get(<<"hash">>, element(2, eth_chain:get_by_number(Chain, 23)))),
    %% head matches fork tip
    ?assertEqual(maps:get(<<"hash">>, lists:last(MockChain)),
                 maps:get(<<"hash">>, element(2, eth_chain:get_by_number(Chain, 30)))),

    _ = try gen_server:stop(Sync) catch _:_ -> ok end,
    _ = try gen_server:stop(Chain) catch _:_ -> ok end,
    _ = try gen_server:stop(Mock) catch _:_ -> ok end.

wait_head(Mock, Chain, Num, Timeout) ->
    ok = eth_test_util:wait_until(
           fun() ->
               case eth_chain:head(Chain) of
                   {N, H} when N =:= Num ->
                       MockChain = eth_mock_node:chain(Mock),
                       Expected = case MockChain of
                                      [] -> undefined;
                                      _ -> maps:get(<<"hash">>, lists:last(MockChain))
                                  end,
                       H =:= Expected;
                   _ ->
                       false
               end
           end, 50, Timeout).

finalized_guard_test_() ->
    {"sync: finalized is only recorded when on the local canonical chain",
     {timeout, 60000, fun finalized_guard/0}}.

finalized_guard() ->
    ok = eth_test_util:start_apps(),

    Mock = 'mock_fing',
    Chain = 'chain_fing',
    Sync = 'sync_fing',
    Dir = eth_test_util:tmp_dir(),

    {ok, _} = eth_mock_node:start_link(Mock),
    {ok, _} = eth_chain:start_link(Chain, Dir),
    eth_rpc_client:init(#{url => eth_mock_node:url(Mock), timeout_ms => 10000}),

    %% Mock serves fork A (salt 1); the local node syncs it fully.
    {_, BlocksA} = eth_test_util:make_blocks(0, 11, z0(), 1),
    eth_mock_node:set_chain(Mock, BlocksA),

    {ok, _} = eth_sync:start_link(Sync, #{chain => Chain,
                                          concurrency => 4,
                                          body_window => 100,
                                          poll_interval_ms => 50,
                                          sync_retry_ms => 50,
                                          max_reorg_depth => 128,
                                          sync_budget => 2048,
                                          start_block => 0}),
    ok = wait_head(Mock, Chain, 10, 30000),

    %% Upstream switches to a competing fork (salt 0) and advertises
    %% finalized=5 from THAT fork. 5 =< head 10, but the hash is not our
    %% canonical block 5, so it must be ignored.
    {_, BlocksB} = eth_test_util:make_blocks(0, 11, z0(), 0),
    eth_mock_node:set_chain(Mock, BlocksB),
    eth_mock_node:set_finalized(Mock, 5),
    timer:sleep(500),
    ?assertEqual(undefined, eth_chain:finalized(Chain)),

    %% ...while a checkpoint that IS canonical is still recorded.
    eth_mock_node:set_chain(Mock, BlocksA),
    eth_mock_node:set_finalized(Mock, 5),
    ok = eth_test_util:wait_until(fun() -> eth_chain:finalized(Chain) =:= 5 end,
                                  50, 30000),

    _ = try gen_server:stop(Sync) catch _:_ -> ok end,
    _ = try gen_server:stop(Chain) catch _:_ -> ok end,
    _ = try gen_server:stop(Mock) catch _:_ -> ok end.