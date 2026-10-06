-module(eth_evm_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MSG0, #{address => <<0:160>>, caller => <<0:160>>, origin => <<0:160>>,
               value => 0, data => <<>>, gas_price => 0, static => false, depth => 0}).

-define(STATE, (eth_state:new(0, #{{store, <<0:160>>, 0} => 0}))).
%% eth_evm:run/5 requires the fork the frame executes under: an instruction the
%% fork does not have is an exceptional halt, not a cheap one. Every test in
%% this module states which fork it means rather than leaving it out, because
%% the interpreter now has no opinion of its own to fall back on. Cancun is the
%% newest fork this node's chain has reached.
-define(ENV, #{fork => cancun}).
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
    Env = #{timestamp => 12345, fork => cancun},
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
%% A precompile (0x04, the identity function) and an address no instruction in these
%% tests mentions. Both are `PUSH20' so a program can name either, and they differ only
%% in the low byte -- which is what lets a gas difference between two programs be read
%% as a warm/cold term and nothing else.
-define(PRECOMPILE, <<0:152, 16#04:8>>).
-define(UNTOUCHED, <<0:152, 16#99:8>>).

call_state(CallerBal, CalleeCode) ->
    eth_state:new(0, #{{balance, ?CALLER} => CallerBal,
                       {nonce, ?CALLER} => 0,
                       {balance, ?CALLEE} => 0,
                       {nonce, ?CALLEE} => 0,
                       {code, ?CALLEE} => CalleeCode}).

%% DELEGATECALL stack: retlen, retoff, argslen, argsoff, to, gas. Six pushes,
%% not CALL's seven -- there is no value argument, which is the whole difference
%% between the two opcodes at the call site and the easiest thing to get wrong.
dcall_seq(ToByte, Op) ->
    <<16#60,0, 16#60,0, 16#60,0, 16#60,0,
      16#60,ToByte, 16#61,16#FF,16#FF, Op>>.

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

%% The state half of an unaffordable call was already right; the **gas** half was not,
%% and that is why a test could sit here for the whole life of this module passing
%% against a node that over-charged 45,247 gas on six corpus fixtures.
%%
%% The spec, in `forks/berlin/vm/instructions/system.py', `call':
%%
%%     sender_balance = get_account(evm.message.tx_env.state,
%%                                 evm.message.current_target).balance
%%     if sender_balance < value:
%%         push(evm.stack, U256(0))
%%         evm.return_data = b""
%%         evm.gas_left += message_call_gas.sub_call
%%
%% The first line was in this module and the third was not, and the third is the one
%% that is worth 45,247 gas. A call that **consumed** its forwarded allowance instead
%% of returning it is a different *answer*, not a different number, and a balance
%% assertion cannot see it at all.
a_call_the_caller_cannot_afford_returns_its_forwarded_gas_test() ->
    %% The target is given a balance so that it *exists*, which keeps EIP-161's 25,000
    %% out of the comparison. It is charged on a value-bearing call to an account with
    %% no balance, no nonce and no code -- which is what `call_state/2` leaves -- and
    %% leaving it in made the difference 34,000 rather than 9,000 and sent me looking
    %% for a sign error that was not there.
    %% The same program twice, once sending 40 the caller cannot cover and once
    %% sending nothing. What is left after the two cancel is **6,700**, and for a year
    %% this test asserted 9,000 with a comment saying it was "EIP-161's 9,000 for the
    %% value transfer and nothing else". The 9,000 is right and "and nothing else"
    %% was the defect: the refund on this path returns `sub_call', which is the
    %% forwarded gas **plus the 2,300 stipend**, and the caller was charged `cost',
    %% which does not include the stipend. So the caller is handed 2,300 it never paid
    %% for, and the difference is 9,000 - 2,300.
    %%
    %% **This is the fourth test in this repository that recorded a defect as a
    %% requirement**, and the second whose *justification* is what made it wrong -- a
    %% confident comment explaining why the wrong number was right. The corpus named
    %% the residue as a uniform **+2,300** across the six forks of
    %% `eip2929_gas_cost_increases/test_call_insufficient_balance`, which is the
    %% stipend to the gas, and this test asserted the number that defect produced.
    %%
    %% What the test is actually for survives the correction: **provided** the failed
    %% call handed its forwarded gas back, the difference is the refund and nothing
    %% else. A version that consumed the forwarded gas differs by most of a million,
    %% because `call_args/2' forwards 0xFFFF -- so it still catches that, which is the
    %% defect it was written for, and it now catches this one as well.
    %% Under `with_local_reads/1' because the target's account is only partly seeded
    %% and an unseeded read does not answer zero -- it falls through `eth_state' to the
    %% configured base source, which in the default `upstream' mode is an RPC call, and
    %% in a unit test that is a *crash* rather than a failure. The same trap the note on
    %% `both_slots/3' describes.
    eth_test_util:with_local_reads(fun() ->
        [?assertEqual({F, 6700},
                      {F, unaffordable_call_cost(F) - affordable_call_cost(F)})
         || F <- [istanbul, berlin, cancun]],
        %% And the absolute figures, so the difference above cannot be satisfied by two
        %% wrong numbers that happen to differ by 6,700. They are the access price and
        %% the access price plus 6,700, and nothing else -- no part of the 0xFFFF the
        %% call forwards. The two forks are listed separately because
        %% EIP-2929's `COLD_ACCOUNT_ACCESS_COST` is 2,600 and not 700, and a single
        %% bound written against Istanbul's 721 is off by a factor at every fork after
        %% it.
        [?assertEqual({F, {A, A + 6700}},
                      {F, {affordable_call_cost(F), unaffordable_call_cost(F)}})
         || {F, A} <- [{istanbul, 721}, {berlin, 2621}, {cancun, 2621}]]
    end).

%% `spent/3' is already the spend -- `?GAS - Left' -- so these are `spent/3' and not
%% `?GAS - spent/3'. Writing the second form gave `Left` rather than the cost, the
%% difference came out as -9,000 instead of +9,000, and I spent a while looking for a
%% sign error in the EVM.
unaffordable_call_cost(Fork) ->
    spent(<<(call_seq(16#0D, 40, 16#F1))/binary, 16#00>>, broke_state(), Fork).

affordable_call_cost(Fork) ->
    spent(<<(call_seq(16#0D, 0, 16#F1))/binary, 16#00>>, broke_state(), Fork).

broke_state() -> eth_state:set_balance(call_state(10, <<>>), ?CALLEE, 5).

%% The spec's other two lines, which the same fix brought: the call pushes 0 and
%% **empties the return data**. A `RETURNDATASIZE` after a call that did not happen
%% must read zero, and it used to read whatever the previous call left behind.
%% Under `with_local_reads/1' like its sibling, for the same reason: the two slots
%% written here are not in the overlay, and an unseeded read goes to the configured
%% base source, which is a *hang* in a unit test rather than a zero.
a_call_the_caller_cannot_afford_empties_the_return_data_test() ->
    eth_test_util:with_local_reads(fun() ->
        %% **A successful call first, so there is something to clear.** The first
        %% version of this program was a lone failing call, and it asserted
        %% `RETURNDATASIZE == 0` -- which passed with the `evm.return_data = b""' line
        %% deleted, because nothing had ever set the return data. A test that asserts a
        %% value is zero proves nothing unless something else could have made it
        %% non-zero, and the injection that showed this (delete the reset, every test
        %% still green) is the reason it is stated here.
        %%
        %% The callee is `PUSH1 1; PUSH1 0; RETURN` -- one byte back -- so the first
        %% call leaves a return data of size 1 and the second must clear it.
        Callee = <<16#60, 1, 16#60, 0, 16#F3>>,
        Code = <<(call_seq(16#0D, 0, 16#F1))/binary,
                 (call_seq(16#0D, 40, 16#F1))/binary,
                 16#3D, 16#60, 5, 16#55, 16#00>>,
        {ok, _, _, St, _} = eth_evm:run(Code, ?MSG0, call_state(10, Callee),
                                        #{fork => cancun}, ?GAS),
        ?assertEqual(0, eth_state:storage(St, ?CALLER, 5)),
        %% And the control: with only the *successful* call, the size is 1. Without this
        %% the assertion above is a statement about a return-data register that was
        %% never written, which is what made it vacuous in the first place.
        Only = <<(call_seq(16#0D, 0, 16#F1))/binary,
                  16#3D, 16#60, 5, 16#55, 16#00>>,
        {ok, _, _, St0, _} = eth_evm:run(Only, ?MSG0, call_state(10, Callee),
                                         #{fork => cancun}, ?GAS),
        ?assertEqual(1, eth_state:storage(St0, ?CALLER, 5)),
        %% And the success flag the failing CALL pushed is 0, not 1.
        {ok, _, _, St2, _} =
            eth_evm:run(<<(call_seq(16#0D, 40, 16#F1))/binary, 16#60, 6, 16#55, 16#00>>,
                        ?MSG0, call_state(10, Callee), #{fork => cancun}, ?GAS),
        ?assertEqual(0, eth_state:storage(St2, ?CALLER, 6))
    end).

%% ---------------------------------------------------------------------------
%% A precompile's output is the call's output, and `finish_call/8' does not publish
%% it. EIP-211 makes the buffer part of the call's *result*: a call that returned one
%% byte leaves one byte readable by `RETURNDATASIZE', `RETURNDATACOPY' and `SHA3'.
%% `finish_call/8' copies `Out' into memory and pushes the success flag; it does not
%% touch `retdata', because for an account CALL that is `handle_child/9''s job and it
%% does it. **The precompile path had no such job**, so all three of its branches
%% handed the caller back to the interpreter with the register holding whatever the
%% *previous* call had left.
%%
%% The corpus named it, at -19,900 on twenty-four fixtures. See
%% `storing_a_precompiles_return_size_costs_the_set_price_test/0', which is the gas
%% half; the defect is a state one first and a gas one second.
%% ---------------------------------------------------------------------------

%% `mem[0] = 1`, then `CALL` identity with one byte in and one byte out, so its answer
%% is exactly `<<1>>'. `RETURNDATASIZE' then stores the *length* at slot 5 and the word
%% the buffer was copied into at slot 6 -- because a test that only asserted the length
%% would pass on a buffer holding the right number of zero bytes. One byte in is
%% enough; the first version of this probe used a `PUSH32' word and stopped 15 gas in,
%% having mis-parsed its own immediate.
one_byte_to_identity() ->
    <<16#60, 1, 16#60, 0, 16#53,                  % PUSH1 1; PUSH1 0; MSTORE8
      16#60, 1, 16#60, 0,                        % retlen=1   retoff=0
      16#60, 1, 16#60, 0,                        % argslen=1  argsoff=0
      16#60, 0,                                  % value = 0
      16#60, 16#04, 16#5A, 16#F1,                % PUSH1 4; GAS; CALL
      16#50>>.                                   % POP the success flag

%% `mem[0] = 1` and nothing else, so `RETURNDATASIZE' is read with no call having
%% happened. This is the control both tests below need.
no_call_at_all() -> <<16#60, 1, 16#60, 0, 16#53>>.

%% A CALL to a precompile with `argslen = ArgLen' and `retlen = 0', which is the shape
%% the `call_seq/3' helper cannot express: it hard-codes both lengths at 0. 0x08 wants
%% a whole number of 192-byte pairs, so an input that is not a multiple of 192 is the
%% rejected-input case -- and **empty input is not one**, because the pairing of zero
%% pairs is trivially true and EIP-197 answers with 32 bytes of 1. The first version
%% of the test below passed empty input, the call *succeeded*, and the assertion read
%% 32 where it expected the buffer to be cleared.
precompile_call(ToByte, ArgLen) ->
    <<16#60, 0, 16#60, 0,                        % retlen=0   retoff=0
      16#60, ArgLen, 16#60, 0,                   % argslen   argsoff=0
      16#60, 0,                                  % value = 0
      16#60, ToByte, 16#5A, 16#F1, 16#50>>.      % PUSH1 to; GAS; CALL; POP

a_precompile_call_publishes_its_return_data_test() ->
    eth_test_util:with_local_reads(fun() ->
        Fork = cancun,
        Code = <<(one_byte_to_identity())/binary,
                 16#3D,                          % RETURNDATASIZE
                 16#60, 5, 16#55,                % PUSH1 5; SSTORE  -> the length
                 16#60, 0, 16#51,                % PUSH1 0; MLOAD   -> the word
                 16#60, 6, 16#55,                % PUSH1 6; SSTORE  -> that word
                 16#00>>,
        {ok, _, _, St, _} = eth_evm:run(Code, ?MSG0, call_state(1000, <<>>),
                                        #{fork => Fork}, ?GAS),
        %% `1 bsl 248' and not 1: `MLOAD' reads **32** bytes big-endian, and the one
        %% byte the CALL copied sits at the low end of that word. Masking with `AND
        %% 0xFF' reads the *high* end and answers 0, which is what the first version of
        %% this assertion got -- a correct buffer and a wrong test, which is the one
        %% outcome worse than a wrong node.
        ?assertEqual({1, 1 bsl 248}, {eth_state:storage(St, ?CALLER, 5),
                                     eth_state:storage(St, ?CALLER, 6)}),
        %% **The control: a frame that called nothing reads zero.** Without it the
        %% pair above is a statement about a register that could have been right for
        %% free -- which is the exact shape of the defect being pinned, since a
        %% precompile call that published nothing also read 0. A positive assertion
        %% needs something that could have made it different, and this is it.
        {ok, _, _, St0, _} =
            eth_evm:run(<<(no_call_at_all())/binary,
                          16#3D, 16#60, 5, 16#55, 16#00>>,
                        ?MSG0, call_state(1000, <<>>), #{fork => Fork}, ?GAS),
        ?assertEqual(0, eth_state:storage(St0, ?CALLER, 5))
    end).

%% The gas half, and how the corpus found the state half.
%% `test_identity_returndatasize' and `test_warm_coinbase' both end a frame with
%% `CALL; POP; RETURNDATASIZE; PUSH1 k; SSTORE', and the delta was **-19,900** on
%% twenty-four fixtures: `SSTORE_SET_GAS` (20,000) minus `SLOAD_GAS` (100). That is
%% EIP-2200's arm (1.) `current == new', taken because `new' read as 0, where the
%% chain takes arm (2.1.1). Reading the histogram is what named the cause: a 19,900
%% that decomposes onto two neighbouring constants is not a mispriced opcode, it is a
%% wrong *value* feeding the right price.
storing_a_precompiles_return_size_costs_the_set_price_test() ->
    eth_test_util:with_local_reads(fun() ->
        Fork = cancun,
        WithSize = <<(one_byte_to_identity())/binary,
                     16#3D, 16#60, 9, 16#55, 16#00>>,
        WithZero = <<(one_byte_to_identity())/binary,
                     16#60, 0, 16#60, 9, 16#55, 16#00>>,
        S = call_state(1000, <<>>),
        {ok, _, L1, St1, _} = eth_evm:run(WithSize, ?MSG0, S, #{fork => Fork}, ?GAS),
        {ok, _, L0, St0, _} = eth_evm:run(WithZero, ?MSG0, S, #{fork => Fork}, ?GAS),
        %% The two post-states differ, so this is measuring two outcomes and not one
        %% program run twice. Asserted because the whole point is that the *value*
        %% changes: two identical states would make the gas difference meaningless.
        ?assertEqual({1, 0}, {eth_state:storage(St1, ?CALLER, 9),
                              eth_state:storage(St0, ?CALLER, 9)}),
        %% Every term read from the schedule, including the one-gas gap between
        %% `PUSH1' and `RETURNDATASIZE'. Nothing here is a written-down number, because
        %% a test that repeats a constant in the module it is testing cannot tell a
        %% price change from a typo.
        %%
        %% `sstore_cost/4' answers `{Cost, Refund}', and only the cost belongs in a
        %% spend comparison -- the first version added the tuple, and the error was
        %% `3 + {100, 0}', which is what a wrong return shape looks like rather than a
        %% wrong price.
        Set = element(1, eth_fork_schedule:sstore_cost(Fork, 0, 0, 1)),
        Noop = element(1, eth_fork_schedule:sstore_cost(Fork, 0, 0, 0)),
        ?assertEqual(eth_fork_schedule:constant_cost(16#60, Fork) + Noop
                     - eth_fork_schedule:constant_cost(16#3D, Fork) - Set,
                     (?GAS - L0) - (?GAS - L1))
    end).

%% A precompile that **ran and rejected** its input is a call failure, and EIP-211
%% makes the buffer empty for one -- so it must clear what the previous call left.
%% This is the worse half of the defect and the half with no `-19,900' to announce it:
%% reading **zero** is merely wrong, reading the *previous* call's length is wrong in
%% a way that depends on what the frame did before, which no gas figure will show you.
a_rejected_precompile_call_clears_a_stale_return_data_buffer_test() ->
    eth_test_util:with_local_reads(fun() ->
        %% The first call succeeds and leaves a return data of size 1 -- the callee is
        %% `PUSH1 1; PUSH1 0; RETURN', which returns one byte. The second is 0x08, the
        %% pairing check, handed **one** byte: EIP-197 wants a whole number of 192-byte
        %% pairs, so that is `invalid_input' -- a *failed call*, which
        %% `eth_pairing_bn128' reports as `{error, invalid_input, _}' and
        %% `eth_evm_precompiles' as `{failed, _}'. Deliberately **not** `unsupported`:
        %% that word means this node cannot run the check at all, and the test would
        %% then be measuring a refusal to produce the block rather than a call failure,
        %% which is a different thing with a different fix.
        %%
        %% One byte, not zero. Empty input is the *pairing of zero pairs*, which is
        %% trivially true, so it succeeds and answers 32 bytes -- the first version of
        %% this test passed empty input and read 32 where it meant to read a cleared
        %% buffer.
        Callee = <<16#60, 1, 16#60, 0, 16#F3>>,
        Code = <<16#60, 1, 16#60, 0, 16#53,                 % mem[0] = 1
                 (call_seq(16#0D, 0, 16#F1))/binary,        % the call that succeeds
                 (precompile_call(16#08, 1))/binary,         % the call that fails
                 16#3D, 16#60, 7, 16#55, 16#00>>,
        {ok, _, _, St, _} = eth_evm:run(Code, ?MSG0, call_state(1000, Callee),
                                        #{fork => cancun}, ?GAS),
        ?assertEqual(0, eth_state:storage(St, ?CALLER, 7)),
        %% And the control, which is why this test is not the mistake this module has
        %% already paid for once: the *same* program with the rejected call removed
        %% reads **1**. A test asserting zero that never showed a non-zero proves
        %% nothing -- see the note on
        %% `a_call_the_caller_cannot_afford_empties_the_return_data_test/0'.
        {ok, _, _, St1, _} =
            eth_evm:run(<<16#60, 1, 16#60, 0, 16#53,
                          (call_seq(16#0D, 0, 16#F1))/binary,
                          16#3D, 16#60, 7, 16#55, 16#00>>,
                        ?MSG0, call_state(1000, Callee), #{fork => cancun}, ?GAS),
        ?assertEqual(1, eth_state:storage(St1, ?CALLER, 7))
    end).

%% The other three `finish_call/8' sites that left `retdata' alone, and why they are in
%% the same change rather than three more: they are the *same* defect. A call that did
%% not happen -- too deep, or a `CREATE' whose sender cannot afford the value -- leaves
%% no return data, so the buffer must be empty rather than whatever the frame last saw.
%%
%% **Neither depth-limit site is in this list, and the reason is worth more than the
%% test would be.** A frame already at depth 1024 cannot make *any* call, so it cannot
%% have populated the return-data buffer either: every `CALL` and `CREATE` it attempts is
%% the one being refused. The buffer is only non-empty at that depth if the frame arrived
%% by recursing, which needs a real 1024-deep call tree -- about 3,300 gas a frame, so
%% 3.4M against this module's `?GAS'.
%%
%% The first version of that test set `depth' in the message and asserted the buffer was
%% empty, and it passed with the fix **deleted**, because the control call was refused
%% too and the buffer was empty either way. A test that cannot fail is worse than no
%% test, so it is not here. The two `finish_call/8' lines are kept because the
%% specification puts the reset *before* the depth check -- `evm.return_data = b""' is
%% the first statement of both `generic_call' and `generic_create' -- and they are the
%% same one-token change as the five that are pinned. They are **unpinned**, and saying
%% so is the point of this note.
%%
%% (`?MSG0#{depth => D}' would not have compiled either -- a map literal cannot be
%% updated in place, and the compiler says "expression updates a literal" -- so this was
%% a function first. It is gone now that no test needs it.)

%% A `CALL` whose forwarded gas and argument length are stated explicitly, so a
%% precompile can be asked for a call it cannot afford. `call_seq/3' hard-codes the gas
%% operand at `PUSH2 0xFFFF' and the argument length at 0, so the seven are spelled out:
%% retlen, retoff, argslen, argsoff, value, to, gas.
%%
%% `retlen = ArgLen' and `argsoff = 0`, so a successful call to identity returns exactly
%% `ArgLen' bytes into `retdata'. That is what makes the control below meaningful: with
%% one byte in, a call that *succeeds* leaves a return data of 1, and the same call
%% forwarding no gas leaves 0. Asserting 0 against a precompile that returns nothing
%% would pass whether or not the branch cleared the buffer.
call_with_gas(ToByte, ArgLen, Gas) ->
    <<16#60,0, 16#60,0, 16#60,ArgLen, 16#60,0, 16#60,0, 16#60,ToByte,
      (push_int(Gas))/binary, 16#F1, 16#50>>.

%% `CREATE' pops value, offset and length with the value on top, so the pushes go
%% length, offset, value. `PUSH1 0' twice then the value, then CREATE, then POP the
%% address it pushed.
create_seq(Value) -> <<16#60, 0, 16#60, 0, (push_int(Value))/binary, 16#F0, 16#50>>.

%% `CREATE'/`CREATE2' leave the created address on the stack; the programs here keep
%% it and store it in slot 9 of the caller, so a test can ask about the account the
%% frame made instead of recomputing `keccak(rlp([sender, nonce]))' -- a second
%% implementation of the address rule, which is the way a fixture ends up disagreeing
%% with the code for a reason that is not the one under test.
%%
%% `PUSH1 9' then `SSTORE': SSTORE pops key then value, and the value is the address
%% `CREATE' just pushed, so the key goes on top of it.

%% **The init code is `CODECOPY`'d into memory, because a frame's memory is scratch.**
%% `eth_evm' keeps the code in `#e.code' and zero-extends `#e.mem' in `charge_mem/2';
%% the code is never loaded into memory, so `CREATE' reading offset N gets zeros
%% unless something wrote them there. In a real contract that something is `CODECOPY'
%% or `CALLDATACOPY', and both are how the corpus does it.
%%
%% The first version of these tests put the init code in the *program text* at offset
%% 10 and read it from offset 10, and deployed **zero bytes**. The create still looked
%% like it worked: `CREATE' pushed a real address, the account existed, the nonce was
%% 1 -- and the code was `<<>>'. So the failure mode was a create that succeeded and
%% deployed nothing, which is a shape this module had no assertion for. Every
%% pre-existing create test here passes `Len = 0', so nothing had ever noticed.
%%
%% **`STOP` fences the init code off from the driver, and without it the *outer* frame
%% runs the init code.** There is no jump here: the interpreter starts at pc 0, runs
%% the driver, and carries on into whatever bytes follow. So with the init code butted
%% straight up against the driver, the outer frame executed it too -- and because the
%% two arms' init codes differ only in `RETURN' versus `REVERT', the deploying arm
%% still reported success (`RETURN' is a successful halt, and `run_t' answers `{ok,
%% Out, ...}' for it) while the reverting arm made the *outer* frame revert. The test
%% was then asserting an absent account in a state whose outer frame had never
%% finished, and the branch under test was not the one being taken. The tell was that
%% the reverting arm's revert payload was 32 zero bytes: memory the outer frame had
%% just written 42 into cannot be zero.
%%
%% The `CREATE' driver is **18 bytes** including that `STOP', and the `CREATE2' driver
%% **20** (one extra `PUSH1 0' for the salt). The init code starts immediately after,
%% at that code offset. Both lengths are matched rather than assumed: a `PUSH1' that
%% silently became a `PUSH2' would move the offset, and the program would then copy
%% the wrong bytes -- the byte-width trap one level up, and it fails *silently*,
%% because `CODECOPY' zero-pads rather than trapping.
create_program(Init) ->
    L = byte_size(Init),
    Driver = <<(push_int(L))/binary, 16#60, 18, 16#60, 0, 16#39,
                (push_int(L))/binary, 16#60, 0, 16#60, 0, 16#F0,
                16#60, 9, 16#55, 16#00>>,
    18 = byte_size(Driver),
    <<Driver/binary, Init/binary>>.

create2_program(Init) ->
    L = byte_size(Init),
    Driver = <<(push_int(L))/binary, 16#60, 20, 16#60, 0, 16#39,
                16#60, 0,
                (push_int(L))/binary, 16#60, 0, 16#60, 0, 16#F5,
                16#60, 9, 16#55, 16#00>>,
    20 = byte_size(Driver),
    <<Driver/binary, Init/binary>>.

%% A one-byte `STOP', and a `PUSH1 42, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN'
%% that deploys 32 bytes.
stop_init_code() -> <<16#00>>.
word_init_code() -> <<16#60, 16#2a, 16#60, 0, 16#52, 16#60, 32, 16#60, 0, 16#F3>>.
%% **`RETURN` becomes `REVERT` and nothing else does** -- one byte, same length, so
%% `create_program/1' produces two outer programs that are byte-identical apart from
%% the init code, and the two arms differ in exactly whether the create succeeded.
%% The check that they differ in one byte is in the test rather than asserted here,
%% because a control that has quietly drifted is the failure this module has already
%% paid for twice.
revert_init_code() -> <<16#60, 16#2a, 16#60, 0, 16#52, 16#60, 32, 16#60, 0, 16#FD>>.

%% The address a run recorded, or `undefined' if the frame pushed nothing -- so a
%% create that failed leaves `undefined' rather than slot 9's zero, which is a valid
%% address (`0x0000...0000') and would read as "created the zero address".
created_addr(St) ->
    case eth_state:storage(St, ?CALLER, 9) of
        0 -> undefined;
        W -> eth_state:address(W)
    end.

%% The address a create *would* have used, for asserting that it does not exist.
%% Only needed where the frame pushed 0, so slot 9 cannot say, and **only valid on a
%% state whose caller nonce has been rolled back** -- it reconstructs
%% `keccak(rlp([sender, nonce]))` with the nonce *before* the increment, so on a
%% state that still carries the increment it names a different address and the
%% assertion that follows is about an account nobody created.
%%
%% That is not hypothetical: a version of the EIP-2 item 3 test used this helper on
%% the deposit-failure branch, and an injection that made that branch keep the
%% child's state -- so no longer rolled back -- left the helper naming the wrong
%% address. The test passed, because it was checking an account that had never
%% existed. A helper that reconstructs a value is only as good as its precondition,
%% and this one has two callers' worth of assumptions in it.
would_create(St) ->
    Nonce = eth_state:nonce(St, ?CALLER),
    <<_:12/binary, Addr:20/binary>> =
        eth_keccak:hash(eth_rlp:encode([?CALLER, Nonce])),
    Addr.

run_create_program(Code) ->
    {ok, _, _, St, _} = eth_evm:run(Code, ?MSG0, call_state(0, <<16#00>>),
                                    ?ENV, ?GAS),
    St.

%% ---------------------------------------------------------------------------
%% EIP-161 (a): a contract made by CREATE or CREATE2 has nonce 1, never 0.
%% ---------------------------------------------------------------------------
%%
%%     Account creation transactions and the CREATE operation SHALL, prior to the
%%     execution of the initialisation code, increment the nonce over and above its
%%     normal starting value by one.
%%     -- EIP-161, Spurious Dragon
%%
%% and the EIP's Rationale gives the reason the rule is one rather than zero, which
%% is what makes it a rule about the nonce rather than about a counter:
%%
%%     CREATE avoids zero in the nonce to avoid any suggestion of the oddity of
%%     CREATEd accounts being reaped half-way through their creation.
%%
%% EIP-161 defines an account *empty* as "no code and zero nonce and zero balance",
%% and (d) requires a touched account which is now empty to be deleted. A created
%% account at nonce 0 with no code yet is therefore a deletion candidate for the whole
%% of its initialisation; the nonce is what keeps it alive while it is bare.
%%
%% This was absent from `eth_evm:create_with_value/9' while `eth_block:deploy/5' -- the
%% create-*transaction* path -- has always set it. So the two ways of deploying a
%% contract in this node disagreed, and the opcode way was wrong. The corpus found it
%% as **84 nonce divergences and not one code divergence** across
%% `constantinople/eip1014_create2/test_create2_return_data.json` -- and the shape is
%% the evidence: "a create that did not happen" and "a create that happened with the
%% wrong nonce" are the same diff, so the *absence* of a code diff is what says the
%% deployment occurred and only the nonce was wrong.

a_created_contract_has_nonce_one_test() ->
    eth_test_util:with_local_reads(fun() ->
        St = run_create_program(create_program(stop_init_code())),
        Addr = created_addr(St),
        ?assertNotEqual(undefined, Addr),
        ?assertEqual(1, eth_state:nonce(St, Addr))
    end).

%% **The rule is Spurious Dragon and later; earlier forks keep the zero.** EIP-161's
%% own "Hard fork" section is the authority (`FORK_BLKNUM: 2,675,000'), and the reason
%% is in its Rationale -- the reaping problem is created by the same EIP's rules (c)
%% and (d), so there is nothing to avoid before it. An unconditional write is
%% therefore not a simplification but a divergence on Frontier through Petersburg,
%% which is four of the thirteen forks in the corpus.
%%
%% Both arms run the **same program** and differ only in the `fork' key of the
%% environment, so nothing about the fixture differs except the thing under test. The
%% pre-Spurious-Dragon arm has no control of its own, and does not need one: the
%% Cancun arm above is the control, and it asserts the other value.
%%
%% **`homestead`, not `byzantium`.** The first version of this test used Byzantium for
%% the "before" arm, and it failed -- correctly. `fork_rank/1' puts Spurious Dragon at
%% 4 and Byzantium at **5**: Byzantium is two forks *after* it, so the arm was asking
%% for a nonce of 0 at a fork that has had the rule for two forks. The pre-SD forks
%% are `frontier', `homestead', `dao' and `tangerine_whistle', at ranks 0 to 3. The
%% mistake is a fork *name* read as "old" rather than as a rank -- the same class of
%% error as reading a fixture's fork name where this module wanted an atom.
a_created_contract_keeps_nonce_zero_before_spurious_dragon_test() ->
    eth_test_util:with_local_reads(fun() ->
        Code = create_program(stop_init_code()),
        {ok, _, _, St, _} = eth_evm:run(Code, ?MSG0, call_state(0, <<16#00>>),
                                        #{fork => homestead}, ?GAS),
        Addr = created_addr(St),
        ?assertNotEqual(undefined, Addr),
        ?assertEqual(0, eth_state:nonce(St, Addr)),
        %% Same program, one fork later: the rule applies. Asserted here as well as in
        %% its own test so this test cannot pass on a node that never writes the nonce.
        {ok, _, _, St2, _} = eth_evm:run(Code, ?MSG0, call_state(0, <<16#00>>),
                                         #{fork => spurious_dragon}, ?GAS),
        ?assertEqual(1, eth_state:nonce(St2, created_addr(St2)))
    end).

a_contract_created_by_create2_has_nonce_one_test() ->
    eth_test_util:with_local_reads(fun() ->
        St = run_create_program(create2_program(stop_init_code())),
        Addr = created_addr(St),
        ?assertNotEqual(undefined, Addr),
        ?assertEqual(1, eth_state:nonce(St, Addr))
    end).

%% A create whose init code returns a word: the deployed code is asserted **first**,
%% because otherwise the nonce is being asked about a bare account, which is the
%% window EIP-161's rationale is about and also a state a real create passes through
%% on its way to having code. This is the assertion that catches "a create that
%% succeeded and deployed nothing" -- which is what the first version of every program
%% in this section actually did.
a_created_contract_carries_the_code_it_returned_test() ->
    eth_test_util:with_local_reads(fun() ->
        St = run_create_program(create_program(word_init_code())),
        Addr = created_addr(St),
        ?assertNotEqual(undefined, Addr),
        ?assertEqual(32, byte_size(eth_state:code(St, Addr))),
        ?assertEqual(1, eth_state:nonce(St, Addr))
    end).

%% **The nonce is written before the init code runs, and the failure branches are what
%% make that observable.** `execution-specs' `process_create_message/1' orders it:
%%
%%     mark_account_created(tx_state, message.current_target)
%%     increment_nonce(tx_state, message.current_target)
%%     evm = process_message(message)
%%     ...
%%     except ExceptionalHalt as error: restore_tx_state(tx_state, snapshot)
%%     else: set_code(tx_state, message.current_target, contract_code)
%%
%% so a create that halts rolls the nonce back along with everything else, and one
%% that succeeds keeps it. This node reaches the same result without a snapshot: the
%% nonce goes on the state handed to the init code, and all four failure branches of
%% `create_with_value/9' return `State1' -- the state from *before* that line -- so
%% they discard it structurally rather than by hand.
%%
%% **This test does not pin the *placement* of the nonce, and an injection is why
%% that sentence is here rather than a claim that it does.** The obvious alternative
%% is to write the nonce in the success arm beside `set_code/3'. Moving it there --
%% deleting it from here and adding it there, so the deployed contract still ends up
%% with nonce 1 -- **passed every test written for this rule**, because all four
%% failure branches of `create_with_value/9' return `State1'`, the state from *before*
%% the transfer, and so discard the child's returned state entirely. The two
%% placements agree on every reachable state, and an account with nonce 1 and no code
%% is not reachable by writing the nonce in the wrong place.
%%
%% So what EELS gets from `restore_tx_state/2' on an exceptional halt, this module
%% gets from its failure branches, and the branches were already right. The nonce
%% goes where EELS puts it because that is the specification's order, not because a
%% test here would notice the difference -- and a comment claiming otherwise would be
%% the exact failure this repository's own rules are about.
%%
%% What this test *does* pin is real and does bite: a create that fails leaves no
%% account behind, checked against a control arm that differs in one byte and does
%% create one.
a_reverted_create_leaves_no_account_behind_test() ->
    eth_test_util:with_local_reads(fun() ->
        %% **The revert is in the init code, not in the outer program.** The first
        %% version appended a `REVERT' after the `SSTORE', and `REVERT' pops offset
        %% and length -- off a stack `CREATE' and `SSTORE' have already emptied -- so
        %% it underflowed instead of reverting, the outer frame reported success, and
        %% slot 9 still held the address. The test then asserted an account was absent
        %% from a state in which the *outer* frame had never reverted at all, which is
        %% not the branch under test either way: what has to roll back is the create,
        %% and only the init code can make a create revert.
        Retrying = create_program(revert_init_code()),
        Deploying = create_program(word_init_code()),
        %% The control is checked before it is used, so a drifted pair fails here
        %% rather than as an absence that both arms agree on.
        ?assertEqual(1, count_differences(Deploying, Retrying)),
        StD = run_create_program(Deploying),
        StR = run_create_program(Retrying),
        Deployed = created_addr(StD),
        %% The control first: a test asserting an account's *absence* passes for the
        %% wrong reason when the control also created nothing, which is the trap this
        %% module has already paid for twice.
        ?assertNotEqual(undefined, Deployed),
        ?assertEqual(32, byte_size(eth_state:code(StD, Deployed))),
        ?assertEqual(1, eth_state:nonce(StD, Deployed)),
        ?assertEqual(undefined, created_addr(StR)),
        ?assertNot(eth_state:exists(StR, would_create(StR)))
    end).

%% How many byte positions two equal-length binaries differ in. Length is asserted by
%% the caller: `zip/2` truncates to the shorter, so a length difference would report a
%% small number rather than fail.
count_differences(A, B) when byte_size(A) =:= byte_size(B) ->
    length([X || {X, Y} <- lists:zip(binary_to_list(A), binary_to_list(B)), X =/= Y]).


%% **`16#61` is PUSH2, not `16#62`.** `16#62` is PUSH3, so a two-byte immediate written
%% with it swallows the *next* opcode as its third byte -- which, in `create_seq/1', is
%% the `CREATE` itself. The result is a program that never creates anything and reports
%% a return-data buffer that nobody touched, which reads as a node defect and is not
%% one. Every hand-written probe here was wrong in that single hex digit at once, and
%% it cost four of them to find.
push_int(V) when V > 255, V =< 65535 -> <<16#61, (V bsr 8), (V band 255)>>;
push_int(V) -> <<16#60, V>>.

a_create_the_sender_cannot_afford_empties_the_return_data() ->
    eth_test_util:with_local_reads(fun() ->
        %% The call succeeds first and leaves a return data of size 1, so the CREATE
        %% has something to clear. The sender holds 1000 and the CREATE asks 20000, so
        %% the value cannot move.
        Callee = <<16#60, 1, 16#60, 0, 16#F3>>,
        Code = <<(call_seq(16#0D, 0, 16#F1))/binary, 16#50,
                 (create_seq(20000))/binary,
                 16#3D, 16#60, 8, 16#55, 16#00>>,
        {ok, _, _, St, _} = eth_evm:run(Code, ?MSG0, call_state(1000, Callee),
                                        #{fork => cancun}, ?GAS),
        ?assertEqual(0, eth_state:storage(St, ?CALLER, 8)),
        %% The control: without the CREATE the buffer holds 1. Asserted because an
        %% assertion of 0 means nothing if the buffer was empty to begin with -- which
        %% is what an earlier hand-written probe of this path concluded, having
        %% assembled the CALL wrongly and read a buffer that had never been written.
        {ok, _, _, St1, _} =
            eth_evm:run(<<(call_seq(16#0D, 0, 16#F1))/binary, 16#50,
                          16#3D, 16#60, 8, 16#55, 16#00>>,
                        ?MSG0, call_state(1000, Callee), #{fork => cancun}, ?GAS),
        ?assertEqual(1, eth_state:storage(St1, ?CALLER, 8))
    end).

%% **`CREATE` clears the buffer on success too, and not to the new address.** This is
%% the one a `finish_call/8' grep cannot find, because the success path does not go
%% through `finish_call/8' -- it pushes the address itself:
%%
%%     incorporate_child_on_success(evm, child_evm)
%%     evm.return_data = b""
%%     push(evm.stack, U256.from_be_bytes(child_evm.message.current_target))
%%
%% (`execution-specs`, `forks/cancun/vm/instructions/system.py`.) The **stack** gets
%% the address; the buffer gets nothing. An earlier reading of EIP-211 -- that a
%% successful `CREATE` leaves the created address in the buffer -- is wrong for the
%% current specification, and the specification was read rather than recalled for
%% exactly that reason.
a_successful_create_empties_the_return_data() ->
    eth_test_util:with_local_reads(fun() ->
        Callee = <<16#60, 1, 16#60, 0, 16#F3>>,
        Code = <<(call_seq(16#0D, 0, 16#F1))/binary, 16#50,
                 (create_seq(0))/binary,           %% value 0: deploys empty code
                 16#3D, 16#60, 8, 16#55, 16#00>>,
        {ok, _, _, St, _} = eth_evm:run(Code, ?MSG0, call_state(1000, Callee),
                                        #{fork => cancun}, ?GAS),
        ?assertEqual(0, eth_state:storage(St, ?CALLER, 8))
    end).

%% The `CREATE` half of the depth limit, which is a separate `finish_call/8' site from
%% `CALL`'s. **`run_create/6` refuses at the same 1024**, and the test that would pin it
%% does not exist, for a reason worth recording rather than a test worth faking:
%%
%% **The depth-limit branches are unobservable from a single frame.** A frame whose
%% depth is already 1024 cannot make *any* call, so it also cannot have populated the
%% return-data buffer -- every `CALL` and `CREATE` it attempts is the one being refused.
%% The buffer is only non-empty at depth 1024 if the frame got there by recursing, and
%% that needs a real 1024-deep call tree: ~3,300 gas a frame, so 3.4M against this
%% module's `?GAS'.
%%
%% The first version of this test set `depth' in the message and asserted the buffer was
%% empty, and it passed with the fix **deleted** -- because the control call was refused
%% too, so the buffer was empty either way. A test that cannot fail is worse than no
%% test, so it is not here. The two `finish_call/8' lines are kept because the
%% specification puts the reset *before* the depth check
%% (`evm.return_data = b""' is the first statement of `generic_call' and
%% `generic_create'), and they are the same one-token change as the six that are pinned
%% -- but they are **unpinned**, and saying so is the point of this note.

a_call_that_did_not_happen_empties_the_return_data_test_() ->
    {foreach, fun() -> ok end,
     [fun a_create_the_sender_cannot_afford_empties_the_return_data/0,
      fun a_successful_create_empties_the_return_data/0,
      fun a_precompile_the_caller_cannot_afford_empties_the_return_data/0]}.

%% A precompile asked for a call the caller cannot forward gas for. This is a *third*
%% precompile outcome, distinct from the two above: the precompile ran, its answer was
%% `{ok, Out, Cost}', and `Cost' exceeded the forwarded allowance, so the call fails and
%% the whole allowance is gone -- it was not a CALL frame, so there is no remainder to
%% hand back. The buffer must be empty for the same reason the other two are.
a_precompile_the_caller_cannot_afford_empties_the_return_data() ->
    eth_test_util:with_local_reads(fun() ->
        Callee = <<16#60, 1, 16#60, 0, 16#F3>>,
        %% `mem[0] = 1`, so identity is given one non-zero byte and answers with one.
        %% Identity costs 15 + 3 per word, so forwarding 0 cannot pay for it.
        Code = <<16#60, 1, 16#60, 0, 16#53,
                 (call_seq(16#0D, 0, 16#F1))/binary, 16#50,
                 (call_with_gas(16#04, 1, 0))/binary,
                 16#3D, 16#60, 8, 16#55, 16#00>>,
        {ok, _, _, St, _} = eth_evm:run(Code, ?MSG0, call_state(1000, Callee),
                                        #{fork => cancun}, ?GAS),
        ?assertEqual(0, eth_state:storage(St, ?CALLER, 8)),
        %% **The control, and it is the whole test:** the same call with gas it can
        %% afford succeeds and publishes its one byte of output. So the 0 above is the
        %% branch clearing the buffer, not a precompile that had nothing to say.
        Ok = <<16#60, 1, 16#60, 0, 16#53,
               (call_seq(16#0D, 0, 16#F1))/binary, 16#50,
               (call_with_gas(16#04, 1, 1000))/binary,
               16#3D, 16#60, 8, 16#55, 16#00>>,
        {ok, _, _, St1, _} = eth_evm:run(Ok, ?MSG0, call_state(1000, Callee),
                                         #{fork => cancun}, ?GAS),
        ?assertEqual(1, eth_state:storage(St1, ?CALLER, 8))
    end).

%% `CALLCODE` is the same block in the spec -- the same `sender_balance` check, the
%% same `evm.gas_left += message_call_gas.sub_call`, and `should_transfer_value=True` --
%% and `check_call_value/5` had only a `call` clause, so `CALLCODE` moved no value and
%% consulted no balance. `delegatecall` and `staticcall` correctly have neither.
callcode_transfers_the_value_and_checks_the_balance_like_call_test() ->
  eth_test_util:with_local_reads(fun() ->
    Funded = call_state(1000, <<16#00>>),
    [begin
         {ok, _, _, St, _} =
             eth_evm:run(<<(call_seq(16#0D, 40, 16#F2))/binary, 16#00>>,
                         ?MSG0, Funded, #{fork => F}, ?GAS),
         ?assertEqual({F, 960}, {F, eth_state:balance(St, ?CALLER)}),
         ?assertEqual({F, 40}, {F, eth_state:balance(St, ?CALLEE)})
     end || F <- [istanbul, berlin, cancun]],
    %% And when the caller cannot cover it, `CALLCODE` fails exactly as `CALL` does --
    %% no value moves. This is the half that was missing; the first half above would
    %% have passed before the fix too, since nothing moved in either direction.
    {ok, _, _, Broke, _} =
        eth_evm:run(<<(call_seq(16#0D, 40, 16#F2))/binary, 16#00>>,
                    ?MSG0, call_state(10, <<16#00>>), #{fork => cancun}, ?GAS),
    ?assertEqual(10, eth_state:balance(Broke, ?CALLER)),
    ?assertEqual(0, eth_state:balance(Broke, ?CALLEE))
  end).

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

%% **Every assertion of the form "the caller pays 9,000 more for a value-bearing call"
%% in this module was short by the stipend.** The caller is charged `MessageCallGas.cost'
%% = `gas' + `extra_gas', and the stipend is in `sub_call' only -- it is a gift, created
%% from nothing, and the caller never pays for it. When the callee runs nothing the
%% whole allowance comes back, so the caller's net is `extra_gas' **less** the 2,300.
%% Three tests here asserted the caller paid it, each wrong by exactly 2,300, and all
%% three were written to pin EIP-161's and EIP-150's figures rather than this one.
%% The two optional terms, and the condition on the second: the 25000 new-account
%% charge only applies to a call that transfers value, because a call that
%% transfers nothing cannot create an account. Charging it on a zero-value call
%% would make every read-only call cost 25000 more than it should.
%%
%% The value transfer is **9,000 less the 2,300 stipend**, not 9,000. This test
%% asserted 9,000 and the node charged 9,000, and both were wrong together.
call_optional_terms_follow_the_specification_test() ->
    NoValue = call_gas(16#F1, cold, funded),
    WithValue = call_gas(16#F1, cold, funded_with_value),
    NewAccount = call_gas(16#F1, cold, empty_account),
    ?assertEqual(NoValue + 9000 - 2300, WithValue),
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
    Env = #{base_fee => 1000000000, fork => cancun},
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

%% ---------------------------------------------------------------------------
%% The code-deposit cost
%% ---------------------------------------------------------------------------
%%
%% `G_codedeposit` is 200 per byte of the code a create hands back, at every fork, and
%% it was charged **nowhere**. The size cap was a bare `byte_size(Code) =< 24576' in a
%% guard -- a predicate with no price behind it, applied at every fork including the
%% ones before EIP-170 introduced it -- so this node deployed code of any size for
%% free, and never went out of gas on a create whose deposit it could not pay.
%%
%% The corpus is what found it, and the arithmetic is what makes it certain rather than
%% likely. `create/test_create_deposit_oog` has a twenty-three-byte callee that stores a
%% word and then `CREATE`s six bytes of init code which itself `RETURN`s 10,000 bytes:
%% a 2,000,000-gas deposit against a 934,172-gas frame. Seven of those fixtures
%% expected the whole 1,000,000 allowance to be spent and the node spent 57,062,
%% handing back 918,145 gas the chain never returns.
deposit_is_two_hundred_a_byte_at_every_fork_test() ->
    [?assertEqual({F, 200}, {F, marginal_deposit(F, 8)})
     || F <- [frontier, homestead, byzantium, petersburg, istanbul, berlin,
              london, cancun, prague]],
    %% And the absolute figure, not only the marginal one, because a marginal test
    %% cannot see a deposit charged at the wrong *rate* for one size and the right one
    %% for another -- it can only see a difference between two sizes.
    %%
    %% Against **one** byte and not against zero, and the 3 gas of difference is the
    %% reason. A `RETURN' of any non-empty length expands the child's memory by a word
    %% and a return of nothing expands none, so a zero-byte control folds 3 gas of
    %% memory expansion into a figure that is supposed to be a deposit, and it comes out
    %% 3,203 against a 0-byte control. One byte is the smallest deployment that pays
    %% the memory term, so both
    %% sides pay it and what is left is the 15 extra bytes at 200 each.
    ?assertEqual({16, 3000}, {16, deposit_for(16) - deposit_for(1)}).

%% EIP-2 item 3, verbatim: "If contract creation does not have enough gas to pay for
%% the final gas fee for adding the contract code to the state, the contract creation
%% fails (i.e. goes out-of-gas) rather than leaving an empty contract."
%%
%% The whole forwarded allowance goes, which is what a frame that halts has always done
%% in this module and what `create_with_value/9' did for the *init code* running out of
%% gas. It had no clause for the deposit, so it deployed instead.
a_create_that_cannot_pay_its_deposit_fails_and_consumes_its_forwarded_gas_test() ->
    [begin
         {_Left, Deployed} = deploy_probe(10000, ?GAS, F),
         ?assertEqual({F, {failed, 0}}, {F, Deployed})
     end || F <- [homestead, byzantium, petersburg, istanbul, berlin, cancun]],
    %% **Two failing sizes leave the parent with exactly the same gas**, and that is
    %% the sharpest statement of "the forwarded allowance is gone" available here.
    %% 5,000 and 6,000 both encode as `PUSH2', so the two parent programs are
    %% byte-identical apart from the immediate, the child's own four instructions cost
    %% the same, and the deposits -- 1,000,000 and 1,200,000 -- differ by 200,000. If
    %% any of the child's unused allowance were returned, the two would differ by it.
    {Left5, _} = deploy_probe(5000, ?GAS, cancun),
    {Left6, _} = deploy_probe(6000, ?GAS, cancun),
    ?assertEqual(Left5, Left6),
    %% A create that *can* pay leaves the parent far more behind, and the difference is
    %% the refund the failing one does not make. At 4,000 bytes the deposit is 800,000
    %% and the frame can pay it, so the child hands back everything it did not spend.
    {Left4, Deployed4} = deploy_probe(4000, ?GAS, cancun),
    ?assertEqual({ok, 1}, Deployed4),
    ?assert(Left4 - Left5 > 100000).

%% EIP-170: `MAX_CODE_SIZE` is `0x6000`, and "if contract creation initialization
%% returns data with length of **more than** MAX_CODE_SIZE bytes, contract creation
%% fails with an out of gas error". Spurious Dragon introduced it and nothing before
%% that fork had one -- the cap is a Spurious Dragon fact, not a constant.
eip_170_caps_deployed_code_at_spurious_dragon_and_not_before_test() ->
    %% 24,577 bytes, affordable at 4,915,400 gas of allowance, so the *only* thing
    %% that can reject it is the cap.
    Gas = 6000000,
    {LeftOver, DeployedEIP170} = deploy_probe(24577, Gas, berlin),
    ?assertEqual({failed, 0}, DeployedEIP170),
    %% 4,915,400 gas of deposit against a 5,906,250-gas frame, so the failure is the
    %% **cap** and not the price -- the create is affordable and is rejected anyway.
    %% EIP-170 says "fails with an out of gas error", and an out-of-gas frame returns
    %% nothing, so the parent is left holding only the 1/64th EIP-150 withholds.
    {LeftUnder, DeployedUnder} = deploy_probe(24576, Gas, berlin),
    ?assertEqual({ok, 1}, DeployedUnder),
    ?assert(LeftUnder - LeftOver > 900000),
    %% Before Spurious Dragon there is no cap, so the very same create succeeds --
    %% `max_code_size/1' answers `infinity' rather than 24576 there, and a constant
    %% 24576 would have been right for one span of the schedule and wrong for eight.
    {_, DeployedFrontier} = deploy_probe(24577, Gas, frontier),
    ?assertEqual({ok, 1}, DeployedFrontier),
    ?assertEqual(infinity, eth_fork_schedule:max_code_size(frontier)),
    ?assertEqual(24576, eth_fork_schedule:max_code_size(spurious_dragon)).

%% A parent that CODECOPYs an init-code buffer to offset 0, issues CREATE over it, and
%% stops. The buffer is `PUSH<n> Size; PUSH1 0; RETURN`, so the child hands back
%% exactly `Size' bytes of its own (zero) memory: a deployment of `Size' bytes and
%% nothing else, with the child executing four instructions whatever `Size' is. That
%% last part is what makes the marginal figure below a *deposit* and not a memory
%% expansion.
deployed_bytes(Size) ->
    Buffer = <<(push_len(Size))/binary, 16#60, 0, 16#F3>>,
    BLen = byte_size(Buffer),
    Args = <<16#60, BLen, 16#60, 0, 16#60, 0, 16#F0>>,   %% length, offset, value
    Copy = <<16#60, BLen, 16#60, 0, 16#60, 0, 16#39>>,   %% destination, offset, length
    Stop = <<16#00>>,
    Offset = byte_size(Copy) + byte_size(Args) + byte_size(Stop),
    <<16#60, BLen, 16#60, Offset, 16#60, 0, 16#39, Args/binary,
      Stop/binary, Buffer/binary>>.

push_len(N) when N > 255 -> <<16#61, N:16>>;
push_len(N) -> <<16#60, N>>.

%% Gas the parent spends on a create deploying `Size' bytes, minus what it would
%% spend deploying one byte. Everything except the deposit is identical between the
%% two -- the parent is the same program, the child runs the same four instructions,
%% and the only difference is how many bytes the child's RETURN produced.
marginal_deposit(Fork, Size) ->
    deposit_for(Size + 1, Fork) - deposit_for(Size, Fork).

deposit_for(Size) -> deposit_for(Size, cancun).
deposit_for(Size, Fork) -> deploy_gas(Size, ?GAS, Fork).

deploy_gas(Size, Gas, Fork) ->
    State = created_address_probe(create, Size),
    {ok, _, Left, _, _} = eth_evm:run(deployed_bytes(Size), ?MSG0, State,
                                      #{fork => Fork}, Gas),
    Gas - Left.

%% `{Left, {ok, 1}}` when the address is deployed, `{Left, {failed, 0}}` when CREATE
%% pushed 0, and the parent's `Left` in both cases -- which is the half of the answer
%% that says whether the forwarded allowance was consumed.
deploy_probe(Size, Gas, Fork) ->
    State = created_address_probe(create, Size),
    Code = deployed_bytes(Size),
    Addr = probe_created_address(Size),
    {Result, Left} = case eth_evm:run(Code, ?MSG0, State, #{fork => Fork}, Gas) of
                         {ok, _Out, L, St, _Logs} -> {created(St, Addr), L};
                         {error, Reason, _St, _Logs} -> erlang:error({create_failed, Reason})
                     end,
    {Left, Result}.

created(St, Addr) ->
    case eth_state:code(St, Addr) of
        <<>> -> {failed, 0};
        _ -> {ok, 1}
    end.

%% The create address for a one-nonce caller and a given init code, seeded as an
%% empty account so `eth_state:exists/2' does not send the test upstream. The child's
%% nonce is what the CREATE reads, and the caller starts at 0.
created_address_probe(create, Size) ->
    Addr = probe_created_address(Size),
    eth_state:new(0, #{{balance, ?CALLER} => 1000000000,
                       {nonce, ?CALLER} => 0,
                       {balance, Addr} => 0,
                       {nonce, Addr} => 0,
                       {code, Addr} => <<>>}).

probe_created_address(Size) ->
    Buffer = <<(push_len(Size))/binary, 16#60, 0, 16#F3>>,
    created_address(create, 0, Buffer).

%% ---------------------------------------------------------------------------
%% Opcode availability by fork
%% ---------------------------------------------------------------------------
%%
%% An instruction the executing fork does not have is an exceptional halt that
%% consumes the frame's whole allowance. These tests are the interpreter's half of
%% the pin; eth_fork_schedule_tests holds the table's half.

%% PUSH0 is Shanghai's (EIP-3855). Before it, the byte is not a cheap way to push
%% zero -- it is a halt. The frame below is `PUSH0, PUSH1 2, PUSH1 0, RETURN', so
%% under pre-Shanghai rules it must not return two zero bytes; it must halt.
%%
%% RETURN takes the offset on top and the length below it, so the length is pushed
%% first. The other way round returns nothing at all and the assertion below would
%% pass at Shanghai for the wrong reason.
push0_is_an_exceptional_halt_before_shanghai_test() ->
    Code = <<16#5F, 16#60, 2, 16#60, 0, 16#F3>>,
    [?assertMatch({error, {undefined_opcode, 16#5F}, _, _},
                  eth_evm:run(Code, ?MSG0, ?STATE, #{fork => F}, ?GAS))
     || F <- [frontier, homestead, byzantium, constantinople, petersburg,
              istanbul, berlin, london, merge, paris]].

push0_runs_from_shanghai_on_test() ->
    Code = <<16#5F, 16#60, 2, 16#60, 0, 16#F3>>,
    [?assertMatch({ok, <<0, 0>>, _, _, _},
                  eth_evm:run(Code, ?MSG0, ?STATE, #{fork => F}, ?GAS))
     || F <- [shanghai, cancun, prague, osaka, amsterdam]].

%% The Cancun additions, each of which the interpreter used to run in every fork
%% because every clause in do_op/3 is unconditional. TLOAD is the cheapest to see:
%% `TSTORE 0, 7, TLOAD 0, PUSH1 0, RETURN' returns the value it just stored, and
%% before Cancun it must halt on the TSTORE rather than return it.
%%
%% The operand order is the one SSTORE and TSTORE both use: the slot is on top
%% and the value below it, so the pushes are value-then-slot. Written the other
%% way round this stores 0 into slot 7, reads slot 0, finds it zero, and the test
%% passes at Cancun for the wrong reason while the pre-Cancun half still fails --
%% which is not a test that can distinguish a correct gate from a broken one.
%%
%% The returned word is decoded rather than compared byte for byte. What is under
%% test here is the fork gate and the transient round trip; the byte order of a
%% 32-byte word is a different question with a different test, and asserting the
%% bytes here would be asserting that question's answer by accident.
tload_and_tstore_are_missing_before_cancun_test() ->
    Code = <<16#60, 7, 16#60, 0, 16#5D,          %% PUSH1 7, PUSH1 0, TSTORE
             16#60, 0, 16#5C,                   %% PUSH1 0, TLOAD
             16#60, 0, 16#52, 16#60, 32, 16#60, 0, 16#F3>>,
    PreCancun = [frontier, homestead, byzantium, constantinople, petersburg,
                 istanbul, berlin, london, merge, paris, shanghai],
    [?assertMatch({error, {undefined_opcode, 16#5D}, _, _},
                  eth_evm:run(Code, ?MSG0, ?STATE, #{fork => F}, ?GAS))
     || F <- PreCancun],
    {ok, Out, _, _, _} = eth_evm:run(Code, ?MSG0, ?STATE, #{fork => cancun}, ?GAS),
    ?assertEqual(32, byte_size(Out)),
    ?assertEqual(7, binary:decode_unsigned(Out)).

%% The other four Cancun arrivals, each checked on its own byte so a failure names
%% the instruction rather than "one of five". Each code pushes whatever the
%% instruction needs and stops; the assertion is only ever about whether the halt
%% names *that* byte, so a code that faults later for an unrelated reason still
%% passes the pre-Cancun half and is not mistaken for a gate that failed to fire.
cancun_only_opcodes_are_missing_before_cancun_test() ->
    Arrivals = [{16#49, <<16#60, 0, 16#49>>, 'BLOBHASH'},
                {16#4A, <<16#60, 0, 16#4A>>, 'BLOBBASEFEE'},
                {16#5C, <<16#60, 0, 16#5C>>, 'TLOAD'},
                {16#5D, <<16#60, 0, 16#60, 0, 16#5D>>, 'TSTORE'},
                {16#5E, <<16#60, 0, 16#60, 32, 16#60, 0, 16#5E>>, 'MCOPY'}],
    ?assertEqual([16#49, 16#4A, 16#5C, 16#5D, 16#5E], [Op || {Op, _, _} <- Arrivals]),
    [begin
         PreCancun = [frontier, byzantium, constantinople, istanbul, london,
                      paris, shanghai],
         [?assertMatch({error, {undefined_opcode, Op}, _, _},
                       eth_evm:run(Code, ?MSG0, ?STATE, #{fork => F}, ?GAS))
          || F <- PreCancun],
         %% At Cancun the gate no longer fires. The frame may still fail -- these
         %% opcodes read state this fixture does not have -- but it must not fail
         %% by claiming the instruction does not exist. Compared with =:= rather
         %% than ?assertNotEqual, whose first argument is used as a pattern and so
         %% cannot hold a bare `_'.
         ?assertNotEqual(undefined_opcode,
                         undefined_opcode_reason(
                           eth_evm:run(Code, ?MSG0, ?STATE, #{fork => cancun},
                                       ?GAS)))
     end || {Op, Code, _Name} <- Arrivals],
    ok.

%% `undefined_opcode' if the frame halted on a byte the fork does not have, and
%% anything else otherwise. Deliberately coarse: the question is only ever whether
%% the availability gate fired, not why the frame failed for some other reason.
undefined_opcode_reason({error, {undefined_opcode, _}, _, _}) -> undefined_opcode;
undefined_opcode_reason({error, Reason, _, _}) -> {other_error, Reason};
undefined_opcode_reason({revert, _, _, _, _}) -> reverted;
undefined_opcode_reason({ok, _, _, _, _}) -> ran.

%% London's BASEFEE (EIP-3198) and Istanbul's two. Chosen because each reads the
%% environment rather than memory, so the only way to run one before its fork is
%% to have executed an instruction that did not exist.
%%
%% SELFBALANCE reads the executing account's balance, so the "available at its
%% fork" half needs the balance in the state's own overlay. Without it eth_state
%% falls through to its upstream reader and this test performs a lazy JSON-RPC
%% fetch against the configured public endpoint -- which is a unit test reaching
%% the network, and it hangs rather than fails when there is none.
fork_gated_environment_opcodes_test() ->
    Bases = [{16#48, [frontier, byzantium, constantinople, istanbul, berlin]},
             {16#46, [frontier, byzantium, constantinople]},
             {16#47, [frontier, byzantium, constantinople]}],
    [begin
         Code = <<Op, 16#60, 0, 16#52, 16#60, 32, 16#60, 0, 16#F3>>,
         [?assertMatch({error, {undefined_opcode, Op}, _, _},
                       eth_evm:run(Code, ?MSG0, ?STATE, #{fork => F}, ?GAS))
          || F <- TooEarly]
     end || {Op, TooEarly} <- Bases],
    ?assertMatch({ok, _, _, _, _},
                 eth_evm:run(<<16#48>>, ?MSG0, ?STATE, #{fork => london}, ?GAS)),
    ?assertMatch({ok, _, _, _, _},
                 eth_evm:run(<<16#46>>, ?MSG0, ?STATE, #{fork => istanbul}, ?GAS)),
    Local = eth_state:new(0, #{{balance, <<0:160>>} => 0}),
    ?assertMatch({ok, _, _, _, _},
                 eth_evm:run(<<16#47>>, ?MSG0, Local, #{fork => istanbul}, ?GAS)).

%% A byte nobody ever assigned halts in every fork, and it is a *different*
%% reason from 0xFE's. 0xFE is a specified halt; an unassigned byte is a missing
%% instruction. eth_evm keeps them apart so a caller can.
undefined_byte_and_invalid_are_different_reasons_test() ->
    %% 0x0C is in the gap between SIGNEXTEND and LT and has never been assigned.
    ?assertMatch({error, {undefined_opcode, 16#0C}, _, _},
                 eth_evm:run(<<16#0C>>, ?MSG0, ?STATE, #{fork => cancun}, ?GAS)),
    ?assertMatch({error, {undefined_opcode, 16#0C}, _, _},
                 eth_evm:run(<<16#0C>>, ?MSG0, ?STATE, #{fork => frontier}, ?GAS)),
    %% 0xFE is INVALID, which every fork defines.
    ?assertMatch({error, invalid_opcode, _, _},
                 eth_evm:run(<<16#FE>>, ?MSG0, ?STATE, #{fork => cancun}, ?GAS)),
    ?assertMatch({error, invalid_opcode, _, _},
                 eth_evm:run(<<16#FE>>, ?MSG0, ?STATE, #{fork => frontier}, ?GAS)).

%% An undefined instruction consumes the frame's whole allowance, as every
%% exceptional halt does. A halt that returned the remaining gas would be a
%% refund, and a refund on a halt is a state transition no client reproduces.
undefined_opcode_consumes_the_whole_allowance_test() ->
    %% 0x5F is Shanghai's, so at Paris it halts -- and it halts on the first
    ?assertMatch({error, {undefined_opcode, 16#5F}, _, _},
                 eth_evm:run(<<16#5F>>, ?MSG0, ?STATE, #{fork => paris}, 100000)),
    %% instruction, with the entire 100000 unspent and therefore unreportable:
    %% run/5's error form carries no gas figure precisely because there is none.
    ?assertMatch({error, {undefined_opcode, 16#5F}, _, _},
                 eth_evm:run(<<16#5F>>, ?MSG0, ?STATE, #{fork => paris}, 1)).

%% The Env has to say which fork. There is no default, because a default is a
%% fork this node chose rather than one the chain chose: run against a Paris block
%% with Cancun's instructions available and the frame succeeds where the chain
%% says it must halt, and the result is recorded as a state root with nothing in
%% it to say the rules were wrong.
env_without_a_fork_is_refused_rather_than_guessed_test() ->
    ?assertError({badkey, fork},
                 eth_evm:run(<<16#00>>, ?MSG0, ?STATE, #{}, ?GAS)),
    ?assertError({badkey, fork},
                 eth_evm:run(<<16#00>>, ?MSG0, ?STATE, #{number => 1}, ?GAS)).

%% The fork in the Env is what the child frames inherit. A CALL runs under the
%% caller's rules, not under anything the callee chooses, so a Paris contract
%% cannot call a PUSH0 into existence by pointing at an account that has one.
%%
%% The observable is the CALL's own return value: a child that halts pushes 0 and
%% the caller carries on, so the parent's success flag says whether the gate fired
%% in the frame that mattered. The two forks are run over the same bytecode, which
%% is what rules out "the test is really asserting something else".
child_frames_inherit_the_fork_from_the_env_test() ->
    Child = <<16#5F>>,                               %% PUSH0, then fall off the end
    Parent = <<(call_seq(16#0D, 0, 16#F1))/binary,   %% CALL, leaves 0 or 1
                16#60, 0, 16#52,                     %% PUSH1 0, MSTORE
                16#60, 32, 16#60, 0, 16#F3>>,         %% RETURN 32 bytes
    State = call_state(1000000, Child),
    {ok, Out, _, _, _} = eth_evm:run(Parent, ?MSG0, State, #{fork => paris}, ?GAS),
    %% The child's PUSH0 does not exist at Paris, so the child halted, the CALL
    %% pushed 0, and the parent returned that 0 rather than aborting with it.
    ?assertEqual(0, binary:decode_unsigned(Out)),
    {ok, Ok, _, _, _} = eth_evm:run(Parent, ?MSG0, State, #{fork => cancun}, ?GAS),
    ?assertEqual(1, binary:decode_unsigned(Ok)).

%% ---------------------------------------------------------------------------
%% Fork-selected rules, observed through execution
%% ---------------------------------------------------------------------------

%% The refund cap, measured rather than asserted from the table.
%%
%% `SSTORE 0 <- 1' on a slot that is already 1 is a no-op write, and at London a
%% no-op write is the one case that earns a refund: EIP-3529 leaves the clear
%% refund in place, so writing a set slot back to zero and then to its original
%% value returns gas. What the cap allows of that refund is the fork's business,
%% and the cap was Berlin's divisor applied to London's refund amounts.
%%
%% The code stores 0 into a slot seeded at 1, then stores 1 back. Each run is
%% given the same allowance and the same starting state, so the gas left is
%% directly comparable, and the only thing that differs is the fork.
refund_cap_is_fork_selected_in_execution_test() ->
    Code = <<16#60, 0, 16#60, 1, 16#55,      %% PUSH1 0, PUSH1 1, SSTORE
             16#60, 1, 16#60, 1, 16#55>>,    %% PUSH1 1, PUSH1 1, SSTORE
    State = eth_state:new(0, #{{store, <<0:160>>, 1} => 1}),
    Gas = 1000000,
    Berlin = run_gas(Code, State, #{fork => berlin}, Gas),
    London = run_gas(Code, State, #{fork => london}, Gas),
    %% Berlin's cap is half of what was spent, London's a fifth. The cap only
    %% bites if the refund the frame earned exceeds it, and the assertion below
    %% is that the two forks actually come out differently -- which is the part
    %% that would pass if both were capped the same way.
    ?assertNotEqual(Berlin, London),
    %% And the direction is right. London's cap is the tighter of the two, so for
    %% a frame whose refund exceeds both caps -- which this one does, since the
    %% clear refund is 4800 against caps of 4580 and 11450 -- London hands back
    %% less gas than Berlin. Asserting the direction matters: a cap that was
    %% wired to the *other* fork would also make the two differ.
    ?assert(London < Berlin),
    %% Cancun inherits London's, since EIP-3529 has not been superseded.
    ?assertEqual(London, run_gas(Code, State, #{fork => cancun}, Gas)).

%% A frame that refunds more than the cap allows gets the cap and no more. The
%% clearest way to ask for that is a frame whose refund is large relative to what
%% it spent, which a single no-op pair is not -- so this checks the bound from the
%% other side: the gas returned is never more than the cap, at either fork.
refund_never_exceeds_the_caps_share_test() ->
    Code = <<16#60, 0, 16#60, 1, 16#55, 16#60, 1, 16#60, 1, 16#55>>,
    State = eth_state:new(0, #{{store, <<0:160>>, 1} => 1}),
    [begin
         Gas = 1000000,
         Left = run_gas(Code, State, #{fork => F}, Gas),
         Spent = Gas - Left,
         Cap = eth_fork_schedule:refund_cap(F, Spent),
         %% Left is Spent minus whatever refund was actually applied, and the
         %% refund can never exceed the cap, so Left is at least Spent - Cap.
         ?assert(Left >= Spent - Cap)
     end || F <- [berlin, london, shanghai, cancun]].

%% SELFDESTRUCT at a pre-Cancun fork destroys an account that was NOT created in
%% this transaction; from Cancun it leaves that account's code and storage alone
%% and only moves the balance.
%%
%% The account is seeded present with code, so `is_created' is false and the
%% fork is the only thing that can decide. Before this, the Cancun rule was
%% applied at every fork, so a pre-Cancun block would have kept code the chain
%% removes.
%%
%% Reads go through with_local_reads/1 because the pre-Cancun half *destroys* the
%% account, and a destroyed account has nothing left to seed in an overlay. Read
%% without that, eth_state would fall through to its upstream reader and block in
%% httpc against a public Sepolia node -- a cancelled test rather than a failure,
%% and one that says nothing about the code.
selfdestruct_destroys_only_from_cancun_test() ->
    eth_test_util:with_local_reads(
      fun() ->
        Victim = <<0:152, 16#0E:8>>,
        Ben = <<0:152, 16#0F:8>>,
        Code = <<16#60, 16#0F, 16#FF>>,          %% PUSH1 0x0f, SELFDESTRUCT
        State = fun() ->
            eth_state:new(0, #{{balance, Victim} => 100,
                               {nonce, Victim} => 0,
                               {code, Victim} => <<16#00>>,
                               {store, Victim, 0} => 7,
                               {balance, Ben} => 0})
        end,
        %% The frame runs *as* the victim, so SELFDESTRUCT is executing on the
        %% account seeded above. ?MSG0's address is the zero address, which holds
        %% nothing, and a self-destruct that moved a zero balance would leave
        %% every assertion below satisfied for the wrong reason.
        Msg0 = ?MSG0,
        Msg = Msg0#{address => Victim},
        Run = fun(Fork) ->
            {ok, _, _, St, _} = eth_evm:run(Code, Msg, State(), #{fork => Fork},
                                            ?GAS),
            St
        end,
        %% The balance always moves, at every fork. That is the half that must
        %% not regress while the other half is being gated.
        [begin
             St = Run(F),
             ?assertEqual(100, eth_state:balance(St, Ben)),
             ?assertEqual(0, eth_state:balance(St, Victim))
         end || F <- [berlin, london, shanghai, cancun]],
        %% Pre-Cancun: code and storage are gone.
        [begin
             St = Run(F),
             ?assertEqual(<<>>, eth_state:code(St, Victim)),
             ?assertEqual(0, eth_state:storage(St, Victim, 0)),
             ?assertEqual(false, eth_state:exists(St, Victim))
         end || F <- [istanbul, berlin, london, merge, paris, shanghai]],
        %% Cancun and later: the account survives, and only the balance moved.
        [begin
             St = Run(F),
             ?assertEqual(<<16#00>>, eth_state:code(St, Victim)),
             ?assertEqual(7, eth_state:storage(St, Victim, 0)),
             ?assertEqual(true, eth_state:exists(St, Victim))
         end || F <- [cancun, prague, osaka, amsterdam]]
      end).

run_gas(Code, State, Env, Gas) ->
    {ok, _Out, Left, _St, _Logs} = eth_evm:run(Code, ?MSG0, State, Env, Gas),
    Left.

%% ---------------------------------------------------------------------------
%% Access costs, measured through execution
%% ---------------------------------------------------------------------------
%%
%% eth_evm carried its own fork-free copy of the base schedule and added a
%% hardcoded cold surcharge afterwards, so EIP-150's figures existed only in
%% eth_fork_schedule and nowhere in execution: a Frontier BALANCE cost 2600.
%% These run the opcodes and measure, because a table test cannot show that the
%% interpreter asked the table.

%% The pre-Berlin account accessors, one opcode per frame.
%%
%% PUSH1 and POP are charged in every case and so are the same in all of them;
%% each figure below is written as a total rather than as "cost plus these two
%% instructions", so that a change to the pushes shows up here instead of being
%% cancelled out. The state is seeded the way `balance_cold_then_warm_test'
%% seeds it, so `exists/2' answers from the overlay and nothing reaches upstream.
account_accessors_cost_eip_150_prices_before_berlin_test() ->
    Tgt = <<0:152, 16#0E:8>>,
    State = eth_state:new(0, #{{balance, Tgt} => 123,
                               {nonce, Tgt} => 0,
                               {code, Tgt} => <<>>}),
    Push = 3 + 2,                          %% PUSH1 0x0e, then POP
    At = fun(Op, Fork) ->
        spent(<<16#60,16#0E, Op, 16#50, 16#00>>, State, Fork) - Push
    end,
    %% BALANCE and EXTCODESIZE exist at every fork and differ in their legacy
    %% figure: 400 and 700. EIP-150 raised BALANCE and left EXTCODESIZE alone.
    ?assertEqual(400, At(16#31, frontier)),
    ?assertEqual(700, At(16#3B, frontier)),
    %% EXTCODEHASH is the other 400, but it arrived with Constantinople (EIP-1052)
    %% and is an undefined opcode before that -- so it is priced at the earliest
    %% fork it can be run at, and asking for it at Frontier is answered with
    %% `undefined_opcode' rather than a price. Asserted here because that is the
    %% answer, and a price for it at Frontier would mean the availability gate had
    %% been bypassed.
    ?assertEqual(400, At(16#3F, constantinople)),
    ?assertMatch({error, {undefined_opcode, 16#3F}, _, _},
                 eth_evm:run(<<16#60,16#0E, 16#3F, 16#50, 16#00>>, ?MSG0, State,
                             #{fork => frontier}, ?GAS)),
    %% Istanbul, the last fork before Berlin, so the figure is not a Frontier
    %% accident.
    ?assertEqual(400, At(16#31, istanbul)),
    %% From Berlin the same opcode is COLD_ACCOUNT_ACCESS_COST. Asserting the
    %% boundary from both sides is what makes this a fork test rather than a
    %% constant test: 400 and 2600 are 2200 apart, and only one of them is right
    %% for any given block.
    ?assertEqual(2600, At(16#31, berlin)).

%% SLOAD before Berlin is 200: neither an account's 400 nor its own Berlin figure
%% of 2100. Asserted alone because it is the number most likely to be confused
%% with a neighbour's -- which is exactly what it was, in a function of its own.
sload_costs_200_before_berlin_test() ->
    State = eth_state:new(0, #{{store, ?CALLER, 5} => 77}),
    Code = <<16#60, 5, 16#54, 16#50, 16#00>>,
    Push = 3 + 2,
    %% SLOAD is not one number. EIP-150: "Increase the gas cost of SLOAD to 200 (from
    %% 50)." EIP-1884: "The SLOAD (0x54) operation changes from 200 to 800 gas."
    %% EIP-2929 then makes it a warm/cold pair from Berlin.
    %%
    %% This test asserted 200 at *every* pre-Berlin fork, which is right for exactly one
    %% span of three: a Frontier SLOAD cost 50 and an Istanbul one 800. All three
    %% figures are the EIPs' own.
    [?assertEqual({F, 50}, {F, spent(Code, State, F) - Push})
     || F <- [frontier, homestead]],
    [?assertEqual({F, 200}, {F, spent(Code, State, F) - Push})
     || F <- [tangerine, spurious_dragon, byzantium, petersburg]],
    %% Muir Glacier shares Istanbul's rank, so it shares its 800.
    [?assertEqual({F, 800}, {F, spent(Code, State, F) - Push})
     || F <- [istanbul, muir_glacier]],
    %% Berlin and later: COLD_SLOAD_COST, which is 2100 and not 2600.
    ?assertEqual(2100, spent(Code, State, berlin) - Push),
    ?assertEqual(2100, spent(Code, State, cancun) - Push).

%% The CALL family before Spurious Dragon pays the EIP-150 access term and
%% nothing else: no 9000 for a value transfer, no 25000 for a new account, both of
%% which are EIP-161's. A zero-value call to a funded account is used so the
%% optional terms are not merely absent by accident -- if `new_account' were being
%% asked about a non-existent address the 25000 would show up and the figure would
%% not match.
%%
%% Reads go through with_local_reads/1 because the second half of this asks about
%% a destination that is *deliberately* absent from the state, and there is
%% nothing to seed: an absent account is the whole point. Read without that,
%% `new_account/3' would fall through to eth_state's upstream reader and block in
%% httpc against a public Sepolia node -- a cancelled test, not a failure.
call_costs_only_the_access_term_before_spurious_dragon_test() ->
    eth_test_util:with_local_reads(fun() ->
        State = call_state(1000, <<16#00>>),
        Args = call_args(16#0D, 0),
        Code = <<Args/binary, 16#F1, 16#50, 16#00>>,
        Pushes = spent(<<Args/binary, 16#00>>, State, frontier),
        [?assertEqual({F, 700 + 2}, {F, spent(Code, State, F) - Pushes})
         || F <- [frontier, homestead]],
        %% Spurious Dragon adds the two terms, and a call with value to a new
        %% account carries all three. The account is absent from the overlay,
        %% which is what `new_account' asks about.
        Absent = eth_state:new(0, #{{balance, ?CALLER} => 1000}),
        WithValue = <<(call_args(16#0E, 40))/binary, 16#F1, 16#50, 16#00>>,
        Pushes2 = spent(<<(call_args(16#0E, 40))/binary, 16#00>>, Absent, byzantium),
        %% **Less the 2,300 stipend**, for the reason on
        %% `call_optional_terms_follow_the_specification_test'. Byzantium is after
        %% Tangerine Whistle, so the stipend is 2,300 here; this test asserted
        %% 34,702 and the node charged it. The 25,000 and the 9,000 are Spurious
        %% Dragon's and EIP-161's and are unchanged.
        ?assertEqual(700 + 9000 + 25000 + 2 - 2300,
                     spent(WithValue, Absent, byzantium) - Pushes2)
    end).

%% ADDRESS costs 2, where it cost 3.
%%
%% `eth_evm:base_cost/1' had no clause for 0x30, so it fell to the
%% `base_cost(_) -> 3' catch-all -- the same trap that once mispriced three of the
%% four CALL opcodes, and the reason the catch-all was called "a trap that has now
%% fired twice". One gas, on every ADDRESS in every block, and `gasUsed' is a
%% receipt field. Deleting the interpreter's copy fixed it, because the fork table
%% has 2; this test is here so a catch-all cannot come back.
address_costs_two_not_three_test() ->
    ?assertEqual(?GAS - 2, ?GAS - spent(<<16#30, 16#00>>, ?STATE, cancun)),
    ?assertEqual(2, eth_fork_schedule:constant_cost(16#30, cancun)).

spent(Code, State, Fork) ->
    {ok, _, Left, _, _} = eth_evm:run(Code, ?MSG0, State, #{fork => Fork}, ?GAS),
    ?GAS - Left.

%% LOG's total, which nothing observed.
%%
%% The 375 * (topics + 1) is charged by the machine loop as the fork table's
%% constant for LOG_n, and do_log/3 charges only the per-byte term. That split is
%% the same total the handler used to produce alone -- `375 * N + 8 * Len' there
%% on top of a flat 375 in the loop -- which is exactly why nothing failed when the
%% handler changed: the two decompositions agree.
%%
%% So the total is pinned here directly, at three different topic counts, because a
%% test at one count cannot tell 375 * (n + 1) from 375 + 375 * n, and the error
%% this guards is 375 per topic. That is a receipts-root difference on every event
%% a contract emits.
log_costs_375_per_topic_plus_one_test() ->
    %% PUSH1 0 is 3 gas; STOP is free. With no data there is no memory expansion
    %% and no per-byte term, so the whole cost is the constant.
    %% do_log/3 pops offset, then length, then the topics -- so the topics go
    %% deepest and the length on top. Getting that order wrong still costs the
    %% same, because the price does not read the stack, which is why this half
    %% would pass either way; the per-byte half below is the one that notices.
    At = fun(N) ->
        Code = list_to_binary([<<16#60, 0>> || _ <- lists:seq(1, N)]
                              ++ [<<16#60, 0>>, <<16#60, 0>>,
                                  <<(16#A0 + N)>>, <<16#00>>]),
        spent(Code, ?STATE, cancun) - 3 * (2 + N)
    end,
    ?assertEqual({0, 375}, {0, At(0)}),
    ?assertEqual({1, 750}, {1, At(1)}),
    ?assertEqual({2, 1125}, {2, At(2)}),
    ?assertEqual({3, 1500}, {3, At(3)}),
    ?assertEqual({4, 1875}, {4, At(4)}).

%% The per-byte term, and the memory expansion it rides on. 32 bytes of data at
%% offset 0 is one word, so LOG1 costs 750 + 256 + 3.
log_charges_eight_a_byte_plus_memory_test() ->
    %% topic, then length, then offset -- the reverse of the order do_log/3 pops
    %% them in, which is Off, then Len, then the topics. The offset is on top, so
    %% it is pushed last; pushing it first silently makes the *offset* 32 and the
    %% length 0, and the frame then costs 3 gas of memory and no data term.
    At = fun(Len, Fork) ->
        Code = <<16#60, 0, 16#60, Len, 16#60, 0, 16#A1, 16#00>>,
        spent(Code, ?STATE, Fork) - 3 * 3
    end,
    %% 32 bytes at offset 0 is one word: 750 + 256 + 3.
    ?assertEqual(750 + 8 * 32 + 3, At(32, cancun)),
    %% 64 bytes is two words: 6 gas of memory, not 3.
    ?assertEqual(750 + 8 * 64 + 6, At(64, cancun)),
    %% 33 bytes is still two words, because memory is charged per word.
    ?assertEqual(750 + 8 * 33 + 6, At(33, cancun)),
    %% And the term is fork-invariant: it is EIP-150's log data price and was never
    %% changed, so a pre-Berlin frame pays the same 8 a byte.
    ?assertEqual(750 + 8 * 32 + 3, At(32, istanbul)).

%% ---------------------------------------------------------------------------
%% SSTORE net metering (EIP-2200), measured through execution
%% ---------------------------------------------------------------------------
%%
%% The table tests in eth_fork_schedule pin the arithmetic. These pin the two
%% things only execution can show: that the interpreter hands the table the value
%% the slot held when the *transaction* began rather than the value it holds now,
%% and that it keeps doing so across a CALL boundary.

%% The account the top-level frame writes to: ?MSG0's own address.
-define(ACCT, <<0:160>>).

%% ?MSG0's own address, which is where a top-level frame's SSTORE lands. Spelled
%% out rather than reused from the Msg map, because a storage read that had to be
%% dug out of a map would read as the test being about the map.
-define(MSG0_ADDRESS, <<0:160>>).

%% `PUSH1 Val, PUSH1 Slot, SSTORE'. Slot is on top, so it is pushed last --
%% SSTORE pops key first, then value.
sstore_op(Val, Slot) -> <<16#60,Val, 16#60,Slot, 16#55>>.

%% The same program with that one SSTORE turned into a JUMPDEST. Only the final
%% byte differs, so the pushes are common to both and cancel in the
%% difference. Building this by hand instead -- writing `<<16#5B>>' where the
%% whole `sstore_op' was -- silently differences the two pushes away too, which
%% showed up here as every price coming out exactly 6 too high.
sstore_blunt(Val, Slot) -> <<16#60,Val, 16#60,Slot, 16#5B>>.

%% JUMPDEST's cost, named once. It is not free -- a blunt program pays it, so the
%% difference comes out one gas under the real price -- and it cannot be read out
%% of `eth_fork_schedule:constant_cost/2', which answers 0 for JUMPDEST as well
%% as for PUSH1. Written down here, in one place, so that a single change to it
%% is a single edit.
-define(JDEST, 1).

%% The net price of a single SSTORE: what `Sharp' spends that `Blunt' does not.
%%
%% Two things are corrected for. The refund: what is measured is cost *net of
%% refund*, which is the figure the frame pays and the one a state root depends
%% on. And JUMPDEST, above.
%%   * the refund. What is measured is cost *net of refund*, which is the figure
%%     the frame pays and the one a state root depends on.
%%
%% No absolute figure is asserted anywhere below: the push price is a per-byte
%% tier that `constant_cost/2' does not carry, so an absolute number would be
%% asserting PUSH1's price as a side effect and would fail for a reason that has
%% nothing to do with SSTORE.
net_price(Sharp, Blunt, State, Fork) ->
    spent(Sharp, State, Fork) - spent(Blunt, State, Fork) + ?JDEST.

%% The price of something a *callee* did: the parent program is byte-identical
%% in both runs, so it cancels and what is left is the callee's own opcode. The
%% two runs differ only in the callee's code, so the JUMPDEST correction is the
%% same one.
callee_net(Parent, With, Without, Fork) ->
    spent(Parent, With, Fork) - spent(Parent, Without, Fork) + ?JDEST.

%% The price of the last SSTORE in a program made of consecutive `sstore_op's.
sstore_net(Code, State, Fork) ->
    Blunt = binary:part(Code, 0, byte_size(Code) - 1),
    net_price(Code, <<Blunt/binary, 16#5B>>, State, Fork).

%% (1.) A no-op write. The interpreter used to charge 2900 with a 100 refund
%% here, netting 2800, where EIP-2200 clause (1) charges SLOAD_GAS and nothing
%% else -- 100 from EIP-2929. That is 2700 gas net overcharged on every no-op
%% write at every fork, including Cancun, and the module comment said so rather
%% than anyone fixing it.
sstore_writing_a_value_it_already_holds_costs_a_warm_read_test() ->
    Code = <<(sstore_op(1, 1))/binary, (sstore_op(1, 1))/binary>>,
    St = eth_state:set_storage(?STATE, ?ACCT, 1, 0),
    ?assertEqual(100, sstore_net(Code, St, cancun)).

%% (2.2.) The test that the `originals' map exists for. The slot is written twice
%% in one transaction, so the second write sees current = 1 while the
%% transaction started at 0. If the interpreter re-read the slot to recover the
%% original it would see 1, conclude the slot was clean, and charge 2900 --
%% pricing two different writes identically, which is the entire defect EIP-2200
%% was written to close.
sstore_a_second_write_to_a_dirty_slot_is_not_priced_as_a_clean_one_test() ->
    Code = <<(sstore_op(1, 1))/binary, (sstore_op(2, 1))/binary>>,
    St = eth_state:set_storage(?STATE, ?ACCT, 1, 0),
    ?assertEqual(100, sstore_net(Code, St, cancun)).

%% The original is per slot, not per frame. Slot 1 starts at 0 and slot 2 at 5;
%% after writing slot 1 the frame writes slot 2, which is still an untouched
%% reset. A single original carried across the frame would put slot 2's original
%% at 0, make it look dirty, and price it as a warm read.
sstore_tracks_an_original_for_each_slot_separately_test() ->
    Code = <<(sstore_op(1, 1))/binary, (sstore_op(7, 2))/binary>>,
    St0 = eth_state:set_storage(?STATE, ?ACCT, 1, 0),
    St = eth_state:set_storage(St0, ?ACCT, 2, 5),
    %% 5,000, and the number is worth pausing on. EIP-2929 rewrites EIP-2200's
    %% `SSTORE_RESET_GAS' to `5000 - COLD_SLOAD_COST' = 2,900 *and* charges an
    %% additional `COLD_SLOAD_COST' when the slot is cold, so the chain's cost for a
    %% clean reset of a cold slot is 2,900 + 2,100 = 5,000 -- the figure EIP-2200
    %% itself names. This asserted 2,900, which is the price of the same reset of a
    %% slot the frame had already touched.
    ?assertEqual(5000, sstore_net(Code, St, cancun)).

%% The original is per (address, slot), and this is the only test that can tell
%% the two apart. The caller writes its *own* slot 1, which starts at 0; the
%% callee then writes the *callee's* slot 1, which starts at 5. Keyed on the slot
%% alone, the callee's write would inherit the caller's original of 0, see
%% 0 =/= 5, and price a clean reset as a dirty write at 100 instead of the 2,900 it
%% should be paying before EIP-2929's additional 2,100.
%%
%% The answer is 5,000, the same 5,000 as the sibling test above and for the same
%% reason: the callee's own slot 1 is cold, because warmth is tracked per
%% `(address, storage_key)' pair, and the caller warming *its* slot 1 does not warm the
%% callee's. 2,900 + 2,100.
sstore_tracks_an_original_for_each_account_separately_test() ->
    Callee = <<(sstore_op(7, 1))/binary, 16#00>>,
    Parent = <<(sstore_op(1, 1))/binary, (call_seq(16#0D, 0, 16#F1))/binary, 16#00>>,
    NoStore = <<(sstore_blunt(7, 1))/binary, 16#00>>,   %% the callee's SSTORE, neutered
    With = both_slots(call_state(1000, Callee), 0, 5),
    Without = both_slots(call_state(1000, NoStore), 0, 5),
    ?assertEqual(5000, callee_net(Parent, With, Without, cancun)).

%% Seed slot 1 of *both* accounts a CALL test touches.
%%
%% `call_state/2' seeds balances, nonces and code but not storage, and an
%% unseeded slot does not read as zero: `eth_state:storage/3' falls through to
%% the configured base source, which in the default `upstream' mode is an RPC
%% call. A test that forgets one such slot does not fail, it *hangs* inside
%% httpc, and EUnit reports that as a cancelled test rather than an error -- so
%% the symptom is a suite that mysteriously loses a test. Seeding both, and
%% `with_local_reads' as a floor under the group, makes the miss impossible.
both_slots(St, CallerV, CalleeV) ->
    eth_state:set_storage(eth_state:set_storage(St, ?CALLER, 1, CallerV),
                          ?CALLEE, 1, CalleeV).

%% Across a frame boundary. DELEGATECALL, not CALL: a CALL frame writes its own
%% account's storage and can therefore never touch a slot the parent goes on to
%% write, so a CALL has nothing to carry across and a test built on one asserts
%% nothing. DELEGATECALL runs the child with the *parent's* address, so the
%% child can write the parent's slot and the parent's next write has to know it.
sstore_after_a_delegatecall_writes_the_slot_knows_it_was_dirty_test() ->
    %% The child writes 9 into the parent's slot 1, which started at 0. The parent
    %% then writes 3. Original 0, current 9, new 3: clause (2.2.), a warm read.
    %% If the map did not cross the boundary the parent would recover the original
    %% by re-reading, see 9, and charge 2900 for a reset it has already paid for.
    Callee = <<(sstore_op(9, 1))/binary, 16#00>>,
    St = both_slots(call_state(1000, Callee), 0, 0),
    Sharp = <<(dcall_seq(16#0D, 16#F4))/binary, (sstore_op(3, 1))/binary>>,
    Blunt = <<(dcall_seq(16#0D, 16#F4))/binary, (sstore_blunt(3, 1))/binary>>,
    ?assertEqual(100, net_price(Sharp, Blunt, St, cancun)).

%% A reverted frame leaves the slot as it was, so the parent's next write is a
%% first write: 20000, not 2900.
%%
%% What this pins is the *state restoration*, not the map. Both ways of handling
%% the child's `originals' -- keep them, or drop them for the parent's -- give
%% 20000 here, because a reverted write left the slot at 0 and the parent
%% re-reads 0, which is the original. That was checked by injection rather than
%% argued: removing the child's originals from the revert path leaves every test
%% in both modules green.
%%
%% Recorded plainly because the obvious reading of the test name is that the
%% map's survival is what is under test, and it is not: what would break this is
%% a revert that failed to put the slot back, and a green run says only that the
%% revert is intact.
sstore_after_a_reverted_delegatecall_is_priced_as_a_first_write_test() ->
    Callee = <<(sstore_op(9, 1))/binary, 16#60,0, 16#FD>>,
    St = both_slots(call_state(1000, Callee), 0, 0),
    Sharp = <<(dcall_seq(16#0D, 16#F4))/binary, (sstore_op(3, 1))/binary>>,
    Blunt = <<(dcall_seq(16#0D, 16#F4))/binary, (sstore_blunt(3, 1))/binary>>,
    %% 20,000 plus EIP-2929's additional 2,100. The cold term belongs in *this*
    %% assertion rather than anywhere else in the test because of what the test is
    %% about: the DELEGATECALL warmed this very slot -- it is the same
    %% `(address, storage_key)' pair, DELEGATECALL running the child with the parent's
    %% address -- and the revert discarded the warmth, so the write that follows is
    %% the first touch of a cold slot. An assertion of 20,000 could not tell a
    %% discarded warm marking from a retained one.
    ?assertEqual(22100, net_price(Sharp, Blunt, St, cancun)).

%% EIP-2200 clause (0), at the boundary. Gas at the SSTORE is 2301 in the first
%% run and exactly 2300 in the second, and the comparison is `=<', so the first
%% proceeds and the second fails the frame. The threshold is expressed against
%% the table rather than written down, so a change to PUSH1's price moves it
%% rather than silently moving the boundary being tested.
sstore_at_or_below_the_stipend_fails_the_frame_test() ->
    Code = sstore_op(7, 1),                       %% a no-op write, so 100
    St = eth_state:set_storage(?STATE, ?ACCT, 1, 7),
    %% The *whole* price, cold term included. `sstore_cost/4' is only EIP-2200's half
    %% of it; EIP-2929's half -- "charge an additional `COLD_SLOAD_COST'" for a slot
    %% not in `accessed_storage_keys' -- is a separate term, and this slot is cold, so
    %% leaving it out put the calibration 2,100 gas above the boundary under test and
    %% made the `=<` assertion below about nothing.
    Sstore = element(1, eth_fork_schedule:sstore_cost(cancun, 7, 7, 7))
             + eth_fork_schedule:sstore_cold_cost(cancun, false),
    %% Calibrate on what the program actually spends, because the push price is
    %% a per-byte tier `constant_cost/2' does not carry: it answers 0 for PUSH1
    %% as well as for JUMPDEST, so a threshold computed from the table would sit
    %% 6 gas above the one being tested and the boundary assertion below would
    %% be about nothing. `Full' is the whole program's cost, so an allowance of
    %% (2300 - Sstore + Full) leaves exactly 2300 at the SSTORE.
    Full = spent(Code, St, cancun),
    At = 2300 - Sstore + Full,
    ?assertMatch({error, out_of_gas, _, _},
                 eth_evm:run(Code, ?MSG0, St, ?ENV, At)),
    ?assertMatch({ok, _, _, _, _},
                 eth_evm:run(Code, ?MSG0, St, ?ENV, At + 1)).

%% ---------------------------------------------------------------------------
%% EIP-2929's transaction-start warm set
%% ---------------------------------------------------------------------------
%%
%% "When a transaction execution begins, `accessed_storage_keys' is initialized to
%% empty, and `accessed_addresses' is initialized to include the `tx.sender',
%% `tx.to' (or the address being created if it is a contract creation transaction) --
%% and the set of all precompiles."
%%
%% None of it was seeded, so the transaction's own recipient, its own sender, and every
%% precompile were each charged `COLD_ACCOUNT_ACCESS_COST' on first touch. The corpus
%% named it as a uniform +2,500 on twenty-four fixtures, and 2,500 is
%% `COLD_ACCOUNT_ACCESS_COST - WARM_STORAGE_READ_COST' exactly, at every fork from
%% Berlin and at none before it.
precompiles_are_warm_from_the_first_call_test() ->
    [?assertEqual({F, 2500}, {F, precompile_warmth(F)})
     || F <- [berlin, london, cancun, prague]],
    %% And not below Berlin, where there is no access list at all. EIP-2929 introduces
    %% the set as well as the rule, so charging the rule earlier would be a claim about
    %% a schedule that has no such concept.
    [?assertEqual({F, 0}, {F, precompile_warmth(F)})
     || F <- [byzantium, petersburg, istanbul, muir_glacier]].

%% `BALANCE' of an address nobody has touched, less `BALANCE' of a precompile.
%% pushes are `PUSH20', so the only difference between the two programs is the low byte
%% of the address, and the whole of the difference is the warm/cold term.
%% of the address, and the whole of the difference is the warm/cold term -- and it is the
%% **unseeded** address that is the minuend, because warm is the cheaper of the two. The
%% first version had the subtraction the other way round and the test failed at -2,500,
%% which is the same fact with the sign against me -- worth recording, because a sign
%% error here reads exactly like a node charging the wrong way round.
%% Zero gas is forwarded on purpose. With nothing forwarded the child cannot run, so
%% the precompile's *own* price never enters the figure and what is left is exactly the
%% access price EIP-2929 is about -- which is the term under test, and would otherwise
%% be 2,485 off by the identity precompile's 15.
precompile_warmth(Fork) ->
    balance_cost(?UNTOUCHED, Fork) - balance_cost(?PRECOMPILE, Fork).

%% The transaction's own `tx.to' and `tx.sender' are in the set before a single
%% instruction runs. The same construction as above, with the address read out of the
%% message: a `BALANCE' of the address the frame is *at* is warm, and one of an address
%% nobody mentioned is cold.
the_transaction_recipient_and_sender_are_warm_at_the_first_instruction_test() ->
    [?assertEqual({F, 2500}, {F, msg_warmth(Key, F)})
     || F <- [berlin, cancun], Key <- [address, origin]],
    [?assertEqual({F, 0}, {F, msg_warmth(Key, F)})
     || F <- [istanbul], Key <- [address, origin]].

msg_warmth(Key, Fork) ->
    A = <<0:152, 16#2A:8>>,
    U = ?UNTOUCHED,
    %% The message the frame runs under, with one of its two addresses replaced.
    %% Written as an update on a *variable* rather than on the macro, because
    %% `(?MSG0)#{Key => A}' is an expression that updates a literal and does not
    %% compile -- the macro is not a variable.
    Base = ?MSG0,
    Msg = Base#{Key => A},
    balance_cost_in(U, Msg, Fork) - balance_cost_in(A, Msg, Fork).

balance_cost(Addr, Fork) -> balance_cost_in(Addr, ?MSG0, Fork).

%% ---------------------------------------------------------------------------
%% EIP-3651: the coinbase is warm from the first instruction
%% ---------------------------------------------------------------------------
%%
%% "At the start of transaction execution, `accessed_addresses' shall be initialized to
%% **also** include the address returned by COINBASE (0x41)." Shanghai.
%%
%% The EIP's reason is the same argument as the sender and `to', not a discount, and it
%% is worth quoting because it is why this is not a subsidy: "The COINBASE address
%% should also always be loaded because it receives the block reward and the transaction
%% fees." Without it a direct payment to the miner is charged
%% `COLD_ACCOUNT_ACCESS_COST' on first touch, and a contract that pays the coinbase and
%% branches on the result -- the pattern the EIP exists for -- is priced as though it
%% were reading an account it had never heard of.
%%
%% The corpus named it as **twelve fixtures**, and this is the same construction as the
%% two tests above: `BALANCE' of the coinbase less `BALANCE' of an address nobody
%% mentioned, so the whole difference is the warm/cold term.
the_coinbase_is_warm_at_the_first_instruction_from_shanghai_test() ->
    [?assertEqual({F, 2500}, {F, coinbase_warmth(F)})
     || F <- [shanghai, cancun, prague, osaka]],
    %% **And not at Paris.** EIP-3651 is a Shanghai arrival and the warm set is
    %% EIP-2929's, so a Paris block charging the coinbase cold is not a gap in the
    %% rule -- it is the rule as it stood. Asserted because a fix that forgot the fork
    %% gate would pass the four forks above and be wrong for every block between
    %% Berlin and Shanghai.
    [?assertEqual({F, 0}, {F, coinbase_warmth(F)})
     || F <- [paris, london, berlin, istanbul]].

%% An Env with no `coinbase' key has not said the coinbase is the zero address -- it has
%% said nothing, and warming `<<0:160>>' would put a warm entry in the set that nothing
%% in the frame can name. The fork gate and the presence check are two different
%% conditions and are asserted separately here, because the one above only ever supplies
%% a coinbase.
a_missing_coinbase_warms_nothing_test() ->
    Named = <<0:152, 16#2A:8>>,
    %% Present and Shanghai: warmed.
    %% `maps:is_key/2' and not a `?assertMatch' on `{K, V}': that pattern only matches a
    %% one-element map, and the warm set is a map of a dozen.
    ?assert(maps:is_key({warm_account, Named},
                        eth_evm:initial_access(?MSG0,
                                               #{fork => shanghai, coinbase => Named},
                                               shanghai))),
    %% Absent: **no** entry, and in particular not one keyed on `undefined'.
    Warm = eth_evm:initial_access(?MSG0, #{fork => shanghai}, shanghai),
    ?assertNot(lists:keymember({warm_account, undefined}, 1, maps:to_list(Warm))),
    %% `<<0:160>>` is deliberately *not* asserted absent: it is `?MSG0's `address' and
    %% `origin', so it is in the set for a reason that has nothing to do with the
    %% coinbase. An assertion that it was missing would be testing the wrong thing and
    %% would only pass if `?MSG0' were changed.
    %% Present but pre-Shanghai: not warmed, which is the fork gate and not the
    %% presence check.
    ?assertNot(lists:keymember({warm_account, Named}, 1,
                               maps:to_list(eth_evm:initial_access(
                                              ?MSG0,
                                              #{fork => paris, coinbase => Named},
                                              paris)))).

%% ---------------------------------------------------------------------------
%% EIP-2930: a declared access is warm from the first instruction
%% ---------------------------------------------------------------------------
%%
%% "The address and storage keys would be **immediately loaded** into the
%% `accessed_addresses` and `accessed_storage_keys` global sets." The list was being
%% **priced** -- `eth_tx:intrinsic_gas/2` charged `2400 * n + 1900 * k` correctly -- and
%% never applied, so a sender who declared an access paid for it twice: once in the
%% intrinsic and again as a cold access on every use. The corpus figure was `+4,000`,
%% which is exactly `(COLD_SLOAD_COST - WARM_STORAGE_READ_COST) * 2` = `2,000 * 2`, and
%% the absence of any intrinsic term is what said the price was right and the
%% application was not.
%%
%% Same construction as the two tests above: the same address both times, the slot
%% declared in one access list and absent from the other, cold as the **minuend**.
%% **The list is on the Msg, not the Env.** It came off the transaction, and the frame
%% reads it from the same place it reads `to', `value' and `data' -- which is the whole
%% argument for putting it there rather than in the block environment. The first version
%% of this test put it in the Env and measured 0, for a reason that looked exactly like
%% "the seeding does not work".
%% **An `SLOAD`, not a `BALANCE`, and on the Msg rather than the Env.** Both were got
%% wrong in turn, and each time the measurement came out 0 and read as "the seeding does
%% not work":
%%
%%   * `BALANCE` of the declared address is an **account** access, priced by
%%     `warm_account/2`. The list warms an account only if the frame is not already at
%%     it, and the address being measured was a bystander, so both readings were cold.
%%   * The list is on the **Msg**, not the Env: it came off the *transaction*, and the
%%     frame reads it from the same place it reads `to`, `value` and `data`.
%%
%% What the list warms is the `(address, key)` **pair**, so the measurement has to touch
%% the key. The frame's own account is `?MSG0`'s `address`, which `warm_set_state()`
%% seeds, so the account is readable and the *slot* is the only thing that can differ.
declared_slot_warmth(Slots, Fork) -> declared_slot_warmth(Slots, 0, Fork).

%% The slot the `SLOAD` reads is a parameter, so "the declared slot is warm" and "an
%% undeclared slot is cold" are statements about the *same* program.
declared_slot_warmth(Slots, Read, Fork) ->
    Self = maps:get(address, ?MSG0),
    Env = #{fork => Fork},
    Cold = sload_cost(?MSG0, Env, Read),
    Base0 = ?MSG0,
    Warm = sload_cost(Base0#{access_list => [{Self, Slots}]}, Env, Read),
    Cold - Warm.

%% `PUSH<n> <slot>; SLOAD; POP; STOP`, with `n` chosen so any slot up to 32 bytes can
%% be named. The push width has to be right or the SLOAD reads a **different slot** than
%% the one declared, and the measurement returns 0 -- which is the same "the seeding does
%% not work" reading, from a third direction. Only `1` and `4` are used here.
sload_cost(Msg, Env, Slot) when Slot =< 255 ->
    Code = <<16#60, Slot, 16#54, 16#50, 16#00>>,
    run_sload(Code, Msg, Env);
sload_cost(Msg, Env, Slot) when Slot =< 16#FFFFFFFF ->
    Code = <<16#63, Slot:32, 16#54, 16#50, 16#00>>,
    run_sload(Code, Msg, Env).

%% The only thing that can move the price is whether the `(address, slot)` pair is in
%% `accessed_storage_keys`.
run_sload(Code, Msg, Env) ->
    {ok, _, Left, _, _} = eth_evm:run(Code, Msg, warm_set_state(), Env, ?GAS),
    ?GAS - Left.

%% The slot must be a 32-byte binary, because that is the shape
%% `eth_tx:access_list_field/1' hands the frame, and it must be turned into the
%% interpreter's **word** before the key is built -- `SLOAD` and `SSTORE` both `pop` the
%% slot off the stack. Getting that wrong produces a warm set that is present,
%% correct-looking and completely inert.
%% **2,000 and not 2,500**, and the difference is the point of the test. The three warm
%% -set tests above measure **account** accesses, whose cold term is
%% `COLD_ACCOUNT_ACCESS_COST` (2,600) against `WARM_ACCESS` (100) -- a difference of
%% 2,500. This one measures a **storage** access, whose cold term is `COLD_SLOAD_COST`
%% (2,100) against `WARM_STORAGE_READ_COST` (100) -- **2,000**. EIP-2930 warms both sets,
%% and they are priced from two different constants, so a test that copies the number
%% from its neighbour asserts the wrong one. The corpus figure is the same 2,000 twice
%% over: `+4,000` on six fixtures.
%% **Under `with_local_reads/1'`, and that is a repair rather than a style choice.**
%% `warm_set_state/0' seeds balances and nonces and **no storage**, so the `SLOAD' this
%% measures falls through `eth_state' to `base_source' -- which in the default
%% `upstream' mode is an RPC call, and a unit test that reaches the network is a test
%% that hangs when the node is offline. This one shipped in `v1.46' without the wrapper
%% and passed only because an earlier test happened to leave the process-wide base
%% source somewhere local. An unrelated change to the call gas accounting moved the
%% ordering and it hung, at a distance of several commits from its cause, which is the
%% worst way to find out. Eighteen tests in this module already wrap for the same
%% reason; this one should have.
a_declared_storage_key_is_warm_at_the_first_instruction_test() ->
    eth_test_util:with_local_reads(fun() ->
            [?assertEqual({F, 2000}, {F, declared_slot_warmth([<<0:256>>], F)})
             || F <- [shanghai, cancun, prague]],
            %% **The control, and it is the half that matters**: a list that declares a
            %% *different* slot leaves this one cold. Without it, "the declared slot is warm"
            %% could be satisfied by the slot being warm for any reason at all -- and the two
            %% attempts that measured `BALANCE` instead of `SLOAD` passed exactly that way.
            [?assertEqual({F, 0}, {F, declared_slot_warmth([<<16#1234:256>>], F)})
             || F <- [shanghai, cancun]],
            %% And symmetrically: declaring slot 0 leaves a *different* slot cold. One direction
            %% of the control would pass with a seeding that warmed every slot.
            [?assertEqual({F, 0}, {F, declared_slot_warmth([<<0:256>>], 16#1234, F)})
             || F <- [shanghai, cancun]],
            %% And an empty list changes nothing, so the whole of the effect is attributable to
            %% the declaration rather than to carrying an access list at all.
            [?assertEqual({F, 0}, {F, declared_slot_warmth([], F)})
             || F <- [shanghai, cancun]],
            %% A slot past a byte, so the conversion from the list's 32 bytes to the
            %% interpreter's word is exercised on a value that is not zero.
            [?assertEqual({F, 2000},
                          {F, declared_slot_warmth([<<16#deadbeef:256>>], 16#deadbeef, F)})
             || F <- [shanghai]]
    end).

%% The coinbase comes from the **Env**, not the message, so this needs its own
%% construction rather than the `msg_warmth/2` above. The same shape otherwise:
%% `PUSH20 <addr>; BALANCE; STOP`, with the coinbase named in the Env and an address
%% nobody named as the control.
%% **The same address both times**, with the coinbase named in one Env and absent from
%% the other. The first version named the coinbase and compared against a *different*
%% address -- `?CALLER` -- which is warmed as the frame's own `address', so both sides
%% cost 100 and the difference was 0. The comparison has to isolate the coinbase and
%% nothing else, and the cold reading is the **minuend** for the same reason as
%% `precompile_warmth/1`: cold is the more expensive of the two, so the difference comes
%% out positive.
coinbase_warmth(Fork) ->
    A = ?UNTOUCHED,
    Cold = balance_cost_in_env(A, #{fork => Fork}),
    Warm = balance_cost_in_env(A, #{fork => Fork, coinbase => A}),
    Cold - Warm.

%% The fork is already in the Env, so it is not a second argument.
balance_cost_in_env(Addr, Env) ->
    Code = <<16#73, Addr/binary, 16#31, 16#00>>,
    {ok, _, Left, _, _} = eth_evm:run(Code, ?MSG0, warm_set_state(), Env, ?GAS),
    ?GAS - Left.

%% `?STATE' holds one account, `<<0:160>>', and reading the balance or the code of an
%% address it does not hold falls through `eth_state' to the configured base source --
%% which in the default `upstream' mode is an RPC call, and in a unit test is a *hang*
%% that eunit reports as a cancelled test rather than a failure. Both addresses these
%% tests name are therefore seeded here. This is the trap the note on `both_slots/3'
%% describes, met from the other direction: seeding a slot does not help if the
%% *account* is absent.
warm_set_state() ->
    lists:foldl(fun(A, Acc) ->
                    eth_state:set_balance(eth_state:set_nonce(Acc, A, 0), A, 0)
                end, ?STATE, [?PRECOMPILE, ?UNTOUCHED, <<0:152, 16#2A:8>>, ?CALLER]).

%% `PUSH20 <addr>; BALANCE; STOP`.
balance_cost_in(Addr, Msg, Fork) ->
    Code = <<16#73, Addr/binary, 16#31, 16#00>>,
    {ok, _, Left, _, _} = eth_evm:run(Code, Msg, warm_set_state(),
                                      #{fork => Fork}, ?GAS),
    ?GAS - Left.

%% ---------------------------------------------------------------------------
%% EIP-2929's additional cold-slot term on SSTORE
%% ---------------------------------------------------------------------------
%%
%% "When calling `SSTORE', check if the `(address, storage_key)' pair is in
%% `accessed_storage_keys'. If it is not, charge an **additional** `COLD_SLOAD_COST`
%% gas, and add the pair to `accessed_storage_keys'."
%%
%% `sstore_cost/4' carries EIP-2929's *parameter rewrites* -- `SLOAD_GAS` -> 100 and
%% `SSTORE_RESET_GAS' -> 2,900 -- and the "additional" was missing, so every first
%% touch of a slot cost 2,100 too little and every second touch was right. The
%% asymmetry is why it survived: a test that writes a slot twice cannot see it, and
%% the corpus gave it up only as a -2,100 delta, 40 fixtures all at the same number.
a_first_write_to_a_slot_pays_eip_2929s_additional_cold_cost_test() ->
    %% A **no-op** write -- the slot already holds 7 and 7 is written -- and that is
    %% the whole trick. EIP-2200 arms the two writes identically (`SLOAD_GAS' either
    %% way), so the first-minus-second difference is EIP-2929's term and nothing else.
    %% A write of a *different* value would measure arm (2.1.1) against arm (1.) --
    %% 20,000 against 100 -- and the cold term would be a rounding error in a 22,000
    %% figure, which is how a missing 2,100 hides inside an assertion that looks
    %% specific.
    One = sstore_op(7, 1),
    St = eth_state:set_storage(?STATE, ?ACCT, 1, 7),
    [?assertEqual({F, 2100}, {F, cold_sstore_penalty(One, St, F)})
     || F <- [berlin, london, cancun, prague]],
    %% And not below Berlin, where there is no access list and no such term. EIP-2929
    %% is the fork that introduces both halves, so a version of this that also charged
    %% it at Istanbul would be right for one span of four and wrong for three.
    [?assertEqual({F, 0}, {F, cold_sstore_penalty(One, St, F)})
     || F <- [byzantium, petersburg, istanbul, muir_glacier]].

%% `2 * once - twice`, which is the "additional" and nothing else.
%%
%% `Code` here is **one** write to a cold slot. `Twice` is the same program with a second
%% identical write, and the first write is byte-for-byte the same in both, so
%% `twice - once` is the *second* write's price -- with the slot already warm, because
%% the first write put the pair in `accessed_storage_keys'. Subtracting that from
%% `once` leaves exactly EIP-2929's additional term, with the opcode, the push prices
%% and EIP-2200's arm all cancelling. Written as the arithmetic it is rather than by
%% neutralising one program against another, because the neutralised version needs a
%% hand-matched control and a control that drifts is a test that quietly stops
%% testing.
cold_sstore_penalty(Code, State, Fork) ->
    Once = <<Code/binary, 16#00>>,
    Twice = <<Code/binary, Code/binary, 16#00>>,
    2 * spent(Once, State, Fork) - spent(Twice, State, Fork).

%% The pre-Berlin SSTORE is **priced**, not refused, and this test used to assert the
%% opposite -- that every pre-Berlin fork is refused -- which is how 48 of the 266
%% committed fixtures came to be executed into wrong state roots. The rule is the flat
%% one, the figures are EIP-2200's own ("SSTORE_SET_GAS: 20000, not changed",
%% "SSTORE_RESET_GAS: 5000, not changed"), and `SLOAD_GAS` is itself fork-selected.
%%
%% **Constantinople is the one fork still refused**: EIP-1283 replaced the flat rule
%% with net metering and Petersburg reverted it, so the flat rule is right for the
%% eight other pre-Berlin forks and wrong for exactly that one.
the_pre_berlin_sstore_is_the_flat_rule_and_only_constantinople_is_refused_test() ->
    Code = sstore_op(1, 1),
    St = eth_state:set_storage(?STATE, ?ACCT, 1, 0),
    %% A store into an empty slot, at the pre-Berlin forks: SSTORE_SET_GAS, 20,000.
    [?assertMatch({ok, _, _, _, _},
                  eth_evm:run(Code, ?MSG0, St, #{fork => F}, ?GAS))
     || F <- [frontier, homestead, tangerine, spurious_dragon, byzantium,
              petersburg, istanbul]],
    [?assert(eth_fork_schedule:sstore_supported(F))
     || F <- [frontier, homestead, tangerine, spurious_dragon, byzantium,
              petersburg, istanbul, muir_glacier, berlin, london, cancun, prague]],
    ?assertNot(eth_fork_schedule:sstore_supported(constantinople)),
    [?assertMatch({error, {unsupported, {sstore, constantinople}}, _, _},
                  eth_evm:run(Code, ?MSG0, St, #{fork => constantinople}, ?GAS)),
     ?assertMatch({ok, _, _, _, _},
                  eth_evm:run(Code, ?MSG0, St, #{fork => berlin}, ?GAS))].

%% ---------------------------------------------------------------------------
%% Calling a precompile
%% ---------------------------------------------------------------------------
%%
%% A CALL's `gas' argument is an *allowance*: the callee may spend up to that much
%% and the rest comes back. For a precompile -- which is not a frame, has no code to
%% run and returns immediately -- the whole cost is paid out of that allowance, and
%% whatever is left of it returns to the caller. So a caller pays exactly the
%% precompile's cost, and forwarding a specific amount is a way of *capping* that
%% cost, not of adding to it.
%%
%% It was wrong in both directions at once, and the two errors had opposite signs,
%% so neither showed up as a consistent overcharge:
%%
%%   * the cost was charged against the *caller's* remaining gas rather than
%%     against the forwarded allowance, and the unused allowance was never returned
%%     at all. `finish_call/8' took the child's leftover gas as an argument and
%%     discarded it (`_Left'); the regular CALL path does its own refund in
%%     `handle_child/9' and passed nothing, so the one argument every regular call
%%     ignored was the only thing the precompile path was relying on;
%%   * so a CALL forwarding *exactly* the precompile's cost failed whenever the
%%     caller's own remainder had dipped below it -- `charge/2' ran out and the
%%     call answered false -- and a CALL forwarding *more* was charged the whole
%%     forwarded amount on top of the cost.
%%
%% ECADD at 150 gas and a contract forwarding exactly 150 is the case that shows it:
%% six `eip196_ec_add_mul' fixtures, at every fork from Berlin to Prague, stored 0
%% where the specification says 1.

%% PUSH1 0 x5 (retLen, retOff, argLen, argOff, value), PUSH1 6 (ECADD),
%% PUSH1 Gas (the allowance), CALL, PUSH1 0, SSTORE -- so the contract stores the
%% call's success flag at slot 0.
%%
%% `Gas' is a `PUSH1' operand and so is truncated to a byte: 256 arrives as 0.
%% Every value used below is under 256, and the helper says so rather than
%% leaving it to be discovered.
precompile_call_sstoring_flag(Gas) when Gas >= 0, Gas =< 255 ->
    <<16#60,0, 16#60,0, 16#60,0, 16#60,0, 16#60,0, 16#60,6, 16#60,Gas, 16#F1,
      16#60,0, 16#55>>.

%% The same call, with the success flag popped instead of stored.
precompile_call_discarding_flag(Gas) when Gas >= 0, Gas =< 255 ->
    <<16#60,0, 16#60,0, 16#60,0, 16#60,0, 16#60,0, 16#60,6, 16#60,Gas, 16#F1,
      16#50, 16#00>>.

%% PUSH1 0 x5, PUSH1 6, PUSH1 Gas, CALL, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0,
%% RETURN -- the same call, but the success flag comes back in the return data
%% instead of going to storage. Storing it would cost 20,000 gas, which is the
%% opposite of what this program is for: it has to be able to run in a frame too
%% tight to afford an SSTORE, because a tight frame is the case under test.
precompile_call_returning_flag(Gas) when Gas >= 0, Gas =< 255 ->
    <<16#60,0, 16#60,0, 16#60,0, 16#60,0, 16#60,0, 16#60,6, 16#60,Gas, 16#F1,
      16#60,0, 16#52, 16#60,32, 16#60,0, 16#F3>>.

%% The gas at which the call is *tight*: enough for the seven pushes and the cold
%% access to the precompile's address, plus a little over the forwarded allowance,
%% so the caller's own remainder after forwarding is smaller than the precompile's
%% cost. That is the arrangement the old code got wrong -- it charged the cost out
%% of the remainder, which by construction was too small -- and it is the
%% arrangement every `eip196_ec_add_mul' fixture is in.
-define(TIGHT_GAS, 2790).

returned_flag(Code, Gas) ->
    {ok, Out, _Left, _St, _Logs} = eth_evm:run(Code, ?MSG0, pc_state(), ?ENV, Gas),
    binary:decode_unsigned(binary:part(Out, 31, 1)).

pc_state() -> eth_state:with_base_source(?STATE, empty).

run_pc(Code, Gas) ->
    {ok, _Out, Left, St, _Logs} =
        eth_evm:run(Code, ?MSG0, pc_state(), ?ENV, Gas),
    {Gas - Left, St}.

a_call_forwarding_exactly_the_precompiles_cost_succeeds_test() ->
    %% ECADD costs 150. Forward 150 and the call must succeed -- this is the case
    %% that failed before, because the cost was taken out of the caller's pocket
    %% rather than out of the 150 the caller had just set aside for it.
    {_Spent, St} = run_pc(precompile_call_sstoring_flag(150), 100000),
    ?assertEqual(1, eth_state:storage(St, ?MSG0_ADDRESS, 0)).

a_tight_frame_forwarding_exactly_the_precompiles_cost_still_succeeds_test() ->
    %% The fixture's actual failure, reproduced.
    %%
    %% With 2,790 gas the frame can afford the pushes, the cold access to 0x06 and
    %% the 150 forwarded -- and then has 19 gas left, which is less than the 150 the
    %% ECADD costs. Charging that cost out of the caller's remainder is what made
    %% the call answer false, and the contract stored 0 where the specification says
    %% 1. Against 100,000 gas of headroom the same defect is invisible, which is
    %% why the ample-gas version of this test is the one that did *not* bite when
    %% the accounting was put back.
    ?assertEqual(1, returned_flag(precompile_call_returning_flag(150), ?TIGHT_GAS)),
    %% And one gas less is not enough, in the same frame, so the boundary is the
    %% cost and not the headroom.
    ?assertEqual(0, returned_flag(precompile_call_returning_flag(149), ?TIGHT_GAS)),
    %% Forwarding more than the frame can spare is capped by EIP-150's 63/64 rule
    %% rather than failing, and still succeeds.
    ?assertEqual(1, returned_flag(precompile_call_returning_flag(250), ?TIGHT_GAS)).

a_call_forwarding_less_than_the_precompiles_cost_fails_test() ->
    %% 149 of an allowance that costs 150: the call fails, and the flag is 0.
    {_Spent, St} = run_pc(precompile_call_sstoring_flag(149), 100000),
    ?assertEqual(0, eth_state:storage(St, ?MSG0_ADDRESS, 0)).

a_call_forwarding_more_than_the_precompiles_cost_pays_only_for_the_cost_test() ->
    %% The point of an allowance. Forwarding 500 and forwarding 150 to the same
    %% 150-gas precompile must cost the same, because the caller pays the
    %% precompile's cost and gets the rest of its allowance back.
    %%
    %% Before the fix this differed by 350: the 500-forwarding call was charged its
    %% whole allowance *and* the cost, and the 150 one was charged its allowance
    %% and then failed for want of the caller's own gas. Differencing two runs is
    %% what makes the assertion about the refund rather than about either total.
    {Exact, _} = run_pc(precompile_call_discarding_flag(150), 100000),
    {More, _} = run_pc(precompile_call_discarding_flag(250), 100000),
    ?assertEqual(Exact, More).

a_failed_call_consumes_exactly_the_allowance_it_was_given_test() ->
    %% A call that cannot cover the precompile's cost is not free and is not
    %% charged the cost: the whole forwarded allowance is gone. 149 and 100 differ
    %% by exactly 49, which is what makes this a statement about the allowance
    %% rather than about either total.
    {Hundred, _} = run_pc(precompile_call_discarding_flag(100), 100000),
    {FortyNine, _} = run_pc(precompile_call_discarding_flag(149), 100000),
    ?assertEqual(49, FortyNine - Hundred).

the_allowance_boundary_is_the_precompiles_cost_exactly_test() ->
    %% One gas apart, and the success flag flips between them. 149 cannot cover a
    %% 150-gas precompile and the whole 149 is consumed; 150 can, and 150 is spent.
    %% So the two frames differ by exactly 1 gas and disagree about whether the call
    %% happened.
    %%
    %% Two things were wrong in the first version of this test and both were in the
    %% test. It asserted that forwarding 151 costs one gas *more* than forwarding
    %% 150, which is backwards -- the extra gas is refunded, so they cost the same
    %% -- and it forwarded 5000 through a `PUSH1', which truncated it to 136, so the
    %% call failed and the frame came out *cheaper* than the 150 case. That read as
    %% the node refunding gas it had never been handed. It was caught only because
    %% the number was measured rather than reasoned to.
    %% The two frames are differenced on the *discarding* program, so the only thing
    %% that differs between them is the allowance. Doing it on the storing program
    %% measures two things at once: the one gas of allowance, and 20,000 - 100 of
    %% SSTORE, because the succeeding frame writes 1 over 0 and the failing one
    %% writes 0 over 0. That is 19,901, and it is the right answer to a different
    %% question.
    {OneShort, _} = run_pc(precompile_call_discarding_flag(149), 100000),
    {Exact, _} = run_pc(precompile_call_discarding_flag(150), 100000),
    ?assertEqual(1, Exact - OneShort),
    %% And the flag, on its own, is the boundary stated as an outcome.
    {_, FlagShort} = run_pc(precompile_call_sstoring_flag(149), 100000),
    {_, FlagExact} = run_pc(precompile_call_sstoring_flag(150), 100000),
    ?assertEqual(0, eth_state:storage(FlagShort, ?MSG0_ADDRESS, 0)),
    ?assertEqual(1, eth_state:storage(FlagExact, ?MSG0_ADDRESS, 0)).

%% ---------------------------------------------------------------------------
%% EIP-150: the stipend is in `sub_call' and not in `cost'
%% ---------------------------------------------------------------------------
%%
%% `the_stipend_goes_to_the_child_and_is_refunded_if_unused_test' above pins what
%% happens when the value **is** affordable: the stipend is handed to the child and the
%% child hands it straight back, so the two readings of `MessageCallGas` agree and
%% that test cannot tell them apart. It passed unchanged against both.
%%
%% These two can, because each observes a figure the other reading gets wrong:
%%
%%   * when the **63/64 cap binds**, the child receives `cap + stipend`. Reading it as
%%     `min(request + stipend, cap)` -- which is what this did -- swallows the stipend
%%     into the cap and the child never sees it. This is the *common* case, because
%%     `GAS`-forwarding calls saturate the cap.
%%   * when the value is **unaffordable**, the refund returns `sub_call`, and since the
%%     caller was charged `cost` -- which excludes the stipend -- the caller is handed
%%     2,300 gas it never paid for. So an unaffordable value-bearing call costs exactly
%%     the stipend *less* than an affordable one.
%%
%% The second is what the corpus found: a uniform **+2,300** across the six forks of
%% `eip2929_gas_cost_increases/test_call_insufficient_balance`, which is the stipend to
%% the gas. `+45,247` before that was the forwarded allowance being consumed rather
%% than returned, and the residue after fixing that was this.

%% In the **cap-binding** regime a value-bearing `CALL' the caller cannot cover costs
%% the caller `call_cost' **less the stipend** -- an exact figure, and the clearest
%% statement of the defect there is. The charge is the pre-stipend clamped figure; the
%% refund is `sub_call', which includes the stipend; so the caller is handed 2,300 it
%% never paid for, and a frame can finish with *more* gas than it started with.
%%
%% **This is the regime the corpus found.** `test_call_insufficient_balance' forwards
%% `GAS' from an account holding nothing, so the cap binds and the old
%% `min(request + stipend, cap)' swallowed the stipend into it -- `+2,300' on six
%% forks. The sibling test above measures the *request*-binding regime instead, and the
%% two are genuinely different tests: with a large frame the request rather than the cap
%% decides, the stipend comes back on the success path *and* on the failure path, and it
%% cancels -- so a difference measured there is the callee's own gas and nothing else.
%% My first attempt at this used the large frame and measured **11** at every fork,
%% which is the callee's eleven gas of pure computation and says nothing about the
%% stipend. The tell was that the number came out the same at Tangerine Whistle, which
%% has no EIP-161 9,000 for it to cancel against.
a_failed_value_bearing_call_costs_the_stipend_less_test() ->
    %% Under `with_local_reads/1' for the reason the sibling test gives: the callee's
    %% account is only partly seeded, and an unseeded read goes to the configured base
    %% source, which in a unit test is a hang rather than a zero.
    eth_test_util:with_local_reads(fun() ->
        %% `call_args/2''s six PUSH1 and one PUSH2. Written down because the assertion
        %% below is an absolute figure, and a figure with an unaccounted-for wrapper
        %% around it is not a figure that can be checked.
        Pushes = 21,
        Price = fun(F) ->
            eth_fork_schedule:call_cost(16#F1, F,
                                       #{warm => false, value_transfer => true,
                                         new_account => false})
        end,
        [?assertEqual({F, Pushes + Price(F) - eth_fork_schedule:call_stipend(F)},
                      {F, value_call_cost(F, 200, 40000)})
         || F <- [tangerine, spurious_dragon, byzantium, istanbul, berlin, london,
                  shanghai, cancun, prague, osaka]],
        %% **Before Tangerine Whistle there is no stipend to hand back**, so the figure
        %% is the price and the pushes and nothing else. Without this the test would
        %% also pass against a `call_stipend/1' that ignored its fork.
        %%
        %% **At 1,000,000, not 40,000**, and the reason is a real fork difference rather
        %% than a convenience: there is no 63/64 cap before Tangerine Whistle, so
        %% `call_args/2''s 65,535 request against a 40,000 frame is an out-of-gas **halt**
        %% -- `huge_call_is_clamped_at_tangerine_whistle_and_halts_before_it_test' above
        %% pins exactly that -- and there is no cost left to assert. Tangerine Whistle
        %% introduced the cap, which is what lets the small frame work at all.
        [?assertEqual({F, Pushes + Price(F)}, {F, value_call_cost(F, 200, 1000000)})
         || F <- [frontier, homestead, dao]],
        %% And the frame does not matter, which is worth stating because it is why the
        %% first attempt failed: the cap cancels out of the charge and the refund, and
        %% what is left is the price and the stipend. Measured at a frame that saturates
        %% the cap and one that does not.
        [?assertEqual({F, value_call_cost(F, 200, 40000)},
                      {F, value_call_cost(F, 200, 1000000)})
         || F <- [tangerine, istanbul, berlin, cancun]]
    end).

%% What a value-bearing `CALL' costs the caller. The caller holds 100, so 200 cannot be
%% covered and 0 always can. The callee is a single STOP, and it matters that it consumes
%% **nothing**: this measures the caller's charge, and a callee that burned gas would put
%% its own consumption into any difference taken against another value.
%%
%% Three arguments, not two: the frame is a parameter because the two saturation regimes
%% are the whole point, and pinning one of them silently is how the first version of this
%% test managed to measure nothing at all.
value_call_cost(Fork, Value, Frame) ->
    Code = <<(call_args(16#0D, Value))/binary, 16#F1, 16#00>>,
    {ok, _, Left, _, _} = eth_evm:run(Code, ?MSG0, call_state(100, <<16#00>>),
                                      #{fork => Fork}, Frame),
    Frame - Left.

%% When the cap binds the child still receives the stipend **on top of** it. The
%% child's own `GAS' is the observation, because the caller's cost cannot tell the two
%% readings apart here: with the cap binding, `min(req, cap)' and `min(req + stipend,
%% cap)' are both `cap'.
%%
%% **Two frames, because there are two regimes and the defect only shows in one of
%% them.** `call_args/2' asks for 65,535. At a large frame the *request* binds and the
%% child should receive exactly 65,535 + 2,300. At a small frame the *cap* binds --
%% which is the common case, because `GAS`-forwarding calls saturate it -- and the child
%% should receive `cap + 2,300` rather than `cap`. A version reading the stipulation as
%% `min(req + stipend, cap)' gets the first regime right by accident and the second
%% wrong, so testing only the large frame would pass against it.
child_gas_at_a_saturating_call_is_the_cap_plus_the_stipend_test() ->
    %% `GAS; PUSH1 0; SSTORE; STOP` -- the child records the allowance it was handed at
    %% slot 0, which is the only place the figure is observable. Under
    %% `with_local_reads/1' for the reason the sibling test gives: the slot is written
    %% but not seeded, and an unseeded read falls through `eth_state' to the configured
    %% base source. Without it this test read **9,300** -- a number belonging to another
    %% test in this module, left in the shared store -- and looked like a failure of the
    %% change rather than of the test.
    eth_test_util:with_local_reads(fun() ->
        Stipend = eth_fork_schedule:call_stipend(istanbul),
        Request = 16#FFFF,
        %% **The child charges its own first instruction before `GAS' reads the
        %% counter**, so the figure observed is always the allowance less that. Measured
        %% here from the request-binding frame, where the allowance is known to be
        %% exactly `Request', rather than written down as a magic number -- a fudge
        %% constant in a gas test is a second copy of the implementation.
        Big = 1000000,
        Prologue = Request - child_gas(Big, 0, istanbul),
        %% ==================== regime 1: the *request* binds ====================
        %% The child's allowance is `Request + Stipend'. This is the regime the old
        %% reading also got right, which is why it is not the only one tested.
        ?assertEqual(Stipend, child_gas(Big, 40, istanbul) - child_gas(Big, 0, istanbul)),
        ?assertEqual(Request + Stipend - Prologue, child_gas(Big, 40, istanbul)),
        %% ==================== regime 2: the *cap* binds ====================
        %% The common case: a `GAS'-forwarding call saturates the 63/64 cap. Reading the
        %% stipulation as `min(req + stipend, cap)' gives the child `cap' here and the
        %% stipend is silently swallowed -- and the **caller's** cost is `cap' either
        %% way, so nothing but the child can see it.
        %%
        %% `Avail' is what is left after `call_args/2''s seven pushes (four PUSH1, two
        %% more, one PUSH2 = 21) and the CALL's own price. The target holds code and is
        %% therefore alive, so there is no 25,000.
        Small = 40000,
        Base = eth_fork_schedule:call_cost(16#F1, istanbul,
                                           #{warm => false, value_transfer => true,
                                             new_account => false}),
        Avail = Small - 21 - Base,
        Cap = Avail - Avail div 64,
        %% **Asserted, not assumed.** A test that picks a small number and hopes the cap
        %% binds is a test that quietly stops testing the case it exists for.
        ?assert(Request > Cap),
        ?assert(Avail < Small),
        ?assertEqual(Cap + Stipend - Prologue, child_gas(Small, 40, istanbul)),
        %% And stated as the thing it is: the child's share is **above** the cap, not
        %% equal to it. Under the old reading this last figure was `Cap - Prologue`.
        ?assert(child_gas(Small, 40, istanbul) > Cap),
        %% ==================== the fork gate ====================
        [?assertEqual({F, eth_fork_schedule:call_stipend(F)},
                      {F, child_gas(Big, 40, F) - child_gas(Big, 0, F)})
         || F <- [tangerine, spurious_dragon, byzantium, berlin, london, shanghai,
                  cancun, prague, osaka]],
        %% **Before Tangerine Whistle there is no stipend**, so the two are identical.
        %% Without this the test would also pass against a `call_stipend/1' that ignored
        %% its fork, which is the other thing that could produce a 2,300.
        [?assertEqual({F, 0}, {F, child_gas(Big, 40, F) - child_gas(Big, 0, F)})
         || F <- [frontier, homestead, dao]]
    end).
%% The allowance a value-bearing `CALL` hands its child, observed from inside the child.
child_gas(Frame, Value, Fork) ->
    Reporter = <<16#5A, 16#60, 0, 16#55, 16#00>>,
    Code = <<(call_args(16#0D, Value))/binary, 16#F1, 16#00>>,
    {ok, _, _, St, _} = eth_evm:run(Code, ?MSG0, call_state(1000000, Reporter),
                                    #{fork => Fork}, Frame),
    eth_state:storage(St, ?CALLEE, 0).

%% ---------------------------------------------------------------------------
%% EIP-150: the 63/64 cap and the stipend, as behaviour
%% ---------------------------------------------------------------------------
%% The table test pins the two figures. These pin the two *behaviours*, and they are
%% different questions: a fork table can be right while the interpreter reads it in the
%% wrong order, which is exactly what happened to the stipend.
%%
%% The call below requests 0xFFFF = 65,535 gas and the frame is given a little under
%% 65,600, so all but one 64th of what is left is *less* than the request and the cap
%% binds. At Tangerine Whistle and later the call is clamped and the frame survives; at
%% DAO and earlier there was no cap, so asking for more than the parent had left was an
%% out-of-gas error and the whole frame halts. The difference is the difference between
%% a clamped call and a dead transaction, so it is worth a test at each end.

huge_call_is_clamped_at_tangerine_whistle_and_halts_before_it_test() ->
    Requested = 16#FFFF,
    %% Between all-but-one-64th-of-the-frame and the frame itself, so the request is
    %% more than the cap allows and more than the parent has left. 65,000 works because
    %% 65,000 - 1,015 = 64,985 < 65,535 < 65,000. My first choice was 65,600, which is
    %% *more* than the request, so nothing overran and the two forks agreed for the
    %% wrong reason -- a test that cannot fail on the change it exists to pin.
    Frame = 65000,
    Code = <<(call_args(16#0D, 0))/binary, 16#F1, 16#00>>,
    Run = fun(Fork) ->
        eth_evm:run(Code, ?MSG0, call_state(1000000, <<16#00>>),
                    #{fork => Fork}, Frame)
    end,
    %% Tangerine Whistle and later: the request is clamped to all but one 64th and the
    %% frame continues to its STOP.
    [begin
         {ok, _, Left, _, _} = Run(F),
         ?assert(Left < Frame)
     end || F <- [tangerine, spurious_dragon, byzantium, istanbul, berlin, cancun]],
    %% Before it: no cap, so the request exceeds what the parent had left and the frame
    %% runs out of gas. The whole allowance is consumed, which is what makes the two
    %% answers visibly different rather than a difference of a few hundred gas.
    [?assertMatch({error, out_of_gas, _State, []}, Run(F))
     || F <- [frontier, homestead, dao]],
    %% And the boundary is stated rather than implied: the frame has less than the
    %% request, so the cap and the old rule disagree about it, and `tangerine' is on
    %% the capped side.
    ?assert(Requested > Frame - Frame div 64),
    ?assert(Requested > Frame),
    ?assert(eth_fork_schedule:all_but_one_64th(tangerine)),
    ?assertNot(eth_fork_schedule:all_but_one_64th(dao)).

the_stipend_goes_to_the_child_and_is_refunded_if_unused_test() ->
    %% A value-bearing call to an account with no code: the child runs nothing, so the
    %% stipend comes straight back and the caller pays only the CALL's own price. This
    %% is the shape that caught the first version of this change, which charged the
    %% caller the pre-stipend figure and refunded the post-stipend one and so handed
    %% the caller 2300 gas it had never paid for.
    Code = <<(call_args(16#0D, 40))/binary, 16#F1, 16#00>>,
    {ok, _, Left, _, _} = eth_evm:run(Code, ?MSG0, call_state(1000000, <<16#00>>),
                                      #{fork => istanbul}, ?GAS),
    NoValue = fun() ->
        C0 = <<(call_args(16#0D, 0))/binary, 16#F1, 16#00>>,
        {ok, _, L0, _, _} = eth_evm:run(C0, ?MSG0, call_state(1000000, <<16#00>>),
                                        #{fork => istanbul}, ?GAS),
        ?GAS - L0
    end,
    WithValue = ?GAS - Left,
    %% EIP-161's 9000 for the value transfer, less the 2,300 stipend. **Not** 9,000 and
    %% **not** 11,300: the stipend is handed to the child and the child hands it back,
    %% and it was never part of what the caller was charged in the first place. Before
    %% Tangerine Whistle there is no 9,000 either and no stipend, so the two agree.
    %% **`NoValue() + 9000 - 2300`, not `NoValue() + 9000`.** The caller is charged
    %% `cost', which excludes the stipend, and the callee here runs nothing, so the
    %% whole allowance including the stipend comes back -- netting 9,000 - 2,300. This
    %% test asserted 9,000, which is the node charging the caller for a gift.
    ?assertEqual(NoValue() + 9000 - 2300, WithValue),
    {ok, _, L1, _, _} = eth_evm:run(Code, ?MSG0, call_state(1000000, <<16#00>>),
                                    #{fork => homestead}, ?GAS),
    ?assertEqual(NoValue() + 0, ?GAS - L1).

%% ---------------------------------------------------------------------------
%% EIP-2929's SELFDESTRUCT term
%% ---------------------------------------------------------------------------
%%
%% Quoted from the EIP: "If the ETH recipient of a SELFDESTRUCT is not in
%% accessed_addresses (regardless of whether or not the amount sent is nonzero),
%% charge an additional COLD_ACCOUNT_ACCESS_COST on top of the existing gas
%% costs, and add the ETH recipient to the set."
%%
%% **The two arms run the identical program.** A cold/warm pair that differs in
%% its own bytecode cannot attribute the difference to the warm set: any extra
%% opcode in the warm arm is another gas term, and the arithmetic then has to
%% exclude it. Here the *only* difference is `Msg.address`, and EIP-2929 puts
%% `tx.to` in the warm set at transaction start, so the beneficiary is warm in
%% one arm and cold in the other with the code held fixed.
%%
%% The frame holds no balance, so the transfer moves zero -- which is the EIP's
%% own parenthetical, and the case a fix keyed on `value > 0' would get free.

%% **Not `<<1:160>>`, which was the first thing tried and is the bug this comment
%% exists to prevent.** `<<1:160>>` *is* the precompile 0x01 address, and EIP-2929
%% puts "the set of all precompiles" in `accessed_addresses` at transaction start
%% -- so the beneficiary was warm in **both** arms, the difference came out 0, and
%% the failure read as "the EIP-2929 term is not being charged". It was charged; it
%% was charged correctly to an address the specification had already declared warm.
%% A fixture that is accidentally already-warm does not report a wrong answer, it
%% reports no answer, which is strictly worse: the assertion `{expected, 2600},
%% {value, 0}' is indistinguishable from a missing implementation.
selfdestruct_beneficiary() -> <<255:160>>.

selfdestruct_program() ->
    <<16#73, (selfdestruct_beneficiary())/binary, 16#FF>>.

%% **Hermetic by construction, not by a global.** The handler reads
%% `eth_state:balance(State, Addr)' for the transfer, and the frame here holds a
%% balance so the transfer is real. If that balance is absent from the overlay the
%% read consults `eth_state:base_source/0', which is process-wide and defaults to
%% `upstream' -- and the trace then points four frames below the opcode, at
%% `eth_rpc_client:do_call/4', on a live JSON-RPC call. AGENTS.md §5 forbids that
%% and §10a records the shape. `eth_test_util:with_ctx/1' was tried first and
%% raised `undef' here rather than answering, which is the same failure wearing a
%% different hat.
%%
%% Seeding both possible frame addresses costs one line and removes the dependency
%% entirely: with the balance in the overlay there is nothing left to fall through,
%% so these tests are as order-independent as any other pure arithmetic assertion.
%% The previous global was also a *shared* one, so a test that mutated it could
%% redirect another module's reads for the rest of the run -- which is the same
%% hazard `with_ctx/1' exists to contain, contained here by not needing it.
selfdestruct_gas_with_address(Fork, FrameAddr) ->
    Base = ?MSG0,
    Msg = Base#{address => FrameAddr, caller => <<0:160>>, origin => <<0:160>>,
               value => 0, static => false},
    %% Fund both addresses the frame might run as, so the transfer has something
    %% to move and no read escapes to a base source.
    Funded = lists:foldl(fun(A, St) -> eth_state:set_balance(St, A, 10) end,
                         eth_state:new(0, #{}),
                         [<<0:160>>, selfdestruct_beneficiary()]),
    {ok, _Out, GasLeft, _St, []} =
        eth_evm:run(selfdestruct_program(), Msg, Funded, #{fork => Fork}, ?GAS),
    ?GAS - GasLeft.

a_cold_selfdestruct_beneficiary_costs_two_thousand_six_hundred_more_test_() ->
    {timeout, 30, fun a_cold_selfdestruct_beneficiary_costs_two_thousand_six_hundred_more/0}.

a_cold_selfdestruct_beneficiary_costs_two_thousand_six_hundred_more() ->
    Cold = selfdestruct_gas_with_address(cancun, <<0:160>>),
    Warm = selfdestruct_gas_with_address(cancun, selfdestruct_beneficiary()),
    ?assertEqual(2600, Cold - Warm).

%% Before Berlin there is no cold-account term at all, and this pins the gate: a
%% fix that charged 2600 everywhere would be right on every fork this node has
%% synchronised past and wrong on half the history.
before_berlin_selfdestruct_ignores_whether_the_beneficiary_is_warm_test() ->
    Cold = selfdestruct_gas_with_address(istanbul, <<0:160>>),
    Warm = selfdestruct_gas_with_address(istanbul, selfdestruct_beneficiary()),
    ?assertEqual(0, Cold - Warm).

%% The EIP's own note: "SELFDESTRUCT does not charge a WARM_STORAGE_READ_COST in
%% case the recipient is already warm, which differs from how the other
%% call-variants work." So the warm arm is the bare 5000 and nothing else. A copy
%% of `call_cost/3''s shape would make this 5100, and the difference is only
%% visible against a frame that has already touched the beneficiary.
a_warm_selfdestruct_beneficiary_costs_exactly_five_thousand_test_() ->
    {timeout, 30, fun a_warm_selfdestruct_beneficiary_costs_exactly_five_thousand/0}.

a_warm_selfdestruct_beneficiary_costs_exactly_five_thousand() ->
    %% PUSH20 (3) + SELFDESTRUCT (5000), with the beneficiary already warm
    %% because it is tx.to. Nothing else -- no WARM_STORAGE_READ_COST, and no
    %% new-account term, because the frame sends zero.
    ?assertEqual(5003, selfdestruct_gas_with_address(cancun, selfdestruct_beneficiary())).


%% ---------------------------------------------------------------------------
%% The 1024-item stack limit
%% ---------------------------------------------------------------------------
%% The Yellow Paper bounds a frame's stack at 1024 items. This node did not, and
%% the absence was not a tidiness gap: 10,000,000 `PUSH1` on a 30M gas limit --
%% which the limit permits, at 3 gas each -- ran to completion in **3,281 ms** with
%% a **942 MB** peak RSS, about 89 bytes per stack item. One transaction's calldata
%% bought one transaction's worth of a gigabyte. After the limit: **55 ms** and
%% **99 MB**, with the same program ending in an exceptional halt.

%% `N` copies of PUSH1 0x01, which is 2 bytes and 3 gas each.
stack_program(N) -> binary:copy(<<16#60, 16#01>>, N).

stack_run(N) -> stack_run(N, cancun).

stack_run(N, Fork) ->
    Base = ?MSG0,
    Msg = Base#{address => <<0:160>>, caller => <<0:160>>, origin => <<0:160>>,
               value => 0, static => false},
    St = eth_state:set_balance(eth_state:new(0, #{}), <<0:160>>, 10),
    eth_evm:run(stack_program(N), Msg, St, #{fork => Fork}, ?GAS).

a_frame_may_hold_one_thousand_and_twenty_four_items_test() ->
    %% The boundary is inclusive: 1024 is legal, and the gas is 3 per push, so
    %% this also pins that the limit costs nothing when it is not hit.
    {ok, _, GasLeft, _, _} = stack_run(1024),
    ?assertEqual(1024 * 3, ?GAS - GasLeft).

pushing_one_thousand_and_twenty_five_items_is_an_exceptional_halt_test() ->
    %% One past the limit. An exceptional halt carries **no gas figure**, which is
    %% the shape every other failure in this module uses: the frame's whole
    %% allowance is consumed, so there is no remainder to report.
    ?assertMatch({error, stack_overflow, _, _}, stack_run(1025)).

%% The counter is the point of the implementation, so drift is the defect to fear.
%% Push the stack to the limit, empty it, and refill it. A `depth` that failed to
%% come back down would halt here at 1024 and read as "the limit is stricter than
%% it should be".
emptying_the_stack_lets_it_be_refilled_to_the_limit_test() ->
    Base = ?MSG0,
    Msg = Base#{address => <<0:160>>, caller => <<0:160>>, origin => <<0:160>>,
               value => 0, static => false},
    St = eth_state:set_balance(eth_state:new(0, #{}), <<0:160>>, 10),
    %% 1024 pushes, 1024 POPs, then 1024 more pushes.
    Program = <<(stack_program(1024))/binary,
                (binary:copy(<<16#50>>, 1024))/binary,
                (stack_program(1024))/binary>>,
    ?assertMatch({ok, _, _, _, _}, eth_evm:run(Program, Msg, St,
                                              #{fork => cancun}, 1000000)).

%% **A crash here would be far worse than a wrong gas figure.** `eth_block:
%% execute_transactions/6' answers any `{error, _}' from `run_transaction/5' by
%% refusing the whole block, so an overflow raised as an `evm_crash' would let one
%% transaction invalidate a block whose every other transaction is valid. The
%% distinct `{error, stack_overflow}' term is what keeps this a failed transaction
%% rather than a rejected block.
stack_overflow_is_a_halt_and_not_a_crash_test() ->
    ?assertMatch({error, stack_overflow, _, _}, stack_run(1025)),
    ?assertNotMatch({error, {evm_crash, _, _, _}, _, _}, stack_run(1025)).


%% ---------------------------------------------------------------------------
%% EXP: the operand order, and EIP-160's price
%% ---------------------------------------------------------------------------
%% Four defects, found together and fixed together, and the reason they were
%% found together is the one worth recording.
%%
%% `evm t8n` was installed (geth 1.17.7, from the Homebrew `ethereum` bottle, which
%% ships `evm` as well as `geth`) and used as an independent oracle. `evm run`
%% answers four input pairs:
%%
%%     PUSH1 2,  PUSH1 3,  EXP  -> 9        3 ** 2
%%     PUSH1 3,  PUSH1 2,  EXP  -> 8        2 ** 3
%%     PUSH1 10, PUSH1 3,  EXP  -> 59049    3 ** 10
%%     PUSH1 3,  PUSH1 10, EXP  -> 1000     10 ** 3
%%     PUSH1 7,  PUSH1 4,  EXP  -> 16384    4 ** 7
%%     PUSH1 4,  PUSH1 7,  EXP  -> 2401     7 ** 4
%%
%% **In every row the result is the second push raised to the first.** `push/1`
%% conses, so the second push is what EXP pops, and EXP's first pop is the base --
%% which means a program computing `Base ** Exponent' pushes the exponent *first*.
%% That is the opposite of what the handler's own variable names invite a reader to
%% assume, which is why the numbers are written out rather than described, and why
%% the same table appears again next to the program builders below.
%%
%% The defects, in the order the fix takes them:
%%
%%   1. `max(byte_size(base), byte_size(exponent))` -- the base's width was priced.
%%      EIP-160 measures the exponent and says nothing about the base.
%%   2. the coefficient was 50 at every fork; before Spurious Dragon it is 10.
%%   3. the handler's literal `10 +' double-charged the flat cost, which the
%%      interpreter loop already takes from `constant_cost/2' ->
%%      `base_gas_cost(16#0A, _, _) -> 10'. So every EXP cost 10 too much.
%%   4. the comment attributed the rule to **EIP-2565**, which is MODEXP's
%%      repricing -- a different opcode (0xf0) whose cost really does involve both
%%      a base and an exponent. A plausible shape borrowed from the wrong EIP is
%%      what let (1) read as deliberate.
%%
%% **The operand order was correct and it was broken here.** Recorded because it is
%% the sharpest instance of a mistake this repository has made: the Yellow Paper was
%% read from memory as `mu_s[0]` being the exponent, the two pops were swapped, and
%% the swap was "confirmed" with a probe -- run against the tree just edited, so it
%% measured the edit rather than the interpreter. The general form is one this file
%% already states in a different place: **a measurement taken against a tree you
%% have just changed is a measurement of your change**, and the oracle was available
%% the whole time and answered in one command. What caught it was re-asking the
%% oracle the question the oracle had been answering all along.

exp_raises_the_base_to_the_exponent_test_() ->
    {timeout, 30, fun exp_raises_the_base_to_the_exponent/0}.

exp_raises_the_base_to_the_exponent() ->
    %% {Base, Exponent, Base ** Exponent, Exponent ** Base}. The fourth column is
    %% what the *reversed* operand order would answer, and it is written out rather
    %% than recomputed: a pair where the two agree would pass under either order and
    %% be a test that cannot see the rule, so the columns being different is the
    %% property, and asserting `?assertNotEqual(Want, Swapped)` says so in the
    %% failure message rather than leaving it as a fact about the fixture.
    Cases = [{2, 3, 8, 9}, {3, 2, 9, 8}, {2, 10, 1024, 100},
             {10, 3, 1000, 59049}, {7, 4, 2401, 16384}, {3, 10, 59049, 1000}],
    [begin
         ?assertNotEqual(Want, Swapped),
         ?assertEqual(Want, exp_result(Base, Exponent, cancun)),
         ?assertEqual(Swapped, exp_result(Exponent, Base, cancun))
     end || {Base, Exponent, Want, Swapped} <- Cases],
    ok.

%% A base's width is not priced. The old rule measured `max(base, exponent)`, so
%% these two programs differed by 1,550 gas and now cost exactly the same: 3 + 3
%% (two PUSH1) + 10 (EXP's flat cost) + 50 * 1 (one byte of exponent).
exp_prices_the_exponents_width_and_not_the_bases_test_() ->
    {timeout, 30, fun exp_prices_the_exponents_width_and_not_the_bases/0}.

exp_prices_the_exponents_width_and_not_the_bases() ->
    Big = 16#7F00000000000000000000000000000000000000000000000000000000000000,
    ?assertEqual(66, exp_gas(2, 1, cancun)),
    ?assertEqual(66, exp_gas(Big, 1, cancun)),
    %% And the exponent's width *is* priced: 50 more per byte, 31 more bytes.
    ?assertEqual(66 + 50 * 31, exp_gas(2, Big, cancun)).

%% EIP-160, quoted: "increase the gas cost of EXP from 10 + 10 per byte in the
%% exponent to 10 + 50 per byte in the exponent." The boundary is Spurious Dragon.
%%
%% **The pair is Tangerine Whistle and Spurious Dragon, not Byzantium.** Spurious
%% Dragon activated at block 2,675,000 and Byzantium at 4,370,000, so Byzantium is
%% *after* it and already costs 50. Sampling "an old fork and a new fork" lands on a
%% pair that straddles nothing: the first sample here was `byzantium' against
%% `cancun', both post-SD, both 66, and the gate looked broken when it was working.
%% A number that does not move across a boundary is measuring the wrong side of it.
exp_costs_ten_per_byte_before_spurious_dragon_and_fifty_from_it_test_() ->
    {timeout, 30, fun exp_costs_ten_per_byte_before_spurious_dragon_and_fifty_from_it/0}.

exp_costs_ten_per_byte_before_spurious_dragon_and_fifty_from_it() ->
    [?assertEqual(26, exp_gas(2, 3, F))
     || F <- [frontier, homestead, tangerine]],
    [?assertEqual(66, exp_gas(2, 3, F))
     || F <- [spurious_dragon, byzantium, istanbul, cancun]],
    %% 40 is the whole of EIP-160, and it is 40 rather than a ratio.
    ?assertEqual(40, exp_gas(2, 3, cancun) - exp_gas(2, 3, homestead)).

%% An exponent of zero measures zero bytes, because `eth_word:to_bytes/1' is the
%% minimal big-endian encoding and maps 0 to `<<>>'. The old rule priced
%% `max(base, exponent)', so a program whose base and exponent were both zero paid
%% for nothing twice over -- and one whose base was 32 bytes and whose exponent was
%% zero paid 1,550 for a single PUSH32.
%% Same `{timeout, 30, fun .../0}' shape as the three above it, which is not
%% decoration: written as a bare `_test_' with its assertions inline, this eunit
%% rejects the generator with "result ... is not a test" and reports the atom `ok'
%% it was handed. A generator that runs the interpreter wants a timeout like any
%% other.
an_exponent_of_zero_costs_only_the_flat_price_test_() ->
    {timeout, 30, fun an_exponent_of_zero_costs_only_the_flat_price/0}.

an_exponent_of_zero_costs_only_the_flat_price() ->
    ?assertEqual(3 + 3 + 10, exp_gas(0, 0, cancun)),
    ?assertEqual(3 + 3 + 10,
                 exp_gas(16#7F00000000000000000000000000000000000000000000000000000000000000,
                         0, cancun)).

%% `<push base> <push exponent> EXP STOP', and nothing else. No state is touched,
%% so nothing here can reach an upstream fetch -- `with_ctx/1' is not ceremony
%% around this test but the only thing standing between a hand-built state and a
%% live RPC call four frames below the opcode.
exp_gas(Base, Exponent, Fork) ->
    ?GAS - exp_gas_left(Base, Exponent, Fork).

exp_gas_left(Base, Exponent, Fork) ->
    Code = iolist_to_binary([exp_push(Exponent), exp_push(Base), <<16#0A, 16#00>>]),
    {ok, _Out, GasLeft, _St2, []} =
        eth_evm:run(Code, exp_msg(), eth_state:new(0, #{}), #{fork => Fork}, ?GAS),
    GasLeft.

%% The word EXP left on the stack, read back out through memory.
exp_result(Base, Exponent, Fork) ->
    Code = iolist_to_binary([exp_push(Exponent), exp_push(Base), <<16#0A>>,
                             <<16#60, 0, 16#52, 16#60, 32, 16#60, 0, 16#F3>>]),
    {ok, Out, _Gas, _St2, []} =
        eth_evm:run(Code, exp_msg(), eth_state:new(0, #{}), #{fork => Fork}, ?GAS),
    ?assertEqual(32, byte_size(Out)),
    binary:decode_unsigned(Out).

%% `?MSG0#{...}' is "expression updates a literal" and does not compile -- a macro
%% is not a variable to update. Bind it first.
exp_msg() ->
    Base = ?MSG0,
    Base#{address => <<0:160>>, caller => <<0:160>>, origin => <<0:160>>,
          value => 0, static => false}.

%% **Push order is the whole of EXP, and it is `exponent, base` -- the exponent
%% FIRST.** `push/1' conses, so the *second* push is what EXP pops first, and EXP's
%% first pop is the base. Measured on geth 1.17.7, all eight rows:
%%
%%     PUSH1 2,  PUSH1 3,  EXP  -> 9        3 ** 2
%%     PUSH1 3,  PUSH1 2,  EXP  -> 8        2 ** 3
%%     PUSH1 10, PUSH1 3,  EXP  -> 59049    3 ** 10
%%     PUSH1 3,  PUSH1 10, EXP  -> 1000     10 ** 3
%%     PUSH1 7,  PUSH1 4,  EXP  -> 16384    4 ** 7
%%     PUSH1 4,  PUSH1 7,  EXP  -> 2401     7 ** 4
%%     PUSH1 5,  PUSH1 0,  EXP  -> 0        0 ** 5
%%     PUSH1 0,  PUSH1 5,  EXP  -> 1        5 ** 0
%%
%% Read the middle two columns as a pair and the rule is one sentence: **the result
%% is the second push raised to the first.** The last two rows are in the table
%% because they are the ones that separate "base" from "exponent" -- 0 ** 5 = 0 and
%% 5 ** 0 = 1, so a node that had them the other way round would answer 1 where the
%% chain answers 0, on a one-byte program.
%%
%% `PUSH1' for a small word, `PUSH32' for one that needs the full width. The width
%% matters and is the point: a 32-byte base pushed with `PUSH1' would be a different
%% program, and the whole claim is that the base's width never reaches the price.
exp_push(W) when W < 256 -> <<16#60, W>>;
exp_push(W) -> <<16#7F, W:256>>.


%% ---------------------------------------------------------------------------
%% EIP-7843: SLOTNUM is 0x4b, costs 2, and does not default
%% ---------------------------------------------------------------------------
%% **The gas figure is 2 and not 20, and the reason is worth stating because every
%% neighbouring environment-reading opcode costs 20.** `constant_cost/2' returns the
%% *base* for the whole `0x41..0x46` family -- all of them answer 2 -- and the EVM adds the
%% family's extra on top, which is why `basefee_costs_20_test' above exists and why this
%% opcode must not be written as "another environment reader". EIP-7843 says "The gas cost
%% for SLOTNUM is a fixed fee of 2", and geth charges `GasQuickStep`. So 2 is right, and it
%% is right *against* the family it sits numerically inside.
-define(SLOTNUM_ENV, (#{fork => amsterdam, slot_number => 11296768})).

%% Slot 11,296,768 is the value real Sepolia block 11,856,337 carries. **A test value
%% that is a real chain value is worth one that is not**, because a round number could be
%% produced by a stub.
slotnum_costs_two_gas_test() ->
    %% SLOTNUM + STOP. The program has to *run* the opcode or the figure below would be
    %% the cost of a bare STOP, which is 0 -- a frame that never reached the instruction
    %% reports a number that looks right for the wrong reason.
    {ok, _, GasLeft, _, _} =
        eth_evm:run(<<16#4B, 16#00>>, ?MSG0, ?STATE, ?SLOTNUM_ENV, ?GAS),
    ?assertEqual(?GAS - 2, GasLeft).

slotnum_pushes_the_slots_number_test() ->
    %% SLOTNUM PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
    Code = <<16#4B, 16#60, 16#00, 16#52,
             16#60, 16#20, 16#60, 16#00, 16#F3>>,
    {ok, Out, _, _, _} =
        eth_evm:run(Code, ?MSG0, ?STATE, ?SLOTNUM_ENV, ?GAS),
    ?assertEqual(<<11296768:256>>, Out).

slotnum_is_a_word_not_a_byte_test() ->
    %% The same program, read back as a number. MSTORE took `0' as the offset and the slot
    %% as the value, so the returned word *is* the slot number -- and a handler that
    %% truncated to 64 bits or pushed the Env value unconverted would answer something
    %% else. Slot 11,296,768 needs 24 bits, so a byte-width slip is visible here.
    Code = <<16#4B, 16#60, 16#00, 16#52,
             16#60, 16#20, 16#60, 16#00, 16#F3>>,
    {ok, Out, _, _, _} =
        eth_evm:run(Code, ?MSG0, ?STATE, ?SLOTNUM_ENV, ?GAS),
    ?assertEqual(11296768, binary:decode_unsigned(Out)).

slotnum_is_not_offered_before_amsterdam_test() ->
    %% **The fork gate, asserted at the boundary rather than by a table.** Cancun is the
    %% fork that owns 0x49 and 0x4A, so it is the nearest neighbour; a gate that returned
    %% true for `cancun' would make the opcode available in every block with blobs in it.
    ?assertNot(eth_fork_schedule:opcode_exists(16#4B, cancun)),
    ?assertNot(eth_fork_schedule:opcode_exists(16#4B, prague)),
    ?assert(eth_fork_schedule:opcode_exists(16#4B, amsterdam)).

slotnum_refuses_when_the_environment_carries_no_slot_number_test() ->
    %% **This is the assertion the opcode exists for.** `undefined' means the payload had
    %% no `slotNumber', and every other environment-reading opcode in this file answers
    %% `s_env(Key, Ctx, 0)' -- so the convenient implementation of SLOTNUM reports the
    %% genesis slot for a block that has none. Slot 0 is a real slot, so there is no
    %% version of "no slot number" this can answer with.
    Code = <<16#4B, 16#00>>,
    %% `run/5' answers a five-tuple on success and a **four**-tuple on a halt -- no logs
    %% element, because a frame that halted produced none. Writing the three-element form
    %% fails with a `pattern' that reads as the node refusing for the wrong reason.
    ?assertMatch({error, {unsupported, {slot_number, absent}}, _State, _Logs},
                 eth_evm:run(Code, ?MSG0, ?STATE, #{fork => amsterdam}, ?GAS)).

slotnum_reads_slot_zero_rather_than_treating_it_as_absent_test() ->
    %% **The other half, and it is the half that makes the refusal above correct rather
    %% than merely cautious.** A handler written as `maps:get(slot_number, Env, undefined)`
    %% and then `case undefined` would answer fine here -- but one written as
    %% `case maps:is_key(...) of false -> refuse; true -> maps:get(..., 0) end` is the same
    %% code, and the control is what tells the two apart. Slot 0 must push 0, and must not
    %% be refused.
    Code = <<16#4B, 16#60, 16#00, 16#52,
             16#60, 16#20, 16#60, 16#00, 16#F3>>,
    {ok, Out, _, _, _} =
        eth_evm:run(Code, ?MSG0, ?STATE,
                    #{fork => amsterdam, slot_number => 0}, ?GAS),
    ?assertEqual(<<0:256>>, Out).
