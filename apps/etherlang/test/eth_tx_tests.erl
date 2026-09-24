-module(eth_tx_tests).

-include_lib("eunit/include/eunit.hrl").

vector_block() ->
    Path = filename:join([filename:dirname(?FILE), "vectors",
                          "sepolia_1735460.json"]),
    {ok, Bin} = file:read_file(Path),
    {ok, #{<<"result">> := Block}} = thoas:decode(Bin),
    Block.

%% Real Sepolia block 1735460 (4 legacy txs): trie root must match.
mainnet_tx_root_test() ->
    Block = vector_block(),
    Txs = maps:get(<<"transactions">>, Block),
    ?assertEqual(4, length(Txs)),
    {ok, Root} = eth_tx:tx_root(Txs),
    ?assertEqual(maps:get(<<"transactionsRoot">>, Block),
                 <<"0x", (string:lowercase(binary:encode_hex(Root)))/binary>>).

legacy_encode_test() ->
    Block = vector_block(),
    [Tx | _] = maps:get(<<"transactions">>, Block),
    {ok, Enc} = eth_tx:to_rlp(Tx),
    %% Legacy: plain RLP list starting with the nonce.
    {ok, [Nonce | _], <<>>} = eth_rlp:decode(Enc),
    ?assertEqual(eth_hex:decode(maps:get(<<"nonce">>, Tx)),
                 binary:decode_unsigned(Nonce)).

eip1559_encode_test() ->
    Tx = #{<<"type">> => <<"0x2">>, <<"chainId">> => <<"0xaa36a7">>,
           <<"nonce">> => <<"0x1">>,
           <<"maxPriorityFeePerGas">> => <<"0x3b9aca00">>,
           <<"maxFeePerGas">> => <<"0x3b9aca00">>,
           <<"gas">> => <<"0x5208">>,
           <<"to">> => <<"0x1000000000000000000000000000000000000001">>,
           <<"value">> => <<"0x0">>, <<"input">> => <<"0x">>,
           <<"accessList">> => [],
           <<"v">> => <<"0x0">>, <<"r">> => <<"0x1">>, <<"s">> => <<"0x2">>},
    {ok, <<16#02, Rest/binary>>} = eth_tx:to_rlp(Tx),
    {ok, [ChainID | _], <<>>} = eth_rlp:decode(Rest),
    ?assertEqual(11155111, binary:decode_unsigned(ChainID)).

unsupported_test() ->
    ?assertEqual({error, unsupported_tx_type},
                 eth_tx:to_rlp(#{<<"type">> => <<"0x7b">>})),
    ?assertEqual({error, bad_tx}, eth_tx:tx_root([not_a_map])).
