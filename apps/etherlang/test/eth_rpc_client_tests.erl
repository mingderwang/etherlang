-module(eth_rpc_client_tests).

-include_lib("eunit/include/eunit.hrl").

z0() -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>.

client_test_() ->
    {timeout, 60000, fun client_case/0}.

client_case() ->
    ok = eth_test_util:start_apps(),
    Mock = 'mock_client',
    {ok, _} = eth_mock_node:start_link(Mock),
    try
        eth_rpc_client:init(#{url => eth_mock_node:url(Mock), timeout_ms => 10000}),

        {ok, <<"0x0">>} = eth_rpc_client:call(<<"eth_blockNumber">>, []),

        {_H, Blocks} = eth_test_util:make_blocks(0, 5, z0(), 0),
        eth_mock_node:set_chain(Mock, Blocks),

        {ok, Head} = eth_rpc_client:call(<<"eth_blockNumber">>, []),
        ?assertEqual(<<"0x4">>, Head),

        {ok, Block0} = eth_rpc_client:call(<<"eth_getBlockByNumber">>, [<<"0x0">>, true]),
        ?assertEqual(<<"0x0">>, maps:get(<<"number">>, Block0)),

        {ok, Block2Header} = eth_rpc_client:call(<<"eth_getBlockByNumber">>,
                                                 [<<"0x2">>, false]),
        ?assertEqual(<<"0x2">>, maps:get(<<"number">>, Block2Header)),
        %% header-only rendering strips transaction objects to hashes
        Txs = maps:get(<<"transactions">>, Block2Header),
        ?assertEqual(true, lists:all(fun is_binary/1, Txs)),

        {ok, Block3Full} = eth_rpc_client:call(<<"eth_getBlockByHash">>,
                                               [maps:get(<<"hash">>, lists:nth(4, Blocks)),
                                                true]),
        ?assertEqual(<<"0x3">>, maps:get(<<"number">>, Block3Full)),

        {ok, null} = eth_rpc_client:call(<<"eth_getBlockByNumber">>, [<<"0xff">>, false]),

        {error, {rpc_error, #{<<"code">> := -32601}}} =
            eth_rpc_client:call(<<"eth_nope">>, [])
    after
        gen_server:stop(Mock)
    end.