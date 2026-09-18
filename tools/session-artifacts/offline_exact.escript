#!/usr/bin/env escript
%%! -pa $(HOME)/projects/bc/etherlang/_build/default/lib/etherlang/ebin
%%! -pa $(HOME)/projects/bc/etherlang/_build/default/lib/eth_hex/ebin
%%! -pa $(HOME)/projects/bc/etherlang/_build/default/lib/sax/ebin
%%! -pa $(HOME)/projects/bc/etherlang/_build/default/lib/jsx/ebin
%%! -pa $(HOME)/projects/bc/etherlang/_build/default/lib/cowboy/ebin
%%! -pa $(HOME)/projects/bc/etherlang/_build/default/lib/ranch/ebin
%%! -pa $(HOME)/projects/bc/etherlang/_build/default/lib/cowlib/ebin
%%! -pa $(HOME)/projects/bc/etherlang/_build/default/lib/coin/ebin
%%! -pa $(HOME)/projects/bc/etherlang/_build/default/lib/thoas/ebin

-mode(compile).

main(_) ->
    DemoBin = demo_deployed(),
    io:format("Demo deployed: ~p bytes~n", [byte_size(DemoBin)]),

    Addr = <<16#0c:160>>,
    AddrHex = eth_hex:encode(Addr),
    CodeHex = eth_hex:encode(DemoBin),

    %% EXACTLY what eth_call:call/1 builds from [Tx, latest, Overrides]:
    Overrides = eth_state:overrides_from_json(
                  #{AddrHex => #{<<"code">> => CodeHex}}),
    State = eth_state:new(7045400, Overrides),

    Env = #{number => 7045400, timestamp => 0, coinbase => <<0:160>>,
            gas_limit => 30000000, prevrandao => <<0:256>>, base_fee => 0,
            blob_base_fee => 0, chain_id => 11155111,
            blockhash => fun(_) -> undefined end},

    Msg = #{address => Addr, caller => <<0:160>>, origin => <<0:160>>,
            value => 0, data => <<16#06f70295:32, 16#1:256>>,
            gas_price => 0, static => false, depth => 0,
            blockNumber => 7045400},

    R = eth_evm:run(DemoBin, Msg, State, Env, 30000000),
    io:format("eth_evm:run(Demo, answer(1), code override) =>~n  ~p~n", [R]).

demo_deployed() ->
    {ok, B} = file:read_file("out/Demo.sol/Demo.json"),
    O = jsx:decode(B, [return_maps]),
    eth_hex:decode(maps:get(<<"object">>, maps:get(<<"deployedBytecode">>, O))).
