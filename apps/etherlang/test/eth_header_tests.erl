-module(eth_header_tests).

-include_lib("eunit/include/eunit.hrl").

%% A real Sepolia header (block 0xb2dd74) as returned by eth_getBlockByNumber
%% with full=false. Its keccak(RLP(fields)) must equal the claimed hash.
sepolia_block() ->
    #{<<"parentHash">> =>
          <<"0xaa8a87aa293f5c511e07e472ecaccac27188e68c37651e62158c4a4d6b783740">>,
      <<"sha3Uncles">> =>
          <<"0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347">>,
      <<"miner">> => <<"0x3826539cbd8d68dcf119e80b994557b4278cec9f">>,
      <<"stateRoot">> =>
          <<"0x94ce3a7f35c302150e768984684beeeb67a6ae56d9b22f7db5eac272d9fe4e2b">>,
      <<"transactionsRoot">> =>
          <<"0xae24ff340100b3d4a07599c556e19a81ebc45bb2810d41434fc616e89fdb4fd9">>,
      <<"receiptsRoot">> =>
          <<"0x07c5675591b41c5a60594096854d52a01f14f1386f8f5f0aa0b2fee4c8c4392f">>,
      <<"logsBloom">> =>
          <<"0x94a619b508c320354aaa2d2bb2ad165a5878e37a6268d5de8edc3e3468060952"
            "aa8a49b421b2301050b1ed2680c2df330462903ff6f5b025cca24b0ce8b56cc2"
            "72161f4336b1d0213325accef76e0639028c058b719c691747ff1cebde8cb708b"
            "b60d982d23372f442818022fbf8cc2342aeae38b26c8648302450f2c0acb2d6a0"
            "d65855115c4b19539bb119a26f5ed541bc5a29f11480ad19068eee8b80b90beaa"
            "be3e0a09c51c34552aff8152b4f28d496fc380e8740828b338388f4084497ce6c"
            "db222d1831be94cec5273bd3346853b0726486898353cd00433348196a6161d147"
            "0ac4a44109180f126c9e02de08bac85f2fbaa802cfb1df0a2701910a65">>,
      <<"difficulty">> => <<"0x0">>,
      <<"number">> => <<"0xb2dd74">>,
      <<"gasLimit">> => <<"0x3938700">>,
      <<"gasUsed">> => <<"0x2698ef0">>,
      <<"timestamp">> => <<"0x6aab8de0">>,
      <<"extraData">> => <<"0x626573752032362e392d646576656c6f702d64393763626436">>,
      <<"mixHash">> =>
          <<"0x29d38dbecc25ffffa9a58f2ac648e3211539ba743067a843577805523cecf587">>,
      <<"nonce">> => <<"0x0000000000000000">>,
      <<"baseFeePerGas">> => <<"0x3deef742">>,
      <<"withdrawalsRoot">> =>
          <<"0xfbb6fbfdc4d9114b8f69f79b0ab5b961c7c449dc86ec12f39aefcde305c34483">>,
      <<"blobGasUsed">> => <<"0x60000">>,
      <<"excessBlobGas">> => <<"0xc82d651">>,
      <<"parentBeaconBlockRoot">> =>
          <<"0xa1cc8b086b4e2364d054eb585da55fe7e646d42f170819128406fb95605999bd">>,
      <<"requestsHash">> =>
          <<"0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855">>,
      <<"hash">> =>
          <<"0xd79af795480c8bd40f009e5ff99a08675a5a44d3148f0a55070aaeb085f682e9">>}.

unhex(<<"0x", Hex/binary>>) -> unhex(Hex);
unhex(Hex) ->
    <<<<(hexval(A) bsl 4 bor hexval(B))>> || <<A, B>> <= Hex>>.

hexval(C) when C >= $0, C =< $9 -> C - $0;
hexval(C) when C >= $a, C =< $f -> C - $a + 10;
hexval(C) when C >= $A, C =< $F -> C - $A + 10.

real_sepolia_header_test() ->
    B = sepolia_block(),
    {ok, H} = eth_header:hash(B),
    ?assertEqual(unhex(maps:get(<<"hash">>, B)), H),
    ?assertEqual({ok, maps:get(<<"hash">>, B)}, eth_header:verify(B)),
    ?assertEqual({ok, maps:get(<<"hash">>, B)}, eth_header:hex_hash(B)).

verify_rejects_tampered_field_test() ->
    B = sepolia_block(),
    Tampered = B#{<<"gasUsed">> => <<"0x2698ef1">>},
    ?assertMatch({error, {bad_block_hash, _, _}}, eth_header:verify(Tampered)).

verify_accepts_hashless_block_test() ->
    B = maps:remove(<<"hash">>, sepolia_block()),
    {ok, Hex} = eth_header:hex_hash(B),
    ?assertEqual({ok, Hex}, eth_header:verify(B)).

missing_field_test() ->
    B = maps:remove(<<"stateRoot">>, sepolia_block()),
    ?assertEqual({error, {missing_header_field, <<"stateRoot">>}}, eth_header:hash(B)).

accessors_test() ->
    B = sepolia_block(),
    ?assertEqual(<<"0xaa8a87aa293f5c511e07e472ecaccac27188e68c37651e62158c4a4d6b783740">>,
                 eth_header:parent_hash(B)),
    ?assertEqual(16#b2dd74, eth_header:number(B)).
