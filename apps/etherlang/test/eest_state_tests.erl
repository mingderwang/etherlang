%% Runs the `execution-spec-tests` state-test corpus against this node's state
%% transition, and records what does not match.
%%
%% This module is the answer to a question the repository could previously only
%% assert an opinion about. "Is the EVM right?" had no evidence behind it: the
%% opcode table was cross-checked against go-ethereum and execution-specs'
%% instruction *counts*, and the gas schedule was derived from the EIPs and
%% pinned by unit tests -- but nothing in this repository had ever been *run*
%% against a third party's expected results. A self-consistent client and a
%% conformant client produce identical results on every fixture written for the
%% self-consistent one, which is how a schedule can be found wrong four times by
%% reading it against the EIPs and still not know it is wrong.
%%
%% So the evidence is a corpus, and this is the thing that runs it.
%%
%% == Where the corpus comes from, and how much of it there is
%%
%% The upstream release is `execution-spec-tests` v5.4.0, asset
%% `fixtures_stable.tar.gz` (published 2025-12-06). Its `state_tests` suite is
%% 2,681 files and 503 MB, of which 315 MB is a single `static/` directory of
%% legacy VMTests. Committing that is not an option and pretending to have run
%% it would be worse, so:
%%
%%   * the *committed* corpus under `test/vectors/eest/` is a curated subset
%%     small enough to read, which the eunit suite pins;
%%   * the *whole* corpus can be run from an extracted tarball by pointing
%%     `EEST_CORPUS` at it, which is how the totals in README.md and TASKS.md
%%     were obtained. The command is in `test/vectors/eest/PROVENANCE.md`.
%%
%% A test that reaches for a network is not allowed in this repository, and the
%% corpus is committed for the same reason the Sepolia payloads are: the
%% expected results are somebody else's, and they must be pinned rather than
%% re-derived.
%%
%% == What is compared, and what is deliberately not
%%
%% Per fixture entry, in order, each a separate outcome so that a codec problem
%% is never reported as an execution problem:
%%
%%   1. the transaction bytes decoded (`eth_tx:from_rlp/1`) and the resulting
%%      hash against the fixture's own `hash`;
%%   2. the recovered sender (`eth_tx:sender/1`) against the fixture's `sender`;
%%   3. the post-state, per account and per slot.
%%
%% Gas is compared *through the balance*, because that is where a state test
%% puts it: the sender's balance falls by `gasUsed * effectivePrice` and the
%% value it sent, so a wrong gas figure shows up as a wrong balance. The runner
%% also inverts that arithmetic to recover the gas each side spent, because
%% "this fixture diverges" is not actionable and "this fixture diverges by 2,100
%% gas, which is EIP-2929's cold account surcharge" is.
%%
%% The signature is *not* re-derived from the fixture's `secretKey`. The
%% fixture's own signed bytes are used, which makes sender recovery a real check
%% rather than a check of this repository's own signing against itself.
%%
%% == Deviations, named
%%
%% These are real limits of what the numbers below mean. None of them is
%% worked around silently.
%%
%%   * **The block's number and timestamp are synthesised, not the fixture's.**
%%     `eth_block` derives a block's fork from its own number and timestamp and
%%     has no way to be told a fork outright, so the runner picks a
%%     number/timestamp pair that lands on the fixture's fork under the mainnet
%%     schedule. Consequence: the `BLOCKNUMBER` and `TIMESTAMP` opcodes do not
%%     see the fixture's values, so a state test that reads them is out of scope.
%%     The alternative -- leaving the fixture's own values and executing every
%%     pre-Merge fixture under Paris -- would be wrong on far more of them and
%%     wrong *silently*, which is the failure mode this repository treats as
%%     worst.
%%   * **Frontier is unreachable.** The mainnet schedule's earliest activation
%%     is Homestead at 1,150,000, so there is no number or timestamp that
%%     selects `frontier`, and a block before it resolves to `paris`. Frontier
%%     entries are reported as `fork_unreachable` and counted, not skipped
%%     quietly.
%%   * **`CHAINID` is mainnet's 1.** That is what the fixtures declare
%%     (`config.chainid: 0x01`) and what `ETH_NETWORK=mainnet` makes
%%     `eth_fork_schedule:chain_id/0` return, so this one agrees by
%%     construction rather than by luck. The runner sets the network explicitly
%%     for the same reason: the default is Sepolia, whose chain id is 11155111.
%%   * **No state root, no receipts root, no bloom, no block header.** A state
%%     test asserts none of those, and this node cannot currently execute a
%%     whole block against EEST anyway (see the `blockchain_tests` gap in
%%     TASKS.md). This is a state-transition corpus, not a block corpus, and the
%%     total below must not be read as block-level conformance.
-module(eest_state_tests).

-include_lib("eunit/include/eunit.hrl").
-include("eth_block.hrl").

-export([schedule_fork_of_key/1,
           corpus/0, committed/0, entries/0, entries/1, outcomes/0,
         tally/1, report/0, report/1, survey/1, survey/0, survey/2, files/1]).

%% A streaming pass over a corpus: the tally, a per-fork breakdown, a histogram of
%% the gas deltas, and a bounded sample of the divergences.
%%
%% `entries/1' builds a list of every result *and* keeps every detail map alive,
%% which is fine for the 266-entry committed subset and hopeless for the full
%% 2,681-file suite: the run spent over an hour at 100% CPU in `erts_bor', the
%% garbage collector, because the detail maps -- one per state mismatch, each
%% holding a diff list and a gas story -- were all retained simultaneously. The
%% arithmetic never closed because nothing was ever going to.
%%
%% So this folds instead of collecting. Nothing here needs the whole result set: the
%% tally is a fold, the per-fork counts are a fold, the histogram is a fold, and the
%% only thing worth keeping verbatim is a sample of divergences, which is bounded by
%% construction. Peak memory is one fixture's decoded JSON rather than the corpus's.
-spec survey(file:filename_all()) -> map().
survey(Root) -> survey(Root, 0).

%% `Every' is a progress interval in files; 0 is silent.
%%
%% The interval exists because a run over the whole upstream corpus is measured in
%% hours, and the first version of this printed **nothing at all** until it finished.
%% Four hours at 100% CPU with an output file still at its first line is
%% indistinguishable from a hung process, and the only way to tell the two apart was
%% to go and look at `ps' -- so a long run could not be left alone and had to be
%% babysat, which is the opposite of what a background measurement is for.
%%
%% Progress goes to `standard_error' so it cannot interleave with the report on
%% `standard_io', and it is off for the committed subset so a test run and a
%% developer run of the same function print the same thing.
survey(Root, Every) ->
    with_mainnet(
      fun() ->
              eth_test_util:with_local_reads(
                fun() ->
                        Files = files(Root),
                        T0 = erlang:monotonic_time(millisecond),
                        lists:foldl(fun(F, A) ->
                                            Acc = file_survey(F, A),
                                            report_progress(Acc, Every, T0),
                                            Acc
                                    end,
                                    initial_survey(length(Files), Every), Files)
                end)
      end).

report_progress(#{files_done := D, files := N, total := T, every := Every}, Every, T0)
  when is_integer(Every), Every > 0, D rem Every =:= 0 ->
    Ms = erlang:monotonic_time(millisecond) - T0,
    io:format(standard_error,
              "~p/~p files, ~p entries, ~p ms~n", [D, N, T, Ms]),
    ok;
report_progress(_Acc, _Every, _T0) ->
    ok.

initial_survey(N, Every) ->
    #{files => N, files_done => 0, every => Every, total => 0,
      tally => maps:from_list([{O, 0} || O <- outcomes()]),
      by_fork => #{}, gas => #{}, rejects => #{}, sample => [], sample_limit => 40}.

%% Fold one file's results in. Reversed so the accumulated list stays cheap.
file_survey(File, Acc) ->
    Acc1 = lists:foldl(fun(R, A) -> survey_one(R, A) end, Acc, file_entries(File)),
    maps:update_with(files_done, fun(N) -> N + 1 end, 1, Acc1).

survey_one({Key, Outcome, Detail, _File} = R, Acc) ->
    #{total := T, tally := Tl, by_fork := Bf, gas := G, rejects := Rj, sample := S,
      sample_limit := Lim} = Acc,
    Fork = fork_of_key(Key),
    Acc1 = Acc#{total => T + 1,
                tally => maps:update_with(Outcome, fun(N) -> N + 1 end, 1, Tl),
                %% **One count per entry, prepended -- not the previous list used as
                %% the new entry's count.** This read
%%%
%%     fun(N) -> [{Outcome, N} | N] end,   %% initialiser [{Outcome, 1}]
%%%
                %% where `N' is already the **list** of `{Outcome, Count}' pairs for this
                %% fork, so every entry's "count" became the whole accumulation so far
                %% and the structure grew quadratically. It had three consequences, all
                %% of them only visible at corpus scale, which is why the committed
                %% 266-entry subset never showed any of them:
                %%
                %%   * `eest_report:print_by_fork/1' does `lists:sum/1' over the counts
                %%     and got a **list** where it wanted a number -- `badarith: 0 +
                %%     [{match, [{match, ...}]}]` -- at the **second** entry of the
                %%     first fork with two entries. So the by-fork breakdown had never
                %%     been printed at all, on any corpus, and the developer tool
                %%     whose job is to print it died instead.
                %%   * Memory grew with the square of the entries per fork. The prague
                %%     run reached 1,993 entries and then the VM gave up.
                %%   * The `n=' and `match=' figures it would have printed, had it
                %%     printed anything, were sums of 1s and lists.
                %%
                %% `print_by_fork/1' counts the occurrences itself, so duplicates are
                %% correct here; what it needed was a **flat** list.
                by_fork => maps:update_with(Fork,
                                           fun(L) -> [{Outcome, 1} | L] end,
                                           [], Bf),
                gas => add_gas_delta(G, Outcome, Detail),
                rejects => add_reject_reason(Rj, Outcome, Detail)},
    Acc2 = case Outcome =:= match orelse length(S) >= Lim of
               true -> Acc1;
               false -> Acc1#{sample => [R | S]}
           end,
    Acc2.

%% Only deltas in the schedule-sized range are histogrammed. The whole-allowance
%% ones -- a frame that burned its limit against a fixture that did not -- say
%% that something is wrong and nothing about which rule, and there are thousands of
%% them; keeping them drowns the ones that name a constant.
add_gas_delta(G, Outcome, #{gas := #{delta := D}})
  when is_integer(D), Outcome =:= state_mismatch, abs(D) =< 100000 ->
    maps:update_with(D, fun(N) -> N + 1 end, 1, G);
add_gas_delta(G, _Outcome, _Detail) -> G.

%% **The rejection histogram: `{expected code, code the node named, its own reason}`.**
%%
%% `rejection_mismatch' is the corpus's largest cluster by count and it was, until this,
%% unmeasurable -- the report printed the outcome, the file and the key, and the reason
%% lived in a detail map the sample discarded. A 40-entry sample out of 1,975 is a 2%
%% look, and the question the cluster raises is precisely which *rule* the node and the
%% corpus disagree about, which a sample cannot answer when one rule accounts for 78% of
%% it.
%%
%% The key is the whole triple, not the outcome: "the corpus says A, the node says B,
%% for reason R" is the unit that identifies a defect, and collapsing to any one of the
%% three loses the distinction between a *renamed* rule and a *different* rule. That
%% distinction is the entire measurement -- measured on the 22 files that declare
%% `expectException', the largest pair is
%% `{INTRINSIC_GAS_TOO_LOW, INTRINSIC_GAS, intrinsic_gas}', in which the node refused for
%% exactly the rule the fixture names and differs only in the name it gave it.
add_reject_reason(Rj, rejection_mismatch,
                  #{expected := Want, got := Got, reason := Reason}) ->
    maps:update_with({Want, Got, Reason}, fun(N) -> N + 1 end, 1, Rj);
add_reject_reason(Rj, expected_rejection_not_raised, #{expected := Want}) ->
    maps:update_with({Want, <<"accepted">>, <<"not_refused">>},
                     fun(N) -> N + 1 end, 1, Rj);
add_reject_reason(Rj, _Outcome, _Detail) -> Rj.

%% The corpus's files, as a list. Split out because `entries/1' and `survey/1' both
%% need it and the `**' detail is worth saying once.
-spec files(file:filename_all()) -> [file:filename()].
files(Root) ->
    %% `**' rather than `*': the corpus is nested fork/suite/file, so a
    %% single-level wildcard finds nothing and reports a zero total, which reads
    %% as "everything passes" rather than as "nothing was run".
    filelib:wildcard(filename:join([Root, "**", "*.json"])).

survey() -> survey(corpus()).

%% ---------------------------------------------------------------------------
%% The corpus
%% ---------------------------------------------------------------------------

%% `EEST_CORPUS' points at an extracted upstream tarball; without it the run is
%% over the committed subset. The two produce different totals by design -- one
%% is the whole upstream suite, the other is what the repository pins -- and
%% `report/0' says which it did.
corpus() ->
    case os:getenv("EEST_CORPUS") of
        false -> committed();
        "" -> committed();
        Dir -> Dir
    end.

%% Path relative to the project root, which is where `rebar3 eunit' runs from.
%% There is no portable way to ask a compiled test module where its own source
%% tree is, and the alternative -- shipping the fixtures into `_build' -- would
%% put 500 MB of somebody else's expected results next to the build output.
committed() -> "apps/etherlang/test/vectors/eest".

%% ---------------------------------------------------------------------------
%% Fork selection
%% ---------------------------------------------------------------------------
%%
%% A fixture names its fork in the test key, `[fork_Berlin-state_test]'. Getting
%% that fork into the execution path needs a block whose number and timestamp
%% land on it under the mainnet schedule, because `eth_block:fork_of/1' has no
%% way to be told a fork outright.
%%
%% `undefined' marks a fork with no such number or timestamp. Frontier is the
%% only one: the mainnet schedule's earliest activation is Homestead at
%% 1,150,000, so nothing selects `frontier' and a block before that resolves to
%% `paris'. Those entries are reported, not skipped.
%%
%% Paris is selected by total difficulty, not by a number -- EIP-3675 -- so the
%% four post-Merge entries carry mainnet's TERMINAL_TOTAL_DIFFICULTY and differ
%% only in timestamp.
fork_point(<<"Homestead">>) -> {1200000, 0, undefined};
fork_point(<<"Byzantium">>) -> {5000000, 0, undefined};
%% EEST's `ConstantinopleFix' is Petersburg's rules: Constantinople's
%% activation was reverted and re-applied, and the pair share a block number, so
%% the schedule reaches petersburg and the higher rank is what comes back.
fork_point(<<"ConstantinopleFix">>) -> {7300000, 0, undefined};
fork_point(<<"Istanbul">>) -> {9100000, 0, undefined};
fork_point(<<"Berlin">>) -> {12250000, 0, undefined};
fork_point(<<"London">>) -> {13000000, 0, undefined};
fork_point(<<"Paris">>) -> {20000000, 1000, mainnet_ttd()};
fork_point(<<"Shanghai">>) -> {20000000, 1690000000, mainnet_ttd()};
fork_point(<<"Cancun">>) -> {20000000, 1720000000, mainnet_ttd()};
fork_point(<<"Prague">>) -> {20000000, 1750000000, mainnet_ttd()};
fork_point(<<"Osaka">>) -> {20000000, 1770000000, mainnet_ttd()};
fork_point(_) -> undefined.

mainnet_ttd() -> 58750000000000000000000.

fork_of_key(Key) ->
    %% `binary' capture, not `list': thoas decodes JSON object keys as binaries,
    %% so the `post' map is keyed by <<"Berlin">> and a name arriving as the
    %% string "Berlin" matches nothing. Every entry then reports
    %% `no_post_for_fork', which reads as a total absence of expected results
    %% rather than as a string/binary mismatch.
    case re:run(Key, "fork_([A-Za-z0-9]+)-", [{capture, all_but_first, binary}]) of
        {match, [Name]} -> Name;
        _ -> undefined
    end.

%% ---------------------------------------------------------------------------
%% Outcomes
%% ---------------------------------------------------------------------------
%%
%% The vocabulary is the point of this module. "Diverges" is not a category:
%% a codec that cannot decode the transaction, a signature that recovers the
%% wrong address, a transaction the node admits that the specification rejects,
%% and a state that comes out different are four different bugs with four
%% different owners, and a single pass/fail number would sum them.

-define(MATCH, match).
-define(STATE_MISMATCH, state_mismatch).
-define(TX_DECODE, tx_decode_failed).
-define(TX_ROUNDTRIP, tx_roundtrip_mismatch).
-define(SENDER, sender_mismatch).
-define(REJECT_NOT_RAISED, expected_rejection_not_raised).
-define(REJECT_MISMATCH, rejection_mismatch).
-define(FORK_UNREACHABLE, fork_unreachable).
-define(CRASH, crash).
%% "This node cannot price something in this transaction." Not a state difference and
%% not a validity disagreement: the node declines rather than answering wrongly. Added
%% when `eth_block:run_transaction/5' started refusing an unpriceable operation instead
%% of executing it into a state root the chain would not produce -- which was 55 of the
%% 266 committed fixtures. Folding those into `crash' would blame the harness and into
%% `state_mismatch' would blame the arithmetic; either would hide the thing the number
%% exists to say.
-define(UNPRICED, unpriced).
-define(NO_POST, no_post_for_fork).
-define(BAD_FIXTURE, unreadable_fixture).

outcomes() ->
    [?MATCH, ?STATE_MISMATCH, ?TX_DECODE, ?TX_ROUNDTRIP, ?SENDER,
     ?REJECT_NOT_RAISED, ?REJECT_MISMATCH, ?FORK_UNREACHABLE, ?CRASH,
     ?NO_POST, ?BAD_FIXTURE, ?UNPRICED].

%% Every outcome, always, including the ones that did not occur.
%%
%% Counting only what was seen makes the map's *shape* a function of the corpus,
%% so a report diff between two runs has to be read against "which keys are
%% missing" as well as "which counts moved", and an absent key is indistinguishable
%% from a key that was never possible. Seeding all of them costs nothing and makes
%% two tallies comparable by value.
tally(Results) ->
    lists:foldl(fun({_Key, Outcome, _Detail, _File}, Acc) ->
                    maps:update_with(Outcome, fun(N) -> N + 1 end, 1, Acc)
                end,
                maps:from_list([{O, 0} || O <- outcomes()]),
                Results).

%% ---------------------------------------------------------------------------
%% Reporting
%% ---------------------------------------------------------------------------

report() -> report(corpus()).

report(Root) ->
    Results = entries(Root),
    #{root => Root,
      total => length(Results),
      tally => tally(Results),
      results => Results}.

%% ---------------------------------------------------------------------------
%% Corpus walking
%% ---------------------------------------------------------------------------

entries() -> entries(corpus()).

entries(Root) ->
    %% `**' rather than `*': the corpus is nested fork/suite/file, so a
    %% single-level wildcard finds nothing and reports a zero total, which reads
    %% as "everything passes" rather than as "nothing was run".
    Files = filelib:wildcard(filename:join([Root, "**", "*.json"])),
    %% Every read is local for the whole traversal, and not as an optimisation.
    %% `eth_state' answers from its overlay and falls through to `base_source' for
    %% anything absent, which in the default `upstream' mode is an HTTP call to a
    %% public Sepolia node. The coinbase is the obvious one: a fixture's `pre'
    %% rarely declares it, and `settle_gas/7' reads its balance to pay the tip.
    %% A test that does this does not fail, it *hangs*, and EUnit reports a hang
    %% as a cancelled test -- so the symptom is a suite quietly losing tests.
    WithLocal = fun() -> lists:sort(lists:append([file_entries(F) || F <- Files])) end,
    with_mainnet(WithLocal).

%% Run against mainnet's fork schedule, and own that decision rather than leaving
%% it to the caller.
%%
%% Two reasons, and the second is the one that actually cost reproducibility.
%%
%% The fork schedule is mainnet's: its block-numbered activations are the ones a
%% fixture fork name can be mapped onto, and `ETH_NETWORK` is how the runner picks
%% them. But `eth_fork_schedule:chain_id/0` reads the same variable, and the
%% fixtures declare `config.chainid: 0x01` -- chain 1, which is mainnet's. Left at
%% the default the variable is `sepolia`, whose chain id is 11155111, so the node
%% answered under a chain the fixture is not on.
%%
%% The tally moved when this was found, and it moved *differently in different
%% places*: five EIP-1559 validity fixtures flipped from `expected_rejection_not_
%% raised' to `rejection_mismatch', because the validator rejects a transaction
%% from the wrong chain -- correctly -- and so stopped being evidence of the bug
%% they were evidence of. `homestead/coverage' moved too, on `CHAINID'. A harness
%% that sets up its own preconditions and then lets the ambient environment pick
%% the rest is not a harness.
with_mainnet(Fun) ->
    Previous = os:getenv("ETH_NETWORK"),
    os:putenv("ETH_NETWORK", "mainnet"),
    try Fun()
    after
        case Previous of
            false -> os:unsetenv("ETH_NETWORK");
            _ -> os:putenv("ETH_NETWORK", Previous)
        end
    end.

%% Every state this module builds reads from `empty': an account or slot the
%% fixture does not declare does not exist, and says so.
%%
%% It used to read from the local MPT via `with_local_reads', and that made the
%% conformance figure depend on what the rest of the test run had left in the trie.
%% A storage slot that a fixture's code reads but never declares is not knowable
%% without executing the code, so no amount of seeding removes it. `empty' removes
%% the dependency instead of reducing it: the answer is now a property of the
%% fixture, so the tally is reproducible.
%%
%% The process-wide `mpt' is still set underneath, and that is deliberate belt and
%% braces rather than redundancy. `empty' is carried on the state term, so it
%% covers every read that takes one; `with_local_reads' covers a read that somehow
%% does not, and turns what would be an HTTP request to a public Sepolia node into
%% a local answer. The second is a safety net, not the mechanism.
state_for(Entry, Post) ->
    eth_state:with_base_source(state(Entry, Post), empty).

file_entries(File) ->
    case read_fixture(File) of
        {ok, Map} when is_map(Map) ->
            [begin {Outcome, Detail} = run(Key, Entry), {Key, Outcome, Detail, File} end
             || {Key, Entry} <- maps:to_list(Map), is_map(Entry)];
        {error, Why} ->
            %% One entry, carrying the reason, so a file that cannot be read is
            %% visible in the tally rather than absent from the total.
            [{File, ?BAD_FIXTURE, Why, File}]
    end.

read_fixture(File) ->
    case file:read_file(File) of
        {error, Reason} -> {error, Reason};
        {ok, Bin} ->
            case thoas:decode(Bin) of
                {ok, Map} when is_map(Map) -> {ok, Map};
                _ -> {error, undecodable}
            end
    end.

%% Run one fixture entry and classify it.
%%
%% The three checks are ordered so that a failure in an earlier one cannot be
%% reported as a failure in a later one. A transaction this node cannot decode
%% says nothing about its state transition, and a sender recovered from the
%% wrong key would make every account differ for a reason that has nothing to do
%% with the EVM. So the codec and the signature are checked first and reported
%% under their own names, and `state_mismatch' means the state transition itself
%% disagreed.
run(Key, Entry) ->
    case fork_of_key(Key) of
        undefined -> {?FORK_UNREACHABLE, {no_fork_in_key, Key}};
        Fork ->
            case fork_point(Fork) of
                undefined -> {?FORK_UNREACHABLE, {no_activation_point, Fork}};
                _ ->
                    case post_for_fork(Entry, Fork) of
                        undefined -> {?NO_POST, {fork, Fork}};
                        Post -> run_post(Fork, Entry, Post)
                    end
            end
    end.

%% The expected post-state for this fork.
%%
%% `post' is keyed by fork name and an entry may list several entries for the
%% same fork -- the filler emits one per generated case -- so the first is taken
%% and the rest are not compared. That is a real limit and it is stated in
%% PROVENANCE.md rather than papered over: a file that generates several cases
%% for one fork is contributing one of them, and which one is not recorded in
%% the fixture's own key.
post_for_fork(Entry, Fork) ->
    Post = maps:get(<<"post">>, Entry, #{}),
    case maps:find(Fork, Post) of
        {ok, [_One | _]} -> _One;
        _ -> undefined
    end.

run_post(Fork, Entry, Post) ->
    %% The `unpriced' refusal is a throw from `execute/4', caught here so one
    %% unpriceable entry does not abort the whole survey. Classifying it is the point:
    %% see the note on the outcome.
    try run_post_inner(Fork, Entry, Post) of
        Result -> Result
    catch
        throw:{?UNPRICED, What} -> {?UNPRICED, {unpriced, What}}
    end.

run_post_inner(Fork, Entry, Post) ->
    %% `txbytes' and `hash' are hex DATA in the fixture; `eth_tx:from_rlp/1' and
    %% the `hash' it puts in the decoded map are raw bytes. Handing one to the
    %% other fails to decode, which is indistinguishable from a codec that
    %% cannot read a transaction type.
    TxBytes = bytes(maps:get(<<"txbytes">>, Post, <<"0x">>)),
    case eth_tx:from_rlp(TxBytes) of
        {error, _} = E -> {?TX_DECODE, E};
        {ok, Tx} -> check_roundtrip(Tx, TxBytes, Entry, Fork, Post)
    end.

%% The decoded transaction, re-encoded, must equal the bytes it came from.
%%
%% This replaced a check of the transaction hash against the fixture's `hash'
%% field, which was wrong and was wrong quietly. The `post' entry carries a
%% `hash'; it is not the transaction's, and this node's hash was right. Computed
%% independently -- keccak256 over the fixture's own `txbytes', outside this
%% codebase -- the result is exactly what `eth_tx:from_rlp/1' produces, and it
%% does not equal the fixture's field. Comparing the two reported a mismatch on
%% every fixture in the corpus. What that field *is* has not been established
%% here, so it is not checked; see the module comment.
%%
%% A round-trip is the better check, and it is not circular: the bytes are
%% execution-specs' own encoding, so re-encoding this node's decoded map back to
%% them exercises the field order and the integer and byte-width rules of every
%% transaction type against a third party rather than against itself.
check_roundtrip(Tx, TxBytes, Entry, Fork, Post) ->
    case eth_tx:to_rlp(Tx) of
        {ok, Reencoded} when Reencoded =:= TxBytes ->
            check_sender(Tx, Entry, Fork, Post);
        {ok, Reencoded} ->
            {?TX_ROUNDTRIP, [{got, short(Reencoded)}, {want, short(TxBytes)}]};
        Other ->
            {?TX_ROUNDTRIP, Other}
    end.

%% Enough of two byte strings to tell them apart in a failure message, and no
%% more: a 98-byte transaction printed whole is a wall of hex that hides the one
%% byte that differs.
short(Bin) when is_binary(Bin), byte_size(Bin) > 24 ->
    {truncated, byte_size(Bin), binary:part(Bin, 0, 12),
     binary:part(Bin, byte_size(Bin) - 12, 12)};
short(Bin) -> Bin.

check_sender(Tx, Entry, Fork, Post) ->
    Want = bytes(maps:get(<<"sender">>, maps:get(<<"transaction">>, Entry, #{}),
                            <<"0x">>)),
    case eth_tx:sender(Tx) of
        {ok, Got} when Got =:= Want -> run_tx(Fork, Tx, Entry, Post);
        {ok, Got} -> {?SENDER, {got, hex(Got)}, {want, hex(Want)}};
        {error, _} = E -> {?SENDER, E}
    end.

%% A transaction with a rejected nonce, an intrinsic gas limit below the floor,
%% or a chain the block is not on must not be executed. The specification says so
%% in the fixture (`expectException'), and a node that ran one anyway would
%% produce a state that no other client produces -- so the check is that the node
%% *refuses* it, and `REJECT_NOT_RAISED' is a divergence, not a pass.
run_tx(Fork, Tx, Entry, Post) ->
    case maps:get(<<"expectException">>, Post, undefined) of
        undefined -> execute(Fork, Tx, Entry, Post);
        Expected -> expect_rejection(Fork, Tx, Entry, Expected)
    end.

%% Rejecting is only half of refusing a transaction, and the runner used to check
%% only that half. `rejection_mismatch' meant "the validator said no" with the
%% reason discarded, so a node that rejected a pre-fork type-2 transaction for
%% entirely the wrong reason -- a wrong nonce, a bad chain id -- scored the same as
%% one that refused it for the reason the fixture names. That is precisely the
%% confusion the outcome vocabulary exists to prevent: a refusal proves nothing
%% about *what* was refused, and the corpus's whole claim is about which rule fired.
%%
%% So the reason is compared against the fixture's `expectException' code. The
%% mapping below is deliberately short, and a reason with no clause is reported as
%% unmapped rather than folded into the nearest one. A loose mapping would
%% manufacture matches, and a manufactured conformance match is the one artefact in
%% this project that would make every other number here a lie.
expect_rejection(Fork, Tx, Entry, Expected) ->
    %% The fixture's **stated** base fee, and the reason it is not `none' is worth
    %% recording, because the reason was wrong for a long time and the experiment that
    %% found it was repeated here rather than believed.
    %%
    %% `merge_base_fee(Base, none) -> Base' reads `none' as "use the fork's default and
    %% do not derive", so this path used to hand the validator a base fee the fixture
    %% never stated while the execution path handed it the derived one: **the two paths
    %% disagreed about the same fixture's header field.**
    %%
    %% Fixing that was measured and **rejected**, on the grounds that it "fixes one
    %% entry and loses nine overall: matches 1,728 -> 1,719 ... Twelve entries move to
    %% `rejection_mismatch' as `{unmapped, fee_too_low}', because with the stated base
    %% fee the *fee* check now fires before the rule those fixtures are about". The
    %% diagnosis in that note -- that this was a **check-ordering** question in
    %% `eth_tx:validate/2' -- **was wrong**, and the evidence is that the reordering is
    %% not what changed the answer.
    %%
    %% The cause was a missing clause. `fee_ceiling_ok/4' chose the ceiling with
    % `case tx_type(Tx) of eip1559 -> MaxFee; eip4844 -> MaxFee; _ -> GasPrice end`, and
    %% **`eip7702` was not in it**. A type-4 transaction has no `gasPrice` field, so the
    %% `_` branch read `field/3''s default of `0`, and with a *correct* base fee of 7
    %% every type-4 transaction was refused as underpriced against its own cap. That
    %% single clause was all 72 of those entries, and it was the entire content of the
    %% "-9": the twelve that moved to `fee_too_low' were type-4 transactions being
    %% refused for a rule that never applied to them. `fee_fields_ok/4' had the
    %% identical missing clause and `v1.54` fixed it there; this is the same defect in
    %% the neighbouring function, which is why the note blamed a reordering rather than
    %% a lookup.
    %%
    %% With that clause present, supplying the stated base fee is **exactly neutral**:
    %% matches 1,784, `state_mismatch` 122 and `rejection_mismatch` 1,974 either way,
    %% with no `{unmapped, fee_too_low}' anywhere. It fixes 3 entries, which stop being
    %% accepted and start being refused for the right rule -- and it is what makes the
    %% two paths agree. The lesson, recorded so it is not re-learned: **a rejected
    %% experiment's *diagnosis* has to be re-tested when the code it blamed changes.**
    %% The measurement was sound; the explanation it offered was not, and it was written
    %% down with the same confidence as the number.
    Block = block(Fork, Entry, derived_base_fee(Entry, #{}, Tx)),
    State = state_for(Entry, #{}),
    case eth_tx:validate(Tx, validation_ctx(Block, State)) of
        {error, Reason} ->
            %% The transaction's type is passed in from `Tx' and not read out of the
            %% fixture's code, because the code is the thing being checked. A
            %% mapping that derived the expected type from the expectation would
            %% compare the expectation with itself.
            Got = node_exception(Reason, eth_tx:tx_type(Tx)),
            Want = exception_code(Expected),
            case Want =:= Got of
                true -> {?MATCH, {rejected, Want}};
                false -> {?REJECT_MISMATCH, #{expected => Want, got => Got,
                                              reason => Reason}}
            end;
        ok ->
            {?REJECT_NOT_RAISED, #{expected => exception_code(Expected)}}
    end.

%% The fixture's code, reduced to the name the specification gives it:
%% `"TransactionException.TYPE_2_TX_PRE_FORK"' -> `TYPE_2_TX_PRE_FORK'.
%%
%% `TransactionException' is dropped and that is not a loosening of the comparison.
%% It is the namespace a *transaction* rule lives in, and every code
%% `eth_tx:validate/2' can raise belongs to it, so keeping it would mean this
%% function compared the fixture's namespace against the node's vocabulary and
%% nothing could ever match -- the first version did exactly that and reported five
%% correct refusals as five mismatches.
%%
%% `BlockchainException' is a different vocabulary and is **kept**: a block-level
%% failure is not a transaction rule, so a fixture expecting one can never be
%% satisfied by a validator's answer, and saying so is better than matching it
%% loosely. Codes this node has no mapping for come back as `{unmapped, Reason}' and
%% land in `rejection_mismatch', so an unmapped code costs a match rather than
%% buying one.
exception_code(<<"TransactionException.", Code/binary>>) -> Code;
exception_code(Expected) when is_binary(Expected) -> Expected;
exception_code(Other) ->
    Other.

%% The code this node would be raising for a given validator error, given the
%% transaction's type.
%%
%% Every code below is one the corpus has actually asked for. That is the rule, and
%% it is why the list is short: a code invented from the EIP's prose rather than
%% read off a fixture would be a guess about the corpus's vocabulary, and a wrong
%% guess here is a *manufactured conformance match*. The type-4 null-destination
%% rule is implemented (`eth_tx:check_set_code/1') and deliberately absent from this
%% table, because no committed fixture asks for its code. Until one does it reports
%% as unmapped, which costs a match -- the correct direction to be wrong in.
%%
%% Each clause is here because the error is raised for that reason and no other.
%% `tx_type_pre_fork' is a single `eth_fork_schedule:tx_type_available/2' call,
%% whose whole answer is a fork comparison, so it can only mean a type that
%% postdates the fork -- but which type is not in the error, so the type is threaded
%% through from the transaction and rendered into the fixture's own vocabulary.
%%
%% `initcode_size_exceeded' and `sender_not_eoa' are the two rules this node
%% **implemented** in response to this table, and that is a different relationship from
%% the rest of it. Everywhere else the corpus named a rule and the node had one under
%% another name; here the corpus named a rule the node did not have at all, and the name
%% is the same on both sides because the rule is the same. Adding the clause is part of
%% implementing the rule: without it the eight EIP-3607 entries and the six EIP-3860
%% entries would have moved from `expected_rejection_not_raised' to `rejection_mismatch',
%% which is to say the node would have started refusing for the right reason and been
%% recorded as refusing for the wrong one.
node_exception(tx_type_pre_fork, eip2930) -> <<"TYPE_1_TX_PRE_FORK">>;
node_exception(tx_type_pre_fork, eip1559) -> <<"TYPE_2_TX_PRE_FORK">>;
node_exception(tx_type_pre_fork, eip4844) -> <<"TYPE_3_TX_PRE_FORK">>;
node_exception(tx_type_pre_fork, eip7702) -> <<"TYPE_4_TX_PRE_FORK">>;
node_exception(tx_type_pre_fork, Type) -> {unmapped_type, Type};
node_exception(empty_auth_list, eip7702) -> <<"TYPE_4_EMPTY_AUTHORIZATION_LIST">>;
node_exception(unsupported_type, _Type) -> <<"TX_TYPE_UNSUPPORTED">>;
node_exception(intrinsic_gas, _Type) -> <<"INTRINSIC_GAS">>;
node_exception(initcode_size_exceeded, _Type) -> <<"INITCODE_SIZE_EXCEEDED">>;
node_exception(sender_not_eoa, _Type) -> <<"SENDER_NOT_EOA">>;
%% A type-4 transaction with maxPriorityFeePerGas above maxFeePerGas reaches this as
%% `invalid_fee', which is what `fee_fields_ok/4' has always thrown for a *fee-field*
%% problem. The corpus names the specific condition rather than the category, and here
%% the node and the corpus are describing the same rule, so the mapping is an identity
%% in substance and not a rename.
node_exception(invalid_fee, eip7702) -> <<"PRIORITY_GREATER_THAN_MAX_FEE_PER_GAS">>;
node_exception(calldata_floor, _Type) -> <<"GASLIMIT_TOO_LOW">>;
node_exception(nonce_too_low, _Type) -> <<"NONCE_TOO_LOW">>;
node_exception(nonce_too_high, _Type) -> <<"NONCE_TOO_HIGH">>;
node_exception(insufficient_funds, _Type) -> <<"INSUFFICIENT_BALANCE">>;
node_exception(bad_chain_id, _Type) -> <<"CHAIN_ID_MISMATCH">>;
node_exception(blob_fee_too_low, _Type) -> <<"BLOB_GAS_PRICE_TOO_LOW">>;
node_exception(bad_blob_hashes, _Type) -> <<"INVALID_BLOBS">>;
node_exception(Reason, _Type) -> {unmapped, Reason}.

%% The block the transaction executes in.
%%
%% Number and timestamp come from `fork_point/1' rather than from the fixture's
%% own `env', because the fork is derived from them and there is no other way in.
%% See the module comment: this is a deviation, and it costs BLOCKNUMBER and
%% TIMESTAMP. Everything else the fixture does specify -- coinbase, gas limit,
%% difficulty -- is used as given.
%% The block's base fee, derived from the fixture when it does not say.
%%
%% The `state_test' format has no `baseFeePerGas' in its `env' -- it is a
%% single-transaction test, not a block -- so a runner has to supply one, and
%% supplying `0' is a choice with consequences: the coinbase is paid
%% `gasUsed * (effectivePrice - baseFee)', so with the base fee wrongly at zero the
%% coinbase is credited the *whole* gas price and every London-or-later fixture
%% carries a coinbase diff that says nothing about the node.
%%
%% 243 of the 249 state mismatches had a coinbase diff. Most also had other
%% diffs, so this is not what is wrong with them, but it meant a real tip bug and a
%% harness default were indistinguishable -- which is the one thing a conformance
%% harness must not be.
%%
%% So the fee is **derived from the fixture's own expected numbers**: the sender's
%% expected spend divided by the effective price is the expected `gasUsed', the
%% coinbase's expected gain divided by that is the expected tip per gas, and the
%% difference is the base fee. For a one-zero-byte Prague transaction the fixture
%% expects 21,010 gas and a 63,030 wei coinbase gain at a price of 10, which is a
%% tip of 3 and so a base fee of 7 -- the protocol minimum, which is what a
%% synthetic genesis block has.
%%
%% This is reconstruction, not knowledge: the fee is an input the format omits and
%% it is recovered from the expected output. That is preferable to guessing `0' and
%% it is stated here because it is the kind of thing that would be dishonest to
%% leave implicit. Where the arithmetic does not come out whole -- a create, a
%% value transfer, a zero price -- it is not derivable, and the coinbase is then
%% reported as `base fee not derivable' rather than compared against a number
%% invented to make it match.
block(Fork, Entry, BaseFee) ->
    Env = maps:get(<<"env">>, Entry, #{}),
    {Number, Timestamp, TD} = fork_point(Fork),
    (eth_block:new(<<0:256>>, Number))#block{
        timestamp = Timestamp,
        miner = addr(maps:get(<<"currentCoinbase">>, Env, <<"0x">>)),
        difficulty = int(maps:get(<<"currentDifficulty">>, Env, <<"0x0">>)),
        total_difficulty = TD,
        gas_limit = int(maps:get(<<"currentGasLimit">>, Env, <<"0x0">>)),
        gas_used = 0,
        %% EIP-4844's blob base fee is a function of the **block's own**
        %% `excess_blob_gas', and `eth_block:blob_fee/2' reads it from here. This
        %% header field was not set at all, so every block the runner built carried
        %% `eth_block:new/2''s default of 0 -- which happens to price blobs at the
        %% 1 wei minimum, and which was therefore *right* for any fixture whose
        %% excess is low enough not to move the curve. `test_sufficient_balance_blob_tx'
        %% states `currentExcessBlobGas = 0x0e0000' = 917,504, and the curve there is
        %% also 1, so the omission did not change that file's answer either -- but the
        %% field is what the EIP names and the harness is what supplies header fields
        %% to execution, so it is read from `env' like every other one.
        excess_blob_gas = int(maps:get(<<"currentExcessBlobGas">>, Env, <<"0x0">>)),
        base_fee_per_gas = merge_base_fee(base_fee_for(schedule_fork_at(Number, Timestamp, TD)),
                                                    BaseFee),
        mix_hash = <<0:256>>,
        logs_bloom = eth_bloom:new()}.

%% The block's base fee, and it is not one value.
%%
%% The field does not exist before London, and `eth_block:effective_gas_price/4'
%% tells the two apart by `undefined' rather than by a number. Handing it `0' for
%% a pre-London block sends it down the EIP-1559 branch -- `maps:get(<<"maxFeePerGas">>',
%% Tx, 0)' cannot distinguish an absent field from a zero one, and both are
%% integers, so `min(0, 0 + 0)' is 0 -- and every legacy transaction then executes
%% with a gas price of zero. The sender pays nothing, the coinbase gets no tip,
%% and the block's balances are wrong in a way that looks like a gas bug in the
%% schedule rather than like a defaulted argument. It is worth knowing that this
%% function has that failure mode; it is not reachable from `finalize/1', which
%% passes the block's own base fee and a pre-London block has none.
%% **Which fork this block is, asked of the schedule.**
%%
%% `block/3` was handing `base_fee_for/1` the *fixture's* fork name, and that name is a
%% **binary**: `fork_of_key/1' does a binary capture out of the entry's key, so it is
%% `<<"Paris">>' and not `paris'. `eth_fork_schedule:at_least/2' takes an atom and
%% answers `false` for anything it does not recognise -- that is the module's stated
%% direction, an unrecognised fork ranks as ancient -- so:
%%
%%     at_least(<<"London">>, london) = false      (verified, not inferred)
%%     at_least(london, london)        = true
%%
%% and `base_fee_for/1` therefore answered `undefined` for **every** fork. Pre-London
%% that is the correct answer, which is exactly why the bug was invisible for the two
%% thirds of the corpus that predates London and fatal for the rest: the block carried
%% no base fee, `effective_gas_price/4' took its `undefined` branch, and a **typed**
%% transaction -- which has no `gasPrice` field to fall back on -- was executed at an
%% effective price of **0**. An instrumented run of
%% `london/eip1559_fee_market_change/test_eip1559_tx_validity` reads
%% `basefee=undefined eff=0 ceiling=7 charged=26006 sender_drop=0`: the sender is
%% debited 700,000 at `maxFeePerGas` and refunded nothing, for gas that was correct.
%%
%% The fix asks `current_fork/4'` about the block the runner is building, using the
%% `{Number, Timestamp, TD}` that `fork_point/1' already returned. Two reasons for that
%% rather than translating the name:
%%
%%   * it is a **list that does not exist**. The alternative -- a `<<"Frontier">> ->
%%     frontier' clause per name -- is a second copy of `eth_fork_schedule`'s fork list,
%%     in the one place that cannot check it. EEST's `ConstantinopleFix` has no schedule
%%     atom at all, so the list needs a clause that is a lie: that fork is Petersburg's
%%     rules, as the note on `fork_point/1' already says.
%%   * the block's own point is the thing being asked about. The name is a label; the
%%     number and timestamp are what `current_fork/4' decides on.
%%
%% Both forms were measured and both are worth +7 fixtures **once the base fee itself
%% is right** (see `derived_base_fee/3`), and neither is worth anything alone. That is
%% the part worth remembering: this fixes a wrong *argument* to a correct question, and
%% the question then turned out to have a wrong *input* as well.
schedule_fork_at(Number, Timestamp, TD) ->
    %% **mainnet, not `configured_network()'**, because the numbers `fork_point/1'
    %% supplies are mainnet's. Asking the configured network -- Sepolia by default --
    %% answers a different question: mainnet's Berlin activation is 12,244,000 and
    %% Sepolia's London is long before 12,250,000, so `schedule_fork_at/3` said `london'
    %% for a Berlin fixture. The new invariant test caught that on its first run, which
    %% is the argument for writing it before trusting the function.
    case eth_fork_schedule:current_fork(mainnet, Number, Timestamp, TD) of
        {ok, F} -> F;
        _ -> frontier
    end.

%% The schedule fork a fixture name resolves to, for a test that wants to assert the
%% mapping without reaching into `block/3'. Exported for the same reason `outcomes/0'
%% is: the invariant is worth stating and the arithmetic behind it is not.
-spec schedule_fork_of_key(binary()) -> atom().
schedule_fork_of_key(Name) when is_binary(Name) ->
    {Number, Timestamp, TD} = fork_point(Name),
    schedule_fork_at(Number, Timestamp, TD).

base_fee_for(Fork) ->
    case eth_fork_schedule:at_least(Fork, london) of
        true -> 0;
        false -> undefined
    end.

%% A derived fee only applies where there is a base fee to have. `none' means the
%% caller had nothing to derive and the fork default stands.
merge_base_fee(undefined, _Derived) -> undefined;
merge_base_fee(Base, none) -> Base;
merge_base_fee(_Base, Derived) -> Derived.

%% Recover the base fee from the expected post-state, or `none'.
%% **The fixture states the base fee, so read it before deriving one.**
%%
%% `env.currentBaseFee' is in the fixture -- `0x07' throughout
%% `london/eip1559_fee_market_change/test_eip1559_tx_validity` -- and the derivation
%% below cannot recover it for these entries. Not because the arithmetic is wrong, but
%% because it has nothing to stand on:
%%
%%     Spend = GasUsed * E               E = min(maxFee, baseFee + priority)
%%     Gain  = GasUsed * (E - baseFee)
%%
%% With `baseFee = 7, maxFee = 7, priority = 1` the **tip is zero**: `E = min(7, 8) = 7`
%% and `E - baseFee = 0`, so `Gain` is 0 and the sender's spend cannot separate the base
%% fee from the effective price. The derivation reads the sender's price as
%% `effective_price/2', which returns `min(maxFee, priority)' = `min(7, 1)' = **1** --
%% the *tip*, not the price -- and with a zero tip that assumption collapses the two
%% equations into one.
%%
%% Solving both equations properly was written and measured, and it is the weaker fix:
%% +2 fixtures against this one's +7, and it needs explicit integer arithmetic in the
%% measurement path because the rational form is a float in Erlang, a float became a
%% block's `base_fee_per_gas', and `eth_word:mask/1' raised `badarith` **inside the
%% node** on a block the test had malformed.
%%
%% So the stated figure wins, and the derivation is kept for the fixtures that state
%% none. The three readings are in one place and in this order, deliberately:
%%
%%   1. `env.currentBaseFee` -- the fixture's own header field, authoritative;
%%   2. the derivation from the two balance deltas -- a guess with three ways to fail;
%%   3. `none`, which `merge_base_fee/1' turns into the fork's default.
%%
%% `merge_base_fee/1`'s first clause is **left alone**. It looks like the bug -- it
%% discards a derived value whenever the fork's figure is `undefined` -- and it is
%% instead the thing that stops a base fee being attached to a pre-London block, where
%% the field must not exist. Removing it was measured: the tally falls **46 -> 19**.
derived_base_fee(Entry, Post, Tx) ->
    case maps:find(<<"currentBaseFee">>, maps:get(<<"env">>, Entry, #{})) of
        {ok, Hex} when is_binary(Hex) -> int(Hex);
        _ -> derive_base_fee(Entry, Post, Tx)
    end.

derive_base_fee(Entry, Post, Tx) ->

    State = maps:get(<<"state">>, Post, #{}),
    Sender = maps:get(<<"sender">>, maps:get(<<"transaction">>, Entry, #{}), <<"0x">>),
    Coinbase = maps:get(<<"currentCoinbase">>, maps:get(<<"env">>, Entry, #{}), <<"0x">>),
    Price = effective_price(Tx, #{}),
    SenderHex = hex(bytes(Sender)),
    CoinbaseHex = hex(bytes(Coinbase)),
    case {Price, maps:find(SenderHex, State), maps:find(CoinbaseHex, State)} of
        {0, _, _} ->
            none;
        {_, error, _} ->
            none;
        {_, _, error} ->
            none;
        {P, {ok, SF}, {ok, CF}} ->
            Pre = maps:get(<<"pre">>, Entry, #{}),
            %% An account the fixture does not declare is an *empty* account, not an
            %% unknown one -- the same convention `mentioned/2' seeds under. The
            %% first version treated a missing pre-balance as a reason to give up,
            %% and the fee recipient is usually not in `pre' at all, so the derivation
            %% never ran on the fixtures it was written for.
            Spend = pre_balance(Pre, SenderHex) - balance_of(SF),
            Gain = balance_of(CF) - pre_balance(Pre, CoinbaseHex),
            case Spend > 0 andalso Gain >= 0 andalso (Spend rem P) =:= 0 of
                true ->
                    GasUsed = Spend div P,
                    case GasUsed > 0 andalso (Gain rem GasUsed) =:= 0 of
                        true -> P - (Gain div GasUsed);
                        false -> none
                    end;
                false -> none
            end
    end.

pre_balance(Pre, Hex) ->
    case maps:find(Hex, Pre) of
        {ok, Fields} -> balance_of(Fields);
        error -> 0
    end.

balance_of(Fields) when is_map(Fields) ->
    int(maps:get(<<"balance">>, Fields, <<"0x0">>));
balance_of(_) -> 0.

%% The pre-state as an overlay.
%%
%% Every account and every slot the fixture declares is put in the overlay, which
%% matters for two reasons. It is the only way `eth_state' can answer without
%% reaching for the upstream node -- a unit test that performs a lazy fetch is
%% not a unit test -- and it means every key a later comparison reads is
%% present, so no read can fall through to `base_source' and return something
%% that is not this fixture's.
state(Entry, Post) ->
    Pre = maps:get(<<"pre">>, Entry, #{}),
    %% eth_state:new/2 takes overrides keyed the way the overlay is keyed, so the
    %% fold builds that key shape directly rather than calling the setters.
    Overrides = lists:foldl(fun(Account, Acc) -> account(Account, Acc) end,
                            #{}, maps:to_list(Pre)),
    eth_state:new(0, lists:foldl(fun({A, Slots}, Acc) -> seed_slots(A, Slots, Acc) end,
                                 seed_absent(mentioned(Entry, Post), Overrides),
                                 slots_named(Entry, Post))).

%% Every address the fixture mentions anywhere: in `pre', in the expected post
%% state, as sender or destination, and as the fee recipient.
%%
%% The union matters, and not only for the comparison. `eth_state:storage/3' and
%% `balance/2' are read *during execution* by the EVM and by `settle_gas/7', and
%% they fall through to `base_source' for anything the overlay does not hold. Under
%% `with_local_reads' that base source is the local MPT: process-wide, shared with
%% every other test in the run, and not this fixture's business.
%%
%% It was measurable. The same corpus and the same code gave six matches standalone
%% and seven under eunit, and the extra one was a fixture passing on state another
%% test had left behind -- a higher match rate caused by unrelated data, which is
%% worse than a flaky number because it is a wrong answer that looks right. Seeding
%% only the comparison was not enough; the reads that changed behaviour were the
%% EVM's own.
mentioned(Entry, Post) ->
    Env = maps:get(<<"env">>, Entry, #{}),
    Tx = maps:get(<<"transaction">>, Entry, #{}),
    lists:usort(
      [addr(A) || A <- maps:keys(maps:get(<<"pre">>, Entry, #{}))]
      ++ [addr(A) || A <- maps:keys(maps:get(<<"state">>, Post, #{}))]
      ++ [addr(maps:get(<<"sender">>, Tx, <<"0x">>)),
          addr(maps:get(<<"to">>, Tx, <<"0x">>)),
          addr(maps:get(<<"currentCoinbase">>, Env, <<"0x">>))]).

%% Every `(account, slot)' the expected post state names, including slots the
%% transaction writes that `pre' never declared. A slot written by the transaction
%% is read before it is written -- that read is EIP-2200's `original' -- so leaving
%% it out of the overlay sends that read to the base source, and the value it comes
%% back with changes the price.
slots_named(_Entry, Post) ->
    PostState = maps:get(<<"state">>, Post, #{}),
    [{addr(A), [word(S) || S <- maps:keys(maps:get(<<"storage">>, F, #{}))]}
     || {A, F} <- maps:to_list(PostState), is_map(F)].

seed_slots(A, Slots, Overrides) ->
    lists:foldl(fun(S, Acc) ->
        case Acc of
            #{{store, A, S} := _} -> Acc;
            _ -> Acc#{{store, A, S} => 0}
        end
    end, Overrides, Slots).

%% An address the fixture mentions but does not declare is an empty account, and an
%% empty account is what a state test means by an address that is not in `pre'. It
%% is put in the overlay as zero rather than left to be looked up.
seed_absent(Addresses, Overrides) ->
    lists:foldl(fun(A, Acc) ->
        case Acc of
            #{{balance, A} := _} -> Acc;
            _ -> Acc#{{balance, A} => 0, {nonce, A} => 0, {code, A} => <<>>}
        end
    end, Overrides, Addresses).

account({Hex, Fields}, Acc) when is_map(Fields) ->
    A = addr(Hex),
    Acc1 = maps:put({nonce, A}, int(maps:get(<<"nonce">>, Fields, <<"0x0">>)), Acc),
    Acc2 = maps:put({balance, A}, int(maps:get(<<"balance">>, Fields, <<"0x0">>)), Acc1),
    Acc3 = maps:put({code, A}, bytes(maps:get(<<"code">>, Fields, <<"0x">>)), Acc2),
    maps:fold(fun(Slot, V, A3) -> maps:put({store, A, word(Slot)}, int(V), A3) end,
              Acc3, maps:get(<<"storage">>, Fields, #{}));
account(_, Acc) -> Acc.

%% The validation context eth_tx:validate/2 wants. Built here rather than taken
%% from eth_block because `validation_ctx/4' is not exported; it is the public
%% function's documented input shape, and this test is checking the validator's
%% verdict rather than reimplementing the validator.
validation_ctx(Block, State) ->
    #{base_fee => base_fee_of(Block),
      gas_limit => Block#block.gas_limit,
      gas_used => Block#block.gas_used,
      chain_id => eth_fork_schedule:chain_id(),
      fork => fork_of_block(Block),
      balance_of => fun(A) -> {ok, eth_state:balance(State, A)} end,
      nonce_of => fun(A) -> {ok, eth_state:nonce(State, A)} end,
      %% EIP-3607 reads the sender's **code**. Without this reader the rule cannot fire
      %% at all: `eth_tx:validate/2' treats an absent `code_of' as "cannot answer", and
      %% the eight `SENDER_NOT_EOA' fixtures would keep reporting
      %% `expected_rejection_not_raised' while the rule looked implemented.
      code_of => fun(A) -> {ok, eth_state:code(State, A)} end,
      %% EIP-4844's blob base fee floor, and the reason four
      %% `INSUFFICIENT_MAX_FEE_PER_BLOB_GAS` fixtures were `expected_rejection_not_raised`:
      %% `eth_tx:check_blobs/2' reads this from the context, and no caller passed it,
      %% so the rule was unreachable on the harness as well as in production. Taken
      %% from `eth_block:blob_base_fee/1' -- **the same function the node charges
      %% at** -- rather than recomputed here, because a harness that derives a
      %% consensus constant a second time is how the two drift apart silently.
      blob_base_fee => eth_block:blob_base_fee(Block)}.

%% The base fee as `eth_block:base_fee_of/1' reads it: `undefined' for a block
%% that has none, and 0 for one at London or later where 0 is a real figure.
base_fee_of(#block{base_fee_per_gas = undefined}) -> undefined;
base_fee_of(#block{base_fee_per_gas = B}) -> B.

fork_of_block(Block) ->
    {ok, Fork} = eth_fork_schedule:current_fork(eth_fork_schedule:configured_network(),
                                               Block#block.number, Block#block.timestamp,
                                               Block#block.total_difficulty),
    Fork.

execute(Fork, Tx, Entry, Post) ->
    Block = block(Fork, Entry, derived_base_fee(Entry, Post, Tx)),
    PreState = state_for(Entry, Post),
    %% The block's own base fee, not the fork default. `run_transaction/5' takes the
    %% base fee as an argument and ignores the record's field, so passing
    %% `base_fee_for(Fork)' here silently discarded the fee the block was just built
    %% with -- the derived one, and the tip came out at the full gas price. Two
    %% sources of truth for one header field, which is the mistake this module's
    %% comments keep warning about.
    {Block1, State1} =
        case eth_block:run_transaction(Block, Tx, PreState,
                                       Block#block.base_fee_per_gas,
                                       Block#block.gas_limit) of
            {error, {unpriced, What}} ->
                throw({?UNPRICED, What});
            {Block1x, State1x} ->
                {Block1x, State1x}
        end,
    Receipt = last_receipt(Block1),
    %% Both states, because the gas figure is an *arithmetic* recovery from the
    %% sender's balance and needs the balance it started from. Reading the
    %% "before" figure out of the post-state -- which the first version did --
    %% makes every side spend zero gas and reports a delta of 0 for a fixture
    %% that is thousands of gas out, which is the one number a reader would
    %% believe.
    compare(Post, Entry, State1, PreState, Receipt, Tx).

last_receipt(Block) ->
    case Block#block.receipts of
        [] -> #{};
        Rs -> lists:last(Rs)
    end.

%% ---------------------------------------------------------------------------
%% Comparison
%% ---------------------------------------------------------------------------

compare(Post, Entry, State, PreState, Receipt, Tx) ->
    Expected = maps:get(<<"state">>, Post, #{}),
    Diffs = lists:sort(lists:append(
        [account_diff(A, F, State) || {A, F} <- maps:to_list(Expected), is_map(F)])),
    case Diffs of
        [] -> {?MATCH, ok};
        _ -> {?STATE_MISMATCH, #{diffs => Diffs,
                                 gas => gas_story(Diffs, Entry, PreState, Receipt, Tx)}}
    end.

%% Every field of every account the fixture declares, compared one at a time. A
%% diff is a flat list of {where, field, want, got} so that a failure names the
%% account and the field rather than "the state", which is the difference between
%% a report and a shrug.
account_diff(A, F, State) ->
    Addr = addr(A),
    field_diff(A, balance, int, F, <<"balance">>, 0,
               overlay(State, {balance, Addr}, 0))
        ++ field_diff(A, nonce, int, F, <<"nonce">>, 0,
                      overlay(State, {nonce, Addr}, 0))
        ++ field_diff(A, code, bytes, F, <<"code">>, <<"0x">>,
                      overlay(State, {code, Addr}, <<>>))
        ++ slot_diff(A, F, State, Addr).

%% Read the overlay and nothing else.
%%
%% `eth_state:balance/2', `nonce/2', `code/2' and `storage/3' all answer from the
%% overlay first and then fall through to `base_source'. Under `with_local_reads'
%% that base source is the local MPT, which is process-wide and shared with every
%% other test in the run -- so a comparison that reached for it was reading whatever
%% the rest of the suite had left behind.
%%
%% The tally proved it. The same corpus, same code, two environments: six fixtures
%% matched standalone and seven under eunit, and the extra one was
%% `frontier/touch/test_zero_gas_price_and_touching' at four forks -- EIP-161's
%% rule that an account touched at zero gas price does not survive. A *higher*
%% match rate caused by unrelated state is worse than a flaky number, because it is
%% a wrong answer that looks right.
%%
%% Reading the overlay directly makes the comparison a pure function of the fixture
%% and of what the node did: absent means absent, which for a state test is zero,
%% because EIP-161 says an account that did not survive has nothing in it.
overlay(State, Key, Default) ->
    maps:get(overlay_key(Key), maps:get(overlay, State, #{}), Default).

%% `eth_state:new/2' rewrites every `{store, A, S}' key of the overrides it is given
%% through `eth_state:slot_key/1', so a slot written to the overlay is under the
%% **32-byte word** whatever the caller passed. This read path did not, so a slot the
%% fixture wrote as `<<"0x00">>' was seeded under the integer `0' and read back under
%% the integer `0' -- while the node's own write went under `<<0:256>>'.
%%
%% The consequence is that **the comparison could not see a storage write the node
%% had made**: every slot read as zero. `london/eip1559_fee_market_change/
%% test_eip1559_tx_validity` is the clearest witness, and it looked like a node defect
%% for a long time -- the node was reported as not storing `1` into slot 0, when an
%% instrumented run of the same fixture has the frame finishing `result=ok` with
%% `charged0=26006`, which is the chain's own figure. The gas was right and the write
%% was right; the runner was looking in the wrong place.
%%
%% Only the `{store, ...}' key needs this. `account/2' already normalises the address
%% for `balance', `nonce' and `code', so those keys match as written.
overlay_key({store, A, S}) -> {store, A, slot_word(S)};
overlay_key(Key) -> Key.

%% The same normalisation `eth_state:slot_key/1' performs: a short binary is padded on
%% the left, a long one is truncated to its last 32 bytes, and an integer is widened.
%% Re-derived here rather than called, because `slot_key/1' is not exported and
%% duplicating five lines is cheaper than exporting a function whose only other
%% caller is a gen_server's internals.
slot_word(S) when is_binary(S) ->
    Pad = 32 - byte_size(S),
    case Pad >= 0 of
        true -> <<0:(Pad * 8), S/binary>>;
        false -> binary:part(S, byte_size(S) - 32, 32)
    end;
slot_word(S) when is_integer(S) -> <<S:256>>;
slot_word(_) -> <<0:256>>.

%% One field, and only if it differs. Reporting every field unconditionally --
%% which the first version did -- makes every account a diff, so a genuine
%% balance difference is buried in a list where equal values are printed next to
%% equal values and the report reads as noise. A diff has to mean *diff*.
field_diff(A, Name, Decoder, F, Key, Default, Got) ->
    case field(F, Key, Default, Decoder) of
        Got -> [];
        Want -> [{addr, A, {Name, Want, Got}}]
    end.

%% One declared field, decoded. `int' and `bytes' are the two decoders this
%% module has, and picking the wrong one for a field is how a comparison ends up
%% asserting something about a number that was read as bytes.
field(F, Key, Default, int) -> int(maps:get(Key, F, Default));
field(F, Key, Default, bytes) -> bytes(maps:get(Key, F, Default)).

slot_diff(A, F, State, Addr) ->
    maps:fold(
      fun(Slot, V, Acc) ->
          Want = int(V),
          Got = overlay(State, {store, Addr, word(Slot)}, 0),
          case Got =:= Want of
              true -> Acc;
              false -> Acc ++ [{store, A, hex(word(Slot)), Want, Got}]
          end
      end, [], maps:get(<<"storage">>, F, #{})).

%% Why a fixture diverged, in the form that names a cause rather than a symptom.
%%
%% A state test asserts gas nowhere. It asserts the *balances* the gas produced,
%% and for the sender that arithmetic inverts exactly: the sender is charged
%% `gasUsed * effectivePrice' up front and refunded the unused remainder, and a
%% successful transaction additionally moves `value' out. So both sides' gas can
%% be recovered from the balances, and the difference between them is a gas
%% figure -- which is the difference between "this fixture diverges" and "this
%% fixture is 45,247 gas light, which is EIP-2929's cold account charge and
%% about sixteen times that". Reporting the raw wei difference instead is the
%% kind of number nobody acts on.
%%
%% A reverted transaction gets its value back, so it must not be subtracted, and
%% the receipt's status is what says which happened. When the price is zero, or
%% the balance difference does not divide by it, there is no gas figure to report
%% and this says so rather than dividing anyway.
gas_story(Diffs, Entry, PreState, Receipt, Tx) ->
    Sender = bytes(maps:get(<<"sender">>, maps:get(<<"transaction">>, Entry, #{}),
                            <<"0x">>)),
    case [D || {addr, A, {balance, _W, _G}} = D <- Diffs, A =:= hex(Sender)] of
        [] -> unavailable;
        [{addr, _, {balance, Want, Got}}] ->
            Price = effective_price(Tx, Receipt),
            Value = moved_value(Tx, Receipt),
            Before = overlay(PreState, {balance, Sender}, 0),
            Expected = gas_of(Before, Want, Price, Value),
            Actual = gas_of(Before, Got, Price, Value),
            #{price => Price, value => Value,
              spent_expected => Expected,
              spent_actual => Actual,
              delta => gas_delta(Expected, Actual)}
    end.

%% How much more or less gas this node spent than the fixture expected, when
%% both sides produced a figure. `no_comparable_gas' rather than a number when
%% either side did not: a delta between two unknowns is a third unknown.
gas_delta({gas, E}, {gas, A}) -> A - E;
gas_delta(_, _) -> no_comparable_gas.

%% Gas implied by a balance, or `no_gas' when the arithmetic does not come out
%% whole. Dividing and rounding would produce a plausible wrong number, which is
%% worse than none.
gas_of(_Before, _Balance, 0, _Value) -> no_gas_at_zero_price;
gas_of(Before, Balance, Price, Value) ->
    case (Before - Balance - Value) rem Price of
        0 -> {gas, (Before - Balance - Value) div Price};
        _ -> no_gas_not_divisible
    end.

%% The price the sender was actually charged at.
%%
%% EIP-1559's effective price is `min(maxFee, baseFee + maxPriorityFee)', and the
%% runner executes against a base fee of zero, so that reduces to the priority
%% fee. A legacy or 2930 transaction has only `gasPrice'.
effective_price(Tx, _Receipt) ->
    case {maps:get(<<"maxFeePerGas">>, Tx, undefined),
          maps:get(<<"maxPriorityFeePerGas">>, Tx, undefined)} of
        {undefined, _} -> q_int(Tx, <<"gasPrice">>);
        {MaxFee, Priority} when is_binary(MaxFee), is_binary(Priority) ->
            min(int(MaxFee), int(Priority));
        {MaxFee, _} when is_binary(MaxFee) -> int(MaxFee);
        _ -> q_int(Tx, <<"gasPrice">>)
    end.

%% What left the sender's balance as value rather than as gas. A revert hands it
%% back, so it is only money that actually moved when the receipt says the
%% transaction succeeded.
moved_value(Tx, Receipt) ->
    case maps:get(<<"status">>, Receipt, 1) of
        1 -> q_int(Tx, <<"value">>);
        _ -> 0
    end.

%% A transaction field that `eth_tx' keeps as hex text.
q_int(Tx, Key) ->
    case maps:get(Key, Tx, undefined) of
        Bin when is_binary(Bin) -> int(Bin);
        _ -> 0
    end.

%% ---------------------------------------------------------------------------
%% Decoding helpers
%% ---------------------------------------------------------------------------
%%
%% The fixture spells every number as a hex QUANTITY string and every byte string
%% as hex DATA. `eth_hex:decode/1' is the QUANTITY decoder and returns an
%% integer; `decode_bytes/1' is the DATA one and returns a binary. Conflating
%% them is the mistake this pair of helpers exists to prevent.

int(undefined) -> 0;
int(Hex) when is_integer(Hex) -> Hex;
int(<<"0x", _/binary>> = Hex) -> eth_hex:decode(Hex);
int(Bin) when is_binary(Bin) -> binary:decode_unsigned(Bin).

%% `eth_hex:decode_bytes/1' answers `{ok, Bin}', not a bare binary. Treating it
%% as the binary hands a tuple to `eth_tx:from_rlp/1`, which fails on every
%% fixture and reports as `tx_decode_failed' -- which is indistinguishable from
%% a codec that cannot read a legacy transaction, and is exactly the kind of
%% failure that would be believed.
bytes(Bin) when is_binary(Bin) ->
    case eth_hex:decode_bytes(Bin) of
        {ok, Out} -> Out;
        _ -> <<>>
    end;
bytes(_) -> <<>>.

%% A storage slot key, as the 32-byte word both the fixture and `eth_state' use.
%% `eth_state:slot_key/1' pads short binaries on the left and truncates long ones,
%% so passing the integer is equivalent and avoids re-deriving the padding here.
word(Hex) when is_integer(Hex) -> Hex;
word(<<"0x", _/binary>> = Hex) -> eth_hex:decode(Hex);
word(Bin) when is_binary(Bin) -> binary:decode_unsigned(Bin).

hex(N) when is_integer(N) -> eth_hex:encode_int(N);
hex(B) when is_binary(B) -> eth_hex:encode_bytes(B).

addr(Hex) when is_binary(Hex) -> eth_state:address(Hex);
addr(Other) -> eth_state:address(Other).
