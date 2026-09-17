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