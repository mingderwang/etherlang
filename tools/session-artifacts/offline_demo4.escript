#!/usr/bin/env escript
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/lib/*/ebin

-mode(compile).

main(_) ->
    %% EXACT same inputs a live Demo.answer(1) eth_call carries:
    Addr = <<16#cc:160>>,
    AddrHex = eth_hex:encode(Addr),
    Code = demo_deployed(),
    io:format("Demo deployed: ~p bytes~n", [byte_size(Code)]),
    Selector = <<16#06f70295:32>>,
    Data = <<Selector/binary, (<<16#1:256>>)/binary>>,

    %% Mirror eth_call:call/1's params shape:
    %%   [Tx, BlockParam, OverridesJson] -> Overrides = eth_state:overrides_from_json(O)
    Tx = #{<<"to">> => AddrHex, <<"input">> => eth_hex:encode(Data),
           <<"gas">> => <<"0x1dcd6500">>},
    OverridesJson = #{AddrHex => #{<<"code">> => eth_hex:encode(Code)}},
    Overrides = eth_state:overrides_from_json(OverridesJson),
    State0 = eth_state:new(7045400, Overrides),

    %% env_from_block(latest) on sepolia, neutral defaults
    Env = #{number => 7045400, timestamp => 0, coinbase => <<0:160>>,
            gas_limit => 30000000, prevrandao => <<0:256>>, base_fee => 0,
            blob_base_fee => 0, chain_id => 11155111,
            blockhash => fun(_) -> undefined end},

    %% msg_from_tx (to => Addr so msg_code reads override code)
    Msg = #{address => Addr, caller => <<0:160>>, origin => <<0:160>>,
            value => 0, data => Data, gas_price => 0, static => false,
            depth => 0, blockNumber => 7045400},

    Gas = detail:decode(<<"0x1dcd6500">>),
    R = eth_evm:run(Code, Msg, State0, Env, Gas),
    io:format("~n== eth_evm:run(Demo.deployed, answer(1), override) offline =="),
    io:format("~p~n", [R]).

demo_deployed() ->
    {ok, B} = file:read_file("/tmp/demo-contract/out/Demo.sol/Demo.json"),
    O = jsx:decode(B, [return_maps]),
    H = maps:get(<<"object">>, maps:get(<<"deployedBytecode">>, O)),
    eth_hex:decode(H).
