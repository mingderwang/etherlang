#!/usr/bin/env escript
-mode(compile).

main(_) ->
    code:add_patha(os:getenv("HOME") ++ "/projects/bc/etherlang/_build/default/lib/etherlang/ebin"),
    code:add_patha(os:getenv("HOME") ++ "/projects/bc/etherlang/_build/default/lib/eth_hex/ebin"),
    Demo = read_demo(),
    %% Replicate eth_call: constants
    DefGas = 30000000,
    Env = eth_call_env(),
    Msg = eth_call_msg(),
    S0 = eth_state_overrides(),
    run_one("3+2=5 (KNOWN GOOD)", eth_hex_to_bin(<<"0x600360020160005260206000f3">>), <<>>, S0, Env, DefGas),
    run_one("Demo.answer(1)", Demo, eth_hex_to_bin(<<"0x06f702950000000000000000000000000000000000000000000000000000000000000001">>), S0, Env, DefGas),
    ok.

run_one(Name, Code, Data, State, Env, Gas) ->
    Msg = #{address => <<0:160>>, caller => <<0:160>>, origin => <<0:160>>,
            value => 0, data => Data, gas_price => 0, static => false,
            depth => 0, blockNumber => 7045400},
    io:format("~n=== ~s === (~p bytes)~n", [Name, byte_size(Code)]),
    R = eth_evm:run(Code, Msg, State, Env, Gas),
    io:format("  -> ~p~n", [R]).

%% Minimal Env matching eth_call_env_from_block defaults.
eth_call_env() ->
    #{number => 7045400, timestamp => 0, coinbase => <<0:160>>,
      gas_limit => 30000000, prevrandao => <<0:256>>, base_fee => 0,
      blob_base_fee => 0, chain_id => 11155111,
      blockhash => fun(_) -> undefined end}.

eth_call_msg() ->
    #{address => <<0:160>>, caller => <<0:160>>, origin => <<0:160>>,
      value => 0, data => <<>>, gas_price => 0, static => false,
      depth => 0, blockNumber => 7045400}.

eth_state_overrides() ->
    eth_state:new(7045400, []).

read_demo() -> eth_hex_to_bin(demo_bytes()).
demo_bytes() -> demo_bytes_fromfile().
demo_bytes_fromfile() ->
    %% Even if a stale copy exists, only parse opcodes; empty if missing.
    try
        {ok, B} = file:read_file("/tmp/demo-contract/out/Demo.sol/Demo.json"),
        O = jsx:decode(B, [return_maps]),
        maps:get(<<"object">>, maps:get(<<"deployedBytecode">>, O))
    catch _:_ -> <<"0x">> end.

eth_hex_to_bin(<<"0x", H/binary>>) -> binary:decode_hex(H);
eth_hex_to_bin(H) -> binary:decode_hex(H).
