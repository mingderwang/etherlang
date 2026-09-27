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

%% The schedule-sized deltas.
%%
%% A delta of a few thousand gas names a constant -- 2,500 is EIP-2929's cold
%% account, 2,100 its cold slot, 2,900 an SSTORE_RESET_GAS, 100 a warm read -- and
%% it repeats across fixtures because it is one missing rule. A delta in the
%% millions means a frame burned its whole allowance where the fixture's did not,
%% which says that something is wrong and nothing about which rule, and there are
%% far too many of those to put in the same list: the first version of this
%% histogram did, and the constants vanished under them.
print_gas(Buckets) ->
    io:format("~n--- schedule-sized gas deltas (positive = this node spent more) ---~n"),
    Sorted = lists:reverse(lists:sort(maps:to_list(Buckets))),
    case Sorted of
        [] -> io:format("    (none in range)~n");
        _ -> [io:format("    ~10w gas   x~w~n", [D, N]) || {D, N} <- Sorted]
    end.

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
         end
     end || {Key, O, Detail, File} <- lists:reverse(Sample)].

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
