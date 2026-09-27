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
%% ---------------------------------------------------------------------------
%% The fork a simulated block executes under
%% ---------------------------------------------------------------------------

%% The block's own number and timestamp decide which rules a simulated call runs
%% under. Simulating every block under one schedule is the default this test
%% exists to forbid: the answers stay plausible, because PUSH0 pushes zero
%% perfectly well, and only the block being wrong gives them away.
%%
%% This was found by injection and not by reading. Replacing the resolution in
%% `eth_call:env_from_block/2' with a hardcoded `cancun' -- so every block at
%% every height simulated under Cancun rules -- left this module entirely green.
%% What was pinned was the fork *table*; nothing pinned that `eth_call' consults
%% it, and the two facts are independent.
%%
%% The two blocks differ in timestamp and in nothing else that matters, and the
%% timestamps are either side of Sepolia's Shanghai activation at 1677557088. The
%% first assertion is the precondition: without it this test would still pass if
%% both blocks resolved to the same fork, which is the case where it proves
%% nothing.
simulated_block_executes_under_its_own_fork_test_() ->
    {timeout, 30000, fun simulated_block_executes_under_its_own_fork_case/0}.

simulated_block_executes_under_its_own_fork_case() ->
    ok = eth_test_util:start_apps(),
    Mock = 'mock_call_fork_rpc',
    {ok, _} = eth_mock_node:start_link(Mock),
    eth_rpc_client:init(#{url => eth_mock_node:url(Mock), timeout_ms => 10000}),

    {_P, [Pre | _]} = eth_test_util:make_blocks(0, 1, z0(), 0),
    {_P2, [Post]} = eth_test_util:make_blocks(1, 1, maps:get(<<"hash">>, Pre), 0),
    Before = at_timestamp(Pre, 1677557087),
    After = at_timestamp(Post, 1677557088),
    eth_mock_node:set_chain(Mock, [Before, After]),
    try
        %% The precondition: the two blocks really are on opposite sides of
        %% Shanghai, so a difference in the answers below is the fork and not
        %% the bytecode.
        ?assertEqual(london, fork_of(0, 1677557087)),
        ?assertEqual(shanghai, fork_of(1, 1677557088)),
        %% PUSH0 (EIP-3855, Shanghai) and a STOP. Under Shanghai rules the frame
        %% pushes zero and returns nothing; under London rules the byte is not an
        %% instruction at all, so the frame halts and eth_call answers with the
        %% fallback it takes for anything it cannot run.
        ?assertEqual({ok, <<"0x">>},
                     eth_call:call([push0_call(), <<"0x1">>, push0_overrides()])),
        ?assertEqual({error, fallback},
                     eth_call:call([push0_call(), <<"0x0">>, push0_overrides()]))
    after
        _ = try gen_server:stop(Mock) catch _:_ -> ok end
    end.

%% The same resolution the node makes, so the precondition above cannot drift from
%% the thing under test by being written differently.
fork_of(Number, Timestamp) ->
    {ok, Fork} = eth_fork_schedule:current_fork(
                   eth_fork_schedule:configured_network(), Number, Timestamp),
    Fork.

at_timestamp(Block, Timestamp) ->
    Block#{<<"timestamp">> => eth_hex:encode_int(Timestamp)}.

push0_call() ->
    #{<<"to">> => ?TO, <<"input">> => <<"0x">>, <<"gas">> => <<"0x1dcd6500">>}.

push0_overrides() ->
    #{?TO => #{<<"code">> => <<"0x5f00">>}}.
