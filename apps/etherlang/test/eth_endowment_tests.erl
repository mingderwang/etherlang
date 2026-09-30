%% The value a **contract-creation transaction** carries, and the rollback that
%% belongs with it.
%%
%% Two rules, one commit, because either alone is a partial change:
%%
%%   1. A create transaction's endowment moves. `eth_block:begin_transaction/8'
%%      transferred on its `IsCreate = false' arm and did not transfer at all on
%%      the `true' arm -- where `Target' is *already* the contract address. So the
%%      sender was never debited and the new contract never credited. EELS moves it
%%      in `process_message/1', which `process_create_message/1' calls like any
%%      other message.
%%   2. A frame that reverts or halts exceptionally leaves nothing behind. EELS
%%      takes `snapshot = copy_tx_state(tx_state)' **before** the value move and
%%      calls `restore_tx_state/2' on `evm.error' -- and the `except Revert' arm
%%      sets `evm.error' too. `run_t/10' takes no snapshot at any arity, so
%%      `run_transaction/5' was handed the evolved state for a revert.
%%
%% Everything here goes through `eth_block:run_transaction/5' -- the production
%% path -- because rule 2 lives in `eth_block', not in `eth_evm'. A probe against
%% `eth_evm' found the missing rollback, and a unit test there would have passed
%% with `eth_block' still broken: the AGENTS.md §4.4 "who calls this?" failure in
%% its quietest form.
-module(eth_endowment_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("etherlang/include/eth_block.hrl").

-define(GWEI, 1000000000).

%% Past Prague on every network this repository knows, so `eth_block:fork_of/1'
%% answers `prague' and a 1559 transaction is available at all.
-define(PRAGUE_BLOCK, 20000000).

%% **With an explicit 256-bit width.** A bare 64-hex-digit literal in a segment
%% whose default integer width is 8 bits truncates to `<<1>>' silently, at compile
%% time, and the recovered sender is then not the account the test funded -- the
%% symptom is a balance that never moves. AGENTS.md §10a, byte-width trap.
-define(SENDER_PRIV, <<16#0101010101010101010101010101010101010101010101010101010101010101:256>>).
-define(MINER, <<16#be:160>>).

%% **`eth_secp256k1:node_id/1` is the 64-byte uncompressed public key, not the
%% address.** Naming it "node id" is a discv4 name, and this module took it for the
%% account -- so every test funded and signed for one account while
%% `eth_tx:sender/1` recovered another, and the `?assertEqual({ok, From},
%% eth_tx:sender(Tx))' guard in `run/3' caught it. **That guard is the only reason
%% this was a loud failure and not five green tests about an account nobody
%% transacted from** -- the AGENTS.md §10a note about a helper that draws its own
%% key, arrived at from the other direction.
sender() ->
    binary:part(eth_keccak:hash(eth_secp256k1:node_id(?SENDER_PRIV)), 12, 20).
funded() -> 1000000 * ?GWEI.

%% ---------------------------------------------------------------------------
%% Rule 1: the endowment moves
%% ---------------------------------------------------------------------------

%% The corpus found this as **10,374 diverging entries** -- every one of
%% `static/state_tests/stTimeConsuming', which is `sstore_combinations_*', and
%% every one of those carries `value: "0x01"' -- and the arithmetic closes on a
%% pre-state of 1,000,000,000,000 at a `gasPrice' of 10:
%%
%%   fixture  sender ends 999,995,752,129   4,247,872 out = 424,787 x 10 + 1
%%   node     sender ends 999,995,550,160   4,449,840 out = 444,984 x 10 + 0
%%
%% **No wei was created or destroyed** -- conservation held on both sides and the
%% divergence was an absent transfer, not a lost balance. An earlier note in
%% `TASKS.md' said the value "leaves the sender and does not arrive", which is the
%% opposite of what the arithmetic says, and the two would have wanted different
%% fixes.
%%
%% The assertion is on **both** sides of the move. A test checking only the sender
%% cannot tell a transfer from a deletion, and a test checking only the recipient
%% passes on a mint.
a_create_transaction_endows_the_new_contract_test() ->
    with_ctx(fun() ->
        From = sender(),
        Value = 1000,
        {ok, _Block, State} = run(create_tx(Value, <<16#00>>), From),
        Addr = created_address(From, 0),
        ?assert(eth_state:exists(State, Addr)),
        ?assertEqual(Value, eth_state:balance(State, Addr)),
        ?assertEqual(1, eth_state:nonce(State, Addr)),
        %% The sender's debit is asserted as a *delta*, not an absolute, because
        %% gas is charged too and is not the rule under test. A fixed number here
        %% would be a restatement of the gas schedule, which is the thing §4.5 warns
        %% about by way of the unspent-gas test that argued for its own defect.
        ?assert(funded() - eth_state:balance(State, From) >= Value)
    end).

%% **A create transaction with no endowment leaves a contract with a zero balance** --
%% and this test's first version asserted that no account existed at all, which is
%% wrong and was caught by running it rather than by reading it. The init code is a
%% single `STOP`, so the create **succeeds**: EIP-161 (a) gives the new contract
%% nonce 1 (landed in `v1.67'), and an account with a nonce is not empty, so EIP-161
%% (c) has nothing to say about it. The account exists; what must be zero is its
%% **balance**, because the endowment was nothing.
%%
%% The pair is worth having because the two rules meet on one account and pull in
%% opposite directions: (a) insists it exists, (c) would delete it if it were empty,
%% and only the nonce is what makes those compatible.
a_create_transaction_with_no_endowment_leaves_a_zero_balance_test() ->
    with_ctx(fun() ->
        From = sender(),
        {ok, _, State} = run(create_tx(0, <<16#00>>), From),
        Addr = created_address(From, 0),
        ?assertEqual(0, eth_state:balance(State, Addr)),
        ?assertEqual(1, eth_state:nonce(State, Addr))
    end).

%% **The control that belongs to `transfer/4`'s zero arm**, which is the test above
%% turned out not to be: EIP-161 (c) is about a *transfer* to an account that does
%% not exist, not about a contract the create instruction made. A zero-value call to
%% an address with no code and no balance must leave that address non-existent --
%% "No account may change state from non-existent to existent-but-*empty*. If an
%% operation would do this, the account SHALL instead remain non-existent."
%%
%% `eth_block:transfer/4`'s `{0, _} -> drop_if_empty(S2, To)' arm is what guarantees
%% it. Without this test the arm is unexercised, and a `transfer/4` that wrote both
%% balances unconditionally would pass everything above.
a_zero_value_call_does_not_create_the_account_test() ->
    with_ctx(fun() ->
        From = sender(),
        Absent = <<16#ca:160>>,
        {ok, _, State} = run(call_tx(Absent, 0), From),
        ?assertEqual(0, eth_state:balance(State, Absent)),
        ?assertNot(eth_state:exists(State, Absent))
    end).

%% ---------------------------------------------------------------------------
%% Rule 2: a reverted frame leaves nothing behind
%% ---------------------------------------------------------------------------

%% **This is the test that makes rule 1 unsafe to land alone.** A create whose init
%% code reverts must not keep the endowment: EELS snapshots *before* `move_ether',
%% so the transfer is undone along with the frame's writes.
%%
%% The control is a create whose init code **returns** instead, and the two differ
%% in one byte -- `RETURN' against `REVERT' -- over the same ten-byte init code. A
%% balance of 0 passes for the wrong reason if the deploying arm also shows 0, so
%% the deploying arm is asserted first and the `RETURN'/`REVERT'` pair is checked to
%% differ in exactly one byte before either is used.
a_reverted_create_transaction_does_not_keep_the_endowment_test() ->
    with_ctx(fun() ->
        From = sender(),
        Value = 1000,
        Reverting = word_revert(),
        Returning = word_return(),
        ?assertEqual(byte_size(Reverting), byte_size(Returning)),
        ?assertEqual(1, count_differences(Returning, Reverting)),
        {ok, _, Kept} = run(create_tx(Value, Returning), From),
        {ok, _, Lost} = run(create_tx(Value, Reverting), From),
        Addr = created_address(From, 0),
        ?assertEqual(Value, eth_state:balance(Kept, Addr)),
        ?assertEqual(1, eth_state:nonce(Kept, Addr)),
        ?assertEqual(0, eth_state:balance(Lost, Addr)),
        ?assertNot(eth_state:exists(Lost, Addr))
    end).

%% The same rollback for an ordinary call: a callee that writes a slot and then
%% reverts leaves the slot as it was. **The `STOP' arm is the control and is
%% asserted first**, because "the slot is 0" is also what a node that ran no code at
%% all would answer -- the trap this repository has paid for twice in one module.
a_reverting_call_transaction_rolls_back_the_callees_writes_test() ->
    with_ctx(fun() ->
        From = sender(),
        Callee = ?MINER,
        Base = eth_state:set_nonce(eth_state:new(0, #{}), Callee, 1),
        {ok, _, Kept} = run(call_tx(Callee, 0), From, write_code(Callee, <<16#00>>, Base)),
        {ok, _, Reverted} = run(call_tx(Callee, 0), From,
                                write_code(Callee, <<16#60,0,16#60,0,16#FD>>, Base)),
        ?assertEqual(7, eth_state:storage(Kept, Callee, 0)),
        ?assertEqual(0, eth_state:storage(Reverted, Callee, 0))
    end).

%% The value does not move when the callee reverts: the caller's money stays with
%% the caller. Separate from the storage assertion above because it is a different
%% account and a different clause -- EELS snapshots before `move_ether', so a
%% reverted `CALL' returns the value as well as the state.
a_reverting_call_transaction_does_not_move_the_value_test() ->
    with_ctx(fun() ->
        From = sender(),
        Callee = ?MINER,
        Base = eth_state:set_nonce(eth_state:new(0, #{}), Callee, 1),
        Value = 777,
        {ok, _, Reverted} = run(call_tx(Callee, Value), From,
                                write_code(Callee, <<16#60,0,16#60,0,16#FD>>, Base)),
        {ok, _, Kept} = run(call_tx(Callee, Value), From,
                            write_code(Callee, <<16#00>>, Base)),
        ?assertEqual(0, eth_state:balance(Reverted, Callee)),
        %% The control: the same call with a `STOP' callee *does* deliver it. Without
        %% this the first assertion also passes on a node that never transfers on any
        %% call -- which is the pre-fix behaviour, so it would be a green test for a
        %% defect this commit did not fix.
        ?assertEqual(Value, eth_state:balance(Kept, Callee))
    end).

%% ---------------------------------------------------------------------------
%% Fixtures
%% ---------------------------------------------------------------------------

%% `PUSH1 7, PUSH1 0, SSTORE` then <Tail>. Three bytes of prefix, so `Tail` starts
%% at code offset 8 -- **matched by construction here**, since the prefix is written
%% out; the byte-width trap one level up would be a `PUSH1' silently becoming a
%% `PUSH2' and `Tail' being decoded as part of an immediate.
write_code(Addr, Tail, State) ->
    eth_state:set_code(State, Addr, <<16#60, 7, 16#60, 0, 16#55, Tail/binary>>).

%% Ten-byte init codes differing in **one byte**: `RETURN' against `REVERT'. Both
%% deal with 32 bytes of memory holding 42, so the pair agrees on what the revert
%% payload would have been -- which is not asserted, and it is said here because that
%% coincidence is the reason the pair is a clean control.
word_return() -> <<16#60, 16#2a, 16#60, 0, 16#52, 16#60, 32, 16#60, 0, 16#F3>>.
word_revert() -> <<16#60, 16#2a, 16#60, 0, 16#52, 16#60, 32, 16#60, 0, 16#FD>>.

%% How many byte positions two equal-length binaries differ in. Length is asserted by
%% the caller: `lists:zip/2' truncates to the shorter, so a length difference would
%% report a small number rather than fail.
count_differences(A, B) ->
    length([X || {X, Y} <- lists:zip(binary_to_list(A), binary_to_list(B)), X =/= Y]).

%% `keccak(rlp([sender, nonce]))[12:]' with the **pre-transaction** nonce. This is a
%% second implementation of the create-address rule and that is a hazard worth
%% naming: the address is what the endowment is credited to, so if it were wrong the
%% balance assertion would read as "the endowment did not move" when it means "the
%% test looked at the wrong account". It is derived from the same rule EELS and
%% `eth_block` use, and pinned here by the fact that the two tests above assert a
%% real balance *and* a nonce of 1 at it -- a wrong address has neither.
created_address(From, Nonce) ->
    <<_:12/binary, Addr:20/binary>> = eth_keccak:hash(eth_rlp:encode([From, Nonce])),
    Addr.

%% ---------------------------------------------------------------------------
%% Transactions
%% ---------------------------------------------------------------------------

%% A **type-2** transaction, so the `to_rlp/1'-split-last-three signing below is
%% valid. EIP-155 puts the chain id in a *legacy* transaction's `v', so for that
%% format the RLP item list and the sighash item list disagree in their last three
%% slots and the split would sign the wrong preimage.
create_tx(Value, InitCode) ->
    tx(#{<<"to">> => <<>>,
          <<"value">> => eth_hex:encode_int(Value),
          <<"input">> => eth_hex:encode_bytes(InitCode),
          <<"gas">> => eth_hex:encode_int(1000000)}).

%% The callee's **code** is not a transaction field -- it is state, so it goes in the
%% state the test builds. Putting it here would have been a second thing to get wrong
%% in a fixture whose subject is the rollback.
call_tx(To, Value) ->
    tx(#{<<"to">> => eth_hex:encode_bytes(To),
          <<"value">> => eth_hex:encode_int(Value),
          <<"gas">> => eth_hex:encode_int(1000000)}).

tx(Fs) ->
    Base = #{<<"nonce">> => eth_hex:encode_int(0),
             <<"maxPriorityFeePerGas">> => eth_hex:encode_int(0),
             <<"maxFeePerGas">> => eth_hex:encode_int(?GWEI),
             <<"chainId">> => eth_hex:encode_int(eth_fork_schedule:chain_id()),
             <<"value">> => eth_hex:encode_int(0),
             <<"input">> => <<"0x">>},
    maps:merge(Base, Fs).

%% **The preimage comes from `eth_tx:to_rlp/1'**, split by dropping the last three
%% items, and the signature is then *checked* with `eth_tx:sender/1'. A hand-written
%% preimage would be a second copy of `eth_tx:sighash/1' beside the test, and the two
%% differ quietly -- which is how a fixture ends up passing for the wrong reason.
sign(Tx, Priv) ->
    {ok, <<_Type, Rest/binary>>} = eth_tx:to_rlp(Tx),
    {ok, Items, <<>>} = eth_rlp:decode(Rest),
    {Preimage, _Sig} = lists:split(length(Items) - 3, Items),
    Digest = eth_keccak:hash(<<16#02, (eth_rlp:encode(Preimage))/binary>>),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    Tx#{<<"v">> => eth_hex:encode_int(V),
        <<"r">> => eth_hex:encode_int(R),
        <<"s">> => eth_hex:encode_int(S)}.

%% Through `eth_block:run_transaction/5', the production path. **No test here asserts
%% a `gasUsed'.** The gas is not either rule, and a number in a fixture is a
%% restatement of the schedule that will fail for an unrelated reason and read as a
%% failure of the thing under test.
run(Tx0, From) -> run(Tx0, From, eth_state:new(0, #{})).

run(Tx0, From, State) ->
    Tx = sign(Tx0, ?SENDER_PRIV),
    %% The recovered sender must be the funded account, or every balance assertion in
    %% this module is about an account nobody transacted from and reads as "the node
    %% moved nothing" -- which is exactly the bug under test.
    ?assertEqual({ok, From}, eth_tx:sender(Tx)),
    Block0 = (eth_block:new(<<0:256>>, ?PRAGUE_BLOCK))
                 #block{base_fee_per_gas = ?GWEI, miner = ?MINER},
    {Block, State1} = eth_block:run_transaction(Block0, Tx, State, ?GWEI, 1000000),
    {ok, Block, State1}.

with_ctx(Fun) ->
    _ = eth_test_util:start_apps(),
    case whereis(eth_mpt) of
        undefined -> {ok, _} = eth_mpt:start_link();
        _ -> ok
    end,
    Previous = eth_state:base_source(),
    ok = eth_state:set_base_source(mpt),
    ok = eth_mpt:put_account(sender(), funded(), 0, eth_keccak:hash(<<>>)),
    try Fun()
    after
        _ = eth_state:set_base_source(Previous)
    end.
