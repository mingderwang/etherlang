-module(eth_call_tests).

%% End-to-end `eth_call` through the local RPC endpoint. The upstream mock does
%% not implement eth_call, so any EVM failure must fall back to the proxy and
%% surface the upstream error object.

-include_lib("eunit/include/eunit.hrl").

-define(TO, <<"0x000000000000000000000000000000000000000c">>).
-define(TO_RAW, <<"000000000000000000000000000000000000000c">>).
-define(ID, <<"0x0000000000000000000000000000000000000004">>).

z0() -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>.

call_test_() ->
    {timeout, 60000, fun call_case/0}.

call_case() ->
    ok = eth_test_util:start_apps(),

    Mock = 'mock_call_rpc',
    Chain = 'chain_call_rpc',
    Server = 'call_rpc_server',
    Dir = eth_test_util:tmp_dir(),
    Port = eth_test_util:free_port(),

    {ok, _} = eth_mock_node:start_link(Mock),
    {ok, _} = eth_chain:start_link(Chain, Dir),
    eth_rpc_client:init(#{url => eth_mock_node:url(Mock), timeout_ms => 10000}),

    {_, Blocks} = eth_test_util:make_blocks(0, 6, z0(), 0),
    eth_mock_node:set_chain(Mock, Blocks),

    {ok, _} = eth_rpc_server:start_link(Server, #{port => Port, chain => Chain}),

    try
        %% EVM arithmetic runs locally via a code override (upstream has no code).
        {ok, #{<<"result">> := R1}} =
            call(Port, eth_hex:encode_int(5), ?TO, <<"latest">>,
                 #{?TO => #{<<"code">> => <<"0x600360020160005260206000f3">>}}),
        ?assertEqual(5, eth_hex:decode(R1)),

        %% State-override balance is visible to BALANCE.
        BalCode = <<"0x73", ?TO_RAW/binary, "3160005260206000f3">>,
        {ok, #{<<"result">> := R2}} =
            call(Port, eth_hex:encode_int(12), ?TO, <<"latest">>,
                 #{?TO => #{<<"balance">> => <<"0x1000">>,
                            <<"code">> => BalCode}}),
        ?assertEqual(16#1000, eth_hex:decode(R2)),

        %% Precompile (identity, 0x04) is executed locally and returned verbatim.
        {ok, #{<<"result">> := R3}} =
            rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 3,
                        <<"method">> => <<"eth_call">>,
                        <<"params">> => [tx(?ID, <<"0xdeadbeef">>), <<"latest">>]}),
        ?assertEqual(<<"0xdeadbeef">>, R3),

        %% Contract creation (no `to`): init code in `input` runs and returns.
        Init = <<"0x602a60005260206000f3">>,
        {ok, #{<<"result">> := R4}} =
            rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 4,
                        <<"method">> => <<"eth_call">>,
                        <<"params">> => [#{<<"from">> => ?TO, <<"input">> => Init},
                                         <<"latest">>]}),
        ?assertEqual(42, eth_hex:decode(R4)),

        %% The legacy `data` key is accepted for init code too.
        {ok, #{<<"result">> := R4b}} =
            rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 41,
                        <<"method">> => <<"eth_call">>,
                        <<"params">> => [#{<<"from">> => ?TO, <<"data">> => Init},
                                         <<"latest">>]}),
        ?assertEqual(42, eth_hex:decode(R4b)),

        %% `data` also feeds CALLDATA: CALLDATASIZE of 4 bytes returns 4.
        CdsCode = <<"0x3660005260206000f3">>,
        {ok, #{<<"result">> := R4c}} =
            rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 42,
                        <<"method">> => <<"eth_call">>,
                        <<"params">> => [#{<<"to">> => ?TO,
                                           <<"data">> => <<"0xaabbccdd">>},
                                         <<"latest">>,
                                         #{?TO => #{<<"code">> => CdsCode}}]}),
        ?assertEqual(4, eth_hex:decode(R4c)),

        %% Revert surfaces an execution-reverted error with the revert data.
        RevertCode = <<"0x604260205260206020fd">>,
        {ok, #{<<"error">> := Err5}} =
            call(Port, eth_hex:encode_int(5), ?TO, <<"latest">>,
                 #{?TO => #{<<"code">> => RevertCode}}),
        ?assertEqual(-32000, maps:get(<<"code">>, Err5)),
        ?assertEqual(<<"execution reverted">>, maps:get(<<"message">>, Err5)),
        Data5 = maps:get(<<"data">>, Err5),
        ?assertEqual(16#42, eth_hex:decode(Data5)),

        %% Block-context: NUMBER returns the requested block number.
        NumCode = <<"0x4360005260206000f3">>,
        {ok, #{<<"result">> := R6}} =
            call(Port, eth_hex:encode_int(6), ?TO, <<"0x2">>,
                 #{?TO => #{<<"code">> => NumCode}}),
        ?assertEqual(2, eth_hex:decode(R6)),

        %% No code on the target -> empty result, served locally.
        {ok, #{<<"result">> := R7}} =
            rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 7,
                        <<"method">> => <<"eth_call">>,
                        <<"params">> => [tx(?TO, <<"0x">>), <<"latest">>]}),
        ?assertEqual(<<"0x">>, R7),

        %% Unsupported opcode -> local EVM bails, proxies upstream, and the
        %% upstream (mock) error object comes back verbatim.
        {ok, #{<<"error">> := Err8}} =
            call(Port, eth_hex:encode_int(8), ?TO, <<"latest">>,
                 #{?TO => #{<<"code">> => <<"0x21">>}}),
        ?assertEqual(-32601, maps:get(<<"code">>, Err8)),
        ?assertEqual(<<"method not found: eth_call">>, maps:get(<<"message">>, Err8))
    after
        _ = try gen_server:stop(Server) catch _:_ -> ok end,
        _ = try gen_server:stop(Chain) catch _:_ -> ok end,
        _ = try gen_server:stop(Mock) catch _:_ -> ok end
    end.

%% Send an eth_call carrying a state-override set.
call(Port, Id, To, Block, Overrides) ->
    rpc(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                <<"method">> => <<"eth_call">>,
                <<"params">> => [tx(To, <<"0x">>), Block, Overrides]}).

tx(To, Input) ->
    #{<<"to">> => To, <<"input">> => Input, <<"gas">> => <<"0x1dcd6500">>}.

rpc(Port, Payload) ->
    URL = "http://127.0.0.1:" ++ integer_to_list(Port),
    Body = thoas:encode(Payload),
    {ok, {{_, 200, _}, _, Resp}} =
        httpc:request(post, {URL, [], "application/json", Body},
                      [{timeout, 10000}], [{body_format, binary}]),
    thoas:decode(Resp).