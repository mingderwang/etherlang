%% What this node's `execution-spec-tests' conformance level is, and what may be
%% asserted about it.
%%
%% == Why there is no test asserting the tally
%%
%% The obvious test -- "assert that N of 266 fixtures match" -- was written, and it
%% is wrong, and it is worth saying precisely why because the reason is the whole
%% point of this module.
%%
%% `eth_state:storage/3' and `balance/2' answer from the transaction's overlay and
%% then fall through to `base_source' for anything the overlay does not hold. A
%% state test declares its pre-state, and this runner seeds all of it, but the
%% *code under test* can read a slot the fixture never mentions. That read goes to
%% the configured base source, and the conformance run sets that to the local MPT
%% (`with_local_reads', which is what stops a unit test fetching over HTTP) -- and
%% the local MPT is process-wide and shared with every other test in the run.
%%
%% So the tally depends on what else the suite did first. Measured, not
%% hypothesised: the same corpus and the same code gave **6** matches in a fresh VM
%% and **7** under eunit, the extra one being `frontier/touch/test_zero_gas_price_
%% and_touching` -- EIP-161's rule that an account touched at zero gas price does
%% not survive -- passing on an account another test had left in the store. Later
%% runs of the suite produced 2. A *higher* match rate caused by unrelated data is
%% worse than a flaky number, because it is a wrong answer that looks right.
%%
%% Seeding everything the fixture mentions -- every address in `pre', in the post
%% state, as sender, as destination and as coinbase, and every slot the post state
%% names -- removed most of it and is still done, because it is correct regardless.
%% It did not remove all of it, because a slot the code reads and never writes is
%% not knowable without executing the code.
%%
%% So the tally is **reported, not asserted**. It is in README.md and TASKS.md with
%% the date it was measured and the caveat attached, and it is reproducible only as
%% "a number this node produced on a machine on a day", which is exactly what a
%% conformance figure should not be treated as. The task that would fix this -- an
%% isolated state base for the runner -- is in TASKS.md.
%%
%% What *is* asserted here is everything that does not move: the shape of the
%% corpus, the shape of the outcome vocabulary, and the fact that nothing in the
%% corpus escapes classification. A tally that cannot be pinned is not a reason to
%% assert nothing.
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
-define(EXPECTED, #{match => 10,
                    state_mismatch => 249,
                    tx_decode_failed => 4,
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
-export([conformance_tally_is_reported/0]).

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
    assert_unreachable_are_reported(Results),
    ?assertEqual(?EXPECTED, eest_state_tests:tally(Results)).



%% The headline claim, as a bound as well as a figure.
%%
%% `?EXPECTED' pins the number. This pins the *claim*, and it earns its place
%% because it fails differently: the exact count is a fact about this corpus on this
%% day, and a fixture moving from `state_mismatch' to `match' would change the count
%% without changing the finding. This fails if the runner ever stops comparing at
%% all -- the failure that would leave every other assertion here passing while the
%% tally read as total conformance.

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
    ?assert(Matched < length(Results) div 10).

%% Frontier has no activation point in this node's schedule -- the earliest is
%% Homestead at 1,150,000, so no number or timestamp selects `frontier', and a
%% block before that resolves to `paris'. Those fixtures therefore cannot be
%% *executed* rather than being wrongly executed, and the difference matters: an
%% honest gap is not a wrong answer. Pinned so the runner cannot start quietly
%% dropping them, which would raise the match rate it reports.
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
    ?assertEqual(11, length(Outcomes)),
    ?assertEqual(11, length(lists:usort(Outcomes))).

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
