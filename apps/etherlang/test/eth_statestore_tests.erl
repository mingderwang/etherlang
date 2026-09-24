-module(eth_statestore_tests).

-include_lib("eunit/include/eunit.hrl").

with_store(Name, Fun) ->
    Dir = eth_test_util:tmp_dir(),
    {ok, _} = eth_statestore:start_link(#{name => Name, dir => Dir}),
    try Fun()
    after
        gen_server:stop(Name)
    end.

put_get_test() ->
    with_store(store_pg, fun() ->
        H = crypto:strong_rand_bytes(32),
        R = eth_rlp:encode([1, 2, <<1, 2, 3, 4>>, <<9>>]),
        ?assertEqual(not_found, eth_statestore:get_account(store_pg, H)),
        ok = eth_statestore:put_accounts(store_pg, [{H, R}]),
        ?assertEqual({ok, R}, eth_statestore:get_account(store_pg, H)),
        S = crypto:strong_rand_bytes(32),
        V = eth_rlp:encode(42),
        ?assertEqual(not_found, eth_statestore:get_storage(store_pg, H, S)),
        ok = eth_statestore:put_storage(store_pg, H, [{S, V}]),
        ?assertEqual({ok, V}, eth_statestore:get_storage(store_pg, H, S)),
        Code = <<1, 2, 3>>,
        CH = eth_keccak:hash(Code),
        ?assertEqual(not_found, eth_statestore:get_code(store_pg, CH)),
        ok = eth_statestore:put_code(store_pg, CH, Code),
        ?assertEqual({ok, Code}, eth_statestore:get_code(store_pg, CH))
    end).

range_test() ->
    with_store(store_rg, fun() ->
        Pairs = [{<<I:256>>, eth_rlp:encode(I)} || I <- [1, 2, 3, 10, 200]],
        ok = eth_statestore:put_accounts(store_rg, Pairs),
        %% Full range.
        {ok, All} = eth_statestore:account_range(store_rg, <<0:256>>,
                                                 maxhash(), 1000000),
        ?assertEqual(5, length(All)),
        %% Bounded [2, 10): keys 2, 3.
        {ok, Sub} = eth_statestore:account_range(store_rg, <<2:256>>,
                                                 <<10:256>>, 1000000),
        ?assertEqual([<<2:256>>, <<3:256>>], [H || {H, _} <- Sub]),
        %% Byte cap cuts the list.
        {ok, [_]} = eth_statestore:account_range(store_rg, <<0:256>>,
                                                 maxhash(), 1),
        %% Storage ranges slice per account.
        A = <<9:256>>,
        SPairs = [{<<S:256>>, eth_rlp:encode(S)} || S <- [5, 6, 7]],
        ok = eth_statestore:put_storage(store_rg, A, SPairs),
        {ok, Got} = eth_statestore:storage_range(store_rg, A, <<0:256>>,
                                                 maxhash(), 1000000),
        ?assertEqual(3, length(Got)),
        %% Other accounts unaffected.
        {ok, []} = eth_statestore:storage_range(store_rg, <<8:256>>,
                                                <<0:256>>, maxhash(),
                                                1000000)
    end).

maxhash() -> binary:copy(<<255>>, 32).

persist_test() ->
    Dir = eth_test_util:tmp_dir(),
    H = crypto:strong_rand_bytes(32),
    R = eth_rlp:encode([1]),
    {ok, _} = eth_statestore:start_link(#{name => store_ps, dir => Dir}),
    ok = eth_statestore:put_accounts(store_ps, [{H, R}]),
    gen_server:stop(store_ps),
    {ok, _} = eth_statestore:start_link(#{name => store_ps, dir => Dir}),
    try
        ?assertEqual({ok, R}, eth_statestore:get_account(store_ps, H))
    after
        gen_server:stop(store_ps)
    end.
