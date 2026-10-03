%% What this node's `execution-spec-tests' conformance level is, and what may be
%% asserted about it.
%%
%% == The tally is asserted, and the reason it is asserted changed
%%
%% `eth_state:storage/3' and `balance/2' answer from the transaction's overlay and
%% then fall through to `base_source' for anything the overlay does not hold. A
%% state test declares its pre-state, and this runner seeds all of it, but the
%% *code under test* can read a slot the fixture never mentions. That read goes to
%% the configured base source, and the conformance run sets that to the local MPT
%% (`with_local_reads', which is what stops a unit test fetching over HTTP) -- and
%% the local MPT is process-wide and shared with every other test in the run.
%%
%% So the tally **was** a function of what else the suite did first, and it was
%% measured rather than hypothesised: the same corpus and the same code gave **6**
%% matches in a fresh VM and **7** under eunit, the extra one being
%% `frontier/touch/test_zero_gas_price_and_touching' -- EIP-161's rule that an
%% account touched at zero gas price does not survive -- passing on an account
%% another test had left in the store. Later runs produced 2. A *higher* match rate
%% caused by unrelated data is worse than a flaky number, because it is a wrong
%% answer that looks right, and on that measurement `?EXPECTED' was removed and the
%% figure became "reported, not asserted".
%%
%% **That measurement no longer reproduces, and the pin is back.** `?EXPECTED' now
%% holds, and it was checked three ways before it was restored: this module run
%% alone, the full suite, and `eest_report' against the same directory. All three
%% give **255 of 266, `state_mismatch' 8, `fork_unreachable' 3**.
%%
%% **Why it stopped drifting is not established**, and the most likely cause is the
%% seeding of everything the fixture mentions -- every address in `pre', in the post
%% state, as sender, as destination and as coinbase, and every slot the post state
%% names. That was done for correctness regardless, and at the time it "removed most
%% of it" without a figure saying how much, so the two measurements were never made
%% against each other. The honest position is that the number is **observed stable
%% rather than known stable**, and that an isolated state base for this runner -- the
%% task named in TASKS.md -- is what would make it the second.
%%
%% That is a weaker guarantee than the old header claimed and a stronger one than
%% "reported". It is stated here rather than in a commit message because the failure
%% mode is specific: **a pin that has stopped meaning anything still passes.** So the
%% pin is paired with `assert_not_mostly_matching/1' below, which fails if the runner
%% ever stops comparing at all, and the two are read together -- `?EXPECTED' says the
%% figure did not move, that function says the figure is still a figure.
%%
%% What is also asserted, and does not depend on any of this: the shape of the
%% corpus, the shape of the outcome vocabulary, and the fact that nothing in the
%% corpus escapes classification.
-module(eest_conformance_tests).

-include_lib("eunit/include/eunit.hrl").

%% The tally, now that it is reproducible.
%%
%% It was not, and the reason is the more useful half of this module's history. Two
%% independent causes, both fixed: a storage read a fixture's code performs but does
%% not declare fell through to a process-wide MPT (now `eth_state:'empty''), and
%% the runner inherited `ETH_NETWORK` from its caller, so the eunit path ran the
%% corpus under Sepolia's chain id against fixtures declaring chain 1. Between them
%% the figure drifted between 2 and 7 across runs of identical code.
%%
%% `match' doubled from 5 to 10, and both halves of the move are worth naming because
%% neither is the state's own doing:
%%
%%   - The five EIP-1559 validity fixtures stopped being evidence of a validator that
%%     *accepted* a type-2 transaction at a pre-London fork. `validate/2' checked only
%%     that a transaction's type was one it could decode, which is a statement about the
%%     code rather than about the block. It is now gated on the fork, via
%%     `eth_fork_schedule:tx_type_available/2'.
%%   - Those five then had to be checked by *reason*, not merely counted as "the
%%     validator said no". The runner compared the fixture's `expectException' code
%%     against the node's own vocabulary, and `rejection_mismatch' fell to 0 with the
%%     refusal verified rather than merely observed. Without the second half the first
%%     would have been worth five entries of a harness that could not tell a correct
%%     refusal from an accidental one.
%%
%% `state_mismatch` is unchanged at 249, which is the honest outcome: the 243 coinbase
%% diffs they carry are now computed against a derived base fee rather than a default
%% of zero, and none of them flipped, so the base fee was masking those but not causing
%% them. See the entry in `TASKS.md`.
%%
%% `tx_decode_failed` went 4 -> 0, `sender_mismatch` and `tx_roundtrip_mismatch` are
%% 0, and one type-4 fixture is now a *verified* refusal. `state_mismatch` went 249 ->
%% 252 and that is the honest direction of travel: the three type-4 execution entries
%% could not previously be represented at all, and now reach the state transition and
%% differ. EIP-7702's authorization list is decoded, priced and validated but **not
%% applied** -- no delegation indicator is written and no authority's code is loaded --
%% so "the state differs" is the correct verdict for them and "could not represent the
%% transaction" was the less informative one.
%%
%% 11 -> 12, and the entry it gained is a **pre-Tangerine Whistle** fixture. The 63/64
%% cap and the 2300 stipend are EIP-150's, and the interpreter applied both at every
%% fork including the four before it; EIP-150's own `substitute' block gives the code it
%% replaced, which has no cap in it at all. `state_mismatch` 252 -> 251, one fixture,
%% for one rule applied to the right span.
%%
%% `state_mismatch` 251 -> 196, and a new outcome of 55. **The tally did not get
%% better; it got honest.** 55 fixtures were being executed into a state root the chain
%% would never produce, because the interpreter refuses operations whose schedule it
%% does not have -- and the refusal was being recorded as an ordinary failed
%% transaction, which is charged its *whole* gas limit. `eth_block:run_transaction/5'
%% now refuses the block instead, so those 55 are named `unpriced` rather than counted
%% as an arithmetic disagreement. They are:
%%
%%   - 48 pre-Berlin `sstore` -- byzantium 14, istanbul 16, petersburg 16, homestead 2
%%   - 7 `precompile 9`, the alt_bn128 pairing check at its Istanbul-and-later address
%%
%% Both are real gaps and both are now loud, which is the point: a wrong state root
%% committed to the trie is the failure mode this project exists to avoid, and a
%% refusal is the correct answer while the schedule is missing.
%%
%% `unpriced` 55 -> **0**. Nothing in the corpus is now executed that this node cannot
%% price, and that took two fixes:
%%
%%   - **48 pre-Berlin `sstore`.** The flat rule is now implemented for the eight
%%     pre-Berlin forks that had it, with EIP-2200's own figures
%%     ("SSTORE_SET_GAS: 20000, not changed", "SSTORE_RESET_GAS: 5000, not changed")
%%     and `SLOAD_GAS` fork-selected at 50 / 200 / 800 by EIP-150 and EIP-1884.
%%     Constantinople stays refused, and it is the *only* one that does.
%%   - **7 `precompile 9`.** `eip152_blake2`'s DELEGATECALLs to 0x09 carry
%%     **zero-length** calldata; blake2f needs exactly 213 bytes, so the call should
%%     fail. `eth_evm_precompiles` reported that as `unsupported`, which the block
%%     layer reads as "this node cannot run this" and refuses the block over. The same
%%     conflation was in the pairing check, whose `check_pairing/1` returned one atom for
%%     both a rejected input and a missing implementation.
%%
%% `match` 12 -> **17**, so the five fixtures the pre-Berlin rule fixed outright are
%% now correct rather than merely priced. `state_mismatch` 196 -> 246 is the other side
%% of the same move: 43 entries now execute and differ for whatever else is wrong with
%% them, which is a diagnosis rather than a refusal.
%%
%% `match` 17 -> **24** since that, from two more missing prices, both found by the
%% corpus rather than by a test:
%%
%%   - **`G_codedeposit` was never charged.** 200 per byte of the code a create hands
%%     back, at every fork, charged nowhere. The size cap was a bare
%%     `byte_size(Code) =< 24576' in a guard -- a predicate with no price behind it, and
%%     applied at every fork including the eight before EIP-170 introduced the cap -- so
%%     this node deployed code of any size for free and never went out of gas on a
%%     create whose deposit it could not pay. `create/test_create_deposit_oog` has a
%%     twenty-three-byte callee that stores a word and then `CREATE`s six bytes of init
%%     code which itself `RETURN`s 10,000 bytes: a 2,000,000-gas deposit against a
%%     934,172-gas frame. Seven of those fixtures expected the whole 1,000,000
%%     allowance to be spent and the node spent 57,062, handing back 918,145 gas the
%%     chain never returns. That fixture's delta is now -2,100 rather than -918,145, and
%%     the residue is the *next* bug on this list.
%%   - **EIP-2929's "additional" `COLD_SLOAD_COST` on `SSTORE` was not charged.** The
%%     EIP has two halves -- rewrite EIP-2200's `SLOAD_GAS` to 100 and
%%     `SSTORE_RESET_GAS` to 2,900, *and* charge an extra 2,100 for a slot not in
%%     `accessed_storage_keys` -- and the node had the first. So every *first* touch of
%%     a slot cost 2,100 too little and every second touch was right, which is why it
%%     survived: a test that writes a slot twice cannot see it. The corpus gave it up
%%     as a -2,100 delta on 40 fixtures, all at the same number.
%%
%% `match` 24 -> **25** again, from a third missing price: **EIP-2929's transaction-start
%% warm set was never seeded.** Its own text: "When a transaction execution begins ...
%% `accessed_addresses` is initialized to include the `tx.sender`, `tx.to` (or the
%% address being created if it is a contract creation transaction) -- and the set of all
%% precompiles." None of it was, so the transaction's own recipient, its own sender and
%% every precompile were each charged `COLD_ACCOUNT_ACCESS_COST` on first touch.
%%
%% The corpus named it as a uniform **+2,500** on twenty-four fixtures, and 2,500 is
%% `COLD_ACCOUNT_ACCESS_COST - WARM_STORAGE_READ_COST` exactly -- 2,600 - 100 -- at every
%% fork from Berlin and at none before it, which is what identifies it as a precompile
%% rather than anything else. The `test_gas.py` contracts behind those fixtures each
%% call one precompile and do nothing else.
%%
%% `match` 53 -> **78** and `state_mismatch` 210 -> 185, and this one is a **node**
%% defect, found by reading a histogram rather than by reasoning about the fixtures.
%% Twenty-four fixtures ended a frame with `CALL; POP; RETURNDATASIZE; PUSH1 k;
%% SSTORE' and were **-19,900**, which is `SSTORE_SET_GAS` (20,000) minus `SLOAD_GAS`
%% (100) -- EIP-2200's arm (1.) taken because the new value read as 0. The new value
%% read as 0 because `eth_evm:run_call/10'` gave the precompile path no way to publish
%% its output: `finish_call/8' does not set `retdata' (`handle_child/9' does, for an
%% account call), so `RETURNDATASIZE' after a *precompile* call reported whatever the
%% previous call had left. A state defect first and a gas defect second; the fix is in
%% `eth_evm.erl' and the pins are in `eth_evm_tests'.
%%
%% A second `match` figure, `46 -> 53`, was a harness defect and no node change at
%% all. Both are in how the runner builds the *block* it executes against.
%%
%%   * `base_fee_for/1` was handed the fixture's fork **name**, which is a binary,
%%     where `eth_fork_schedule:at_least/2` wants an atom -- so it answered `undefined`
%%     for every fork, which is correct before London and wrong from it. The block
%%     carried no base fee and a typed transaction, having no `gasPrice` field, executed
%%     at an effective price of zero.
%%   * the base fee was then derived from the two balance deltas, which cannot work when
%%     the tip is zero -- and the tip is zero in every fixture here.
%%
%% Seven fixtures flip, and **nothing flips the other way**: the five
%% `test_eip1559_tx_validity` entries, plus `homestead/coverage/test_coverage` at
%% Cancun and Prague -- and with them `+152,536 x2`, the largest unexplained figure the
%% corpus had, which turns out to have been the base fee. The other 11 of the 18
%% typed-transaction fixtures move to different and still-large deltas, so a **second
%% cause** remains in that path that none of these reaches. See TASKS.md.
%%
%% `match` 25 -> **46** and `state_mismatch` 238 -> 217, and neither number moved because
%% the node got better at executing anything. The runner could not **see** a storage
%% write the node had made: `eth_state:new/2` rewrites every `{store, A, S}' key of the
%% overlay it is given through `eth_state:slot_key/1', so a slot seeded from a
%% fixture's `<<"0x00">>' went in under the 32-byte word, and this module's read path --
%% `overlay/3' -- looked it up under the *integer* `0'. Every slot therefore read as
%% zero on the way back, and a node that stored `1' was reported as having stored
%% nothing.
%%
%% Twenty-one fixtures were being scored on a comparison that could not see storage.
%% `london/eip1559_fee_market_change/test_eip1559_tx_validity` is the clearest witness
%% and it had been read as a node defect for a long time: an instrumented run of it has
%% the frame finishing `result=ok charged0=26006`, and 26,006 is the chain's own figure
%% for that transaction, so both the gas and the write were right and only the
%% comparison was wrong. See `overlay_key/1'.
%% 220 -> 224 and 43 -> 39 in the EIP-4844 blob-fee fix. The four are
%% `cancun/eip4844_blobs/test_sufficient_balance_blob_tx' and
%% `test_blob_gas_subtraction_tx', whose sender balances were each 786,432 wei
%% too high because `eth_block' never deducted the blob fee. Pinned rather than
%% re-derived, like every other figure here: a *regression* to 220 would mean the
%% charge had been removed, and the count is the only thing that would notice.
%% 224 -> 226, and `state_mismatch' 39 -> 37, from EIP-7702's authorization
%% state transition (`v1.62'): two of the committed subset's entries carry a
%% delegation the node was pricing, validating and then not applying. Both moved
%% the same two entries, so the pair is the boundary of the change and nothing
%% else in the subset moved -- which is what makes the pin worth keeping.
%% 226 -> 249, and `state_mismatch' 37 -> 14, from EIP-3529's refund cap being
%% taken over the **transaction's** gas used rather than the frame's (`v1.65`).
%% **+23 is the largest single-figure move since the access list, and it came from a
%% rule no fixture in the 22-file set exercises** -- those are transaction-*validity*
%% files with little refundable work, so the whole 3,831 of 3,884 is unchanged by
%% this commit. Two corpora, two samples, and "the corpus does not see it" is a
%% statement about a *named* corpus.
%% 249 -> 250 and `state_mismatch' 14 -> 13, from EIP-7702 step 7's
%% `PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST` refund (`v1.66`). **One entry here,
%% but eleven in `prague/eip7702_set_code_tx`, which is now 80 of 80.** The committed
%% subset holds a single type-4 fixture whose authority exists in the pre-state; the
%% directory holds eleven. The single figure is not the size of the fix and the
%% directory figure is not a conformance claim -- they are two samples, and saying
%% "+1" without saying that would understate the change by a factor of eleven.
%% 254 -> 255 and `state_mismatch' 9 -> 8, from a contract-creation transaction's
%% **endowment never moving**: `begin_transaction/8' transferred on its
%% `IsCreate = false' arm and not at all on the `true' arm, where `Target' is already
%% the contract address. 10,374 entries of `static/state_tests/stTimeConsuming` are
%% create transactions carrying `value: "0x01"' and every one of them diverged. Landed
%% with the rollback it belongs to -- EELS snapshots *before* the value move -- so the
%% committed subset moves one and **the corpus moves none of them yet**: the residual
%% is a separate SSTORE pricing defect worth 20,197 gas on the same fixtures, and
%% saying "+10,374" here would be claiming a fix the tally cannot see.
%% 250 -> 254 and `state_mismatch' 13 -> 9, from EIP-161 (a): the account a `CREATE'
%% or `CREATE2' makes has nonce 1, not 0. The create-*transaction* path
%% (`eth_block:deploy/5') has always set it, so the two ways of deploying a contract
%% in this node disagreed. Nothing here is a gas figure -- the whole cost of the
%% defect is a state root, which is why the movement is in `state_mismatch' and not
%% in a number of gas units. **+4 here, and +36 of 168 on
%% `constantinople/eip1014_create2/test_create2_return_data.json` alone**, where the
%% same file is the corpus's single largest `nonce` cluster: 84 nonce divergences
%% with *no* code divergence, since a create that did not happen and a create that
%% happened with the wrong nonce are the same diff shape.
%%
%% **This pin was removed once and put back, and the reason it was removed is the
%% reason it is worth writing down.** It read `match => 255, state_mismatch => 8',
%% and a run measured **`match => 236, state_mismatch => 27'`** instead -- so the pin
%% looked wrong, and it was deleted on the strength of that one figure.
%%
%% **The tree that produced 236 had a consensus gas defect in it.** An uncommitted
%% change to `eth_fork_schedule:sstore_cost/4' was charging `SSTORE_SET_GAS' for a
%% no-op write into a slot whose original value was zero, which EIP-2200 does not
%% price that way, and it cost this tally 19 entries. Reverted, and 255 is what three
%% independent paths produce.
%%
%% So the general form, and it is §10a's "establish the baseline before trusting the
%% number" rather than a new trap: **a measurement taken against a tree that is
%% already broken is not evidence about the pin, it is evidence about the defect, and
%% the two are indistinguishable while the defect is present.** 236 was real, stable
%% and reproducible, and it was wrong -- not about the tally, about the code. The
%% three failing tests that came with it said so, and the pin did not.
-define(EXPECTED, #{match => 255,
                    state_mismatch => 8,
                    unpriced => 0,
                    tx_decode_failed => 0,
                    tx_roundtrip_mismatch => 0,
                    sender_mismatch => 0,
                    expected_rejection_not_raised => 0,
                    rejection_mismatch => 0,
                    fork_unreachable => 3,
                    crash => 0,
                    no_post_for_fork => 0,
                    unreadable_fixture => 0}).

%% The traversal needs a long timeout. EUnit's default is five seconds; the subset
%% is 266 entries and each recovers an ECDSA public key over this node's own
%% secp256k1, which is bignum arithmetic, about 6.5 seconds for the subset. The
%% symptom without a timeout is not a failure but a *cancelled* test, and a
%% cancelled test is the one EUnit reports least loudly.
%% Exported plainly as well, which looks redundant and is not. EUnit finds the test
%% through the generator below; the compiler only knows a function is used if it is
%% exported, and `warnings_as_errors' turns "function ... is unused" into a build
%% failure.
-export([conformance_tally_is_reported/0,
         %% Same reason as the one above, and the same mistake otherwise: as a
         %% `_test/0' this one hit EUnit's five-second default and was reported as a
         %% **cancelled** test rather than a pass, on a machine that also happened to
         %% be running a corpus sweep. It is the same 266-entry traversal.
         the_surveys_by_fork_breakdown_is_a_flat_list_of_outcome_counts/0]).

%% The timeout is attached through a generator rather than by naming the function
%% `_test', which would run it a second time under the five-second default.
conformance_tally_is_reported_test_() ->
    {timeout, 300, fun conformance_tally_is_reported/0}.

%% Every entry in the corpus must land in the outcome vocabulary.
%%
%% This is the assertion that is worth having and that survives the
%% environment-dependence above. `outcomes/0' is exhaustive, so an entry that
%% produced no outcome at all -- a crash, an unhandled exception in a fixture
%% shape this runner does not recognise -- would show up here as a missing atom. A
%% runner that silently skipped what it could not classify would report a higher
%% match rate than it earned, which is the failure mode this module exists to
%% prevent.
conformance_tally_is_reported() ->
    Results = eth_test_util:with_local_reads(
                fun() -> eest_state_tests:entries(eest_state_tests:committed()) end),
    ?assert(length(Results) > 0),
    Unknown = [O || {_, O, _, _} <- Results,
                    not lists:member(O, eest_state_tests:outcomes())],
    ?assertEqual([], Unknown),
    assert_not_mostly_matching(Results),
    assert_the_block_resolves_to_the_fork_the_fixture_names(Results),
    assert_unreachable_are_reported(Results),
    ?assertEqual(?EXPECTED, eest_state_tests:tally(Results)).

%% The headline claim, as a bound rather than a figure.
%%
%% The exact count cannot be asserted -- see the module comment, and `PROVENANCE.md'
%% -- but "about 2%" can, and something must, because the failure this catches is
%% the worst one available to a conformance runner: a comparison that never reports
%% a difference would classify all 266 entries as `match', the tally would read as
%% total conformance, and every other assertion in this module would still pass.
%%
%% So the assertion is that matches are a small minority. Every run observed between
%% 2 and 7 matches out of 266, so a tenth is a bound with an order of magnitude of
%% headroom that still cannot be reached by a runner which has stopped comparing.
assert_not_mostly_matching(Results) ->
    Matched = length([1 || {_, O, _, _} <- Results, O =:= match]),
    %% **This used to be `Matched < length(Results) div 10', and it is worth saying
    %% what happened to it, because it is a threshold change and not a neutral edit.**
    %%
    %% That bound was calibrated when a run observed "between 2 and 7 matches out of
    %% 266", and its stated purpose was to catch a runner that has stopped comparing --
    %% the failure where every entry is classified `match' and the tally reads as total
    %% conformance while every other assertion here still passes.
    %%
    %% It expresses that purpose as a *ratio*, and the ratio is the problem: it fails as
    %% the node gets better. At 25 of 266 it had one fixture of headroom. At 46 of 266
    %% -- 17% -- a node that had just fixed twenty-one fixtures tripped it, and a node
    %% that was fully conformant would trip it harder. **A check that punishes the thing
    %% it is meant to encourage is not a check; it is a ceiling on the work.** So the
    %% bound is gone and the intent is stated directly, in the two directions it can
    %% fail:
    %%
    %%   * `Matched > 0' -- the runner reached a verdict rather than dropping every
    %%     entry, which is what a fixture whose fork is unreachable would do;
    %%   * `Matched < length(Results)' -- the runner still reports differences.
    %%
    %% Both failure modes the original was written for are covered, neither of them
    %% moves when the node improves, and the "fully conformant" case is now the thing
    %% `?EXPECTED' is for rather than something this bound objects to.
    ?assert(Matched > 0),
    ?assert(Matched < length(Results)).

%% Frontier has no activation point in this node's schedule -- the earliest is
%% Homestead at 1,150,000, so no number or timestamp selects `frontier', and a
%% block before that resolves to `paris'. Those fixtures therefore cannot be
%% *executed* rather than being wrongly executed, and the difference matters: an
%% honest gap is not a wrong answer. Pinned so the runner cannot start quietly
%% dropping them, which would raise the match rate it reports.
%% **The block the runner builds for a fixture must resolve to the fork the fixture
%% names.**
%%
%% This is the invariant `schedule_fork_at/3' was added to restore, and it is worth
%% pinning separately from the tally because the tally cannot tell you *which* of two
%% defects it is looking at. `base_fee_for/1` was handed the entry's fork *name* --
%% a binary, from `fork_of_key/1' -- where `eth_fork_schedule:at_least/2` wants an
%% atom, so it answered `undefined` for every fork. That is the correct answer before
%% London, which is why two thirds of the corpus never noticed, and it is why the
%% tally was the only place the divergence could show up.
%%
%% The check is deliberately about the *block* and not about the name: the entry names
%% `Paris', `fork_point/1' turns that into a number and a timestamp, and what matters is
%% that `current_fork/4'` on that point says Paris. A name check would pass while the
%% block was wrong, which is the bug.
assert_the_block_resolves_to_the_fork_the_fixture_names(Results) ->
    Pairs = [{<<"London">>, london}, {<<"Paris">>, paris}, {<<"Shanghai">>, shanghai},
             {<<"Cancun">>, cancun}, {<<"Prague">>, prague}, {<<"Osaka">>, osaka},
             {<<"Berlin">>, berlin}, {<<"Istanbul">>, istanbul}],
    %% Keyed on the *matched* entries only. An assertion over the whole corpus would be
    %% vacuous for any fork the corpus happens not to match, and would then stop
    %% checking anything the moment the tally moved -- which is the opposite of what a
    %% pin is for.
    Seen = [N || {K, match, _, _} <- Results,
                 {N, _} <- Pairs,
                 binary:match(K, <<"fork_", N/binary, "-">>) =/= nomatch],
    [?assertEqual({N, F}, {N, eest_state_tests:schedule_fork_of_key(N)})
     || {N, F} <- Pairs, lists:member(N, Seen)],
    %% And at least one is exercised, or the list above was checked against nothing.
    ?assert(length(Seen) > 0).

assert_unreachable_are_reported(Results) ->
    Unreachable = [R || {_, fork_unreachable, _, _} = R <- Results],
    ?assert(length(Unreachable) > 0),
    %% Keyed on the *fork name in the test key*, not on the directory. A file under
    %% `frontier/' is not a Frontier-fork fixture: `frontier/touch/test_zero_gas_
    %% price_and_touching' contains entries for Byzantium, ConstantinopleFix,
    %% Homestead and Istanbul, and the first version of this assertion assumed the
    %% directory and failed on exactly that file.
    %%
    %% The file component is also a string rather than a binary -- `filelib:wildcard/1'
    %% returns the shape of its pattern -- so a `binary:match/2' on it raised
    %% `badarg' in the tests whose whole job is to check the corpus's shape.
    Frontier = [R || {K, _, _, _} = R <- Results,
                     string:find(K, "fork_Frontier-") =/= nomatch],
    ?assert(length(Frontier) > 0),
    [?assertMatch({_, fork_unreachable, _, _}, R) || R <- Frontier],
    %% And `Frontier' is the *only* unreachable fork, which is the claim the runner's
    %% comment and `fork_point/1' make. Asserting it exactly means a fixture fork
    %% added to the corpus that the runner cannot select fails here, instead of
    %% quietly joining the `fork_unreachable' count and making this node's
    %% conformance look worse for a reason that is a gap in the runner.
    UnreachableForks = lists:usort([fork_named(K) || {K, fork_unreachable, _, _} <- Results]),
    ?assertEqual(["Frontier"], [F || F <- UnreachableForks, F =/= undefined]),
    ok.

%% The fork a test key names, or `undefined' when it names none.
fork_named(Key) ->
    case re:run(Key, "fork_([A-Za-z0-9]+)-", [{capture, all_but_first, list}]) of
        {match, [Name]} -> Name;
        _ -> undefined
    end.


%% The committed corpus is neither empty nor the whole upstream suite. Either would
%% make the reported tally mean something other than what it says.
%% The per-fork breakdown must be a **flat** list of `{Outcome, Count}' with integer
%% counts, and the counts must add up to the fork's entry count. `eest_report' does
%% `lists:sum/1' over them, so a count that is anything else is not a wrong figure --
%% it is a crash, and the tool that exists to print the breakdown died instead of
%% printing it.
%%
%% It did. `survey_one/2' read
%%
%%     fun(N) -> [{Outcome, N} | N] end,   %% initialiser [{Outcome, 1}]
%%
%% where `N' is already the **list** of pairs for that fork, so each entry's "count" was
%% the whole accumulation so far. Three consequences, none visible on the committed
%% 266-entry subset, which is why this went unnoticed:
%%
%%   * `print_by_fork/1' raised `badarith' -- `0 + [{match, [{match, ...}]}]' -- at the
%%     **second** entry of the first fork with two entries. The by-fork section had
%%     never been printed, on any corpus.
%%   * The structure grew with the **square** of the entries per fork. A full-corpus run
%%     reached 1,993 entries on prague and the VM gave up.
%%   * The `n=' and `match=' figures it would have printed, had it printed anything, were
%%     sums of 1s and lists.
%%
%% The committed subset has 266 entries over 13 forks, so its forks hold 3 to 30 entries
%% each -- comfortably enough to have caught this, and did not, because nothing read the
%% field. That is the shape of the defect: the consumer was the only thing that could
%% see it, and the consumer was a developer tool nobody ran at scale.
%% The timeout is attached through a generator, for the reason on
%% `conformance_tally_is_reported_test_/0'. Without it this is a *cancelled* test and
%% not a failure, which is the worst way for a regression gate to report itself.
the_surveys_by_fork_breakdown_is_a_flat_list_of_outcome_counts_test_() ->
    {timeout, 300, fun the_surveys_by_fork_breakdown_is_a_flat_list_of_outcome_counts/0}.

the_surveys_by_fork_breakdown_is_a_flat_list_of_outcome_counts() ->
    #{by_fork := Bf} = eest_state_tests:survey(eest_state_tests:committed(), 1000),
    Forks = maps:to_list(Bf),
    [begin
         %% Flat, and every count an integer. These two are the whole invariant.
         ?assert(is_list(L)),
         [?assert(well_formed_count(P)) || P <- L],
         %% And the counts are the fork's entries: the sum is the `n=' the report prints
         %% and the length is the same number computed a second way, so neither can be
         %% satisfied by a list that happens to sum right for the wrong reason.
         ?assertEqual(length(L), lists:sum([C || {_, C} <- L]))
     end || {_Fork, L} <- Forks],
    ?assert(length(Forks) >= 8).

%% **NOT ASSERTED HERE: that the per-fork counts add up to `total'.** They do not, in
%% this process, and I could not attribute it. Measured on the committed corpus, same
%% code, same corpus:
%%
%%   * a **fresh VM** (`erl -noshell -s eest_report main <corpus>`): `total = 266`,
%%     11 fork keys, and `length/1` over their lists sums to **266**. Exact.
%%   * **inside this suite**: `total = 266`, and the same sum is **255** -- 11 short,
%%     **exactly one per fork**, all eleven of them.
%%
%% `total` and `by_fork` are updated in the **same map literal** in `survey_one/2`, a
%% line apart, so every `T + 1' is accompanied by a `maps:update_with/4' on `by_fork'
%% and they cannot legitimately disagree. So whatever accounts for the 11 is not a
%% missing update, which means my reading of the code or of the measurement is wrong
%% somewhere. The honest thing is to say so: asserting `266 = 255` would make the suite
%% green on a defect, and asserting either figure alone would pin one of them without
%% knowing which is right. Recorded in TASKS.md with these numbers.

%% One `{Outcome, Count}' from `by_fork': the outcome an atom and the count a positive
%% integer. The old fold produced a count that was a **list**, which is the whole
%% failure in one predicate.
well_formed_count({Outcome, Count}) ->
    is_atom(Outcome) andalso is_integer(Count) andalso Count >= 1.


committed_subset_is_a_real_subset_test() ->
    Files = subset_files(),
    ?assert(length(Files) >= 20),
    %% The forks are named by path, so their count is a check that the directory
    %% layout was not flattened. The path is relative -- `committed/0' is
    %% `apps/etherlang/test/vectors/eest' -- so the prefix has to come off first;
    %% without that every file's first component is `apps' and the count is 1.
    Prefix = eest_state_tests:committed() ++ "/",
    ?assert(length(lists:usort([fork_dir(string:slice(F, string:length(Prefix)))
                                || F <- Files])) >= 8),
    %% Upstream's state-test suite is 2,681 files and 503 MB. If this ever approaches
    %% that, the numbers in the documentation are describing something else.
    ?assert(length(Files) < 300).

%% The runner must be able to *tell things apart*.
%%
%% An outcome vocabulary that collapsed "the transaction did not decode", "the
%% signature recovered the wrong address" and "the state came out different" into
%% one `fail' would make the tally a number nobody could act on, and the collapse
%% would be invisible: the totals would look the same. So the vocabulary is asserted
%% to be the distinct reasons it is, and none may duplicate.
the_outcome_vocabulary_distinguishes_failure_kinds_test() ->
    Outcomes = eest_state_tests:outcomes(),
    ?assertEqual(12, length(Outcomes)),
    ?assertEqual(12, length(lists:usort(Outcomes))),
    %% `unpriced' is in the vocabulary because `eth_block:run_transaction/5' started
    %% refusing a block whose execution it cannot price, rather than executing it into a
    %% state root the chain would not produce. Without an outcome of its own those
    %% entries would have been counted as `crash' -- blaming the harness -- or as
    %% `state_mismatch' -- blaming the arithmetic -- and either would have hidden the
    %% thing the number exists to say.
    ?assert(lists:member(unpriced, Outcomes)),
    %% And it must stay distinct from the two it could plausibly be folded into.
    ?assertNot(lists:member(unpriced, [state_mismatch, crash])).

%% The fixtures are the third party's expected results, so they are committed and
%% never fetched, and this asserts the corpus is really on disk where the runner
%% looks rather than found by a network call that happens to be fast today.
the_committed_fixtures_are_on_disk_test() ->
    ?assert(length(subset_files()) > 0).

subset_files() ->
    filelib:wildcard(filename:join([eest_state_tests:committed(), "**", "*.json"])).

%% `filelib:wildcard/1' returns whatever shape the pattern had, and the pattern here
%% is built by `filename:join/1' from a string, so the matches are strings and
%% `binary:split/3' on one is a `badarg'. The first version assumed binaries, and
%% failed in the one test that exists to check the corpus's shape.
fork_dir(File) ->
    case string:split(File, "/", all) of
        [Fork | _] -> Fork;
        [] -> undefined
    end.
