#!/usr/bin/env escript
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/lib/*/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/etherlang-1.0.0/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/jsx/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/thoas/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/eth_hex/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/eth_unicast/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/eth_word/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/eth_rlp/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/eth_keccak/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/eth_evm_precompiles/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/cowlib/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/ranch/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/cowboy/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/gun/ebin
%%! -pa /Users/mingderwang/projects/bc/etherlang/_build/default/rel/etherlang/lib/etmdc/ebin
%%
%% eth_offline_run.escript
%%
%% Run the exact `eth_call` EVM path **with no network and no node** so a
%% bytecode change can be iterated in seconds instead of through sync.
%%
%% It mirrors what the live node does when handed an eth_call with state
%% overrides (the `code` override is the whole point: it lets you run ANY
%% bytecode locally, not just what upstream has deployed):
%%
%%   1. tx/override JSON  -> eth_state:overrides_from_json/1
%%   2. eth_state:new(Block, Overrides)  -> state overlay with the code injected
%%   3. eth_call:msg_from_tx/1 -> Msg
%%   4. eth_call:env_from_block/2  -> Env (from the requested block)
%%   5. eth_evm:run(Code, Msg, State, Env, Gas) -> halt
%%
%% Relative to the live node, the ONLY difference here is there is no JSON-RPC
%% listener; everything before eth_evm:run/5 is byte-identical.

-mode(compile).

main(_) ->
    io:format("== eth_offline_run: exact override path, no network =="),
    Addr = <<16#0c:160>>,
    AddrHex = eth_hex:encode(Addr),

    %% --- 1. The code we want to run locally (Demo-versioned, honest census) ---
    %% Use the exact arithmetic body solc gave `answer`: real deployed bytecode.
    Demo = demo_deployed(),
    io:format("Demo deployed: ~p bytes~n", [byte_size(Demo)]),

    %% --- 2. override JSON exactly as a client sends the eth_call 3rd param ---
    CodeJson = eth_hex:encode(Demo),
    OverrideJson = #{AddrHex => #{<<"code">> => CodeJson,
                                  <<"balance">> => <<"0x3635c9adc5dea00000">>}},
    Overrides = eth_state:overrides_from_json(OverrideJson),

    %% --- 3. state overlay with the code injected at Addr ---
    BlockNum = 7045400,
    State = eth_state:new(BlockNum, Overrides),

    %% Sanity: the injected code is what we think.
    ReadBack = eth_state:code(State, Addr),
    io:format("override read-back: ~p (~p bytes)~n",
              [byte_size(ReadBack) =:= byte_size(Demo), byte_size(ReadBack)]),

    %% --- 4. Msg + Env exactly as eth_call:call/1 builds them ---
    Msg = eth_call:msg_from_tx(msg_tx(), BlockNum),
    Env = eth_call:env_from_block(block(), <<"latest">>),

    %% --- 5. run it ---
    Code = eth_state:code(State, Addr),
    Result = eth_evm:run(Code, Msg, State, Env, 30000000),
    io:format("~n== eth_evm:run(Demo, answer(1)) OFFLINE =="),
    io:format("~p~n", [Result]),
    case Result of
        {ok, Out, _, _, _} -> io:format(">>> {ok, ~s}~n", [eth_hex:encode(Out)]);
        {revert, Out, _, _, _} -> io:format(">>> REVERT (~s)~n", [eth_hex:encode(Out)]);
        Other -> io:format(">>> ~p~n", [Other])
    end.

msg_tx() ->
    #{<<"to">> => eth_hex:encode(<<16#0c:160>>),
      <<"input">> => <<"0x06f702950000000000000000000000000000000000000000000000000000000000000001">>,
      <<"value">> => <<"0x0">>, <<"gas">> => <<"0x1dcd6500">>,
      <<"from">> => <<"0x0000000000000000000000000000000000000000">>}.

block() ->
    %% Spirit of the block eth_call would resolve `latest` to on Sepolia.
    #{<<"number">> => <<"0x6b83b8">>, <<"timestamp">> => <<"0x>",
      <<"miner">> => <<"0x0000000000000000000000000000000000000000">>,
      <<"gasLimit">> => <<"0x1c9c380">>, <<"mixHash">> => <<0:256>>,
      <<"baseFeePerGas">> => <<"0x3b9aca00">>, <<"blobBaseFee">> => <<"0x">>}.

demo_deployed() ->
    {ok, B} = file:read_file("tools/demo-contract/out/Demo.sol/Demo.json"),
    O = jsx:decode(B, [return_maps]),
    eth_hex:decode(maps:get(<<"object">>,
                            maps:get(<<"deployedBytecode">>, O))).
