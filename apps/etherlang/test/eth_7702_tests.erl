%% EIP-7702: the authorization list as a **state transition**.
%%
%% This module exists because the transaction was fully priced and structurally
%% validated and then executed as though it carried no authorizations at all.
%% Everything here goes through `eth_block:run_transaction/5' -- the production
%% path -- rather than calling `eth_block:process_authorizations/3' directly,
%% because a rule only the harness can reach is a fixture-only improvement: the
%% function would be correct and the node would still write no designators.
-module(eth_7702_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("etherlang/include/eth_block.hrl").

-define(GWEI, 1000000000).

%% A block number past Prague on every network this repository knows, so
%% `eth_block:fork_of/1' answers `prague' and a type-4 transaction is available
%% at all. `eth_fork_schedule:tx_type_available/2' refuses the type earlier, and a
%% fixture at Cancun would be refused for that reason -- a real result, answering
%% a rule that is not the one under test.
-define(PRAGUE_BLOCK, 20000000).

%% A **fixed** sender key, not `generate_key/0' on every call. The AGENTS.md §10a
%% note is the reason: a helper that draws its own key makes a test pass against
%% an account the test never funded, and the symptom is a balance that never
%% moves. `sign/2' is handed this key so the recovered sender is the one funded
%% in `with_ctx/1'.
%% **With an explicit 256-bit width**, which is the whole content of that
%% comment. Written as a bare literal this is 64 hex digits in a segment whose
%% default integer width is *8 bits*, so it truncates to the single byte `<<1>>` --
%% silently, at compile time, and `eth_secp256k1:node_id/1' then raises
%% `function_clause' naming neither the macro nor the key. That is AGENTS.md §10a's
%% byte-width trap, reached by writing the very thing it warns about.
-define(SENDER_PRIV, <<16#0101010101010101010101010101010101010101010101010101010101010101:256>>).

%% The block's coinbase, at 160 bits.
%%
%% **Every address below carries an explicit `:160', and that is not a style
%% choice.** A hex literal too wide for its segment's default 8-bit integer width
%% is truncated silently at compile time: `<<16#1000...0001>>' is `<<1>>', a valid
%% one-byte binary. Nothing is malformed, the number is just wrong, and the
%% failure surfaces four frames away in `eth_state:address/1''s `0x...' clause --
%% `hv/1' raising `function_clause', naming neither the literal nor the field.
%%
%% This file wrote all three of these bare, in the same edit, two lines below a
%% comment explaining the trap. That is worth more than the fix: **a comment
%% documenting a trap does not immunise the code beneath it.** The `<<1>>' then
%% became a `to' of `<<"0x01">>', a 19-byte-short address, and the trace pointed at
%% `eth_state:hv/1'.
-define(MINER, <<16#c0de:160>>).

-define(TO, <<16#1000000000000000000000000000000000000001:160>>).
-define(DELEGATE, <<16#2000000000000000000000000000000000000002:160>>).
-define(OTHER, <<16#3000000000000000000000000000000000000003:160>>).
-define(ZERO, <<0:160>>).

%% ---------------------------------------------------------------------------
%% The delegation state transition
%% ---------------------------------------------------------------------------

%% The corpus's own shape, restated: one tuple, one designator, one nonce bump,
%% and not one storage write. `prague/eip7702_set_code_tx/
%% test_intrinsic_gas_cost.json' is hundreds of these.
%%
%% The control is the sender's nonce, asserted as `Nonce - 1` -- a difference
%% rather than a value, because the sender's own bump is the one the node was
%% already doing correctly. A node that wrote the designator *and* skipped the
%% sender's bump would pass a test that asserted only the sender, and vice versa.
a_delegation_is_written_and_the_nonce_bumped_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Authority = addr_of(Priv),
        Tx = sign(set_code_tx([authorization(?DELEGATE, 0, Priv)]), ?SENDER_PRIV),
        {_, State1} = run(Tx),
        ?assertEqual(eth_tx:delegation_indicator(?DELEGATE),
                     eth_state:code(State1, Authority)),
        ?assertEqual(1, eth_state:nonce(State1, Authority)),
        %% The sender's own bump is untouched: the authorization bumped the
        %% *authority's* nonce, and these are two different accounts.
        ?assertEqual(0, eth_state:nonce(State1, addr_of(?SENDER_PRIV)) - 1)
    end).

%% Step 6's exception, and the reason the zero address is not a designator for
%% address zero: "If `address` is `0x0000000000000000000000000000000000000000`,
%% do not write the delegation indicator. Clear the account's code by resetting
%% the account's code hash to the empty code hash."
%%
%% The precondition is an account that is *already* delegated, in the same
%% transaction. A fresh EOA has nothing to clear, so this test would pass against
%% a node that never wrote a designator at all -- which is the node this commit
%% started from.
an_authorization_for_the_zero_address_clears_the_code_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Authority = addr_of(Priv),
        Tx = sign(set_code_tx([authorization(?DELEGATE, 0, Priv),
                               authorization(?ZERO, 1, Priv)]), ?SENDER_PRIV),
        {_, State1} = run(Tx),
        ?assertEqual(<<>>, eth_state:code(State1, Authority)),
        ?assertEqual(2, eth_state:nonce(State1, Authority))
    end).

%% Step 5: "Verify the nonce of `authority` is equal to `nonce`." A tuple whose
%% nonce is one ahead is skipped, and -- the half that matters -- the *next* tuple
%% in the list is still processed. "If any step above fails, immediately stop
%% processing the tuple and continue to the next tuple" is a rule about one tuple,
%% not about the list.
a_tuple_whose_nonce_does_not_match_is_skipped_and_the_next_one_applies_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Other = eth_secp256k1:generate_key(),
        Tx = sign(set_code_tx([authorization(?DELEGATE, 7, Priv),
                               authorization(?OTHER, 0, Other)]), ?SENDER_PRIV),
        {_, State1} = run(Tx),
        %% The first is skipped: no code, and the nonce did not move.
        ?assertEqual(<<>>, eth_state:code(State1, addr_of(Priv))),
        ?assertEqual(0, eth_state:nonce(State1, addr_of(Priv))),
        %% The second applied, which is the clause a `case' that *returned* on
        %% the first failure would have lost.
        ?assertEqual(eth_tx:delegation_indicator(?OTHER),
                     eth_state:code(State1, addr_of(Other)))
    end).

%% "Verify the code of `authority` is empty or already delegated" -- the first
%% disjunct's negation. An authority holding real code is skipped, so a
%% delegation can never overwrite a contract. This is the node's only defence
%% against a user handing their contract away in a type-4 transaction.
an_authority_with_real_code_is_skipped_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Authority = addr_of(Priv),
        Contract = <<16#60, 16#00, 16#60, 16#00, 16#fd>>,
        ?assertEqual(5, byte_size(Contract)),
        State0 = put_code(eth_state:new(0, #{}), Authority, Contract, 1),
        Tx = sign(set_code_tx([authorization(?DELEGATE, 1, Priv)]), ?SENDER_PRIV),
        {_, State1} = run_tx(Tx, State0),
        ?assertEqual(Contract, eth_state:code(State1, Authority)),
        ?assertEqual(1, eth_state:nonce(State1, Authority))
    end).

%% The second disjunct, the one that says `or`: an account already holding a
%% designator may be re-delegated, and the second destination *replaces* the
%% first. A node that read "already delegated" as "already final" would skip
%% this, and would then be unable to switch a wallet to a different signer --
%% the first thing anyone does with the feature.
an_authority_already_delegated_may_be_re_delegated_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Authority = addr_of(Priv),
        Tx = sign(set_code_tx([authorization(?DELEGATE, 0, Priv),
                               authorization(?OTHER, 1, Priv)]), ?SENDER_PRIV),
        {_, State1} = run(Tx),
        ?assertEqual(eth_tx:delegation_indicator(?OTHER),
                     eth_state:code(State1, Authority)),
        ?assertEqual(2, eth_state:nonce(State1, Authority))
    end).

%% Step 1: "Verify the chain id is either 0 or the current chain id." Zero is the
%% EIP's wildcard, so it must be *accepted* -- a validator that treated 0 as a
%% chain id to match would refuse every cross-chain-signed authorization, which
%% is the sponsorship case the EIP's motivation names.
an_authorization_for_chain_zero_is_applied_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Tx = sign(set_code_tx([zero_chain_authorization(?DELEGATE, 0, Priv)]),
                  ?SENDER_PRIV),
        {_, State1} = run(Tx),
        ?assertEqual(eth_tx:delegation_indicator(?DELEGATE),
                     eth_state:code(State1, addr_of(Priv)))
    end).

an_authorization_for_another_chain_is_skipped_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Tx = sign(set_code_tx([authorization_with_chain(424242, ?DELEGATE, 0, Priv)]),
                  ?SENDER_PRIV),
        {_, State1} = run(Tx),
        ?assertEqual(<<>>, eth_state:code(State1, addr_of(Priv))),
        ?assertEqual(0, eth_state:nonce(State1, addr_of(Priv)))
    end).

%% EIP-2's low-`s' rule, which EIP-7702 step 3 restates: "Verify `s` is less than
%% or equal to `secp256k1n/2`."
%%
%% The fixture is the same authorization with `s' replaced by `n - s', and both
%% halves of why that matters are asserted, because the first version of this test
%% asserted the wrong one and the *node* was right.
%%
%% **(i)** `(r, n - s)' is a valid signature over the same message with the same
%% key -- EIP-2's subject, one signed message and two acceptable signatures.
%%
%% **(ii)** It does **not** recover the same authority. Measured: the low-`s' form
%% of a key recovers to one address and the `n - s' form to a *different* public
%% key, for either value of `v'. "Malleable, therefore harmless" is the wrong
%% reading, and it is the one this module first wrote down. Recovery maps a
%% signature to an *account*, so if both forms were accepted the same
%% authorization -- same chain, address and nonce -- would designate a different
%% account depending only on which equivalent signature relayed it, and a
%% delegation could be silently redirected. Exactly one of `s' and `n - s' is low,
%% so the rule is what makes the designation a function of the tuple.
%%
%% The refusal is asserted through `eth_tx:authorization_authority/1', which is the
%% policy layer, and the recovery through `eth_secp256k1:recover/4', which is the
%% primitive -- because `authorization_authority/1' checks `s_is_low/1' *first* and
%% so answers `error' to both, which would make "it recovers to something" true of
%% anything.
a_high_s_authorization_is_skipped_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Authority = addr_of(Priv),
        Parts = authorization_parts(Priv, ?DELEGATE, 0),
        [ChainId, Addr, Nonce, YParity, R, S] = Parts,
        N = 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141,
        HighS = N - S,
        ?assert(eth_secp256k1:s_is_low(S)),
        ?assertNot(eth_secp256k1:s_is_low(HighS)),
        %% **(i)** The high-`s' form is a well-formed signature, not garbage: the
        %% primitive recovers *some* public key from it, for either parity. This is
        %% what makes the rule necessary rather than a malformed-input filter -- a
        %% fixture whose `s' were merely "some big number" would be skipped by any
        %% node that skipped malformed signatures, and would prove nothing.
        Pub = eth_keccak:hash(<<16#05, (eth_rlp:encode(
                                [ChainId, Addr, Nonce]))/binary>>),
        {ok, Point} = eth_secp256k1:recover(Pub, R, HighS, YParity),
        {ok, OtherPoint} = eth_secp256k1:recover(Pub, R, HighS, 1 - YParity),
        ?assertNotEqual(<<>>, Point),
        ?assertNotEqual(Point, OtherPoint),
        %% **(ii)** And it is a *different account* from the one that signed. This
        %% is the assertion the first version got backwards, and getting it backwards
        %% is what made the comment claim the node was broken.
        ?assertNotEqual(Authority, binary:part(eth_keccak:hash(Point), 12, 20)),
        %% The policy layer refuses it, which is EIP-7702 step 3's rule.
        ?assertEqual(error, eth_tx:authorization_authority(
                              [ChainId, Addr, Nonce, YParity, R, HighS])),
        Tx = sign(set_code_tx([malleated(Parts, HighS)]), ?SENDER_PRIV),
        {_, State1} = run(Tx),
        ?assertEqual(<<>>, eth_state:code(State1, Authority)),
        ?assertEqual(0, eth_state:nonce(State1, Authority))
    end).

%% The EIP's one surprise, and the clause a state-transition table written from
%% intuition gets backwards: "The authorization list is processed before the
%% execution portion of the transaction begins" -- and "if transaction execution
%% results in failure ... the processed delegation indicators is **not rolled
%% back**."
%%
%% So the delegation must be applied to a state the *frame* does not own: between
%% the sender's nonce increment and the frame. A node that applied the list inside
%% the frame's starting state, or restored the pre-authorization state on revert,
%% is wrong on exactly the transactions that fail.
the_delegation_survives_a_reverting_transaction_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Authority = addr_of(Priv),
        %% **The destination needs code**, which is the precondition the first
        %% version of this test omitted -- and the omission made it vacuous rather
        %% than failing. A call to an account with no code returns success without
        %% executing anything, so the calldata was never run, the transaction
        %% *succeeded*, and the assertion that it reverted failed by accident. The
        %% symptom was `status = 1' on a test named "survives a reverting
        %% transaction": a test whose name and precondition disagree, which is the
        %% one combination that cannot be trusted at all.
        %%
        %% `PUSH1 0 PUSH1 0 REVERT` -- a revert with no side effects of its own, so
        %% anything the delegating state lost is the revert path's doing.
        Code = <<16#60, 16#00, 16#60, 16#00, 16#fd>>,
        %% One byte per literal, and **asserted**, because the first version wrote
        %% this as `<<16#6000, 16#6000, 16#fd>>' -- two hex digits per byte in a
        %% segment whose default integer width is 8 bits -- and that compiles to the
        %% *three*-byte `<<0,0,253>>'. The two `0x60' PUSH1 opcodes are silently
        %% truncated away, so the program is `STOP; STOP; REVERT': it halts at the
        %% first byte and the transaction **succeeds**, which is the opposite of what
        %% the test name says.
        %%
        %% The symptom was the fifth instance of one trap, and the assertion below
        %% exists so the sixth cannot be silent: the program's length is load-bearing
        %% here, and a length nobody checks is a length that can be wrong.
        ?assertEqual(5, byte_size(Code)),
        State0 = put_code(eth_state:new(0, #{}), ?TO, Code, 0),
        Tx = sign(set_code_tx([authorization(?DELEGATE, 0, Priv)]), ?SENDER_PRIV),
        {Block, State1} = run_tx(Tx, State0),
        [Receipt] = eth_block:receipts(Block),
        ?assertEqual(0, maps:get(<<"status">>, Receipt)),
        ?assertEqual(eth_tx:delegation_indicator(?DELEGATE),
                     eth_state:code(State1, Authority)),
        ?assertEqual(1, eth_state:nonce(State1, Authority))
    end).

%% The control for the test above, and the reason the reverting one is not
%% vacuous: a transaction that *succeeds* produces the same delegation. A node
%% that wrote the designator only on the revert path, or only on the success
%% path, fails one of the two. Both are asserted on the same fixture shape, so
%% the only difference between them is the calldata.
the_delegation_is_written_when_the_transaction_succeeds_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Authority = addr_of(Priv),
        %% **The same destination, with code, differing only in that last byte.**
        %% `STOP' where the test above has `REVERT', so the two runs differ in one
        %% opcode and nothing else -- same account, same nonce, same
        %% authorization, same sender, same block. Without that pairing, a node
        %% that always wrote the designator and one that always refused would be
        %% distinguishable from the two tests only by accident.
        State0 = put_code(eth_state:new(0, #{}), ?TO, <<16#00, 16#00, 16#00>>, 0),
        Tx = sign(set_code_tx([authorization(?DELEGATE, 0, Priv)]), ?SENDER_PRIV),
        {Block, State1} = run_tx(Tx, State0),
        [Receipt] = eth_block:receipts(Block),
        ?assertEqual(1, maps:get(<<"status">>, Receipt)),
        ?assertEqual(eth_tx:delegation_indicator(?DELEGATE),
                     eth_state:code(State1, Authority))
    end).

%% Ten tuples, ten designators, ten nonce bumps -- the corpus's real shape, and
%% the one that says the list is processed *in order and to completion* rather
%% than only its first entry. An implementation that stopped after one, or that
%% only ever applied the last, passes every single-tuple test above.
ten_authorizations_are_applied_in_order_test() ->
    with_ctx(fun() ->
        Privs = [eth_secp256k1:generate_key() || _ <- lists:seq(1, 10)],
        Auths = [authorization(<<I:160>>, 0, P)
                 || {I, P} <- lists:zip(lists:seq(1, 10), Privs)],
        Tx = sign(set_code_tx(Auths), ?SENDER_PRIV),
        {_, State1} = run(Tx),
        lists:foreach(
          fun({I, P}) ->
                  ?assertEqual(eth_tx:delegation_indicator(<<I:160>>),
                               eth_state:code(State1, addr_of(P))),
                  ?assertEqual(1, eth_state:nonce(State1, addr_of(P)))
          end, lists:zip(lists:seq(1, 10), Privs))
    end).

%% Step 2: "Verify the nonce is less than `2**64 - 1`."
%%
%% This is the clause a conforming *encoder* can never produce and a
%% hand-crafted tuple trivially can, and the injection that removed the check
%% failed nothing -- which is how this test came to exist. The finding is the
%% useful part: the rule was implemented, correct, and completely unpinned.
an_authorization_whose_nonce_is_too_large_is_skipped_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Authority = addr_of(Priv),
        %% **The authority holds `2**64 - 1`, the very nonce the tuple names.** This
        %% is what makes the *limit* the operative rule. The first version left the
        %% authority at 0, so the tuple was skipped by the nonce-*match* check --
        %% a different rule, one step later in the EIP's list -- and removing the
        %% limit check entirely changed nothing, which the injection reported as
        %% "no bite" for a test whose name is the limit.
        %%
        %% That is the general form: **a test for rule N is only about rule N if
        %% every other rule passes.** Two fixtures a single nonce apart, with the
        %% account in each holding the nonce its tuple names, are what make the
        %% limit the only thing that differs.
        State0 = put_nonce(eth_state:new(0, #{}), Authority, (1 bsl 64) - 1),
        Tx = sign(set_code_tx([authorization(?DELEGATE, (1 bsl 64) - 1, Priv)]),
                  ?SENDER_PRIV),
        {_, State1} = run_tx(Tx, State0),
        ?assertEqual(<<>>, eth_state:code(State1, Authority)),
        %% The nonce did not move, so nothing was applied.
        ?assertEqual((1 bsl 64) - 1, eth_state:nonce(State1, Authority))
    end).

%% **The control, and the boundary it pins.** The test above is satisfied by any
%% node that skips *every* authorization -- which is the node this commit started
%% from -- so it cannot be left alone. The authority is funded at `2**64 - 2` and
%% signs a tuple at that same nonce, one below the limit, and the delegation is
%% applied and the nonce reaches `2**64 - 1`, the largest an account nonce can
%% be.
%%
%% The authority has to *hold* the boundary nonce for this to be the limit being
%% tested: the first version of this control signed at `2**64 - 2` while the
%% authority sat at 0, and it was skipped -- correctly, by the nonce-*match* rule,
%% which is a different rule. A control that fails for a different reason than the
%% case it controls is §10a's "a row's precondition borrowed from a sibling row".
an_authorization_one_nonce_below_the_limit_is_applied_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Authority = addr_of(Priv),
        State0 = put_nonce(eth_state:new(0, #{}), Authority, (1 bsl 64) - 2),
        Tx = sign(set_code_tx([authorization(?DELEGATE, (1 bsl 64) - 2, Priv)]),
                  ?SENDER_PRIV),
        {_, State1} = run_tx(Tx, State0),
        ?assertEqual(eth_tx:delegation_indicator(?DELEGATE),
                     eth_state:code(State1, Authority)),
        ?assertEqual((1 bsl 64) - 1, eth_state:nonce(State1, Authority))
    end).

%% "The authorization list is processed before the execution portion of the
%% transaction begins, **but after the sender's nonce is incremented**."
%%
%% The ordering is only observable when the authority *is* the sender, which is
%% the ordinary case: a user delegating their own account. Then the tuple's nonce
%% must equal the account's nonce **after** the transaction's own increment, and
%% the account ends up with two: one from the transaction, one from the
%% authorization.
%%
%% The injection that applied the list *before* `begin_transaction/8' passed every
%% other test in this module, because in all of them the authority is a different
%% account and the order of two writes to two accounts is unobservable. That is
%% the whole reason this test exists, and the reason it is not a variation on the
%% first one: it is the only fixture in which the EIP's word "after" has a
%% consequence.
an_authority_who_is_the_sender_also_gets_the_transactions_nonce_increment_test() ->
    with_ctx(fun() ->
        Sender = ?SENDER_PRIV,
        Me = addr_of(Sender),
        %% The sender's nonce is 0 in the pre-state, so `begin_transaction/8'
        %% makes it 1, and the tuple must therefore carry 1 -- not 0.
        Tx = sign(set_code_tx([authorization(?DELEGATE, 1, Sender)]), Sender),
        {_, State1} = run(Tx),
        ?assertEqual(eth_tx:delegation_indicator(?DELEGATE),
                     eth_state:code(State1, Me)),
        ?assertEqual(2, eth_state:nonce(State1, Me))
    end).

%% **The control, and the direction of the ordering.** The same transaction with
%% the tuple's nonce left at 0 -- the *pre*-increment value -- must be skipped,
%% because by the time the list is processed the account's nonce is 1. A node
%% that applied the list before the increment would accept this one, so the pair
%% of tests is what pins the order rather than either test alone.
an_authorization_naming_the_senders_pre_transaction_nonce_is_skipped_test() ->
    with_ctx(fun() ->
        Sender = ?SENDER_PRIV,
        Me = addr_of(Sender),
        Tx = sign(set_code_tx([authorization(?DELEGATE, 0, Sender)]), Sender),
        {_, State1} = run(Tx),
        ?assertEqual(<<>>, eth_state:code(State1, Me)),
        %% Only the transaction's own increment.
        ?assertEqual(1, eth_state:nonce(State1, Me))
    end).

%% ---------------------------------------------------------------------------
%% The signing preimage
%% ---------------------------------------------------------------------------

%% EIP-7702 step 3, in full: "Where `msg = keccak(MAGIC || rlp([chain_id, address,
%% nonce]))`." The `0x05` is the domain separator that makes the preimage useless
%% for anything else.
%%
%% The digests are asserted to differ, because the failure mode for getting this
%% wrong is not a raised error: the wrong preimage recovers *some* address, and
%% the authorization is applied to an account nobody signed for. The bare-RLP
%% digest is the subtler of the two ways to get it wrong, and it is the one a
%% validator is likelier to write, because the transaction's own preimage is a
%% type byte followed by RLP.
the_authorization_preimage_is_domain_separated_from_the_transaction_test() ->
    Priv = eth_secp256k1:generate_key(),
    AuthDigest = authorization_digest(11155111, ?DELEGATE, 0),
    Body = eth_rlp:encode([11155111, ?DELEGATE, 0]),
    %% The preimage itself, pinned. The first version of this test asserted only
    %% that the digest was *not* something else, which is satisfied by any digest
    %% at all -- including a wrong one -- and this is the assertion that says what
    %% the digest is.
    ?assertEqual(eth_keccak:hash(<<16#05, Body/binary>>), AuthDigest),
    %% And the two ways to get it wrong, both of which recover *some* address
    %% rather than raising: no magic byte at all, and a type byte in the magic
    %% byte's place -- the transaction's own preimage shape.
    ?assertNotEqual(AuthDigest, eth_keccak:hash(Body)),
    ?assertNotEqual(AuthDigest, eth_keccak:hash(<<16#04, Body/binary>>)),
    %% Round trip: a tuple built by signing this digest recovers to the signer,
    %% which is the property the two assertions above protect.
    [ChainId, Addr, Nonce, YParity, R, S] = authorization_parts(Priv, ?DELEGATE, 0),
    ?assertEqual({ok, addr_of(Priv)},
                 eth_tx:authorization_authority([ChainId, Addr, Nonce, YParity, R, S])).

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

set_code_tx(Auths) ->
    set_code_tx(Auths, #{}).

set_code_tx(Auths, Extra) ->
    maps:merge(#{<<"type">> => <<"0x4">>,
                 <<"chainId">> => eth_hex:encode_int(eth_fork_schedule:chain_id()),
                 <<"nonce">> => <<"0x0">>,
                 <<"maxPriorityFeePerGas">> => <<"0x1">>,
                 <<"maxFeePerGas">> => eth_hex:encode_int(2 * ?GWEI),
                 <<"gas">> => eth_hex:encode_int(500000),
                 <<"to">> => eth_hex:encode_bytes(?TO),
                 <<"value">> => <<"0x0">>,
                 <<"input">> => <<"0x">>,
                 <<"accessList">> => [],
                 <<"authorizationList">> => Auths}, Extra).

%% One authorization tuple, signed by `Priv', and carried in the transaction as a
%% **map with hex strings** -- the shape a decoded payload arrives in. So the
%% node's own normalisation (`eth_tx:authorization_tuple/1') is on the path
%% rather than bypassed by handing it pre-decoded lists.
authorization(Address, Nonce, Priv) ->
    authorization_with_chain(eth_fork_schedule:chain_id(), Address, Nonce, Priv).

zero_chain_authorization(Address, Nonce, Priv) ->
    authorization_with_chain(0, Address, Nonce, Priv).

authorization_with_chain(ChainId, Address, Nonce, Priv) ->
    %% **Pattern-matched, not `element/3..6/1'.** The parts come back as a
    %% *list* -- `[chain_id, address, nonce, y_parity, r, s]', the shape
    %% `eth_tx:authorization_authority/1' takes -- and `element/2' on a list is a
    %% `badarg' rather than a wrong answer. Written as `element/4' it named the
    %% helper, so the trace was short; written as a match it names the shape.
    [_C, _A, _N, YParity, R, S] =
        authorization_parts_with_chain(Priv, ChainId, Address, Nonce),
    #{<<"chainId">> => eth_hex:encode_int(ChainId),
      <<"address">> => eth_hex:encode_bytes(Address),
      <<"nonce">> => eth_hex:encode_int(Nonce),
      <<"yParity">> => eth_hex:encode_int(YParity),
      <<"r">> => eth_hex:encode_int(R),
      <<"s">> => eth_hex:encode_int(S)}.

%% The signed parts, kept as a list so a test can rebuild the tuple with a
%% *different* `s' -- which is the only way to write the malleability test.
authorization_parts(Priv, Address, Nonce) ->
    authorization_parts_with_chain(Priv, eth_fork_schedule:chain_id(), Address, Nonce).

authorization_parts_with_chain(Priv, ChainId, Address, Nonce) ->
    Digest = authorization_digest(ChainId, Address, Nonce),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    [ChainId, Address, Nonce, V, R, S].

authorization_digest(ChainId, Address, Nonce) ->
    eth_keccak:hash(<<16#05, (eth_rlp:encode([ChainId, Address, Nonce]))/binary>>).

%% The same tuple with `S' replaced, and expressed as the map the transaction
%% carries so it goes through the same normalisation as every other authorization.
malleated(Parts, HighS) ->
    [ChainId, Addr, Nonce, YParity, R, _S] = Parts,
    #{<<"chainId">> => eth_hex:encode_int(ChainId),
      <<"address">> => eth_hex:encode_bytes(Addr),
      <<"nonce">> => eth_hex:encode_int(Nonce),
      <<"yParity">> => eth_hex:encode_int(YParity),
      <<"r">> => eth_hex:encode_int(R),
      <<"s">> => eth_hex:encode_int(HighS)}.

run_tx(Tx, State0) ->
    Block0 = (eth_block:new(<<0:256>>, ?PRAGUE_BLOCK))
                 #block{base_fee_per_gas = ?GWEI, miner = ?MINER},
    eth_block:run_transaction(Block0, Tx, State0, ?GWEI, 500000).

run(Tx) ->
    run_tx(Tx, eth_state:new(0, #{})).

put_code(State, Addr, Code, Nonce) ->
    eth_state:set_nonce(eth_state:set_code(State, Addr, Code), Addr, Nonce).

put_nonce(State, Addr, Nonce) ->
    eth_state:set_nonce(State, Addr, Nonce).

%% Derived from `eth_tx:to_rlp/1' by splitting the last three items off, rather
%% than written out. A hand-written preimage is a second copy of
%% `eth_tx:sighash/1' beside the test, and the two differ quietly.
sign(Tx, Priv) ->
    {ok, <<TypeByte, Rest/binary>>} = eth_tx:to_rlp(Tx),
    {ok, Items, <<>>} = eth_rlp:decode(Rest),
    {Preimage, _Sig} = lists:split(length(Items) - 3, Items),
    Digest = eth_keccak:hash(<<TypeByte, (eth_rlp:encode(Preimage))/binary>>),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    Tx#{<<"v">> => eth_hex:encode_int(V),
        <<"r">> => eth_hex:encode_int(R),
        <<"s">> => eth_hex:encode_int(S)}.

addr_of(Priv) ->
    binary:part(eth_keccak:hash(eth_secp256k1:node_id(Priv)), 12, 20).

with_ctx(Fun) ->
    _ = eth_test_util:start_apps(),
    case whereis(eth_mpt) of
        undefined -> {ok, _} = eth_mpt:start_link();
        _ -> ok
    end,
    ok = clear_mpt(),
    Previous = eth_state:base_source(),
    ok = eth_state:set_base_source(mpt),
    ok = eth_mpt:put_account(addr_of(?SENDER_PRIV), 1000000 * ?GWEI, 0,
                             eth_keccak:hash(<<>>)),
    try Fun()
    after
        _ = eth_state:set_base_source(Previous),
        _ = clear_mpt()
    end.

clear_mpt() ->
    lists:foreach(fun(F) -> file:delete(F) end, filelib:wildcard(
                     filename:join(eth_test_util:tmp_dir(), "*"))),
    ok.
