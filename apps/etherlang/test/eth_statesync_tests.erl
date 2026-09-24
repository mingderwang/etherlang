-module(eth_statesync_tests).

-include_lib("eunit/include/eunit.hrl").

z0() -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>.

%% Full heal against a stub snap peer serving a 5-account trie with
%% storage and code, all proof-anchored. Asserts the worker pages to
%% done and the store holds everything.
heal_test_() ->
    {timeout, 60, fun heal/0}.

heal() ->
    %% Account trie: keys 0..4, accounts [nonce, balance, storageRoot, codeHash].
    SlotMap = #{eth_keccak:hash(<<1:256>>) => slots_for(1),
                eth_keccak:hash(<<3:256>>) => slots_for(3)},
    Accts = [{I, mk_acct(I, SlotMap)} || I <- lists:seq(0, 4)],
    Pairs = [{eth_keccak:hash(<<I:256>>), eth_rlp:encode(A)} || {I, A} <- Accts],
    Tree = eth_trie:build(Pairs),
    Root = eth_trie:root(Pairs),
    Codes = #{eth_keccak:hash(<<99, I>>) => <<99, I>> || I <- [1, 3]},
    Stub = spawn(fun() -> stub_loop(#{tree => Tree, pairs => Pairs,
                                      slotmap => SlotMap, codes => Codes}) end),
    Dir = eth_test_util:tmp_dir(),
    {ok, _} = eth_chain:start_link(chain_ss, Dir),
    SDir = eth_test_util:tmp_dir(),
    {ok, _} = eth_statestore:start_link(#{name => store_ss, dir => SDir}),
    try
        {_, [B0]} = eth_test_util:make_blocks(0, 1, z0(), 0),
        B1 = B0#{<<"stateRoot">> => hex0x(Root)},
        {ok, H} = eth_header:hash(B1),
        B2 = B1#{<<"hash">> => hex0x(H)},
        ok = eth_chain:append(chain_ss, [{0, B2, true}]),
        {ok, _} = eth_statesync:start_link(#{name => sync_ss, chain => chain_ss,
                                             store => store_ss, peer => Stub,
                                             interval => 100}),
        try
            ok = wait_done(sync_ss, 200),
            %% All accounts landed with exact RLP.
            lists:foreach(fun({I, _}) ->
                K = eth_keccak:hash(<<I:256>>),
                {_, A} = lists:keyfind(I, 1, Accts),
                ?assertEqual({ok, eth_rlp:encode(A)},
                             eth_statestore:get_account(store_ss, K))
            end, Accts),
            %% Storage slots for accounts 1 and 3.
            {ok, V} = eth_statestore:get_storage(
                        store_ss,
                        eth_keccak:hash(<<1:256>>),
                        eth_keccak:hash(<<7:256>>)),
            ?assertEqual(eth_rlp:encode(7 * 11 + 1), V),
            %% Codes landed.
            {ok, <<99, 1>>} = eth_statestore:get_code(
                                store_ss, eth_keccak:hash(<<99, 1>>))
        after
            gen_server:stop(sync_ss)
        end
    after
        gen_server:stop(chain_ss),
        gen_server:stop(store_ss),
        exit(Stub, kill)
    end.

wait_done(_Name, 0) -> error(heal_timeout);
wait_done(Name, N) ->
    case eth_statesync:status(Name) of
        #{phase := done} -> ok;
        _ -> timer:sleep(100), wait_done(Name, N - 1)
    end.

slots_for(I) ->
    [{eth_keccak:hash(<<S:256>>), eth_rlp:encode(S * 11 + I)} || S <- [7, 8]].

mk_acct(I, SlotMap) ->
    Key = eth_keccak:hash(<<I:256>>),
    case maps:find(Key, SlotMap) of
        {ok, Slots} ->
            SRoot = eth_trie:root(Slots),
            [I, I * 1000, SRoot, eth_keccak:hash(<<99, I>>)];
        error ->
            [I, I * 1000, empty_root(), empty_code()]
    end.
empty_root() ->
    hex("56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421").
empty_code() ->
    hex("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470").

%% Stub snap peer: pages 2 accounts per response with real proofs.
stub_loop(#{tree := Tree, pairs := Pairs} = D) ->
    receive
        {'$gen_call', {Pid, Ref}, {snap_account_range, _Root, Origin, _Limit}} ->
            Rest = [{H, A} || {H, A} <- lists:sort(Pairs), H >= Origin],
            Page = lists:sublist(Rest, 2),
            Reply = case Page of
                        [] -> {ok, [[], [], []]};
                        _ ->
                            {Hs, As} = lists:unzip(Page),
                            {LastH, _} = lists:last(Page),
                            {ok, [Hs, As, eth_trie:prove(Tree, LastH)]}
                    end,
            Pid ! {Ref, Reply},
            stub_loop(D);
        {'$gen_call', {Pid, Ref}, {snap_storage_range, _Root, Acct, Origin, _Limit}} ->
            Reply = case maps:find(Acct, maps:get(slotmap, D)) of
                        {ok, Slots} -> serve_slots(Slots, Origin);
                        error -> {ok, [[], [], []]}
                    end,
            Pid ! {Ref, Reply},
            stub_loop(D);
        {'$gen_call', {Pid, Ref}, {snap_bytecodes, Hashes}} ->
            #{codes := Codes} = D,
            Pid ! {Ref, {ok, [maps:get(H, Codes, <<>>) || H <- Hashes]}},
            stub_loop(D)
    end.

serve_slots(Slots, Origin) ->
    Rest = [{H, V} || {H, V} <- lists:sort(Slots), H >= Origin],
    Page = lists:sublist(Rest, 2),
    case Page of
        [] ->
            {ok, [[], [], []]};
        _ ->
            {Hs, Vs} = lists:unzip(Page),
            {LastH, _} = lists:last(Page),
            Tree = eth_trie:build(Slots),
            {ok, [Hs, Vs, eth_trie:prove(Tree, LastH)]}
    end.

hex0x(Bin) -> <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.
hex(S) when is_list(S) -> hex(list_to_binary(S));
hex(B) ->
    H = binary:replace(B, <<"0x">>, <<>>, [global]),
    binary:decode_hex(H).

%% RPC reads served from a populated store (no chain data needed for the
%% store path; missing keys proxy and fail closed without upstream).
rpc_reads_test_() ->
    {timeout, 60, fun rpc_reads/0}.

rpc_reads() ->
    eth_test_util:start_apps(),
    SDir = eth_test_util:tmp_dir(),
    {ok, _} = eth_statestore:start_link(#{name => store_rpc, dir => SDir}),
    try
        Addr = hex("0x1000000000000000000000000000000000000001"),
        AHash = eth_keccak:hash(Addr),
        Acct = [16#5, 1000000, empty_root(), hex("0x" ++ lists:duplicate(64, $0))],
        ok = eth_statestore:put_accounts(store_rpc, [{AHash, eth_rlp:encode(Acct)}]),
        Slot = hex("0x" ++ lists:duplicate(63, $0) ++ "7"),
        SlotH = eth_keccak:hash(Slot),
        ok = eth_statestore:put_storage(store_rpc, AHash, [{SlotH, eth_rlp:encode(42)}]),
        Code = <<1, 2, 3, 4>>,
        CH = eth_keccak:hash(Code),
        Acct2 = [0, 0, empty_root(), CH],
        Addr2 = hex("0x2000000000000000000000000000000000000002"),
        ok = eth_statestore:put_accounts(store_rpc, [{eth_keccak:hash(Addr2),
                                                       eth_rlp:encode(Acct2)}]),
        ok = eth_statestore:put_code(store_rpc, CH, Code),
        Port = eth_test_util:free_port(),
        {ok, _} = eth_rpc_server:start_link(srv_state,
                                            #{port => Port, store => store_rpc,
                                              sync => 'no_such_sync_name'}),
        try
            {ok, #{<<"result">> := Bal}} = post(Port, <<"eth_getBalance">>,
                                                [hex0x(Addr), <<"latest">>]),
            ?assertEqual(1000000, eth_hex:decode(Bal)),
            {ok, #{<<"result">> := Nonce}} = post(Port, <<"eth_getTransactionCount">>,
                                                  [hex0x(Addr), <<"latest">>]),
            ?assertEqual(5, eth_hex:decode(Nonce)),
            {ok, #{<<"result">> := GotCode}} = post(Port, <<"eth_getCode">>,
                                                    [hex0x(Addr2), <<"latest">>]),
            ?assertEqual(hex0x(Code), GotCode),
            {ok, #{<<"result">> := GotSlot}} = post(Port, <<"eth_getStorageAt">>,
                                                    [hex0x(Addr),
                                                     hex0x(Slot), <<"latest">>]),
            ?assertEqual(42, eth_hex:decode(GotSlot))
        after
            gen_server:stop(srv_state)
        end
    after
        gen_server:stop(store_rpc)
    end.

post(Port, Method, Params) ->
    Body = thoas:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
                          <<"method">> => Method, <<"params">> => Params}),
    {ok, {{_, 200, _}, _, Resp}} =
        httpc:request(post, {"http://127.0.0.1:" ++ integer_to_list(Port),
                             [{"content-type", "application/json"}],
                             "application/json", Body},
                      [{timeout, 10000}], [{body_format, binary}]),
    thoas:decode(Resp).
