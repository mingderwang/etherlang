-module(eth_trie_tests).

-include_lib("eunit/include/eunit.hrl").

empty_test() ->
    ?assertEqual(hex("56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"),
                 eth_trie:root([])).

%% ethereum/tests TrieTests/trietest.json "emptyValues": final set after
%% the two deletes (ether, shaman) is four pairs.
empty_values_test() ->
    Pairs = [{<<"do">>, <<"verb">>},
             {<<"horse">>, <<"stallion">>},
             {<<"doge">>, <<"coin">>},
             {<<"dog">>, <<"puppy">>}],
    ?assertEqual(hex("5991bb8c6514148a29db676a14ac506cd2cd5775ace63c30a4fe457715e9ac84"),
                 eth_trie:root(Pairs)).

branching_test() ->
    %% trietest.json "branchingTests" inserts (the vector then deletes them
    %% back to empty, covered by empty_test; deletes are not implemented).
    %% Expected root cross-checked with an independent implementation.
    Keys = ["04110d816c380812a427968ece99b1c963dfbce6",
            "095e7baea6a6c7c4c2dfeb977efac326af552d87",
            "0a517d755cebbf66312b30fff713666a9cb917e0",
            "24dd378f51adc67a50e339e8031fe9bd4aafab36",
            "293f982d000532a7861ab122bdc4bbfd26bf9030",
            "2cf5732f017b0cf1b1f13a1478e10239716bf6b5",
            "31c640b92c21a1f1465c91070b4b3b4d6854195f",
            "37f998764813b136ddf5a754f34063fd03065e36",
            "37fa399a749c121f8a15ce77e3d9f9bec8020d7a",
            "4f36659fa632310b6ec438dea4085b522a2dd077",
            "62c01474f089b07dae603491675dc5b5748f7049",
            "729af7294be595a0efd7d891c9e51f89c07950c7",
            "83e3e5a16d3b696a0314b30b2534804dd5e11197",
            "8703df2417e0d7c59d063caa9583cb10a4d20532",
            "8dffcd74e5b5923512916c6a64b502689cfa65e1",
            "95a4d7cccb5204733874fa87285a176fe1e9e240",
            "99b2fcba8120bedd048fe79f5262a6690ed38c39",
            "a4202b8b8afd5354e3e40a219bdc17f6001bf2cf",
            "a94f5374fce5edbc8e2a8697c15331677e6ebf0b",
            "a9647f4a0a14042d91dc33c0328030a7157c93ae",
            "aa6cffe5185732689c18f37a7f86170cb7304c2a",
            "aae4a2e3c51c04606dcb3723456e58f3ed214f45",
            "c37a43e940dfb5baf581a0b82b351d48305fc885",
            "d2571607e241ecf590ed94b12d87c94babe36db6",
            "f735071cbee190d76b704ce68384fc21e389fbe7"],
    Pairs = [{binary:decode_hex(list_to_binary(K)), <<"something">>} || K <- Keys],
    ?assertEqual(hex("4d0650d4409840f1c5fc651cbf56d621dc8d0ee71251940e8cf27c28b77f000b"),
                 eth_trie:root(Pairs)).

jeff_test() ->
    %% trietest.json "jeff": the null op deletes 0000..7890, so it is absent
    %% from the final set (9 pairs).
    Pairs = [{hex("0000000000000000000000000000000000000000000000000000000000000045"),
              hex("22b224a1420a802ab51d326e29fa98e34c4f24ea")},
             {hex("0000000000000000000000000000000000000000000000000000000000000046"),
              hex("67706c2076330000000000000000000000000000000000000000000000000000")},
             {hex("000000000000000000000000697c7b8c961b56f675d570498424ac8de1a918f6"),
              hex("1234567890")},
             {hex("0000000000000000000000007ef9e639e2733cb34e4dfc576d4b23f72db776b2"),
              hex("4655474156000000000000000000000000000000000000000000000000000000")},
             {hex("000000000000000000000000ec4f34c97e43fbb2816cfd95e388353c7181dab1"),
              hex("4e616d6552656700000000000000000000000000000000000000000000000000")},
             {hex("4655474156000000000000000000000000000000000000000000000000000000"),
              hex("7ef9e639e2733cb34e4dfc576d4b23f72db776b2")},
             {hex("4e616d6552656700000000000000000000000000000000000000000000000000"),
              hex("ec4f34c97e43fbb2816cfd95e388353c7181dab1")},
             {hex("000000000000000000000000697c7b8c961b56f675d570498424ac8de1a918f6"),
              hex("6f6f6f6820736f2067726561742c207265616c6c6c793f000000000000000000")},
             {hex("6f6f6f6820736f2067726561742c207265616c6c6c793f000000000000000000"),
              hex("697c7b8c961b56f675d570498424ac8de1a918f6")}],
    ?assertEqual(hex("9f6221ebb8efe7cff60a716ecb886e67dd042014be444669f0159d8e68b42100"),
                 eth_trie:root(Pairs)).

insert_middle_leaf_test() ->
    Pairs = [{<<"key1aa">>, <<"0123456789012345678901234567890123456789xxx">>},
             {<<"key1">>, <<"0123456789012345678901234567890123456789Very_Long">>},
             {<<"key2bb">>, <<"aval3">>},
             {<<"key2">>, <<"short">>},
             {<<"key3cc">>, <<"aval3">>},
             {<<"key3">>, <<"1234567890123456789012345678901">>}],
    ?assertEqual(hex("cb65032e2f76c48b82b5c24b3db8f670ce73982869d38cd39a624f23d62a9e89"),
                 eth_trie:root(Pairs)).

branch_value_update_test() ->
    Pairs = [{<<"abc">>, <<"123">>},
             {<<"abcd">>, <<"abcd">>},
             {<<"abc">>, <<"abc">>}],
    ?assertEqual(hex("7a320748f780ad9ad5b0837302075ce0eeba6c26e3d8562c67ccc0f1b273298a"),
                 eth_trie:root(Pairs)).

%% Insertion order must not affect the root.
order_test() ->
    Pairs = [{<<"do">>, <<"verb">>},
             {<<"dog">>, <<"puppy">>},
             {<<"doge">>, <<"coin">>},
             {<<"horse">>, <<"stallion">>}],
    R1 = eth_trie:root(Pairs),
    R2 = eth_trie:root(lists:reverse(Pairs)),
    ?assertEqual(R1, R2).

%% Real Sepolia eth_getProof verifies against the state root.
real_proof_test() ->
    Path = filename:join([filename:dirname(?FILE), "vectors",
                          "sepolia_proof_latest.json"]),
    {ok, Bin} = file:read_file(Path),
    {ok, #{<<"result">> := P}} = thoas:decode(Bin),
    Root = hex("0x4bcf8bfd58164c89ba9ca54d7497619bf13abf7f4a5ef0dcdfa8daa572261ba2"),
    Addr = hex("0xd86e1fedb7120369ff5175b74f4413cb74fcacdb"),
    %% Key is keccak(address).
    Key = eth_keccak:hash(Addr),
    Nodes = [hex(N) || N <- maps:get(<<"accountProof">>, P)],
    {ok, Val} = eth_trie:verify_proof(Root, Key, Nodes),
    %% Value is the RLP account [nonce, balance, storageRoot, codeHash].
    {ok, [Nonce, Balance, _StorageRoot, CodeHash], <<>>} =
        eth_rlp:decode(Val),
    ?assertEqual(eth_hex:decode(maps:get(<<"nonce">>, P)),
                 binary:decode_unsigned(Nonce)),
    ?assertEqual(eth_hex:decode(maps:get(<<"balance">>, P)),
                 binary:decode_unsigned(Balance)),
    ?assertEqual(hex(maps:get(<<"codeHash">>, P)), CodeHash),
    %% Tampered root fails.
    <<B, Rest/binary>> = Root,
    Bad = <<(B bxor 16#FF), Rest/binary>>,
    ?assertMatch({error, _},
                 eth_trie:verify_proof(Bad, Key, Nodes)),
    %% An unrelated key must never verify to a value against this proof.
    Absent = eth_keccak:hash(<<"no-such-account-anywhere-near">>),
    ?assert(begin
        case eth_trie:verify_proof(Root, Absent, Nodes) of
            {ok, not_found} -> true;
            {error, _} -> true;
            _ -> false
        end
    end).

hex(S) when is_list(S) -> hex(list_to_binary(S));
hex(B) ->
    H = binary:replace(B, <<"0x">>, <<>>, [global]),
    binary:decode_hex(H).
