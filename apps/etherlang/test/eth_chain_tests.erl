-module(eth_chain_tests).

-include_lib("eunit/include/eunit.hrl").

z0() -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>.

num_of(B) -> eth_hex:decode(maps:get(<<"number">>, B)).
hash_of(B) -> maps:get(<<"hash">>, B).

pair(Blocks, Full) -> [{num_of(B), B, Full} || B <- Blocks].

with_chain(Name, Dir, Fun) ->
    {ok, _} = eth_chain:start_link(Name, Dir),
    try Fun()
    after
        gen_server:stop(Name)
    end.

append_and_query_test() ->
    Name = 'chain_a',
    Dir = eth_test_util:tmp_dir(),
    with_chain(Name, Dir, fun() ->
        {_H, Blocks} = eth_test_util:make_blocks(0, 6, z0(), 0),
        ?assertEqual(ok, eth_chain:append(Name, pair(Blocks, true))),
        ?assertEqual({5, hash_of(lists:nth(6, Blocks))}, eth_chain:head(Name)),
        ?assertEqual(lists:nth(4, Blocks),
                     element(2, eth_chain:get_by_number(Name, 3))),
        ?assertEqual(lists:nth(3, Blocks),
                     element(2, eth_chain:get_by_hash(Name, hash_of(lists:nth(3, Blocks))))),
        ?assertEqual(hash_of(lists:nth(5, Blocks)), eth_chain:canonical_hash(Name, 4)),
        ?assertEqual(5, eth_chain:highest(Name)),
        ?assertEqual(6, eth_chain:size(Name)),
        ?assert(eth_chain:has_block(Name, 2)),
        ?assertNot(eth_chain:has_block(Name, 9))
    end).

reorg_test() ->
    Name = 'chain_b',
    Dir = eth_test_util:tmp_dir(),
    with_chain(Name, Dir, fun() ->
        {_H0, Old} = eth_test_util:make_blocks(0, 9, z0(), 0),
        ok = eth_chain:append(Name, pair(Old, true)),
        {_, Old3, _} = eth_chain:get_by_number(Name, 3),
        Old8 = eth_chain:canonical_hash(Name, 8),

        %% Upstream reorgs: blocks 3..11 are replaced (salt 1), still linking
        %% to our block 2.
        {_, Fork} = eth_test_util:make_blocks(3, 9,
                                              hash_of(lists:nth(3, Old)), 1),
        ?assertEqual(ok, eth_chain:append(Name, pair(Fork, true))),

        ?assertEqual({11, hash_of(lists:nth(9, Fork))}, eth_chain:head(Name)),
        {_, New3, _} = eth_chain:get_by_number(Name, 3),
        ?assertNotEqual(Old3, New3),
        ?assertNotEqual(undefined, eth_chain:canonical_hash(Name, 8)),
        ?assertNotEqual(Old8, eth_chain:canonical_hash(Name, 8)),
        %% common ancestor preserved
        ?assertEqual(hash_of(lists:nth(3, Old)),
                     eth_chain:canonical_hash(Name, 2))
    end).

rewind_test() ->
    Name = 'chain_c',
    Dir = eth_test_util:tmp_dir(),
    with_chain(Name, Dir, fun() ->
        {_H, Blocks} = eth_test_util:make_blocks(0, 6, z0(), 0),
        ok = eth_chain:append(Name, pair(Blocks, true)),
        ?assertEqual(ok, eth_chain:rewind(Name, 3)),
        ?assertEqual({3, hash_of(lists:nth(4, Blocks))}, eth_chain:head(Name)),
        ?assertNot(eth_chain:has_block(Name, 5)),
        ?assert(eth_chain:has_block(Name, 3))
    end).

missing_parent_test() ->
    Name = 'chain_d',
    Dir = eth_test_util:tmp_dir(),
    with_chain(Name, Dir, fun() ->
        {_H, Blocks} = eth_test_util:make_blocks(0, 6, z0(), 0),
        ok = eth_chain:append(Name, pair(Blocks, true)),
        Random = <<"0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef">>,
        {_, B} = eth_test_util:make_blocks(6, 1, Random, 99),
        ?assertEqual({missing_parent, Random},
                     eth_chain:append(Name, pair(B, true)))
    end).

persistence_test() ->
    NameA = 'chain_e',
    NameB = 'chain_f',
    Dir = eth_test_util:tmp_dir(),
    {ok, _} = eth_chain:start_link(NameA, Dir),
    {_H, Blocks} = eth_test_util:make_blocks(0, 4, z0(), 0),
    ok = eth_chain:append(NameA, pair(Blocks, true)),
    gen_server:stop(NameA),

    {ok, _} = eth_chain:start_link(NameB, Dir),
    try
        ?assertEqual({3, hash_of(lists:nth(4, Blocks))}, eth_chain:head(NameB)),
        ?assertEqual(lists:nth(3, Blocks),
                     element(2, eth_chain:get_by_number(NameB, 2))),
        ?assertEqual([], dets_stats_check(NameB))
    after
        gen_server:stop(NameB)
    end.

%% Just a sanity helper (never actually fails) to exercise size API after reload.
dets_stats_check(Name) ->
    case eth_chain:size(Name) of
        4 -> [];
        N -> ["unexpected size " ++ integer_to_list(N)]
    end.

rejects_bad_hash_test() ->
    Name = 'chain_g',
    Dir = eth_test_util:tmp_dir(),
    with_chain(Name, Dir, fun() ->
        {_H, Blocks} = eth_test_util:make_blocks(0, 3, z0(), 0),
        [B0, B1, B2] = Blocks,
        Bad = B2#{<<"gasUsed">> => <<"0xffff">>},
        ?assertMatch({error, {bad_block, 2, {bad_block_hash, _, _}}},
                     eth_chain:append(Name, [{0, B0, true}, {1, B1, true}, {2, Bad, true}])),
        %% nothing was accepted
        ?assertEqual(undefined, eth_chain:head(Name))
    end).

finality_floor_test() ->
    Name = 'chain_h',
    Dir = eth_test_util:tmp_dir(),
    with_chain(Name, Dir, fun() ->
        {_H, Blocks} = eth_test_util:make_blocks(0, 6, z0(), 0),
        ok = eth_chain:append(Name, pair(Blocks, true)),

        ?assertEqual(undefined, eth_chain:finalized(Name)),
        ok = eth_chain:set_finalized(Name, 3),
        ?assertEqual(3, eth_chain:finalized(Name)),

        %% rewind at or above the checkpoint is fine
        ?assertEqual(ok, eth_chain:rewind(Name, 5)),
        ?assertEqual(ok, eth_chain:rewind(Name, 3)),
        ?assertEqual({3, hash_of(lists:nth(4, Blocks))}, eth_chain:head(Name)),

        %% below the checkpoint is refused
        ?assertEqual({error, {below_finality, 3}}, eth_chain:rewind(Name, 2)),
        ?assertEqual({3, hash_of(lists:nth(4, Blocks))}, eth_chain:head(Name)),

        %% checkpoint never moves backwards
        ok = eth_chain:set_finalized(Name, 1),
        ?assertEqual(3, eth_chain:finalized(Name))
    end).

finality_blocks_reorg_test() ->
    Name = 'chain_i',
    Dir = eth_test_util:tmp_dir(),
    with_chain(Name, Dir, fun() ->
        {_H, Blocks} = eth_test_util:make_blocks(0, 6, z0(), 0),
        ok = eth_chain:append(Name, pair(Blocks, true)),
        ok = eth_chain:set_finalized(Name, 4),

        %% a fork replacing block 3 (i.e. below finality) must be rejected
        {_, Fork} = eth_test_util:make_blocks(3, 3, hash_of(lists:nth(3, Blocks)), 7),
        ?assertMatch({error, {below_finality, 4}},
                     eth_chain:append(Name, pair(Fork, true))),
        ?assertEqual(5, eth_chain:highest(Name))
    end).

finality_persistence_test() ->
    NameA = 'chain_j',
    NameB = 'chain_k',
    Dir = eth_test_util:tmp_dir(),
    {ok, _} = eth_chain:start_link(NameA, Dir),
    {_H, Blocks} = eth_test_util:make_blocks(0, 4, z0(), 0),
    ok = eth_chain:append(NameA, pair(Blocks, true)),
    ok = eth_chain:set_finalized(NameA, 2),
    gen_server:stop(NameA),

    {ok, _} = eth_chain:start_link(NameB, Dir),
    try
        ?assertEqual(2, eth_chain:finalized(NameB)),
        ?assertEqual({error, {below_finality, 2}}, eth_chain:rewind(NameB, 1))
    after
        gen_server:stop(NameB)
    end.

%% With a tiny retention the store keeps only the most recent window (plus the
%% finalized block) so DETS can never grow without bound.
prune_window_test() ->
    Name = 'chain_l',
    Dir = eth_test_util:tmp_dir(),
    with_prune_env(fun() ->
        with_chain(Name, Dir, fun() ->
            {_H, Blocks} = eth_test_util:make_blocks(0, 12, z0(), 0),
            ok = eth_chain:append(Name, pair(Blocks, true)),
            %% head 11, keep last 4: 8..11
            ?assertEqual({11, hash_of(lists:nth(12, Blocks))}, eth_chain:head(Name)),
            ?assertEqual(4, eth_chain:size(Name)),
            ?assert(eth_chain:has_block(Name, 11)),
            ?assert(eth_chain:has_block(Name, 8)),
            ?assertNot(eth_chain:has_block(Name, 7)),
            %% pruning also retired the hash index
            ?assertEqual(not_found, eth_chain:get_by_hash(Name, hash_of(lists:nth(1, Blocks))))
        end)
    end).

%% The finalized block is retained even as it ages out of the window, so a
%% rewind to the checkpoint stays possible.
prune_keeps_finalized_test() ->
    Name = 'chain_m',
    Dir = eth_test_util:tmp_dir(),
    with_prune_env(fun() ->
        with_chain(Name, Dir, fun() ->
            {_H, Blocks} = eth_test_util:make_blocks(0, 12, z0(), 0),
            ok = eth_chain:append(Name, pair(Blocks, true)),
            ok = eth_chain:set_finalized(Name, 9),
            %% append one more block to trigger a prune pass
            {_H2, More} = eth_test_util:make_blocks(12, 1, hash_of(lists:nth(12, Blocks)), 0),
            ok = eth_chain:append(Name, pair(More, true)),
            ?assertEqual(4, eth_chain:size(Name)),
            ?assert(eth_chain:has_block(Name, 9)),
            ?assertNot(eth_chain:has_block(Name, 8)),
            %% rewind to the finalized checkpoint still works
            ?assertEqual(ok, eth_chain:rewind(Name, 9)),
            ?assertEqual({9, hash_of(lists:nth(10, Blocks))}, eth_chain:head(Name))
        end)
    end).

with_prune_env(Fun) ->
    os:putenv("CHAIN_RETENTION", "4"),
    os:putenv("MAX_REORG_DEPTH", "2"),
    try Fun() after
        os:unsetenv("CHAIN_RETENTION"),
        os:unsetenv("MAX_REORG_DEPTH")
    end.