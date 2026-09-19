#!/usr/bin/env escript
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/etherlang-0.1.0/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/jsox/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/thoas/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/eth_keccak/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/eth_evm_precompiles/ebin
%%
%% offline_evm.escript <runtimebytecode.hex> <calldata.hex>
%% Runs eth_evm:run/5 on the given deployed bytecode with the given calldata,
%% exactly like eth_call with a "code" state override. Returns the VM result.

-mode(compile).

main([]) ->
    io:format("usage: offline_evm.escript <deployed-hex> <calldata-hex>~n");
main([CodeHex, DataHex]) ->
    AddrHexB = <<"0x000000000000000000000000000000000000000c">>,
    Addr = eth_state:address(AddrHexB),
    Code = eth_state:hex_to_bin(CodeHex),
    OverrideJson = #{AddrHexB => #{<<"code">> => CodeHex}},
    Overrides = eth_state:overrides_from_json(OverrideJson),
    State = eth_state:new(7045400, Overrides),
    Env = #{number => 7045400,
            timestamp => 16#660d45b0,
            coinbase => eth_state:address(<<"0x0000000000000000000000000000000000000000">>),
            gas_limit => 16#1c9c380,
            prevrandao => <<0:256>>,
            base_fee => 16#3b9aca00,
            blob_base_fee => 0,
            chain_id => 11155111,
            blockhash => fun(_) -> undefined end},
    Msg = #{address => Addr,
            caller => eth_state:address(<<"0x0000000000000000000000000000000000000000">>),
            origin => eth_state:address(<<"0x0000000000000000000000000000000000000000">>),
            value => 0,
            data => eth_state:hex_to_bin(DataHex),
            gas_price => 0,
            static => false,
            depth => 0,
            blockNumber => 7045400},
    Result = eth_evm:run(Code, Msg, State, Env, 30000000),
    io:format("~p~n", [Result]).