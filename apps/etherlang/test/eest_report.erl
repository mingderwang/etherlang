-module(eest_report).
-export([main/1]).

%% Prints the conformance tally for a corpus, grouped, with the gas deltas that
%% account for the largest share of the state divergences.
%%
%% Usage: eest_report <corpus-dir>
%%
%% This is a developer tool, not a test. It reads whatever corpus it is pointed
%% at -- the committed subset by default, an extracted upstream tarball with
%% EEST_CORPUS -- and its job is to print a breakdown a person can act on. The
%% eunit suite pins the committed subset's tally; this prints the full one.

main([Dir]) ->
    _ = application:ensure_all_started(crypto),
    _ = eth_test_util:start_apps(),
    %% mainnet, because the fork schedule is mainnet's and because the fixtures
    %% declare chain id 1. Left to the default the schedule is Sepolia's, whose
    %% pre-merge forks are all active at genesis, so every pre-Merge fixture
    %% would execute under Paris.
    os:putenv("ETH_NETWORK", "mainnet"),
    T0 = erlang:monotonic_time(millisecond),
    Results = eest_state_tests:entries(Dir),
    Ms = erlang:monotonic_time(millisecond) - T0,
    print_summary(Dir, Results, Ms),
    print_by_fork(Results),
    print_gas_histogram(Results),
    print_worst(Results, 25),
    halt(0);
main(_) ->
    io:format("usage: eest_report <corpus-dir>~n"),
    halt(1).

print_summary(Dir, Results, Ms) ->
    io:format("~n=== EEST state-test conformance ===~n"),
    io:format("corpus : ~s~n", [Dir]),
    io:format("entries: ~w  in ~w ms~n~n", [length(Results), Ms]),
    Tally = eest_state_tests:tally(Results),
    Total = length(Results),
    Matched = maps:get(match, Tally, 0),
    io:format("matched: ~w of ~w (~.1f%)~n~n",
              [Matched, Total, pct(Matched, Total)]),
    [io:format("  ~-32w ~6w~n", [O, N])
     || {O, N} <- lists:reverse(lists:keysort(2, maps:to_list(Tally)))].

pct(_, 0) -> 0.0;
pct(N, T) -> 100.0 * N / T.

print_by_fork(Results) ->
    io:format("~n--- by fork ---~n"),
    Grouped = lists:foldl(
      fun({Key, O, _, _}, Acc) ->
          F = fork_of(Key),
          maps:update_with(F, fun(L) -> [O | L] end, [O], Acc)
      end, #{}, Results),
    [begin
         T = lists:foldl(fun(O, M) -> maps:update_with(O, fun(N) -> N+1 end, 1, M) end,
                         #{}, L),
         io:format("  ~-20s n=~-6w match=~-6w diverge=~w~n",
                   [binary_to_list(F), length(L), maps:get(match, T, 0),
                    length(L) - maps:get(match, T, 0)])
     end || {F, L} <- lists:sort(maps:to_list(Grouped))].

fork_of(Key) when is_binary(Key) ->
    case re:run(Key, "fork_([A-Za-z0-9]+)-", [{capture, all_but_first, binary}]) of
        {match, [N]} -> N;
        _ -> <<"?">>
    end;
fork_of(_) -> <<"?">>.

%% The gas deltas, bucketed, split by magnitude.
%%
%% The split is the whole point. A delta in the low thousands is a *schedule term*
%% missed by a fixed amount, and it repeats across fixtures because it is one bug:
%% 2,500 is EIP-2929's cold account surcharge, 2,100 its cold slot, 100 the warm
%% read, 2,900 an SSTORE_RESET_GAS, 15,000 a pre-London clear refund. Those are
%% the actionable ones and they name themselves.
%%
%% A delta in the millions is not a schedule term. It is a frame that consumed its
%% entire allowance where the fixture's did not -- an exceptional halt against a
%% clean stop -- so the number carries no information about *which* rule is wrong,
%% only that something is. Mixing the two in one histogram buries the first kind
%% under the second, which is what the first version of this did.
%%
%% `~w' rather than `~+w': the `+' modifier means "print in base 10" to `~w', so
%% `~+2500w' prints `10#2500w' -- Erlang term syntax, in a report about gas.
print_gas_histogram(Results) ->
    Deltas = lists:sort([D || {_, state_mismatch, #{gas := #{delta := D}}, _} <- Results,
                              is_integer(D)]),
    io:format("~n--- gas deltas (positive = this node spent more) ---~n"),
    io:format("  comparable deltas: ~w of ~w state mismatches~n",
              [length(Deltas), length([1 || {_, state_mismatch, _, _} <- Results])]),
    {Small, Large} = lists:partition(fun(D) -> abs(D) =< 100000 end, Deltas),
    io:format("~n  schedule-sized (|delta| =< 100000) -- these name a constant:~n"),
    print_buckets(Small),
    io:format("~n  whole-allowance (|delta| > 100000) -- a halt against a stop:~n"),
    print_buckets(Large).

print_buckets(Deltas) ->
    Buckets = lists:foldl(fun(D, Acc) ->
                              maps:update_with(D, fun(N) -> N + 1 end, 1, Acc)
                          end, #{}, Deltas),
    Sorted = lists:reverse(lists:sort(maps:to_list(Buckets))),
    case Sorted of
        [] -> io:format("    (none)~n");
        _ -> [io:format("    ~10w gas   x~w~n", [D, N]) || {D, N} <- Sorted]
    end.

print_worst(Results, N) ->
    Diverge = [R || {_, O, _, _} = R <- Results, O =/= match, O =/= fork_unreachable],
    io:format("~n--- ~w divergences, by suite ---~n", [length(Diverge)]),
    Suites = lists:foldl(fun({_, O, _, File}, Acc) ->
                             maps:update_with({suite_of(File), O},
                                              fun(N2) -> N2 + 1 end, 1, Acc)
                         end, #{}, Diverge),
    [io:format("  ~-58s ~-30w ~w~n", [S, O, C])
     || {{S, O}, C} <- lists:reverse(lists:sort(maps:to_list(Suites)))],
    io:format("~n--- first ~w divergent fixtures ---~n", [N]),
    [begin
         io:format("  ~-30w ~s~n", [O, suite_of(File)]),
         io:format("      ~s~n", [short_key(Key)]),
         case Detail of
             #{gas := #{delta := D}} when is_integer(D) ->
                 io:format("      gas delta ~+w~n", [D]);
             _ -> ok
         end
     end || {Key, O, Detail, File} <- lists:sublist(Diverge, N)].

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
