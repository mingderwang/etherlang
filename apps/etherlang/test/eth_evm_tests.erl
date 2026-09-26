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
    <<(call_args(ToByte, Value))/binary, Op>>.

%% The same seven arguments with the opcode left off, so the cost of the pushes
%% can be measured and subtracted rather than written down as a constant.
call_args(ToByte, Value) ->
    <<16#60,0, 16#60,0, 16#60,0, 16#60,0, 16#60,Value,
      16#60,ToByte, 16#61,16#FF,16#FF>>.

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
%% The CALL family has no base cost of its own
%% ---------------------------------------------------------------------------

%% EIP-2929 prices a call as its access cost and nothing else: 2600 cold, 100
%% warm, plus 9000 for a value transfer and 25000 when the destination account
%% does not yet exist, plus memory expansion of the argument and return regions.
%% do_call/3 charges all of that, so base_cost/1 has nothing left to add and must
%% be 0 for all four opcodes.
%%
%% DELEGATECALL was the only one that said so. CALL, CALLCODE and STATICCALL said
%% nothing at all and fell to the catch-all, which charges 3. So every CALL,
%% CALLCODE and STATICCALL in every block was charged 3 gas more than the
%% specification says, while DELEGATECALL was correct.
%%
%% Three gas changes no execution outcome, which is why nothing caught it: no
%% test fails, no contract behaves differently, the node still tracks the head.
%% But gasUsed is a field in a receipt, the receipts root is in the block header,
%% and the header is hashed -- so this is exactly the class of difference that
%% makes an otherwise-correct execution compute the wrong block hash.
call_family_has_no_base_cost_of_its_own_test() ->
    [?assertEqual({call_name(Op), 2600},
                  {call_name(Op), call_gas(Op, cold, funded)})
     || Op <- [16#F1, 16#F2, 16#F4, 16#FA]],
    ok.

%% ...and the same four once the target is warm. This is what separates "the
%% access cost is right" from "the total happens to come out right": the three
%% gas in question are independent of warm/cold, so a table wrong in both places
%% could pass the cold case alone.
call_family_warm_target_costs_one_hundred_test() ->
    [?assertEqual({call_name(Op), 100},
                  {call_name(Op), call_gas(Op, warm, funded)})
     || Op <- [16#F1, 16#F2, 16#F4, 16#FA]],
    ok.

%% The two optional terms, and the condition on the second: the 25000 new-account
%% charge only applies to a call that transfers value, because a call that
%% transfers nothing cannot create an account. Charging it on a zero-value call
%% would make every read-only call cost 25000 more than it should.
call_optional_terms_follow_the_specification_test() ->
    NoValue = call_gas(16#F1, cold, funded),
    WithValue = call_gas(16#F1, cold, funded_with_value),
    NewAccount = call_gas(16#F1, cold, empty_account),
    ?assertEqual(NoValue + 9000, WithValue),
    ?assertEqual(WithValue + 25000, NewAccount).

%% Gas one call opcode costs, measured by running the argument pushes, the call
%% and a STOP. The pushes and the warm-up are measured and subtracted rather than
%% written down, so what is asserted is a statement about the call rather than
%% about the code wrapped around it.
call_gas(Op, Warm, Account) ->
    Warmup = case Warm of
                 cold -> <<>>;
                 warm -> <<16#60,16#0D, 16#31, 16#50>>
             end,
    {State, Value, ToByte} = case Account of
                                funded -> {call_state(1000000, <<16#00>>), 0, 16#0D};
                                funded_with_value ->
                                    {call_state(1000000, <<16#00>>), 40, 16#0D};
                                empty_account ->
                                    {empty_target_state(), 40, 16#0E}
                            end,
    Code = <<Warmup/binary, (call_seq(ToByte, Value, Op))/binary, 16#00>>,
    {ok, _, Left, _, _} = eth_evm:run(Code, ?MSG0, State, ?ENV, ?GAS),
    ?GAS - Left - prologue_gas() - warmup_cost(Warm).

warmup_cost(cold) -> 0;
warmup_cost(warm) -> warmup_gas().

%% The 25000 new-account term applies when the destination does not exist, and
%% eth_state:exists/2 answers it from the overlay -- by reading the balance, the
%% nonce *and* the code. So the address has to be seeded as present and empty
%% rather than left out: an address with no entries at all sends the EVM upstream,
%% and a unit test that reaches the network is a test that hangs when the node is
%% offline. That is the whole content of this fixture, and the reason 0x0E rather
%% than 0x0D: 0x0D is funded, and a funded account is not a new one.
empty_target_state() ->
    Empty = <<0:152, 16#0E:8>>,
    eth_state:new(0, #{{balance, ?CALLER} => 1000000,
                       {nonce, ?CALLER} => 0,
                       {balance, Empty} => 0,
                       {nonce, Empty} => 0,
                       {code, Empty} => <<>>}).

%% Gas the seven pushed arguments cost, measured by running them and stopping.
prologue_gas() ->
    Code = <<(call_args(16#0D, 0))/binary, 16#00>>,
    {ok, _, Left, _, _} = eth_evm:run(Code, ?MSG0, call_state(1000000, <<16#00>>),
                                      ?ENV, ?GAS),
    ?GAS - Left.

%% Gas the BALANCE that warms the target costs: its PUSH1, the cold access, and
%% the POP. Also measured, so a change to BALANCE's price cannot quietly make
%% this test's warm figure wrong in the same direction twice.
warmup_gas() ->
    Code = <<16#60,16#0D, 16#31, 16#50, 16#00>>,
    {ok, _, Left, _, _} = eth_evm:run(Code, ?MSG0, call_state(1000000, <<16#00>>),
                                      ?ENV, ?GAS),
    ?GAS - Left.

call_name(16#F1) -> "CALL";
call_name(16#F2) -> "CALLCODE";
call_name(16#F4) -> "DELEGATECALL";
call_name(16#FA) -> "STATICCALL".

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

%% ---------------------------------------------------------------------------
%% EIP-4844 point evaluation (0x0A) is reachable from execution
%% ---------------------------------------------------------------------------
%%
%% eth_kzg implements 0x0A and is verified against mainnet exec-specs fixtures,
%% but for a long time nothing in src/ called it: is_precompile(10) was false, so
%% the module was reachable only from its own tests. These run the real fixture
%% through the EVM, because a precompile that works in isolation and is not
%% dispatched is not a precompile.

%% Real mainnet transaction 0xcb3dc8..., copied from eth_kzg_tests. The same
%% 192 bytes as that module's fixture, reached here by CALL rather than directly.
kzg_mainnet_input() ->
    <<16#018156B94FE9735E573BAB36DAD05D60FEB720D424CCD20AAF719343C31E4246:256,
      16#019123BCB9D06356701F7BE08B4494625B87A7B02EDC566126FB81F6306E915F:256,
      16#6C2EB1E94C2532935B8465351BA1BD88EABE2B3FA1AADFF7D1CD816E8315BD38:256,
      16#A9546D41993E10DF2A7429B8490394EA9EE62807BAE6F326D1044A51581306F58D4B9DFD5931E044688855280FF3799E:384,
      16#A2EA83D9391E0EE42E0C650ACC7A1F842A7D385189485DDB4FD54ADE3D9FD50D608167DCA6C776AAD4B8AD5C20691BFE:384>>.

%% The success output is FIELD_ELEMENTS_PER_BLOB then BLS_MODULUS, each a 32-byte
%% big-endian integer: 4096 = 0x1000, so 30 zero bytes then 0x10 0x00.
kzg_success_output() ->
    <<4096:256,
      16#73EDA753299D7D483339D80809A1D80553BDA402FFFE5BFEFFFFFFFF00000001:256>>.

%% 0x0A returns that 64-byte value when the proof verifies, and the EVM has to
%% deliver it through the normal call return path.
kzg_point_evaluation_is_reachable_from_the_evm_test() ->
    {ok, Out, GasLeft, _, _} = eth_evm:run(kzg_caller(10, kzg_mainnet_input()),
                                           ?MSG0, eth_state:new(0, #{}),
                                           ?ENV, ?GAS),
    ?assertEqual(kzg_success_output(), Out),
    ?assert(?GAS - GasLeft > 50000).

%% ...and it costs 50000, pinned without any hand arithmetic: the same code
%% against 0x04 IDENTITY differs only in the precompile, and 0x04's own cost
%% (15 + 3 per word, per EIP-161) is subtracted. So the difference is exactly
%% 50000 - 33, whatever the prologue, the CODECOPY, the memory expansion and the
%% EIP-2929 access cost happen to be -- none of which this test has to know.
kzg_costs_fifty_thousand_test() ->
    Kzg = ?GAS - gas_left(kzg_caller(10, kzg_mainnet_input())),
    Identity = ?GAS - gas_left(kzg_caller(4, kzg_mainnet_input())),
    ?assertEqual(50000 - (15 + 3 * 6), Kzg - Identity).

%% A failed point evaluation is a halt that consumes the frame's gas, not a
%% fallback to another node. The proof here is the real one with its last byte
%% flipped, so the pairing check fails on a genuine input.
kzg_failure_halts_and_consumes_the_frame_test() ->
    Good = kzg_mainnet_input(),
    <<Head:191/binary, Last>> = Good,
    Bad = <<Head/binary, (Last bxor 1)>>,
    {error, {kzg, point_evaluation_failed}, _, _} =
        eth_evm:run(kzg_caller(10, Bad), ?MSG0, eth_state:new(0, #{}),
                    ?ENV, ?GAS),
    ok.

%% ...and the halt is not the `unsupported' shape that eth_call answers with a
%% fallback. If it were, a local failure would be reported as another node's
%% answer, which is the specific thing this wiring exists to prevent.
kzg_failure_is_not_reported_as_unsupported_test() ->
    Good = kzg_mainnet_input(),
    <<Head:191/binary, Last>> = Good,
    Bad = <<Head/binary, (Last bxor 1)>>,
    {error, Reason, _, _} = eth_evm:run(kzg_caller(10, Bad), ?MSG0,
                                        eth_state:new(0, #{}), ?ENV, ?GAS),
    ?assertEqual({kzg, point_evaluation_failed}, Reason),
    %% `unsupported' is the shape eth_call answers with an upstream fallback.
    ?assertNotMatch({unsupported, _}, Reason).

%% Both frames differ only in the precompile address, so a difference in outcome
%% is attributable to the precompile and not to the surrounding code.
gas_left(Code) ->
    {ok, _, GasLeft, _, _} = eth_evm:run(Code, ?MSG0, eth_state:new(0, #{}),
                                         ?ENV, ?GAS),
    GasLeft.

%% Code that CODECOPYs a 192-byte input to memory, CALLs precompile `Precompile'
%% asking for 64 bytes of return data, and RETURNs those 64 bytes. The input's
%% offset within the code is the length of the prefix, so the prefix is built
%% first and measured.
kzg_caller(Precompile, Input) ->
    Len = byte_size(Input),
    %% CALL pops gas, to, value, argsOffset, argsLength, retOffset, retLength --
    %% so they are pushed in the reverse of that. Getting this order wrong is
    %% silent: the call still succeeds, it just asks the precompile for no input
    %% and returns 192 bytes of nothing, and the precompile rejects a short input.
    Args = <<16#60,64, 16#60,0, 16#60,Len, 16#60,0, 16#60,0,
             16#60,Precompile, 16#61,16#FF,16#FF>>,
    %% CODECOPY pops destOffset, offset, size, so size is pushed first. `offset'
    %% is an offset into the code, and the input is spliced in after the prefix,
    %% so the prefix has to measure itself before the offset is known.
    Copy = <<16#60,Len, 16#60,0, 16#60,0, 16#39>>,
    Suffix = <<16#60,64, 16#60,0, 16#F3>>,
    %% A CALL returns to the instruction after it, so the code that runs next has
    %% to be the code -- not the data. Putting the input between the CALL and the
    %% RETURN means the CALL succeeds and then the input is executed as
    %% instructions, which fails on a pop from an empty stack some bytes in. The
    %% input is therefore appended last and CODECOPY reads it from there.
    Offset = byte_size(Copy) + byte_size(Args) + 1 + byte_size(Suffix),
    Prefix = <<16#60,Len, 16#60,Offset, 16#60,0, 16#39, Args/binary, 16#F1>>,
    <<Prefix/binary, Suffix/binary, Input/binary>>.

%% The gas half of that claim, which the top-level result cannot show: run/5's
%% error form carries no gas figure, so "consumes the frame's gas" is not
%% observable from outside a failed frame. It is observable from a frame that
%% *called* into the failure, and that is the case that matters -- a refund to the
%% caller is the bug this guards.
%%
%% One parent, two children. The parent hands the child almost all of its gas and
%% then does a 20000-gas SSTORE.
%%
%%   child succeeds  the child's unspent gas is refunded, the parent can afford
%%                   the store, and the store happens
%%   child fails     the parent gets nothing back, cannot afford the store, and
%%                   halts out of gas with the store unwritten
%%
%% Same parent code, same parent budget, only the child's code differs, so the
%% outcome difference is attributable to the refund.
kzg_failure_refunds_nothing_to_its_caller_test() ->
    Good = kzg_caller(10, kzg_mainnet_input()),
    Bad = kzg_caller(10, corrupt_last_byte(kzg_mainnet_input())),
    %% Succeeding: the child refunded its remainder, so the parent could afford
    %% the SSTORE and read its own value back.
    ?assertEqual({ok, 255}, kzg_refund_probe(Good)),
    %% Failing: nothing came back, and the SSTORE -- the very next real opcode --
    %% cost 20000 more than the parent had. `charge/2' runs before the write, so
    %% the halt is proof the store never happened. The reason reads out_of_gas
    %% rather than the KZG failure, because that failure was one frame down and
    %% only its consequence reaches here.
    ?assertEqual({error, out_of_gas}, kzg_refund_probe(Bad)).

%% One parent, used for both cases: CALL the child at 0x0D with 999000 gas, then
%% SSTORE 255 at slot 0, read it back and return it. The two runs differ only in
%% the child's code, so the outcome difference is attributable to the refund.
kzg_refund_probe(ChildCode) ->
    Parent = <<16#60,0, 16#60,0, 16#60,0, 16#60,0, 16#60,0,
               16#60,16#0D, 16#62,16#0F,16#42,40,
               16#F1,
               16#60,255, 16#60,0, 16#55,
               16#60,0, 16#54, 16#60,0, 16#52,
               16#60,32, 16#60,0, 16#F3>>,
    case eth_evm:run(Parent, ?MSG0, kzg_parent_state(ChildCode), ?ENV, ?GAS) of
        {ok, <<Value:256>>, _, _, _} -> {ok, Value};
        {error, Reason, _, _} -> {error, Reason}
    end.

%% The slot is seeded to 0 and the parent only ever writes 255, so "unchanged" and
%% "written" are distinguishable without a sentinel. Seeding also matters for a
%% reason beyond clarity: eth_state reads an unseeded slot by fetching upstream,
%% so a test that leaves it out does not fail, it hangs.
kzg_parent_state(ChildCode) ->
    eth_state:new(0, #{{balance, ?CALLER} => 10000000,
                       {nonce, ?CALLER} => 0,
                       {store, ?CALLER, 0} => 0,
                       {balance, ?CALLEE} => 0,
                       {nonce, ?CALLEE} => 0,
                       {code, ?CALLEE} => ChildCode}).

%% Flip one bit of the proof. Same length, so this exercises a real pairing
%% failure rather than the short-input check.
corrupt_last_byte(Bin) ->
    <<Head:(byte_size(Bin) - 1)/binary, Last>> = Bin,
    <<Head/binary, (Last bxor 1)>>.

%% ---------------------------------------------------------------------------

%% ---------------------------------------------------------------------------
%% EIP-3860: both creators pay for the init code
%% ---------------------------------------------------------------------------
%%
%% do_create/3 charged CREATE2 its hashing term and CREATE nothing at all, so
%% deploying a large contract cost nothing for the code that was about to run,
%% and CREATE2 was short two thirds of what it owes. gasUsed is a receipt field,
%% so this is a receipts-root difference on every CREATE and CREATE2 in a block.
%%
%% The expectations are differences rather than totals, so no part of this has to
%% know what the pushes, the CODECOPY, the memory expansion or the access terms
%% cost. Two things had to be held constant for a difference to mean anything,
%% and both were confounds in the first version of this test:
%%
%%   - The parent's own work. It CODECOPYs a fixed-size buffer whatever the
%%     length under test, so its memory expansion and copy cost are the same in
%%     every run. Copying exactly `Len' bytes instead would have added a
%%     quadratic memory term to the number being measured.
%%   - The child's own work. The buffer starts with `PUSH1 0 PUSH1 0 RETURN' and
%%     the rest is padding the child never reaches, because RETURN halts the
%%     frame. So the child costs the same whatever `Len' says. PUSH0 would have
%%     been the obvious padding and is the wrong choice: it is an instruction,
%%     so the child's cost would have scaled with the length under test.
%%
%% The baseline is a 4-byte init code rather than an empty one, because an empty
%% init code executes no instruction while every other case executes the RETURN
%% and that difference would land in the number. So what is measured here is the
%% marginal cost of each word *after* the first.

create_pays_two_per_initcode_word_test() ->
    ?assertEqual(2, marginal_word_cost(create, 33)),
    ?assertEqual(2, marginal_word_cost(create, 64)),
    ?assertEqual(4, marginal_word_cost(create, 65)),
    ?assertEqual(6, marginal_word_cost(create, 128)).

create2_pays_eight_per_initcode_word_test() ->
    ?assertEqual(8, marginal_word_cost(create2, 33)),
    ?assertEqual(8, marginal_word_cost(create2, 64)),
    ?assertEqual(16, marginal_word_cost(create2, 65)),
    ?assertEqual(24, marginal_word_cost(create2, 128)).

%% ...so the gap between the two creators is the hashing term, 6 a word, on top of
%% a constant 3. Everything else cancels -- the shared 2 for the init code, the
%% parent's memory and copy, the child's execution. The 3 does not, and is not
%% noise: CREATE2 takes a salt where CREATE takes nothing, so its parent pushes
%% one more argument and that PUSH1 is 3 gas. It is a real, fixed difference
%% between the two opcodes rather than an artefact, so it is stated rather than
%% fitted away.
%%
%% This is the assertion an edit would fail if it made the two disagree about the
%% shared half while leaving each one's own total correct.
create_and_create2_differ_only_by_the_hashing_term_test() ->
    [?assertEqual({Len, Gap}, {Len, 6 * Words + 3})
     || Len <- [4, 32, 33, 64, 96, 128],
        Words <- [initcode_words(Len)],
        Gap <- [create_cost(create2, Len) - create_cost(create, Len)]].

initcode_words(Len) -> (Len + 31) div 32.

marginal_word_cost(Op, Len) -> create_cost(Op, Len) - create_cost(Op, 4).

%% Gas used by a parent that CODECOPYs the buffer to offset 0, issues Op over
%% `Len' bytes of it, and stops.
create_cost(Op, Len) ->
    Init = binary:part(init_code_buffer(), 0, Len),
    ?GAS - create_probe_left(Op, Init, create_parent(Op, Len)).

create_parent(Op, Len) ->
    Buffer = init_code_buffer(),
    BLen = byte_size(Buffer),
    Args = case Op of
               create ->
                   %% CREATE pops value, offset, length.
                   <<16#60,Len, 16#60,0, 16#60,0, 16#F0>>;
               create2 ->
                   %% CREATE2 pops value, offset, length, salt.
                   <<16#60,0, 16#60,Len, 16#60,0, 16#60,0, 16#F5>>
           end,
    Copy = <<16#60,BLen, 16#60,0, 16#60,0, 16#39>>,
    Stop = <<16#00>>,
    Offset = byte_size(Copy) + byte_size(Args) + byte_size(Stop),
    <<16#60,BLen, 16#60,Offset, 16#60,0, 16#39, Args/binary,
      Stop/binary, Buffer/binary>>.

%% Big enough for the longest length below, fixed so the parent's memory does
%% not move with it.
init_code_buffer() -> <<16#60,0, 16#60,0, 16#F3, (padding(160 - 3))/binary>>.

padding(0) -> <<>>;
padding(N) -> <<16#5F, (padding(N - 1))/binary>>.

%% eth_state:exists/2 reads the balance, the nonce and the code of the address
%% about to be created, and an address with no entries sends the EVM upstream --
%% where a unit test hangs rather than fails. So the address is computed here
%% from the same public keccak and rlp the node uses, and seeded as empty. That
%% duplicates the derivation rather than checking it; the derivation itself is
%% pinned separately by create_revert_keeps_nonce_drops_value_test/0.
create_probe_left(Op, Init, Code) ->
    State = create_probe_state(Op, Init),
    case eth_evm:run(Code, ?MSG0, State, ?ENV, ?GAS) of
        {ok, _, Left, _, _} -> Left;
        {error, Reason, _, _} -> erlang:error({create_probe_failed, Op, Reason})
    end.

create_probe_state(Op, Init) ->
    Nonce = 0,
    Addr = created_address(Op, Nonce, Init),
    eth_state:new(0, #{{balance, ?CALLER} => 10000000,
                       {nonce, ?CALLER} => Nonce,
                       {balance, Addr} => 0,
                       {nonce, Addr} => 0,
                       {code, Addr} => <<>>}).

created_address(create, Nonce, _Init) ->
    <<_:12/binary, Addr:20/binary>> =
        eth_keccak:hash(eth_rlp:encode([?CALLER, Nonce])),
    Addr;
created_address(create2, _Nonce, Init) ->
    H = eth_keccak:hash(Init),
    <<_:12/binary, Addr:20/binary>> =
        eth_keccak:hash(<<16#FF, ?CALLER/binary, 0:256, H/binary>>),
    Addr.
