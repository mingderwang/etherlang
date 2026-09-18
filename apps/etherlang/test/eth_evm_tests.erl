-module(eth_evm_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MSG0, #{address => <<0:160>>, caller => <<0:160>>, origin => <<0:160>>,
               value => 0, data => <<>>, gas_price => 0, static => false, depth => 0}).

-define(STATE, (eth_state:new(0, #{{store, <<0:160>>, 0} => 0}))).
-define(ENV, #{}).
-define(GAS, 1000000).

add_return_test() ->
    %% PUSH1 2, PUSH1 3, ADD, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
    Code = <<16#60,2, 16#60,3, 16#01, 16#60,0, 16#52, 16#60,32, 16#60,0, 16#F3>>,
    {ok, Out, Gas, _St, []} = eth_evm:run(Code, ?MSG0, ?STATE, ?ENV, ?GAS),
    ?assertEqual(32, byte_size(Out)),
    ?assertEqual(5, binary:decode_unsigned(Out)),
    ?assert(Gas > 0).

sstore_sload_test() ->
    %% PUSH1 0x2a, PUSH1 0, SSTORE, PUSH1 0, SLOAD, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
    Code = <<16#60,16#2a, 16#60,0, 16#55, 16#60,0, 16#54, 16#60,0, 16#52, 16#60,32, 16#60,0, 16#F3>>,
    {ok, Out, _Gas, _St, []} = eth_evm:run(Code, ?MSG0, ?STATE, ?ENV, ?GAS),
    ?assertEqual(42, binary:decode_unsigned(Out)).

revert_test() ->
    Code = <<16#60,0, 16#60,0, 16#FD>>,
    ?assertMatch({revert, <<>>, _, _, _}, eth_evm:run(Code, ?MSG0, ?STATE, ?ENV, ?GAS)).

invalid_opcode_test() ->
    Code = <<16#FE>>,
    ?assertMatch({error, invalid_opcode, _, _}, eth_evm:run(Code, ?MSG0, ?STATE, ?ENV, ?GAS)).

stack_underflow_test() ->
    %% ADD with empty stack
    Code = <<16#01>>,
    ?assertMatch({error, {evm_crash, error, function_clause, _}, _, _},
                 eth_evm:run(Code, ?MSG0, ?STATE, ?ENV, ?GAS)).

keccak_test() ->
    %% PUSH1 0, PUSH1 0, KECCAK256, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
    Code = <<16#60,0, 16#60,0, 16#20, 16#60,0, 16#52, 16#60,32, 16#60,0, 16#F3>>,
    {ok, Out, _Gas, _St, []} = eth_evm:run(Code, ?MSG0, ?STATE, ?ENV, ?GAS),
    Expected = eth_keccak:hash(<<>>),
    ?assertEqual(Expected, Out).

identity_call_test() ->
    %% Store 0x2a at mem 0, call identity precompile (addr 4), return result
    Code = <<16#60,16#2a, 16#60,0, 16#52,          %% push 42, push 0, mstore
             16#60,32, 16#60,32, 16#60,32, 16#60,0,
             16#60,0, 16#60,4, 16#61,16#ff,16#ff, 16#F1, %% call
             16#50,                                  %% pop success
             16#60,32, 16#60,32, 16#F3>>,            %% return 32 bytes from mem[32]
    {ok, Out, _Gas, _St, []} = eth_evm:run(Code, ?MSG0, ?STATE, ?ENV, ?GAS),
    ?assertEqual(32, byte_size(Out)),
    ?assertEqual(42, binary:decode_unsigned(Out)).

block_env_test() ->
    %% TIMESTAMP PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
    Code = <<16#42, 16#60,0, 16#52, 16#60,32, 16#60,0, 16#F3>>,
    Msg0 = ?MSG0,
    Msg = Msg0#{data => <<>>},
    Env = #{timestamp => 12345},
    {ok, Out, _Gas, _St, []} = eth_evm:run(Code, Msg, ?STATE, Env, ?GAS),
    ?assertEqual(12345, binary:decode_unsigned(Out)).

static_sstore_test() ->
    Code = <<16#60,1, 16#60,0, 16#55>>,
    Msg0 = ?MSG0,
    Msg = Msg0#{static => true},
    ?assertMatch({error, write_protection, _, _},
                 eth_evm:run(Code, Msg, ?STATE, ?ENV, ?GAS)).

jumpdest_test() ->
    %% Infinite loop bounded by gas: loop back to pc 2.
    Code = <<16#60,2, 16#5B, 16#60,2, 16#56>>,
    ?assertMatch({error, out_of_gas, _, _},
                 eth_evm:run(Code, ?MSG0, ?STATE, ?ENV, 30)).
