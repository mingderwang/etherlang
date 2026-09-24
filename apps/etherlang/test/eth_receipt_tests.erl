-module(eth_receipt_tests).

-include_lib("eunit/include/eunit.hrl").

z0() -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>.
addr_a() -> <<"0xd86e1fedb7120369ff5175b74f4413cb74fcacdb">>.
topic_t1() -> <<"0xf6a97944f31ea060dfde0566e4167c1a1082551e64b60ecb14d599a9d023d451">>.

vector_receipts() ->
    Path = filename:join([filename:dirname(?FILE), "vectors",
                          "sepolia_1735460_receipts.json"]),
    {ok, Bin} = file:read_file(Path),
    {ok, #{<<"result">> := Receipts}} = thoas:decode(Bin),
    Receipts.

vector_block() ->
    Path = filename:join([filename:dirname(?FILE), "vectors",
                          "sepolia_1735460.json"]),
    {ok, Bin} = file:read_file(Path),
    {ok, #{<<"result">> := Block}} = thoas:decode(Bin),
    Block.

%% Real Sepolia receipts trie-root must match the block header.
real_root_test() ->
    Block = vector_block(),
    Receipts = vector_receipts(),
    ?assertEqual(4, length(Receipts)),
    {ok, Root} = eth_receipt:receipt_root(Receipts),
    ?assertEqual(maps:get(<<"receiptsRoot">>, Block),
                 <<"0x", (string:lowercase(binary:encode_hex(Root)))/binary>>).

roundtrip_test() ->
    [R | _] = vector_receipts(),
    {ok, Enc} = eth_receipt:to_rlp(R),
    {ok, Back} = eth_receipt:from_rlp(Enc),
    ?assertEqual(maps:get(<<"status">>, R), maps:get(<<"status">>, Back)),
    ?assertEqual(eth_hex:decode(maps:get(<<"cumulativeGasUsed">>, R)),
                 eth_hex:decode(maps:get(<<"cumulative_gas_used">>, Back))),
    ?assertEqual(length(maps:get(<<"logs">>, R)),
                 length(maps:get(<<"logs">>, Back))).

bloom_test() ->
    [R | _] = vector_receipts(),
    Logs = maps:get(<<"logs">>, R),
    ?assert(length(Logs) > 0),
    [L | _] = Logs,
    Addr = maps:get(<<"address">>, L),
    [T | _] = maps:get(<<"topics">>, L),
    ?assert(eth_bloom:contains(hex(maps:get(<<"logsBloom">>, R)), hex(Addr))),
    ?assert(eth_bloom:contains(hex(maps:get(<<"logsBloom">>, R)), hex(T))),
    ?assertNot(eth_bloom:contains(hex(maps:get(<<"logsBloom">>, R)),
                                  crypto:strong_rand_bytes(20))),
    %% Recomputed bloom matches the stored one.
    Terms = [[hex(maps:get(<<"address">>, X)),
              [hex(Tp) || Tp <- maps:get(<<"topics">>, X)],
              hex(maps:get(<<"data">>, X))] || X <- Logs],
    ?assertEqual(hex(maps:get(<<"logsBloom">>, R)),
                 eth_receipt:logs_bloom(Terms)).

hex(B) ->
    H = binary:replace(B, <<"0x">>, <<>>, [global]),
    binary:decode_hex(H).

%% Handler-level: local receipt + log filter over a stored chain.
handler_test_() ->
    {timeout, 60, fun handler/0}.

handler() ->
    eth_test_util:start_apps(),
    Dir = eth_test_util:tmp_dir(),
    Chain = chain_rcpt,
    {ok, _} = eth_chain:start_link(Chain, Dir),
    Port = eth_test_util:free_port(),
    try
        {_, Blocks} = eth_test_util:make_blocks(0, 4, z0(), 0),
        ok = eth_chain:append(Chain, pair(Blocks)),
        [_, _, _, B3] = Blocks,
        [Tx0, Tx1] = maps:get(<<"transactions">>, B3),
        H0 = maps:get(<<"hash">>, Tx0),
        R0 = receipt(1, 21000, [{addr_a(), [topic_t1()], <<"0x1234">>}]),
        R1 = receipt(1, 42000, []),
        ok = eth_chain:put_receipts(Chain, 3, [R0, R1]),
        {ok, _} = eth_rpc_server:start_link(srv_rcpt, #{port => Port,
                                                        chain => Chain,
                                                        sync => 'no_such_sync_name'}),
        try
            %% Receipt served locally.
            {ok, #{<<"result">> := Rcpt}} =
                rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
                            <<"method">> => <<"eth_getTransactionReceipt">>,
                            <<"params">> => [H0]}),
            ?assertEqual(H0, maps:get(<<"transactionHash">>, Rcpt)),
            ?assertEqual(<<"0x3">>, maps:get(<<"blockNumber">>, Rcpt)),
            ?assertEqual(1, length(maps:get(<<"logs">>, Rcpt))),
            ?assertEqual(<<"0x5208">>, maps:get(<<"cumulativeGasUsed">>, Rcpt)),
            ?assertEqual(<<"0x5208">>, maps:get(<<"gasUsed">>, Rcpt)),
            ?assertEqual(addr_a(), maps:get(<<"address">>, hd(maps:get(<<"logs">>, Rcpt)))),
            %% Second tx: no logs.
            H1 = maps:get(<<"hash">>, Tx1),
            {ok, #{<<"result">> := Rcpt1}} =
                rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 2,
                            <<"method">> => <<"eth_getTransactionReceipt">>,
                            <<"params">> => [H1]}),
            ?assertEqual([], maps:get(<<"logs">>, Rcpt1)),
            ?assertEqual(<<"0xA410">>, maps:get(<<"cumulativeGasUsed">>, Rcpt1)),
            ?assertEqual(<<"0x5208">>, maps:get(<<"gasUsed">>, Rcpt1)),
            %% Log filter: address match.
            {ok, #{<<"result">> := Logs}} =
                rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 3,
                            <<"method">> => <<"eth_getLogs">>,
                            <<"params">> => [#{<<"fromBlock">> => <<"0x3">>,
                                               <<"toBlock">> => <<"0x3">>,
                                               <<"address">> => addr_a()}]}),
            ?assertEqual(1, length(Logs)),
            %% Address mismatch: empty.
            {ok, #{<<"result">> := []}} =
                rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 4,
                            <<"method">> => <<"eth_getLogs">>,
                            <<"params">> => [#{<<"fromBlock">> => <<"0x3">>,
                                               <<"toBlock">> => <<"0x3">>,
                                               <<"address">> => <<"0x0000000000000000000000000000000000000001">>}]}),
            %% Topic match / mismatch.
            {ok, #{<<"result">> := [_]}} =
                rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 5,
                            <<"method">> => <<"eth_getLogs">>,
                            <<"params">> => [#{<<"fromBlock">> => <<"0x3">>,
                                               <<"toBlock">> => <<"0x3">>,
                                               <<"topics">> => [topic_t1()]}]}),
            {ok, #{<<"result">> := []}} =
                rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 6,
                            <<"method">> => <<"eth_getLogs">>,
                            <<"params">> => [#{<<"fromBlock">> => <<"0x3">>,
                                               <<"toBlock">> => <<"0x3">>,
                                               <<"topics">> => [<<"0x0000000000000000000000000000000000000000000000000000000000000000">>]}]})
        after
            gen_server:stop(srv_rcpt)
        end
    after
        gen_server:stop(Chain)
    end.

receipt(Status, CumGas, Logs) ->
    Ls = [#{<<"address">> => A, <<"topics">> => Ts, <<"data">> => D}
          || {A, Ts, D} <- Logs],
    Terms = [[un0x(maps:get(<<"address">>, L)),
              [un0x(T) || T <- maps:get(<<"topics">>, L)],
              un0x(maps:get(<<"data">>, L))] || L <- Ls],
    #{<<"type">> => <<"0x0">>,
      <<"status">> => case Status of 1 -> <<"0x1">>; _ -> <<"0x0">> end,
      <<"cumulative_gas_used">> => eth_hex:encode_int(CumGas),
      <<"logs_bloom">> => <<"0x", (binary:encode_hex(eth_receipt:logs_bloom(Terms)))/binary>>,
      <<"logs">> => Ls}.

un0x(<<"0x", R/binary>>) -> binary:decode_hex(R);
un0x(B) when is_binary(B) -> binary:decode_hex(B).

pair(Blocks) ->
    [{eth_hex:decode(maps:get(<<"number">>, B)), B, true} || B <- Blocks].

rpc(Port, Payload) ->
    Body = thoas:encode(Payload),
    {ok, {{_, 200, _}, _, Resp}} =
        httpc:request(post, {"http://127.0.0.1:" ++ integer_to_list(Port),
                             [{"content-type", "application/json"}],
                             "application/json", Body},
                      [{timeout, 10000}], [{body_format, binary}]),
    thoas:decode(Resp).
