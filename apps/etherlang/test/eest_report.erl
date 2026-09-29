-module(eest_report).
-export([main/1]).

%% Prints the conformance survey for a corpus: the tally, a per-fork breakdown, a
%% histogram of the schedule-sized gas deltas, and a bounded sample of the
%% divergences.
%%
%% Usage: eest_report <corpus-dir>
%%
%% This is a developer tool, not a test. It reads whatever corpus it is pointed at
%% -- the committed subset by default, an extracted upstream tarball with
%% EEST_CORPUS -- and its job is to print a breakdown a person can act on. The
%% eunit suite pins the committed subset's tally; this prints the full one.
%%
%% It goes through `eest_state_tests:survey/1', which folds rather than collects.
%% The collecting version, `entries/1', is fine for 266 fixtures and hopeless for
%% the full 2,681: it retains every result and every detail map at once, and a run
%% over the whole suite spent over an hour at 100% CPU inside `erts_bor' -- the
%% garbage collector -- before finishing a single fork. Peak memory here is one
%% fixture's decoded JSON.

main([Dir]) ->
    _ = application:ensure_all_started(crypto),
    _ = eth_test_util:start_apps(),
    %% mainnet, because the fork schedule is mainnet's and because the fixtures
    %% declare chain id 1. The runner sets this itself now; setting it here as well
    %% is harmless and means the tool is right even if it is pointed at something
    %% odd.
    os:putenv("ETH_NETWORK", "mainnet"),
    T0 = erlang:monotonic_time(millisecond),
    %% A progress line every 25 files, to `standard_error'. 25 rather than 1 because
    %% the committed subset is 25 files and this is a developer tool for a corpus of
    %% thousands; at one line per file the short run is noise and the long run is
    %% unreadable. See `eest_state_tests:survey/2' for why this exists at all.
    S = eest_state_tests:survey(Dir, 25),
    Ms = erlang:monotonic_time(millisecond) - T0,
    print(Dir, S, Ms),
    halt(0);
main(_) ->
    io:format("usage: eest_report <corpus-dir>~n"),
    halt(1).

print(Dir, S, Ms) ->
    Tally = maps:get(tally, S),
    Total = maps:get(total, S),
    Matched = maps:get(match, Tally, 0),
    io:format("~n=== EEST state-test conformance ===~n"),
    io:format("corpus : ~s~n", [Dir]),
    io:format("files  : ~w~n", [maps:get(files, S)]),
    io:format("entries: ~w  in ~w ms~n~n", [Total, Ms]),
    io:format("matched: ~w of ~w (~.1f%)~n~n", [Matched, Total, pct(Matched, Total)]),
    print_tally(Tally),
    print_by_fork(maps:get(by_fork, S)),
    print_gas(maps:get(gas, S)),
    print_rejects(maps:get(rejects, S, #{})),
    print_sample(maps:get(sample, S)).

pct(_, 0) -> 0.0;
pct(N, T) -> 100.0 * N / T.

print_tally(Tally) ->
    [io:format("  ~-32w ~6w~n", [O, N])
     || {O, N} <- lists:reverse(lists:keysort(2, maps:to_list(Tally)))].

print_by_fork(Bf) ->
    io:format("~n--- by fork ---~n"),
    [begin
         T = lists:foldl(fun({O, _}, M) ->
                                 maps:update_with(O, fun(N) -> N + 1 end, 1, M)
                         end, #{}, L),
         N = lists:sum([C || {_, C} <- L]),
         io:format("  ~-20s n=~-6w match=~-6w diverge=~w~n",
                   [binary_to_list(F), N, maps:get(match, T, 0),
                    N - maps:get(match, T, 0)])
     end || {F, L} <- lists:sort(maps:to_list(Bf))].

%% The rejection histogram, in full and unsampled.
%%
%% Every distinct `{corpus code, node code, node reason}' triple, with its count, ordered
%% by count. This is the unit that says whether a `rejection_mismatch' is the node
%% refusing for the **wrong rule** -- a real defect, and the one this project has to fix
%% -- or for the **right rule under a different name**, which is the harness's vocabulary
%% being out of date and is not a defect at all. Those two look identical in a tally and
%% demand opposite responses, which is why the tally alone could not be worked with.
print_rejects(Rejects) ->
    io:format("~n--- rejection reasons (corpus code / node code / node reason) ---~n"),
    Sorted = lists:reverse(lists:sort([{N, K} || {K, N} <- maps:to_list(Rejects)])),
    case Sorted of
        [] -> io:format("    (none)~n");
        _ -> [io:format("    ~8w  ~s~n", [N, rejection_line(K)]) || {N, K} <- Sorted]
    end.

%% `~p' for all three, not `~s'. `Got' is a binary for a mapped reason and a **tuple**
%% `{unmapped, Atom}' for one with no clause -- the last row of the histogram -- and
%% `io_lib:format("~s", {unmapped, null_destination})' raises `badarg'. So the printer
%% died on the single most informative row of the table, which is a bad way to discover
%% that a row exists.
rejection_line({Expected, Got, Reason}) ->
    lists:flatten(io_lib:format("~p  ->  ~p  (~p)", [Expected, Got, Reason])).

%% The schedule-sized deltas, **and what this section did not look at.**
%%
%% A delta of a few thousand gas names a constant -- 2,500 is EIP-2929's cold
%% account, 2,100 its cold slot, 2,900 an SSTORE_RESET_GAS, 100 a warm read -- and
%% it repeats across fixtures because it is one missing rule. A delta in the
%% millions means a frame burned its whole allowance where the fixture's did not,
%% which says that something is wrong and nothing about which rule, and there are
%% far too many of those to put in the same list: the first version of this
%% histogram did, and the constants vanished under them.
%%
%% **The second half is the one that matters**, and it exists because the first half
%% printed `(none in range)' over a corpus containing the largest single divergence
%% this repository has produced. Those 1,408 entries were all
%% `no_comparable_gas' -- a delta between two unknowns, because those fixtures set
%% `maxPriorityFeePerGas = 0' against a base fee of 7, so the effective price *is*
%% the base fee and no balance difference encodes a gas cost -- and an instrument
%% that buckets the cases it can compute and discards the rest is indistinguishable,
%% in its output, from an instrument reporting nothing wrong. Deltas beyond the
%% range were dropped the same way, and a magnitude in the hundreds of thousands is
%% itself a finding.
print_gas(Gas) ->
    io:format("~n--- gas deltas (positive = this node spent more) ---~n"),
    Sorted = lists:reverse(lists:sort(maps:to_list(maps:get(buckets, Gas)))),
    case Sorted of
        [] -> io:format("    (none within the schedule-sized range, -"
                        "-/+100,000 gas)~n");
        _ -> [io:format("    ~10w gas   x~w~n", [D, N]) || {D, N} <- Sorted]
    end,
    print_over(Gas),
    print_unseen(Gas).

%% Deltas too large to sit beside the schedule-sized ones. Counted, with the maximum
%% kept, rather than dropped: a delta in the hundreds of thousands means a frame
%% consumed its whole allowance where the fixture's did not, and that is a
%% statement about the node even though it names no rule.
print_over(#{over := 0}) ->
    ok;
print_over(#{over := N, over_max := M}) ->
    io:format("  beyond the range:~n"),
    io:format("    ~10w deltas over 100,000 gas, largest ~w~n", [N, M]),
    ok.

%% The divergences this section **cannot** put a number on, per reason. Printed even
%% when the in-range table above it is full, because a full table of computable
%% deltas says nothing about the entries that have none.
print_unseen(#{unseen := U}) when map_size(U) =:= 0 ->
    ok;
print_unseen(#{unseen := U}) ->
    io:format("  no comparable gas figure, by reason -- these are divergences this "
              "table cannot size:~n"),
    [io:format("    ~10w  ~s~n", [N, why(R)])
     || {R, N} <- lists:reverse(lists:sort(maps:to_list(U)))],
    ok.

why(no_comparable_gas) ->
    "one side produced a gas figure and the other did not";
why(zero_price) ->
    "the effective gas price is 0, so no balance difference encodes a gas cost";
why(not_divisible) ->
    "the balance difference is not a whole multiple of the effective price";
why(no_sender_balance_diff) ->
    "the diff carries no balance for the sender";
why(no_gas_story) ->
    "no gas story was produced for this state mismatch";
why(Other) ->
    io_lib:format("~p", [Other]).

%% A bounded sample of the divergences. The bound is the point: this is a summary
%% of a corpus that does not fit in memory, and a report that tried to hold all of
%% it would be the thing that does not fit.
print_sample(Sample) ->
    io:format("~n--- ~w sample divergences ---~n", [length(Sample)]),
    [begin
         io:format("  ~-30w ~s~n", [O, suite_of(File)]),
         io:format("      ~s~n", [short_key(Key)]),
         case Detail of
             #{gas := #{delta := D}} when is_integer(D) ->
                 io:format("      gas delta ~+w~n", [D]);
             _ -> ok
         end,
         print_reason(Detail)
     end || {Key, O, Detail, File} <- lists:reverse(Sample)].

%% **The reason a rejection diverged, which this report used not to print at all.**
%%
%% `rejection_mismatch' is 12.6% of the corpus -- 1,975 entries, the largest single
%% cluster, and the one AGENTS.md §12 names as the next thing to measure. It was
%% unattributable because the sample printed the outcome, the file and the key and
%% nothing else, while the reason lived in the detail map that the printer discarded.
%% So the largest thing that was wrong with this node could be read off a summary that
%% said only "this file diverges", which is the report AGENTS.md §10a calls "the kind of
%% number nobody acts on" -- arrived at by omission rather than by choice.
%%
%% This prints the fixture's code, the name the node gave it, and the node's own reason
%% atom, so the three can be compared. For every other outcome it prints nothing, so the
%% line count of the report is unchanged where there is nothing to say.
print_reason(#{expected := Want, got := Got, reason := Reason}) ->
    io:format("      expected ~s, node said ~s (reason: ~p)~n", [Want, Got, Reason]);
print_reason(_) ->
    ok.

short_key(Key) when is_binary(Key), byte_size(Key) > 110 ->
    binary:part(Key, byte_size(Key) - 110, 110);
short_key(Key) -> Key.

suite_of(File) when is_binary(File) ->
    Parts = binary:split(File, <<"/">>, [global]),
    case [P || P <- Parts, binary:match(P, <<"eip">>) =/= nomatch
               orelse binary:match(P, <<"test_">>) =/= nomatch] of
        [P | _] -> P;
        [] -> lists:last(Parts)
    end;
suite_of(File) -> File.
