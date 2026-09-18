#!/usr/bin/env escript
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/lib/etherlang/ebin
-main(_) ->
    {ok, J} = file:read_file("/tmp/demo-contract/out/Demo.sol/Demo.json"),
    Obj = jsx:decode(J, [return_maps]),
    BinHex = maps:get(<<"object">>, maps:get(<<"deployedBytecode">>, Obj)),
    Bin = eth_hex:decode(BinHex),
    io:format("deployed code ~p bytes~n", [byte_size(Bin)]),

    %% Replicate exactly what eth_call.erl does:
    %%   State = eth_state:new(BlockNumber, Overrides),
    %%   Code = maps:get({code, To}, Overrides, _)  %% override wins
    %%   Msg/Env from tx; Gas default.
    Overrides = #{};
    _ = Overrides,
    To = <<16#0c:160>>,
    State = eth_state:new(7045400, #{}),
    St2 = eth_state:set_code(State, To, Bin),

    Msg = #{address => To, caller => <<0:160>>, origin => <<0:160>>,
            value => 0,
            %% answer(1): selector 06f70295 + arg 1
            data => <<16#06f70295:32, 16#1:256>>,
            gas_price => 0, static => false, depth => 0, blockNumber => 7045400},
    Env = #{number => 7045400, timestamp => 0, coinbase => <<0:160>>,
            gas_limit => 30000000, prevrandao => <<0:256>>, base_fee => 0,
            blob_base_fee => 0, chain_id => 11155111,
            blockhash => fun(_) -> undefined end},

    R = eth_evm:run(Bin, Msg, St2, Env, 30000000),
    io:format("RESULT = ~p~n", [R]).
