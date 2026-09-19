-module(eth_rpc_server_tests).

-include_lib("eunit/include/eunit.hrl").

z0() -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>.

rpc_server_test_() ->
    {timeout, 60000, fun rpc_server_case/0}.

rpc_server_case() ->
    ok = eth_test_util:start_apps(),

    Mock = 'mock_rpc',
    Chain = 'chain_rpc',
    Server = 'rpc_server',
    Dir = eth_test_util:tmp_dir(),
    Port = eth_test_util:free_port(),

    {ok, _} = eth_mock_node:start_link(Mock),
    {ok, _} = eth_chain:start_link(Chain, Dir),
    eth_rpc_client:init(#{url => eth_mock_node:url(Mock), timeout_ms => 10000}),

    {_, Blocks} = eth_test_util:make_blocks(0, 6, z0(), 0),
    eth_mock_node:set_chain(Mock, Blocks),

    %% Local store: blocks 0..3 only, header-only (Full=false).
    Pairs = [begin
                 Num = eth_hex:decode(maps:get(<<"number">>, B)),
                 {Num, header_only(B), false}
             end || B <- Blocks],
    {Ok, Rest} = lists:split(4, Pairs), _ = Rest,
    ok = eth_chain:append(Chain, Ok),

    {ok, _} = eth_rpc_server:start_link(Server, #{port => Port,
                                                 chain => Chain,
                                                 sync => 'no_such_sync_name'}),
    try
        %% Local method
        {ok, #{<<"result">> := <<"0x3">>}} =
            rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
                        <<"method">> => <<"eth_blockNumber">>, <<"params">> => []}),

        %% Served locally (header-only stored block, non-full requested)
        {ok, #{<<"result">> := B2}} =
            rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 2,
                        <<"method">> => <<"eth_getBlockByNumber">>,
                        <<"params">> => [<<"0x2">>, false]}),
        ?assertEqual(<<"0x2">>, maps:get(<<"number">>, B2)),
        TxsHeader = maps:get(<<"transactions">>, B2),
        ?assertEqual(true, lists:all(fun is_binary/1, TxsHeader)),

        %% Full body requested for a header-only local block -> proxied
        {ok, #{<<"result">> := B2Full}} =
            rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 3,
                        <<"method">> => <<"eth_getBlockByNumber">>,
                        <<"params">> => [<<"0x2">>, true]}),
        TxsFull = maps:get(<<"transactions">>, B2Full),
        ?assertEqual(true, lists:all(fun is_map/1, TxsFull)),

        %% Beyond local head -> proxied to upstream
        {ok, #{<<"result">> := B5}} =
            rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 4,
                        <<"method">> => <<"eth_getBlockByNumber">>,
                        <<"params">> => [<<"0x5">>, false]}),
        ?assertEqual(<<"0x5">>, maps:get(<<"number">>, B5)),

        %% Upstream-only method proxied
        {ok, #{<<"result">> := Bal}} =
            rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 5,
                        <<"method">> => <<"eth_getBalance">>,
                        <<"params">> => [<<"0x0000000000000000000000000000000000000001">>,
                                         <<"latest">>]}),
        ?assertEqual(<<"0xde0b6b3a7640000">>, Bal),

        %% Block count from local store
        {ok, #{<<"result">> := <<"0x2">>}} =
            rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 6,
                        <<"method">> => <<"eth_getBlockTransactionCountByNumber">>,
                        <<"params">> => [<<"0x2">>]}),

        %% eth_syncing with no sync engine running -> safe default
        {ok, #{<<"result">> := false}} =
            rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 7,
                        <<"method">> => <<"eth_syncing">>, <<"params">> => []}),

        %% Client-version reporting (standards-mandated; also required by
        %% ethstats agents to complete their registration handshake)
        {ok, #{<<"result">> := V1}} =
            rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 8,
                        <<"method">> => <<"web3_clientVersion">>, <<"params">> => []}),
        ?assertMatch(<<"etherlang/", _/binary>>, V1),
        {ok, #{<<"result">> := V2}} =
            rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 9,
                        <<"method">> => <<"eth_getVersion">>, <<"params">> => []}),
        ?assertMatch(<<"etherlang/", _/binary>>, V2),

        %% Batch request
        {ok, RespList} =
            rpc(Port, [#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 10,
                         <<"method">> => <<"eth_blockNumber">>, <<"params">> => []},
                       #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 11,
                         <<"method">> => <<"eth_getBalance">>,
                         <<"params">> => [<<"0x1">>, <<"latest">>]}]),
        ?assertEqual(2, length(RespList)),
        ById = fun(Id) -> maps:get(<<"result">>,
                                    hd([M || M <- RespList, maps:get(<<"id">>, M) =:= Id])) end,
        ?assertEqual(<<"0x3">>, ById(10)),
        ?assertEqual(<<"0xde0b6b3a7640000">>, ById(11)),

        %% Parse error
        {ok, #{<<"error">> := #{<<"code">> := -32700}}} =
            rpc(Port, <<"not json">>),

        %% GET is rejected
        {ok, {{_, 405, _}, _, _}} =
            httpc:request(get, {"http://127.0.0.1:" ++ integer_to_list(Port), []},
                          [{timeout, 10000}], [])
    after
        _ = try gen_server:stop(Server) catch _:_ -> ok end,
        _ = try gen_server:stop(Chain) catch _:_ -> ok end,
        _ = try gen_server:stop(Mock) catch _:_ -> ok end
    end.

rpc(Port, Payload) when is_binary(Payload) ->
    http_post(Port, Payload);
rpc(Port, Payload) ->
    http_post(Port, thoas:encode(Payload)).

header_only(B) ->
    B#{<<"transactions">> => [maps:get(<<"hash">>, T)
                              || T <- maps:get(<<"transactions">>, B)]}.

http_post(Port, Body) ->
    URL = "http://127.0.0.1:" ++ integer_to_list(Port),
    {ok, {{_, 200, _}, _, Resp}} =
        httpc:request(post, {URL, [], "application/json", Body},
                      [{timeout, 10000}], [{body_format, binary}]),
    {ok, Decoded} = thoas:decode(Resp),
    {ok, Decoded}.