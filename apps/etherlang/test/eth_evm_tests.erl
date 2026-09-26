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

%% EIP-145 SHL/SHR/SAR: stack-top is the shift AMOUNT, word below is the
%% VALUE being shifted (Fun(Value, Amount), not Fun(Amount, Value)).  These
%% three are the regression for the foundry/solidity selector-dispatch bug
%% (SHR 0xe0 on a CALLDATALOAD'd selector compared to PUSH4).
shr_operand_order_test() ->
    %% PUSH2 0x0100, PUSH1 4, SHR, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
    %% value=0x100 >> amount=4 -> 0x10 (16).  Buggy order (4>>0x100) -> 0.
    Code = <<16#61,16#01,16#00, 16#60,4, 16#1C, 16#60,0, 16#52, 16#60,32, 16#60,0, 16#F3>>,
    {ok, Out, _Gas, _St, []} = eth_evm:run(Code, ?MSG0, ?STATE, ?ENV, ?GAS),
    ?assertEqual(16, binary:decode_unsigned(Out)).

shl_operand_order_test() ->
    %% PUSH1 1, PUSH1 4, SHL -> 1 << 4 = 16.  Buggy order (4<<1) -> 8.
    Code = <<16#60,1, 16#60,4, 16#1B, 16#60,0, 16#52, 16#60,32, 16#60,0, 16#F3>>,
    {ok, Out, _Gas, _St, []} = eth_evm:run(Code, ?MSG0, ?STATE, ?ENV, ?GAS),
    ?assertEqual(16, binary:decode_unsigned(Out)).

sar_operand_order_test() ->
    %% PUSH2 0x0100, PUSH1 4, SAR -> 0x100 >> 4 = 16 (arithmetic, positive).
    Code = <<16#61,16#01,16#00, 16#60,4, 16#1D, 16#60,0, 16#52, 16#60,32, 16#60,0, 16#F3>>,
    {ok, Out, _Gas, _St, []} = eth_evm:run(Code, ?MSG0, ?STATE, ?ENV, ?GAS),
    ?assertEqual(16, binary:decode_unsigned(Out)).

%% The full solidity-style selector dispatcher: load calldata[0:32], SHR by
%% 0xe0, compare to PUSH4 0x85bb7d69, JUMPI to the "answer" body or fall to
%% the empty REVERT.  This is the exact pattern forge/foundry bytecode uses
%% and was 100%-reverting before the shift fix.
selector_dispatch_returns_42_test() ->
    Code = <<16#60,16#00, 16#35,                       %% PUSH1 0, CALLDATALOAD
             16#60,16#E0, 16#1C,                       %% PUSH1 0xe0, SHR
             16#80, 16#63,16#85,16#bb,16#7d,16#69, 16#14,  %% DUP1 PUSH4 sel EQ
             16#61,16#00,16#15, 16#57,                 %% PUSH2 0x15 JUMPI
             16#60,16#00, 16#80, 16#FD,                %% fallback: REVERT(0,0)
             16#5B,                                    %% JUMPDEST
             16#60,16#2A, 16#60,0, 16#52,              %% answer: PUSH1 42, MSTORE
             16#60,32, 16#60,0, 16#F3>>,               %% RETURN 32 bytes
    Msg0 = ?MSG0,
    Msg = Msg0#{data => <<16#85bb7d69:32>>},
    {ok, Out, _Gas, _St, []} = eth_evm:run(Code, Msg, ?STATE, ?ENV, ?GAS),
    ?assertEqual(32, byte_size(Out)),
    ?assertEqual(42, binary:decode_unsigned(Out)).

selector_dispatch_wrong_selector_reverts_test() ->
    Code = <<16#60,16#00, 16#35,
             16#60,16#E0, 16#1C,
             16#80, 16#63,16#85,16#bb,16#7d,16#69, 16#14,
             16#61,16#00,16#15, 16#57,
             16#60,16#00, 16#80, 16#FD,
             16#5B,
             16#60,16#2A, 16#60,0, 16#52,
             16#60,32, 16#60,0, 16#F3>>,
    Msg0 = ?MSG0,
    Msg = Msg0#{data => <<16#12345678:32>>},
    ?assertMatch({revert, <<>>, _, _, _},
                 eth_evm:run(Code, Msg, ?STATE, ?ENV, ?GAS)).

%% ---------------------------------------------------------------------------
%% Value-transfer + revert semantics (P0 regression set)
%% ---------------------------------------------------------------------------

%% All overlay keys a CALL/CREATE touches are seeded here so no test ever
%% performs a lazy upstream fetch (unit tests run with no RPC client).
-define(CALLER, <<0:160>>).
-define(CALLEE, <<0:152, 16#0D:8>>).

call_state(CallerBal, CalleeCode) ->
    eth_state:new(0, #{{balance, ?CALLER} => CallerBal,
                       {nonce, ?CALLER} => 0,
                       {balance, ?CALLEE} => 0,
                       {nonce, ?CALLEE} => 0,
                       {code, ?CALLEE} => CalleeCode}).

%% CALL stack: retlen, retoff, argslen, argsoff, value, to, gas.
call_seq(ToByte, Value, Op) ->
    <<16#60,0, 16#60,0, 16#60,0, 16#60,0, 16#60,Value,
      16#60,ToByte, 16#61,16#FF,16#FF, Op>>.

call_value_revert_rolls_back_test() ->
    %% Callee immediately reverts; the 40 wei sent must come back.
    Revert = <<16#60,0, 16#60,0, 16#FD>>,
    Parent = <<(call_seq(16#0D, 40, 16#F1))/binary, 16#00>>,
    {ok, _, _, St, _} = eth_evm:run(Parent, ?MSG0, call_state(100, Revert),
                                    ?ENV, ?GAS),
    ?assertEqual(100, eth_state:balance(St, ?CALLER)),
    ?assertEqual(0, eth_state:balance(St, ?CALLEE)).

call_insufficient_balance_fails_cleanly_test() ->
    %% Caller holds 10, sends 40: call fails, no state change (old code
    %% wrapped the debit to 2^256-30 and credited the callee).
    Revert = <<16#60,0, 16#60,0, 16#FD>>,
    Parent = <<(call_seq(16#0D, 40, 16#F1))/binary, 16#00>>,
    {ok, _, _, St, _} = eth_evm:run(Parent, ?MSG0, call_state(10, Revert),
                                    ?ENV, ?GAS),
    ?assertEqual(10, eth_state:balance(St, ?CALLER)),
    ?assertEqual(0, eth_state:balance(St, ?CALLEE)).

create_revert_keeps_nonce_drops_value_test() ->
    %% Init code reverts: value returns, nonce stays consumed, nothing deployed.
    Init = <<16#60,0, 16#60,0, 16#FD>>,
    <<_:12/binary, NewAddr:20/binary>> =
        eth_keccak:hash(eth_rlp:encode([?CALLER, 5])),
    State0 = eth_state:new(0, #{{balance, ?CALLER} => 100,
                                {nonce, ?CALLER} => 5,
                                {balance, NewAddr} => 0,
                                {nonce, NewAddr} => 0,
                                {code, NewAddr} => <<>>}),
    %% CODECOPY 5 bytes of init from pc 15, then CREATE(value 40).
    Parent = <<16#60,5, 16#60,15, 16#60,0, 16#39,
               16#60,5, 16#60,0, 16#60,40, 16#F0, 16#00,
               Init/binary>>,
    {ok, _, _, St, _} = eth_evm:run(Parent, ?MSG0, State0, ?ENV, ?GAS),
    ?assertEqual(6, eth_state:nonce(St, ?CALLER)),
    ?assertEqual(100, eth_state:balance(St, ?CALLER)),
    ?assertEqual(<<>>, eth_state:code(St, NewAddr)).

%% ---------------------------------------------------------------------------
%% EIP-1153 transient storage is transaction-global (P0 regression set)
%% ---------------------------------------------------------------------------

transient_survives_delegatecall_test() ->
    %% Callee stores 99 transiently; parent (same address via DELEGATECALL)
    %% reads it back. Lost entirely before the scoping fix.
    Child = <<16#60,99, 16#60,7, 16#5D, 16#00>>,
    Parent = <<(call_seq(16#0D, 0, 16#F4))/binary,
               16#60,7, 16#5C, 16#60,0, 16#52, 16#60,32, 16#60,0, 16#F3>>,
    {ok, Out, _, _, _} = eth_evm:run(Parent, ?MSG0, call_state(0, Child),
                                     ?ENV, ?GAS),
    ?assertEqual(99, binary:decode_unsigned(Out)).

transient_discarded_on_child_revert_test() ->
    %% Parent stores 42, child overwrites to 99 then reverts: parent must
    %% still read 42 (child frame discarded, parent frame intact).
    Child = <<16#60,99, 16#60,7, 16#5D, 16#60,0, 16#60,0, 16#FD>>,
    Parent = <<16#60,42, 16#60,7, 16#5D,
               (call_seq(16#0D, 0, 16#F4))/binary,
               16#60,7, 16#5C, 16#60,0, 16#52, 16#60,32, 16#60,0, 16#F3>>,
    {ok, Out, _, _, _} = eth_evm:run(Parent, ?MSG0, call_state(0, Child),
                                     ?ENV, ?GAS),
    ?assertEqual(42, binary:decode_unsigned(Out)).

%% ---------------------------------------------------------------------------
%% Fallback honesty + log propagation (P0 regression set)
%% ---------------------------------------------------------------------------

blobhash_falls_back_test() ->
    %% BLOBHASH must proxy upstream (unsupported), never fabricate zero.
    Code = <<16#60,0, 16#49, 16#00>>,
    ?assertMatch({error, {unsupported, {opcode, 16#49}}, _, _},
                 eth_evm:run(Code, ?MSG0, ?STATE, ?ENV, ?GAS)).

child_logs_propagate_test() ->
    %% Callee emits one LOG0; the top-level run must report it (was dropped).
    Child = <<16#60,0, 16#60,0, 16#A0, 16#00>>,
    Parent = <<(call_seq(16#0D, 0, 16#F1))/binary, 16#00>>,
    {ok, _, _, _, Logs} = eth_evm:run(Parent, ?MSG0, call_state(0, Child),
                                      ?ENV, ?GAS),
    ?assertEqual(1, length(Logs)).

%% ---------------------------------------------------------------------------
%% EIP-2929 warm/cold access costs (gas-observable via GasLeft)
%% ---------------------------------------------------------------------------

sload_cold_then_warm_test() ->
    %% First SLOAD: 100 base + 2000 cold; second: 100 warm.
    %% PUSH1x2 (6) + 2100 + POP (2) + 100 + POP (2) + STOP (0) = 2210.
    State = eth_state:new(0, #{{store, ?CALLER, 5} => 77}),
    Code = <<16#60,5, 16#54, 16#50, 16#60,5, 16#54, 16#50, 16#00>>,
    {ok, _, GasLeft, _, _} = eth_evm:run(Code, ?MSG0, State, ?ENV, ?GAS),
    ?assertEqual(?GAS - 2210, GasLeft).

balance_cold_then_warm_test() ->
    %% First BALANCE: 100 base + 2500 cold; second: 100 warm.
    %% PUSH1x2 (6) + 2600 + POP (2) + 100 + POP (2) + STOP (0) = 2710.
    Tgt = <<0:152, 16#0E:8>>,
    State = eth_state:new(0, #{{balance, Tgt} => 123,
                                {nonce, Tgt} => 0,
                                {code, Tgt} => <<>>}),
    Code = <<16#60,16#0E, 16#31, 16#50, 16#60,16#0E, 16#31, 16#50, 16#00>>,
    {ok, _, GasLeft, _, _} = eth_evm:run(Code, ?MSG0, State, ?ENV, ?GAS),
    ?assertEqual(?GAS - 2710, GasLeft).

%% ---------------------------------------------------------------------------
%% Environment-reading opcodes cost 20, not 2
%% ---------------------------------------------------------------------------

%% BASEFEE, BLOBHASH and BLOBBASEFEE were priced at 2, 3 and 2. That is not a
%% rounding difference: 2 is the price of the ADDRESS family, and these three
%% were pulled into that block by a range clause. A contract that reads the
%% base fee in a loop -- which is most DeFi code that computes what a swap is
%% worth -- was charged a tenth of the real price, so it ran roughly ten times
%% deeper before hitting the gas limit than it should have, and a block's
%% gasUsed came out low by that factor. The two implemented ones are measured
%% through the gas they leave behind; BLOBHASH is measured by the boundary,
%% because the EVM refuses to execute it and so never reports a remainder.

basefee_costs_20_test() ->
    %% BASEFEE + STOP.
    {ok, _, GasLeft, _, _} = eth_evm:run(<<16#48, 16#00>>, ?MSG0, ?STATE, ?ENV, ?GAS),
    ?assertEqual(?GAS - 20, GasLeft).

blobbasefee_costs_20_test() ->
    {ok, _, GasLeft, _, _} = eth_evm:run(<<16#4A, 16#00>>, ?MSG0, ?STATE, ?ENV, ?GAS),
    ?assertEqual(?GAS - 20, GasLeft).

blobhash_costs_20_test() ->
    %% PUSH1 the index (3), then BLOBHASH. At 20 gas the opcode is reached and
    %% reports `unsupported`; one gas short, the charge itself fails and the
    %% run is out-of-gas instead. That boundary is the cost, and it is the only
    %% place BLOBHASH's price is observable at all, since the opcode never
    %% executes and so never returns a gas remainder.
    Code = <<16#60,0, 16#49>>,
    ?assertMatch({error, {unsupported, {opcode, 16#49}}, _, _},
                 eth_evm:run(Code, ?MSG0, ?STATE, ?ENV, 23)),
    ?assertMatch({error, out_of_gas, _, _},
                 eth_evm:run(Code, ?MSG0, ?STATE, ?ENV, 22)).

%% A base fee read costs the same whatever the environment says, so the price
%% cannot be moved by choosing a base fee.
basefee_cost_does_not_depend_on_the_value_test() ->
    {ok, _, Absent, _, _} = eth_evm:run(<<16#48, 16#00>>, ?MSG0, ?STATE, ?ENV, ?GAS),
    Env = #{base_fee => 1000000000},
    {ok, _, Present, _, _} = eth_evm:run(<<16#48, 16#00>>, ?MSG0, ?STATE, Env, ?GAS),
    ?assertEqual(Absent, Present),
    ?assertEqual(?GAS - 20, Present).

%% ---------------------------------------------------------------------------
%% EIP-6780 SELFDESTRUCT (P0 regression set)
%% ---------------------------------------------------------------------------

%% SELFDESTRUCT stack: beneficiary only.
selfdestruct_seq(BenByte) ->
    <<16#60,BenByte, 16#FF>>.

selfdestruct_other_tx_keeps_code_test() ->
    %% Victim NOT created in this tx: balance moves, code and storage stay
    %% (EIP-6780). Old code happened to match on code (it never deleted),
    %% so this locks the specified behavior.
    VictimCode = <<16#60,1, 16#60,0, 16#52, 16#60,32, 16#60,0, 16#F3>>,
    Ben = <<0:152, 16#0E:8>>,
    State0 = eth_state:new(0, #{{balance, ?CALLEE} => 70,
                                {nonce, ?CALLEE} => 0,
                                {code, ?CALLEE} => VictimCode,
                                {store, ?CALLEE, 3} => 9,
                                {balance, Ben} => 0,
                                {balance, ?CALLER} => 0,
                                {nonce, ?CALLER} => 0}),
    Msg0 = ?MSG0,
    Msg = Msg0#{address => ?CALLEE},
    {ok, _, _, St, _} = eth_evm:run(selfdestruct_seq(16#0E), Msg, State0,
                                    ?ENV, ?GAS),
    ?assertEqual(0, eth_state:balance(St, ?CALLEE)),
    ?assertEqual(70, eth_state:balance(St, Ben)),
    ?assertEqual(VictimCode, eth_state:code(St, ?CALLEE)),
    ?assertEqual(9, eth_state:storage(St, ?CALLEE, 3)).

selfdestruct_same_tx_destroys_test() ->
    %% Victim created, then CALLED in the same run: its runtime
    %% self-destructs -> full deletion (code gone, storage shadowed).
    %% Init stores 8 at slot 1 and RETURNS the self-destructing runtime
    %% (3 bytes at init offset 17); it must not execute it inline.
    Runtime = selfdestruct_seq(16#0E),
    Init = <<16#60,8, 16#60,1, 16#55,
             16#60,3, 16#60,17, 16#60,0, 16#39,
             16#60,3, 16#60,0, 16#F3,
             Runtime/binary>>,
    InitLen = byte_size(Init),
    <<_:12/binary, NewAddr:20/binary>> =
        eth_keccak:hash(eth_rlp:encode([?CALLER, 0])),
    Ben = <<0:152, 16#0E:8>>,
    State0 = eth_state:new(0, #{{balance, ?CALLER} => 100,
                                {nonce, ?CALLER} => 0,
                                {balance, NewAddr} => 0,
                                {nonce, NewAddr} => 0,
                                {code, NewAddr} => <<>>,
                                %% SSTORE gas tiering reads current value:
                                %% seed so the test never fetches upstream.
                                {store, NewAddr, 1} => 0,
                                {balance, Ben} => 0}),
    %% CODECOPY init from pc 50, CREATE(value 0), then CALL the deployment.
    Parent = <<16#60,InitLen:8, 16#60,50, 16#60,0, 16#39,
               16#60,InitLen:8, 16#60,0, 16#60,0, 16#F0,
               16#60,0, 16#60,0, 16#60,0, 16#60,0, 16#60,0,
               16#73, NewAddr:20/binary, 16#61,16#FF,16#FF, 16#F1,
               16#00,
               Init/binary>>,
    {ok, _, _, St, _} = eth_evm:run(Parent, ?MSG0, State0, ?ENV, ?GAS),
    ?assertEqual(1, eth_state:nonce(St, ?CALLER)),
    ?assertEqual(100, eth_state:balance(St, ?CALLER)),
    ?assertEqual(0, eth_state:balance(St, Ben)),
    ?assertEqual(<<>>, eth_state:code(St, NewAddr)),
    ?assertEqual(0, eth_state:storage(St, NewAddr, 1)),
    ?assertEqual(false, eth_state:exists(St, NewAddr)).
