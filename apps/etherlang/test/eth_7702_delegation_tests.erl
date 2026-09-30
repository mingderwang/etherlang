%% EIP-7702, part two: **following** a delegation, and EIP-3607's relaxation.
%%
%% `v1.62` wrote the `0xef0100 || address` designator. Nothing read it. This module
%% is the other half, and the half that decides whether the feature means anything:
%% a delegated account has to *execute* its delegate, and it has to be allowed to
%% originate transactions.
%%
%% Three of the EIP's rules here are counter-intuitive enough that they are stated
%% in the tests rather than in comments only, because each is a plausible
%% implementation that is wrong:
%%
%%   * **one hop, then stop** -- a chain or a loop of delegations resolves to a
%%     designator *executed as code*, and `0xef` is not an instruction;
%%   * **a delegation to a precompile is empty code**, so the precompile does not
%%     run and the call succeeds;
%%   * **the account keeps its own identity** -- the delegate's code, the account's
%%     storage, balance and `ADDRESS`.
-module(eth_7702_delegation_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("etherlang/include/eth_block.hrl").

-define(GWEI, 1000000000).
-define(PRAGUE_BLOCK, 20000000).
-define(SENDER_PRIV, <<16#0101010101010101010101010101010101010101010101010101010101010101:256>>).
-define(MINER, <<16#c0de:160>>).

%% The account that carries the delegation: the *authority*, whose storage the
%% delegate's code writes and whose `ADDRESS` the frame must report.
-define(ACCOUNT, <<16#4000000000000000000000000000000000000004:160>>).
%% The contract the account delegates to.
-define(DELEGATE, <<16#5000000000000000000000000000000000000005:160>>).
%% A second, unrelated contract, for the controls.
-define(OTHER, <<16#6000000000000000000000000000000000000006:160>>).

%% ---------------------------------------------------------------------------
%% A transaction to a delegated account runs the delegate, as the account
%% ---------------------------------------------------------------------------

%% The two halves in one fixture, because they are the same claim from two sides.
%% `PUSH1 1 PUSH1 0 SSTORE STOP` at the delegate: the slot written is **the
%% account's**, not the delegate's. A node that followed the delegation by
%% re-pointing `address` at the delegate would write the *delegate's* slot 0 and
%% pass a test that only asked whether the code ran.
the_delegates_code_runs_in_the_context_of_the_account_test() ->
    with_ctx(fun() ->
        State0 = delegated(put_code(eth_state:new(0, #{}), ?DELEGATE, sstore1(), 0)),
        {_, State1} = run(to_account(State0, ?ACCOUNT)),
        ?assertEqual(1, eth_state:storage(State1, ?ACCOUNT, 0)),
        ?assertEqual(0, eth_state:storage(State1, ?DELEGATE, 0))
    end).

%% **The control: without the delegation the code does not run.** The account holds
%% `<<16#EF, 16#01, 16#00>>` on its own -- the 3-byte prefix with no address, which
%% is *not* a valid designator because it is not 23 bytes -- so the transaction
%% calls an account whose code is three meaningless bytes. A frame that cannot run
%% them (there is no instruction `0xef`) does nothing, and the slot stays 0.
%%
%% Without this the first test is satisfied by a node that executes *any* account's
%% code, including a designator.
the_designator_itself_is_not_executed_when_it_is_not_a_valid_indicator_test() ->
    with_ctx(fun() ->
        S = put_code(eth_state:new(0, #{}), ?ACCOUNT,
                     <<16#EF, 16#01, 16#00>>, 1),
        {_, State1} = run(to_account(S, ?ACCOUNT)),
        ?assertEqual(0, eth_state:storage(State1, ?ACCOUNT, 0))
    end).

%% "CALL loads the code at `address` and executes it in the context of `authority`"
%% -- so `ADDRESS` inside a delegated frame is the **account**. `sstore1/0` proves
%% the storage; this proves the address the opcode reports, which is a different
%% read of the same sentence and is what a wallet's own code branches on.
the_address_opcode_reports_the_account_not_the_delegate_test() ->
    with_ctx(fun() ->
        %% PUSH1 0x0b ADDRESS PUSH1 0 SSTORE STOP -- store ADDRESS at slot 0.
        Code = <<16#60, 16#0b, 16#30, 16#60, 0, 16#55, 16#00>>,
        ?assertEqual(7, byte_size(Code)),
        State0 = delegated(put_code(eth_state:new(0, #{}), ?DELEGATE, Code, 0)),
        {_, State1} = run(to_account(State0, ?ACCOUNT)),
        %% `binary:decode_unsigned/1`, **not `eth_word:to_bytes(?ACCOUNT, 256)`**:
        %% `?ACCOUNT` is already a 20-byte binary and `to_bytes/2` wants an
        %% integer, so it reached `band` with a binary operand and raised from
        %% inside `eth_word` -- three frames from the fixture, naming neither the
        %% opcode under test nor the address. The stored word is compared as the
        %% integer it is.
        Stored = eth_state:storage(State1, ?ACCOUNT, 0),
        ?assertEqual(binary:decode_unsigned(?ACCOUNT), Stored),
        ?assertNotEqual(binary:decode_unsigned(?DELEGATE), Stored)
    end).

%% ---------------------------------------------------------------------------
%% The same three rules, reached by CALL rather than by a transaction
%% ---------------------------------------------------------------------------

%% The transaction-destination tests above prove the delegate's code runs in the
%% **account's** context. This proves the same thing for a **frame**, which is a
%% different code path: `run_call/11' builds the child `Msg' and the injected
%% defect that changed `call -> {To, CurAddr, Value}' to `call -> {CurAddr, ...}'
%% -- executing the delegate as the *caller* -- **failed nothing**, because no test
%% exercised a `CALL` into a delegated account at all.
%%
%% The fixture: `?OTHER` CALLs `?ACCOUNT`, which is delegated to a contract that
%% writes slot 0. The write must land on `?ACCOUNT`. A frame that resolved the
%% delegation by re-pointing `address` at the delegate would write it on
%% `?DELEGATE`, and one that ran the delegate's code in the *caller's* context
%% would write it on `?OTHER`. All three accounts are checked, and only one of them
%% is named in the test.
a_call_to_a_delegated_account_runs_in_the_accounts_context_test() ->
    with_ctx(fun() ->
        St = delegated(put_code(eth_state:new(0, #{}), ?DELEGATE, sstore1(), 0)),
        St1 = put_code(St, ?OTHER, call_code(?ACCOUNT, 100000), 0),
        {_, State1} = run(to_account(St1, ?OTHER)),
        %% The account: the delegation is executed in *its* context.
        ?assertEqual(1, eth_state:storage(State1, ?ACCOUNT, 0)),
        %% Neither of the two places a re-pointed implementation would have put it.
        ?assertEqual(0, eth_state:storage(State1, ?DELEGATE, 0)),
        ?assertEqual(0, eth_state:storage(State1, ?OTHER, 0))
    end).

%% **The control for the frame path**: the same `CALL`, to an account that is *not*
%% delegated and holds the same code. So the write happens -- on the account, as
%% always. Without it the test above is satisfied by a `CALL` that never runs its
%% callee's code, which is a perfectly good way to get slot 0 right on the wrong
%% account (by not touching it) as long as the account is not the one asserted.
a_call_to_an_ordinary_account_writes_to_that_account_test() ->
    with_ctx(fun() ->
        St = put_code(eth_state:new(0, #{}), ?ACCOUNT, sstore1(), 0),
        St1 = put_code(St, ?OTHER, call_code(?ACCOUNT, 100000), 0),
        {_, State1} = run(to_account(St1, ?OTHER)),
        ?assertEqual(1, eth_state:storage(State1, ?ACCOUNT, 0))
    end).

%% "Additionally, if a transaction's `destination' has a delegation indicator, add
%% the target of the delegation to `accessed_addresses`."
%%
%% The injected defect that dropped the `delegate' key from the Msg **failed
%% nothing**, so no test could see it. The observable is the delegate's own code
%% reading the delegate's account: `EXTCODESIZE(<DELEGATE>)` costs 100 if the
%% account is already warm and 2,600 if it is not, and the resolution is what
%% should have warmed it.
%%
%% Two runs with the **same program**: one where the destination is delegated, and
%% one where the destination is an ordinary account holding the program itself.
%%
%%     delegated  = PUSH20 (3) + EXTCODESIZE warm (100) + POP (2) = 105
%%     ordinary   = PUSH20 (3) + EXTCODESIZE cold (2600) + POP (2) = 2605
%%     ordinary - delegated = **2500**
%%
%% **The first version predicted -100** and was wrong about a thing I had not
%% checked: a transaction's own destination is in the warm set from the start
%% (`initial_access/3` warms `Msg#msg.address`), so *resolving a transaction's
%% delegation costs no access at all* -- the only consequence is that the **delegate**
%% becomes warm. The EIP's extra 2,600 is for "a code executing instruction", and a
%% transaction's destination is not one. Getting that backwards would have meant
%% charging every delegated transaction 2,600 for nothing, and the test as written
%% would have demanded it.
%%
%% And 2,500 is the figure that pins the rule rather than a side effect: a node that
%% did not pre-warm the delegate gives 0, and a node that warmed the delegate
%% unconditionally -- including in the control, where it is nobody's delegate -- also
%% gives 0. Only "warm it when it *is* the destination's delegate" gives 2,500.
a_transaction_to_a_delegated_account_warms_its_delegate_test() ->
    with_ctx(fun() ->
        %% PUSH20 <DELEGATE> EXTCODESIZE POP STOP -- one read of the delegate's
        %% own account, from inside the delegate.
        Prog = <<16#73, ?DELEGATE/binary, 16#3b, 16#50, 16#00>>,
        ?assertEqual(24, byte_size(Prog)),
        Delegated = put_code(eth_state:new(0, #{}), ?DELEGATE, Prog, 0),
        A = gas_of_tx(delegated(Delegated), ?ACCOUNT),
        %% The control: the same program, at an ordinary destination.
        B = gas_of_tx(put_code(eth_state:new(0, #{}), ?ACCOUNT, Prog, 0), ?ACCOUNT),
        ?assertEqual({want, 2500, A, B}, {want, B - A, A, B})
    end).

%% ---------------------------------------------------------------------------
%% One hop, then stop
%% ---------------------------------------------------------------------------

%% "In case a delegation indicator points to another delegation, creating a
%% potential chain or loop of delegations, clients must retrieve only the first
%% code and then stop following the delegation chain."
%%
%% So `?ACCOUNT` delegates to `?DELEGATE`, and `?DELEGATE`'s own code is a
%% *designator* pointing back at `?ACCOUNT`. A recursive resolver would loop; this
%% one stops, and what it executes is the designator's **23 bytes**, whose first
%% instruction `0xef` is not in the instruction set -- so the frame halts.
%%
%% The observable is that the write never happens: if the chain were followed to
%% `sstore1/0' the slot would be 1, and if the resolver returned *empty* code for
%% the chained case the test would pass for the wrong reason. Hence the second
%% fixture below, where the first hop's target is a real contract.
a_delegation_pointing_at_a_delegation_stops_after_one_hop_test() ->
    with_ctx(fun() ->
        %% The chain is `?ACCOUNT` -> `?DELEGATE` -> `?OTHER`, and `?OTHER` holds
        %% `sstore1/0'. So the second hop reaches **real code that would write**,
        %% and a recursive resolver -- the implementation that looks right, and the
        %% one that terminates on no input, because `A -> B -> A` is a cycle it
        %% cannot tell from a chain -- would follow it and leave the slot at 1.
        %%
        %% The first version made the cycle direct (`?DELEGATE` pointed back at
        %% `?ACCOUNT`) and asserted the slot was 0. That is **satisfied by a frame
        %% that ran nothing at all** -- which is what the broken `call_code/2`
        %% fixture produced, and the test passed. A "nothing happened" assertion
        %% cannot distinguish "the chain was not followed" from "no code ran", and
        %% the second reading is the one a broken fixture gives for free.
        %%
        %% So the sharp version puts a *writer* one hop past the delegation, and
        %% asserts both halves: the slot is 0 **and** the frame halted, because what
        %% one hop retrieves here is a designator's 23 bytes and `0xef` is not an
        %% instruction.
        Code = sstore1(),
        Loop = eth_tx:delegation_indicator(?OTHER),
        ?assertEqual(23, byte_size(Loop)),
        St = delegated(
                put_code(eth_state:new(0, #{}), ?DELEGATE, Loop, 0)),
        St1 = put_code(St, ?OTHER, Code, 0),
        {Block, State1} = run(to_account(St1, ?ACCOUNT)),
        [Receipt] = eth_block:receipts(Block),
        %% Halted: the retrieved code is `0xef0100...`, whose first byte is not an
        %% instruction. A node that resolved recursively would have succeeded here
        %% and written 1.
        ?assertEqual(0, maps:get(<<"status">>, Receipt)),
        ?assertEqual(0, eth_state:storage(State1, ?ACCOUNT, 0)),
        ?assertEqual(0, eth_state:storage(State1, ?OTHER, 0))
    end).

%% **The control that makes the one above mean "one hop" and not "never follows".**
%% `?DELEGATE` holds real code, so `?ACCOUNT` -> `?DELEGATE` resolves in one hop
%% and the write happens. The pair differs in the delegate's code and nothing else.
one_hop_to_a_real_contract_does_run_test() ->
    with_ctx(fun() ->
        State0 = delegated(put_code(eth_state:new(0, #{}), ?DELEGATE, sstore1(), 0)),
        {_, State1} = run(to_account(State0, ?ACCOUNT)),
        ?assertEqual(1, eth_state:storage(State1, ?ACCOUNT, 0))
    end).

%% ---------------------------------------------------------------------------
%% A delegation to a precompile is empty code
%% ---------------------------------------------------------------------------

%% "When a precompile address is the target of a delegation, the retrieved code is
%% considered empty and CALL ... will execute empty code, and therefore succeed with
%% no execution when given enough gas to initiate the call."
%%
%% **The observable is `RETURNDATASIZE`, not the CALL's success flag.** The first
%% version used `0x01` (`ecrecover`) with no calldata, on the reasoning that
%% EIP-2 needs 128 bytes so the precompile would fail and the flag would read 0.
%% **This node's `ecrecover` returns success on empty input**, so the flag was 1
%% from a *direct* call too, and the pair of tests could not tell "empty code" from
%% "a precompile that succeeded" -- the control failed, which is the only reason
%% this is visible at all. Had the two arms agreed by accident the test would have
%% been green and meaningless.
%%
%% So the fixture gives the precompile **32 bytes to hash** and reads the size of
%% what comes back: empty code returns `b""` and stores 0, `sha256` returns 32 bytes
%% and stores 32. The two cannot be confused, and the direct-call control proves
%% which arm is which.
a_delegation_to_a_precompile_runs_empty_code_and_returns_nothing_test() ->
    with_ctx(fun() ->
        Sha = <<0:152, 2>>,
        ?assertEqual(sha256, eth_fork_schedule:precompile_at(prague, 2)),
        %% The delegate has *code* of its own, so a node that followed the
        %% delegation by resolving twice, or by ignoring the precompile rule
        %% entirely, would run it and write to the account.
        St = delegated(put_code(eth_state:new(0, #{}), Sha, sstore1(), 0)),
        %% Put 32 bytes at memory[0] so the precompile has something to hash.
        HashMe = <<16#60, 16#2a, 16#60, 0, 16#52>>,
        %% 5 bytes: PUSH1, PUSH1, PUSH1, PUSH1, MSTORE -- I wrote 4 first, and the
        %% compiler constant-folded the comparison and refused to build. **A size
        %% assertion on a literal is a build failure**, which is the cheapest
        %% possible version of this check: it cannot be wrong at run time.
        ?assertEqual(5, byte_size(HashMe)),
        St1 = put_code(St, ?OTHER, iolist_to_binary(
                                        [HashMe, call_retdatasize_code(?ACCOUNT,
                                                                      100000, 32)]), 0),
        {Block, State1} = run(to_account(St1, ?OTHER)),
        [Receipt] = eth_block:receipts(Block),
        ?assertEqual(1, maps:get(<<"status">>, Receipt)),
        %% 0: empty code, so the return buffer is empty.
        ?assertEqual(0, eth_state:storage(State1, ?OTHER, 0)),
        %% And the delegate's own code did not run either.
        ?assertEqual(0, eth_state:storage(State1, ?ACCOUNT, 0))
    end).

%% **The resolution is still charged when the retrieved code is empty.** This is
%% the half of the precompile rule with no *behavioural* consequence and a real
%% *gas* one: "the caller's own access to the account is still charged" is not in
%% the EIP's words, but the extra account access is charged by the same sentence
%% that makes the code empty, and reporting a precompile delegate as "no delegation"
%% drops it.
%%
%%     to a codeless `?ACCOUNT'          = CALL 2600 (cold)              = 2600
%%     to `?ACCOUNT' delegated to 0x02   = CALL 2600 + resolution **100** = 2700
%%     difference                        = **100**
%%
%% **100, not 2,600**, and that is the EIP's own consequence rather than a
%% discount: `eth_evm:initial_access/3` seeds the transaction-start warm set with
%% every precompile address, and `0x02` is one. So a delegation *to a precompile* is
%% always resolved warm, and the extra account access is the `WARM_STORAGE_READ_COST`
%% the EIP names for that case. The first version predicted 2,600 and measured 100,
%% and the reason it could not have been 2,600 is that the delegate is never cold
%% here -- which also means this arm is the one place the warm figure is reachable
%% without arranging a prior access.
a_delegation_to_a_precompile_is_still_charged_test() ->
    with_ctx(fun() ->
        Sha = <<0:152, 2>>,
        %% **Both arms run an empty frame.** The control account holds *no* code at
        %% all. The first version gave it `sstore1/0' -- "the same code the delegate
        %% would have run" -- and the two arms then differed by 22,006, because the
        %% control was doing an `SSTORE` the delegated arm deliberately does not. The
        %% comparison is only about the *resolution*, so the two arms must differ in
        %% the resolution and in nothing else; holding code in one and not the other
        %% is a second difference, and it is 22,000 wide.
        Codeless = gas_of_call(eth_state:new(0, #{}), ?ACCOUNT),
        %% **The indicator is built for `Sha` explicitly**, not by `delegated/1' --
        %% that helper points at `?DELEGATE', so using it would have delegated to a
        %% contract instead of to a precompile, and the compiler caught the
        %% consequence (`Sha' unused) before the run. The wrong-delegate mistake is
        %% not always silent; sometimes the build says so.
        StD = eth_state:set_code(eth_state:new(0, #{}), ?ACCOUNT,
                                 eth_tx:delegation_indicator(Sha)),
        Delegated = gas_of_call(StD, ?ACCOUNT),
        %% **Not** `delegated/1' on `St' for both arms: the second arm needs the
        %% delegation and the first must not have it, and `?ACCOUNT' already holds
        %% `sstore1/0' so `delegated/1' overwrites it with the indicator.
        ?assertEqual({want, 100, Codeless, Delegated},
                     {want, Delegated - Codeless, Codeless, Delegated})
    end).

%% **The control: a direct call to the same precompile returns 32 bytes.** If this
%% ever reads 0, the precompile is not running in either arm and the pair has
%% stopped distinguishing anything.
a_direct_call_to_the_precompile_returns_thirty_two_bytes_test() ->
    with_ctx(fun() ->
        Sha = <<0:152, 2>>,
        HashMe = <<16#60, 16#2a, 16#60, 0, 16#52>>,
        St = put_code(eth_state:new(0, #{}), ?OTHER,
                      iolist_to_binary([HashMe, call_retdatasize_code(Sha, 100000, 32)]), 0),
        {_, State1} = run(to_account(St, ?OTHER)),
        ?assertEqual(32, eth_state:storage(State1, ?OTHER, 0))
    end).

%% ---------------------------------------------------------------------------
%% CODESIZE versus EXTCODESIZE
%% ---------------------------------------------------------------------------

%% "For code reading, only `CODESIZE` and `CODECOPY` instructions are affected. They
%% operate directly on the executing code instead of the delegation. For example,
%% when executing a delegated account `EXTCODESIZE` returns `23` ... whereas
%% `CODESIZE` returns the size of the code residing at `address`."
%%
%% So inside the delegate, `EXTCODESIZE` of the account is 23 and `EXTCODESIZE` of
%% the delegate is 6. Both are read in the same frame, from the same state, one
%% opcode apart -- so a node that resolved `EXTCODESIZE` as well would have to be
%% right about both to pass, and a node that resolved neither fails one of them.
extcodesize_sees_the_indicator_but_codesize_sees_the_delegate_test() ->
    with_ctx(fun() ->
        %% PUSH1 ?ACCOUNT EXTCODESIZE PUSH1 0 SSTORE
        %% PUSH1 ?DELEGATE EXTCODESIZE PUSH1 1 SSTORE
        Code = <<16#73, ?ACCOUNT/binary, 16#3b, 16#60, 0, 16#55,
                16#73, ?DELEGATE/binary, 16#3b, 16#60, 1, 16#55,
                16#00>>,
        %% One byte per opcode and per immediate, and the total **derived by adding the
        %% pieces** rather than typed -- the compiler constant-folds
        %% `byte_size/1' on a literal binary, so a wrong number here is a *build
        %% failure*, which is the only good way to find it. The first version wrote
        %% 52; the pieces sum to 51.
        ?assertEqual((1 + 20) + 1 + (1 + 1) + 1 + (1 + 20) + 1 + (1 + 1) + 1 + 1,
                     byte_size(Code)),
        State0 = delegated(put_code(eth_state:new(0, #{}), ?DELEGATE, Code, 0)),
        {_, State1} = run(to_account(State0, ?ACCOUNT)),
        %% EXTCODESIZE of the account is the *indicator*, 23 bytes, not the
        %% delegate's code.
        ?assertEqual(23, eth_state:storage(State1, ?ACCOUNT, 0)),
        ?assertEqual(byte_size(Code), eth_state:storage(State1, ?ACCOUNT, 1))
    end).

%% ---------------------------------------------------------------------------
%% EIP-3607
%% ---------------------------------------------------------------------------

%% "Modify the restriction put in place by EIP-3607 to allow EOAs whose code is a
%% valid delegation indicator ... to originate transactions."
%%
%% The sender is an account carrying a designator, sends to itself, and the frame
%% runs. The delegation is written by a prior type-4 transaction in the same run,
%% so the pre-state already has it.
a_delegated_account_may_originate_a_transaction_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Me = addr_of(Priv),
        %% Two transactions, because a transaction cannot originate while its own
        %% authorization is unapplied -- EIP-3607 is checked against the state as it
        %% is, and the indicator is only written by the first one. Writing them as
        %% one transaction would test nothing.
        %% `set_code_tx/1`, not `set_code_tx/2'. The extra argument is the map of
        %% overrides, and the private key went there: `maps:merge/2' then failed with
        %% the key as its second argument, printing the whole transaction beside it.
        %% The error named `maps:merge/2` and the transaction, and named neither the
        %% arity nor the argument that was wrong.
        D1 = sign(set_code_tx([authorization(?DELEGATE, 0, Priv)], #{}), ?SENDER_PRIV),
        %% `?DELEGATE` needs **code** for the second half of the claim to mean
        %% anything, and the second transaction goes to **`Me` itself** -- the
        %% now-delegated sender, sending to itself, which is the case a wallet
        %% actually does. The first version pointed it at `?ACCOUNT` and left
        %% `?DELEGATE` empty, so the frame ran nothing and the storage assertion
        %% read 0: a fixture that cannot fail for the reason it names.
        St0 = delegated(put_code(fund(eth_state:new(0, #{}), Me, 1000 * ?GWEI),
                                 ?DELEGATE, sstore1(), 0)),
        {_, St1} = run({D1, St0}),
        ?assertEqual(eth_tx:delegation_indicator(?DELEGATE),
                     eth_state:code(St1, Me)),
        %% **Through `run/1`, not `run_tx/2`.** Every other fixture in this module
        %% goes through `run/1`, and the one that did not was the one that failed --
        %% with a tuple where a transaction belonged, and a trace naming
        %% `eth_block:run_transaction/5` and the map *inside* the tuple, so the
        %% tuple's own construction was nowhere in the message. One entry point for
        %% "run this against this state" is not tidiness: it is what stops the shape
        %% of the argument from being a per-call-site decision.
        {Block, St2} = run({from_me(Me, 1, Me, Priv), St1}),
        [Receipt] = eth_block:receipts(Block),
        ?assertEqual(1, maps:get(<<"status">>, Receipt)),
        %% And the delegate's code ran, in the sender's own storage -- which is the
        %% second half of the claim. EIP-3607's relaxation alone would let the
        %% transaction through and execute `0xef0100...` as code, halting.
        ?assertEqual(1, eth_state:storage(St2, Me, 0))
    end).

%% **The control.** EIP-3607 still refuses a sender holding *real* code.
%%
%% **Through `eth_tx:validate/2`, not by calling `eth_tx:check_sender_is_eoa/2`.**
%% That function is private, and exporting a validator to reach it from a test
%% would make the test the only caller of the rule -- AGENTS.md §4.4's rule in
%% reverse. The production path is also the one that can catch a *missing* wiring:
%% a private function called by a test proves the function is right and nothing
%% about the node.
a_sender_holding_real_code_is_still_refused_test() ->
    ?assertEqual({error, sender_not_eoa}, admitted(sstore1())).

%% And 23 bytes that are **not** a designator is still refused. The discriminating
%% case is a *different prefix* at the same length -- `0xef0101` rather than
%% `0xef0100`.
%%
%% The first version of this test used `0xef0100 || 0x00..00` and asserted a
%% refusal, on the reasoning that a zero address is not a real delegation. **The
%% node answered `ok` and the node was right:** 23 bytes with the right prefix
%% *is* a valid delegation indicator whatever the address, and the zero address is
%% a legitimate one (EIP-7702's own "clear" case writes an indicator for it in
%% every tuple but the clearing one). A test whose fixture is a special case the
%% specification does not call special fails for a reason that is not about the
%% rule, and here it would have "fixed" the node into refusing valid delegations.
a_sender_holding_23_bytes_that_are_not_a_designator_is_refused_test() ->
    ?assertEqual({error, sender_not_eoa},
                 admitted(<<16#EF, 16#01, 16#01, 0:160>>)),
    %% ... and the length really is 23, so the refusal is about the prefix and
    %% not about the size. A control that pins the fixture's own shape.
    ?assertEqual(23, byte_size(<<16#EF, 16#01, 16#01, 0:160>>)).

%% **And the positive case, on the same path**: a valid designator is accepted.
%% Without it the two refusals above are satisfied by a node that refuses *every*
%% sender holding code, which is the node before the relaxation -- so the pair
%% above would be pinning a rule the EIP removed.
a_sender_holding_a_valid_designator_is_accepted_test() ->
    ?assertNotEqual({error, sender_not_eoa},
                    admitted(eth_tx:delegation_indicator(?DELEGATE))).

%% `validate/2' on a well-formed 1559 transaction, with the sender's code supplied
%% through the context's `code_of' -- the one hook `check_sender_is_eoa/2' reads.
%% The fun answers the same code for every address because the rule only ever asks
%% about the sender, and a per-address table would be a second thing to get right.
admitted(Code) ->
    eth_tx:validate(tx(), #{fork => prague, code_of => fun(_A) -> {ok, Code} end}).

%% **Signed.** `eth_tx:validate/2' recovers the sender, and an unsigned
%% transaction answers `{error, bad_signature}` -- which arrived here as the
%% *value* where `{error, sender_not_eoa}` was expected, and reads at first like
%% the relaxation failing. It is the fixture: the rule under test is reached only
%% after the signature checks out.
tx() ->
    sign(#{<<"type">> => <<"0x2">>,
      <<"chainId">> => eth_hex:encode_int(eth_fork_schedule:chain_id()),
      <<"nonce">> => <<"0x0">>,
      <<"maxPriorityFeePerGas">> => <<"0x1">>,
      <<"maxFeePerGas">> => <<"0x2">>,
      <<"gas">> => <<"0x5208">>,
      <<"to">> => eth_hex:encode_bytes(?OTHER),
      <<"value">> => <<"0x0">>,
      <<"data">> => <<"0x">>,
      <<"accessList">> => []}, ?SENDER_PRIV).

%% ---------------------------------------------------------------------------
%% EIP-7702 step 4: `accessed_addresses`
%% ---------------------------------------------------------------------------

%% Step 4: "Add `authority` to `accessed_addresses`, as defined in EIP-2929."
%%
%% The subtle half is *when*. The EIP puts it immediately after recovery and
%% before the code and nonce checks, and the reference implementation follows that
%% exactly -- so a tuple that is **refused** still leaves its authority warm for the
%% rest of the transaction. Warming only the authorities whose tuples *applied*
%% would be a tidier-looking rule that disagrees on precisely the tuples a user gets
%% wrong, which is the only place a user notices.
%%
%% The observable is a price, not a value: the delegate's code reads the refused
%% authority's **balance**, and warm is 100 where cold is 2,600. The balance itself
%% is irrelevant to what the frame computes, which is what makes it a clean probe.
%%
%% Two transactions, differing in **one thing**: which address the refused tuple
%% names. Both tuples are refused (both claim nonce 7; neither account is at 7), so
%% both transactions leave the post-state identical and the *only* difference is
%% whether the account the frame reads was warmed. 2,500 is that gap and nothing
%% else produces it.
a_refused_authorization_still_warms_its_authority_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Me = addr_of(Priv),
        %% PUSH20 <Me> BALANCE POP STOP -- the delegate reads the authority.
        Prog = <<16#73, Me/binary, 16#31, 16#50, 16#00>>,
        ?assertEqual(24, byte_size(Prog)),
        Base = delegated(put_code(eth_state:new(0, #{}), ?DELEGATE, Prog, 0)),
        Warm = gas_of_auth(Base, refused_authorization(Me, Priv)),
        %% **Signed by a different key**, and that is the whole content of the
        %% control. The authority is the account that *signed*, not the tuple's
        %% `address' field -- the field is the delegation **target**, and the two are
        %% different addresses. The first version signed both tuples with `Priv', so
        %% both recovered to `Me', both arms warmed it, and both came back at
        %% **46,105** -- the warm figure, twice. So the control was not a control at
        %% all: it varied the field that step 4 does not read.
        %%
        %% This is worth stating on its own, because it is a distinction a test can
        %% lose silently: an implementation that warmed the tuple's `address' would
        %% pass a test that signs with the same key and fail this one.
        Other = eth_secp256k1:generate_key(),
        Cold = gas_of_auth(Base, refused_authorization(?OTHER, Other)),
        ?assertEqual({want, 2500, Warm, Cold},
                     {want, element(1, Cold) - element(1, Warm), Warm, Cold})
    end).

%% **The control, and it is an absolute rather than a comparison.** A type-2
%% transaction has no authorization list, so nothing is warmed and the frame's
%% `BALANCE' is cold. The figure is pinned outright and decomposed:
%%
%%     21,000  intrinsic
%%     +    3  PUSH20
%%     + 2,600  BALANCE, cold
%%     +    2  POP
%%     = 23,605
%%
%% The first version compared this against a **type-4** arm and asserted a 2,500
%% gap, which measured **-22,500**: the two transaction types differ by EIP-7702's
%% 25,000 authorization price, so the comparison was mostly that. **A control that
%% crosses a difference the subject does not have in common measures the
%% difference.** The 2,500 comparison is the previous test's job and it is done
%% there with two transactions of the *same* type.
a_transaction_with_no_authorization_list_leaves_the_account_cold_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Me = addr_of(Priv),
        Prog = <<16#73, Me/binary, 16#31, 16#50, 16#00>>,
        Base = delegated(put_code(eth_state:new(0, #{}), ?DELEGATE, Prog, 0)),
        {Block, _} = run({tx_to(?ACCOUNT, #{}), Base}),
        [Receipt] = eth_block:receipts(Block),
        ?assertEqual(1, maps:get(<<"status">>, Receipt)),
        ?assertEqual({want, 21000 + 3 + 2600 + 2},
                     {want, maps:get(<<"gasUsed">>, Receipt)})
    end).

%% A tuple that is **refused**: it names `Address' and claims nonce 7, and no
%% account in these fixtures is at nonce 7. The signature is over *this* tuple's own
%% preimage -- chain id, address, nonce 7 -- or recovery would name a different
%% authority and the test would measure the wrong warm set.
refused_authorization(Address, Priv) ->
    Nonce = 7,
    Digest = eth_keccak:hash(<<16#05, (eth_rlp:encode(
                   [eth_fork_schedule:chain_id(), Address, Nonce]))/binary>>),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    #{<<"chainId">> => eth_hex:encode_int(eth_fork_schedule:chain_id()),
      <<"address">> => eth_hex:encode_bytes(Address),
      <<"nonce">> => eth_hex:encode_int(Nonce),
      <<"yParity">> => eth_hex:encode_int(V),
      <<"r">> => eth_hex:encode_int(R),
      <<"s">> => eth_hex:encode_int(S)}.

%% **The destination is `?ACCOUNT`, stated rather than inherited.** `set_code_tx/2`'s
%% default `to' is `?OTHER', which is codeless, so the first version of this helper
%% sent the transaction to an account with no code and the frame ran nothing: both
%% arms came back at **exactly** 46,000, the intrinsic and nothing else, with
%% `status = 1'. A gas figure that is exactly the intrinsic is a frame that did not
%% run, and it read as a difference of zero rather than as a broken fixture.
gas_of_auth(State, Auth) ->
    To = #{<<"to">> => eth_hex:encode_bytes(?ACCOUNT)},
    {Block, _} = run({sign(set_code_tx([Auth], To), ?SENDER_PRIV), State}),
    [Receipt] = eth_block:receipts(Block),
    {maps:get(<<"gasUsed">>, Receipt), maps:get(<<"status">>, Receipt),
     eth_state:storage(State, ?ACCOUNT, 0)}.

%% ---------------------------------------------------------------------------
%% The resolution's own gas
%% ---------------------------------------------------------------------------

%% "If a code executing instruction accesses a cold account during the resolution
%% of delegated code, add an additional EIP-2929 `COLD_ACCOUNT_READ_COST` cost of
%% 2600 gas ... Otherwise, assess a `WARM_STORAGE_READ_COST` cost of 100."
%%
%% Asserted as a **difference between two runs** rather than an absolute figure, and
%% that is the point: a difference of exactly 2600 cannot be produced by any pair of
%% gas totals in which the term is absent, present-but-wrong, or applied to the
%% wrong account. An absolute assertion here would be satisfiable by a wrong figure
%% that happened to cancel against something else.
resolving_a_cold_delegate_costs_an_extra_2600_test() ->
    with_ctx(fun() ->
        %% The caller CALLs ?ACCOUNT, which is delegated. One run with the
        %% delegation and one without; the only difference is the resolution.
        WithIt = gas_of(delegated(put_code(eth_state:new(0, #{}),
                                           ?DELEGATE, sstore1(), 0))),
        Without = gas_of(put_code(eth_state:new(0, #{}), ?ACCOUNT, sstore1(), 0)),
        ?assertEqual({want, 2600, WithIt, Without}, {want, WithIt - Without, WithIt, Without})
    end).

%% **The warm half of the same rule.** The delegate is reached *first*, by a
%% `BALANCE` in the same frame, so the resolution finds it warm and the term is
%% 100 rather than 2,600. The pair differs in one opcode's presence and the
%% resolution's figure is the only thing that moves.
%%
%% **The first attempt warmed it with an EIP-2930 access list**, which is the
%% obvious way and does not work on this node: `eth_evm:access_list_access/2`
%% folds the list into `{warm_store, Addr, Slot}` entries and **never adds the
%% address to `accessed_addresses`**, so the list was charged 2,400 of intrinsic
%% gas and warmed nothing. Measured: the "warm" arm came out **2,400 more** than
%% the cold one, and the difference was the access list's own price.
%%
%% That is a real defect in its own right, in a different EIP, and it is recorded
%% as an open item rather than fixed here -- a commit that fixes EIP-7702's
%% delegation and EIP-2930's warm set is two commits. Named in `AGENTS.md`.
resolving_a_warm_delegate_costs_an_extra_100_test() ->
    with_ctx(fun() ->
        Cold = gas_of(delegated(put_code(eth_state:new(0, #{}),
                                         ?DELEGATE, sstore1(), 0)), cold),
        Warm = gas_of(delegated(put_code(eth_state:new(0, #{}),
                                         ?DELEGATE, sstore1(), 0)), warm),
        %% **+105, and every part of it is accounted for.** The warm arm pays:
        %%   2,600 to `BALANCE' the delegate cold (the access cost), plus 100 for the
        %%   resolution, plus 5 for the two extra opcodes the cold arm does not have
        %%   (`PUSH20` is 3, `POP` is 2).
        %% The cold arm pays 2,600 for the resolution and nothing else.
        %%   2,600 + 100 + 5 - 2,600 = **105**.
        %%
        %% Written the other way round -- "the resolution saved 2,500" -- the number
        %% is 2,500 and it is *not* what the two runs differ by, because the warm arm
        %% had to pay 2,600 to do the warming. The first version asserted 2,500 and
        %% measured -105. Asserting a *saving* where a *difference* is observable is
        %% the same shape as asserting a component of a sum and getting the total.
        %%
        %% And the decomposition is what makes it strong: a node with **no** term at
        %% all differs by 2,605; one that charged the cold figure twice differs by
        %% -2,495; one that ignored warmth differs by -2,600 + 5. Only 2,600-then-100
        %% gives 105.
        ?assertEqual({want, 105, Cold, Warm}, {want, Warm - Cold, Cold, Warm})
    end).

%% The two prices the rule states, as a unit assertion on the one function that
%% owns them. The integration test above cannot say *which* figure is wrong -- only
%% that the two differ by 2,500 -- so the figures themselves need a home.
the_resolution_costs_2600_cold_and_100_warm_at_prague_test() ->
    ?assertEqual(2600, eth_fork_schedule:delegation_resolution_cost(prague, false)),
    ?assertEqual(100, eth_fork_schedule:delegation_resolution_cost(prague, true)),
    %% **Zero before Berlin**, because the warm/cold split is EIP-2929's and the
    %% EIP quotes its figures. Unreachable in practice -- a designator can only be
    %% written from Prague -- and zero is the honest answer for the forks that
    %% cannot have one.
    ?assertEqual(0, eth_fork_schedule:delegation_resolution_cost(istanbul, false)),
    ?assertEqual(0, eth_fork_schedule:delegation_resolution_cost(frontier, true)).

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

%% `PUSH1 1 PUSH1 0 SSTORE STOP` -- write 1 to the *executing account's* slot 0.
sstore1() -> <<16#60, 1, 16#60, 0, 16#55, 16#00>>.

%% A contract that CALLs `To` with no arguments and no value, and stores the
%% success flag at its own slot 0.
%%
%% **Built, not typed.** Every immediate is a `PUSH` whose opcode and width are
%% *computed* from the value, because a hand-written two-hex-digit literal in a
%% default 8-bit segment is one byte -- the trap this repository has now paid for
%% five times in a single commit. `push/1` cannot truncate, so neither can anything
%% built on it.
call_code(To, Gas) -> iolist_to_binary(call_parts(To, Gas, 0)).

%% Touch `Warm` first, so the frame's `accessed_addresses` already holds it.
warm_then_call(Warm, To, Gas) ->
    iolist_to_binary([<<16#73, Warm/binary>>, <<16#31, 16#50>>,     % PUSH20; BALANCE; POP
                      call_parts(To, Gas, 0)]).

%% Store the call's `RETURNDATASIZE` at slot 0 rather than its success flag. A
%% success flag cannot tell "empty code" from "a precompile that happened to
%% succeed", and this node's `ecrecover` with no calldata *does* succeed -- which
%% is why the first version of the precompile test asserted a flag the fixture
%% could not move. Return-data **size** is the EIP's own observable: empty code
%% returns `b""`, and a precompile returns its output.
call_retdatasize_code(To, Gas, ArgsLen) ->
    iolist_to_binary(call_parts(To, Gas, ArgsLen) ++
                     [<<16#3d, 16#60, 0, 16#55, 16#00>>]).   % RETURNDATASIZE; PUSH1 0; SSTORE; STOP

%% `ArgsLen` is an **integer**, not the one-byte binary it is pushed as. The
%% first version took the binary and wrote `<<Tail:8>>`, which is a construction
%% segment -- it raised `badarg` on a binary, in the fixture, before the node saw
%% anything. A function that takes "the value" and is handed "the encoding of the
%% value" is a question about arity that reads as a type error.
call_parts(To, Gas, ArgsLen) ->
    P = fun(N) -> push(N) end,
    %% **`iolist_to_binary/1`, not `lists:flatten/1`.** The list is a list of
    %% *binaries*, and `lists:flatten/1` flattens a nested list -- so it hands back
    %% a **flat list of integers** where a binary belongs. It compiles, the fixture
    %% is built without complaint, and the failure surfaces four frames away as an
    %% exception inside the interpreter, which `run_frame/5`'s `catch` turns into
    %% "the frame consumed everything": `gasUsed` came back as exactly the
    %% transaction's gas **limit**, 1,000,000, in both arms of the gas test, and
    %% their difference was a very confident 0.
    %%
    %% The tell was that the two figures were *equal to the limit* rather than
    %% merely equal -- a gas difference of zero is a measurement, a gas figure
    %% pinned to the ceiling is a frame that never returned. And two other tests in
    %% this module were **passing** on the same broken fixture, because they assert
    %% "the slot is 0" and a frame that ran nothing also leaves it 0.
    [P(<<0>>),                     % retLength
     P(<<0>>),                     % retOffset
     P(<<ArgsLen:8>>),            % argsLength
     P(<<0>>),                     % argsOffset
     P(<<0>>),                     % value
     <<16#73, To/binary>>,         % to   (PUSH20)
     P(<<Gas:256>>),               % gas
     <<16#f1>>].                   % CALL

push(Bin) when is_binary(Bin), byte_size(Bin) >= 1, byte_size(Bin) =< 32 ->
    <<(16#5F + byte_size(Bin)), Bin/binary>>.

%% `?ACCOUNT` carries a designator pointing at `?DELEGATE`, and `?DELEGATE` holds
%% whatever the fixture put there.
delegated(State) ->
    eth_state:set_code(State, ?ACCOUNT,
                       eth_tx:delegation_indicator(?DELEGATE)).

%% Everything below answers `{Tx, State}' and `run/1' takes that shape, so a
%% fixture can never lose its pre-state by returning a bare transaction. The first
%% draft of this file had `to_account/2` return a `Tx` and `to_other/2` return a
%% `{Tx, State}`, so half the tests ran against an empty trie and the other half
%% against theirs -- and the ones that ran against an empty trie were the ones
%% whose subject is a *delegation*, so they failed for a reason three steps from
%% the reason. **Two shapes for one concept, where the wrong one is silent.**
to_account(State, Addr) ->
    {tx_to(Addr, #{}), State}.

%% **Signed, because `eth_block:run_transaction/5` requires a recoverable sender
%% and answers `{error, {cannot_finalize, unrecoverable_sender}}` without one.**
%% All thirteen of this module's tests failed on that before it was signed, which
%% is the useful shape of the failure: it named the missing precondition rather
%% than reporting a wrong balance, so nothing had to be inferred.
tx_to(Addr, Extra) ->
    sign((set_code_tx([], Extra))#{<<"to">> => eth_hex:encode_bytes(Addr),
                                   <<"type">> => <<"0x2">>}, ?SENDER_PRIV).

%% **A bare `Tx`, not `{Tx, State}'.** The first version returned a tuple because
%% every other fixture helper does, and `run_tx/2` then took the *tuple* as the
%% transaction: `{badmap, <<1,1,1,...>>}` -- the `?SENDER_PRIV` binary, reported
%% against a badmap from four frames away. **The convention had become the
%% exception's subject.** A uniform return shape is worth having, but not at the
%% cost of one helper being unable to use it.
from_me(To, Nonce, _Addr, Priv) ->
    Base = (set_code_tx([], #{}))#{<<"to">> => eth_hex:encode_bytes(To),
                                   <<"nonce">> => eth_hex:encode_int(Nonce),
                                   <<"type">> => <<"0x2">>},
    {ok, <<TypeByte, Rest/binary>>} = eth_tx:to_rlp(Base),
    {ok, Items, <<>>} = eth_rlp:decode(Rest),
    {Preimage, _Sig} = lists:split(length(Items) - 3, Items),
    Digest = eth_keccak:hash(<<TypeByte, (eth_rlp:encode(Preimage))/binary>>),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    Base#{<<"v">> => eth_hex:encode_int(V),
          <<"r">> => eth_hex:encode_int(R),
          <<"s">> => eth_hex:encode_int(S)}.

%% Run the caller fixture and answer the transaction's `gasUsed`. `cold` and
%% `warm` select whether the caller touches `?DELEGATE` before the CALL; there is
%% **no access-list arm**, for the reason given in the warm test.
gas_of(State) -> gas_of(State, cold).

gas_of(State, How) ->
    {Block, _} = run(to_other(State, How)),
    [Receipt] = eth_block:receipts(Block),
    maps:get(<<"gasUsed">>, Receipt).

to_other(State, How) ->
    Caller = case How of
                 cold -> call_code(?ACCOUNT, 100000);
                 warm -> warm_then_call(?DELEGATE, ?ACCOUNT, 100000)
             end,
    St = put_code(State, ?OTHER, Caller, 0),
    {tx_to(?OTHER, #{}), St}.

%% `gasUsed` for a transaction whose `to' is `To`, against `State'.
%% `gasUsed` for a caller at `?OTHER` that CALLs `To`.
gas_of_call(State, To) ->
    {Block, _} = run({tx_to(?OTHER, #{}),
                      put_code(State, ?OTHER, call_code(To, 100000), 0)}),
    [Receipt] = eth_block:receipts(Block),
    maps:get(<<"gasUsed">>, Receipt).

gas_of_tx(State, To) ->
    {Block, _} = run({tx_to(To, #{}), State}),
    [Receipt] = eth_block:receipts(Block),
    maps:get(<<"gasUsed">>, Receipt).

fund(State, Addr, Amount) -> eth_state:set_balance(State, Addr, Amount).


run({Tx, State}) -> run_tx(Tx, State).

run_tx(Tx, State) ->
    %% Both arguments asserted, because the failure this was added for named
    %% neither: a `{badmap, ...}' whose argument was a **one-element tuple holding
    %% the transaction**, printed by `eth_block:run_transaction/5` four frames away,
    %% so the trace showed the map *inside* the tuple and not the tuple's own
    %% construction. Two one-line checks turn that into a sentence.
    ?assert(is_map(Tx)),
    ?assert(is_map(State)),
    Block0 = (eth_block:new(<<0:256>>, ?PRAGUE_BLOCK))
                 #block{base_fee_per_gas = ?GWEI, miner = ?MINER},
    eth_block:run_transaction(Block0, Tx, State, ?GWEI, 2000000).

set_code_tx(Auths, Extra) ->
    maps:merge(#{<<"type">> => <<"0x4">>,
                 <<"chainId">> => eth_hex:encode_int(eth_fork_schedule:chain_id()),
                 <<"nonce">> => <<"0x0">>,
                 <<"maxPriorityFeePerGas">> => <<"0x1">>,
                 <<"maxFeePerGas">> => eth_hex:encode_int(2 * ?GWEI),
                 <<"gas">> => eth_hex:encode_int(1000000),
                 <<"to">> => eth_hex:encode_bytes(?OTHER),
                 <<"value">> => <<"0x0">>,
                 <<"input">> => <<"0x">>,
                 <<"accessList">> => [],
                 <<"authorizationList">> => Auths}, Extra).

authorization(Address, Nonce, Priv) ->
    Digest = eth_keccak:hash(<<16#05, (eth_rlp:encode(
                   [eth_fork_schedule:chain_id(), Address, Nonce]))/binary>>),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    #{<<"chainId">> => eth_hex:encode_int(eth_fork_schedule:chain_id()),
      <<"address">> => eth_hex:encode_bytes(Address),
      <<"nonce">> => eth_hex:encode_int(Nonce),
      <<"yParity">> => eth_hex:encode_int(V),
      <<"r">> => eth_hex:encode_int(R),
      <<"s">> => eth_hex:encode_int(S)}.

%% The transaction's own preimage is **derived from `eth_tx:to_rlp/1'`** by
%% splitting the last three items off, never written out by hand: a hand-written
%% preimage is a second copy of the node's signer beside the test, and the two
%% differ quietly.
sign(Tx, Priv) ->
    {ok, <<TypeByte, Rest/binary>>} = eth_tx:to_rlp(Tx),
    {ok, Items, <<>>} = eth_rlp:decode(Rest),
    {Preimage, _Sig} = lists:split(length(Items) - 3, Items),
    Digest = eth_keccak:hash(<<TypeByte, (eth_rlp:encode(Preimage))/binary>>),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    Tx#{<<"v">> => eth_hex:encode_int(V),
        <<"r">> => eth_hex:encode_int(R),
        <<"s">> => eth_hex:encode_int(S)}.

put_code(State, Addr, Code, Nonce) ->
    eth_state:set_nonce(eth_state:set_code(State, Addr, Code), Addr, Nonce).

addr_of(Priv) ->
    binary:part(eth_keccak:hash(eth_secp256k1:node_id(Priv)), 12, 20).

with_ctx(Fun) ->
    _ = eth_test_util:start_apps(),
    case whereis(eth_mpt) of
        undefined -> {ok, _} = eth_mpt:start_link();
        _ -> ok
    end,
    lists:foreach(fun(F) -> file:delete(F) end,
                  filelib:wildcard(filename:join(eth_test_util:tmp_dir(), "*"))),
    Previous = eth_state:base_source(),
    ok = eth_state:set_base_source(mpt),
    ok = eth_mpt:put_account(addr_of(?SENDER_PRIV), 1000000 * ?GWEI, 0,
                             eth_keccak:hash(<<>>)),
    try Fun()
    after
        _ = eth_state:set_base_source(Previous),
        lists:foreach(fun(F) -> file:delete(F) end,
                      filelib:wildcard(filename:join(eth_test_util:tmp_dir(), "*")))
    end.

