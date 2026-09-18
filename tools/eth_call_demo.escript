#!/usr/bin/env escript
%%! -noshell -noinput
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/lib/*/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/etherlang-0.1.0/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/jsx/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/eth_hex/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/eth_evm_precompiles/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/cowlib/ebin

%% eth_call_demo.escript
%%
%% Run the LOCAL EVM on arbitrary code via the exact `eth_call` state-override
%% path the node uses for its 3rd parameter, fully offline. No network, no
%% daemon needed. Two modes:
%%
%%   escript tools/eth_call_demo.escript                 # 3+2=5 arithmetic probe
%%   escript tools/eth_call_demo.escript demo            # solc-compiled Demo.answer
%%
%% The point: prove the local EVM independently of sync/upstream, so you can
%% iterate a contract in seconds. KNOWN LIMIT: the local EVM does NOT yet
%% implement every Cancun/Shanghai opcode that current `solc` (>=0.8.25 default)
%% emits, so real solc 0.8.35 output (PUSH0-family/Cancun) may revert. Compile
%% demo contracts with `--evm-version paris` (or implement the opcodes) until
%% coverage is complete. See README "EVM support" + todo list.

-mode(compile).

main(Args) ->
    Mode = case Args of [M | _] -> M; _ -> <<"arith">> end,
    {Code, Calldata, Name} =
        case Mode of
            <<"demo">> -> {demo_deployed(), demo_calldata(), <<"Demo.answer(1)">>};
            _ -> {<<16#60,16#03, 16#60,16#02, 16#01, 16#60,16#00,16#52,
                  16#60,16#20,16#60,16#00,16#f3>>,
                  <<16#06f70295:32, 16#1:256>>, <<"arith 3+2">>}
        end,

    Addr = <<16#0c:160>>,
    AddrHex = eth_hex:encode(Addr),

    OverridesJson = #{AddrHex => maps:merge(
                                    #{<<"code">> =>
                                          eth_hex:encode(Code)},
                                    case Mode of
                                        <<"demo">> ->
                                            #{<<"balance">> => <<"0x3635c9adc5dea00000">>};
                                        _ -> #{}
                                    end)},
    Overrides = eth_state:overrides_from_json(OverridesJson),
    BlockNum = 7045400,
    State = eth_state:new(BlockNum, Overrides),

    io:format("code read back at ~s: ~p bytes~n",
              [AddrHex, byte_size(eth_state:code(State, Addr))]),

    Msg = #{address => Addr, caller => <<0:160>>, origin => <<0:160>>,
            value => 0, data => Calldata, gas_price => 0, static => false,
            depth => 0, blockNumber => BlockNum},
    Env = #{number => BlockNum, timestamp => 16#63f4d3c0,
            coinbase => <<0:160>>, gas_limit => 30000000,
            prevrandao => <<0:256>>, base_fee => 0, blob_base_fee => 0,
            chain_id => 11155111, blockhash => fun(_) -> undefined end},

    Gas = 30000000,
    io:format("~n== eth_evm:run(~s) OFFLINE (state-override path, exact msg/env) ==~n",
              [Name]),
    io:format("~p~n", [eth_evm:run(Code, Msg, State, Env, Gas)]).

demo_calldata() ->
    %% answer(uint256): selector 0x06f70295, arg 1
    <<16#06f70295:32, 16#1:256>>.

demo_deployed() ->
    {ok, B} = file:read_file(
                filename:join([code:lib_dir(eth_hex), "..", "..", "..",
                               "apps", "etherlang", "..", "etherlang",
                               "..", "etherlang", "tools", "demo-contract",
                               "out", "Demo.sol", "Demo.json"])),
    O = jsx:decode(B, [return_maps]),
    H = maps:get(<<"object">>, maps:get(<<"deployedBytecode">>, O)),
    eth_hex:decode(H).
