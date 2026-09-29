#!/usr/bin/env escript
%% -*- erlang -*-
%% Derive the size figures quoted in README.md, AGENTS.md §3 and TASKS.md.
%%
%% **These numbers drifted three times** -- once silently, twice with a correction commit
%% that was itself off by one -- and the cause was never the counting. It was that the
%% *procedure* was prose. "Lines of code" was undefined, so two derivations that both
%% looked reasonable gave 13,527 and 13,584, and a number nobody can reproduce is not a
%% measurement. So the definition lives here, in one place, executable, and the documents
%% quote its output and name this script.
%%
%%   modules      : files ending .erl, tracked by git **plus any untracked one**, so a
%%                  new module is counted on the day it is written and not only once it is
%%                  committed. (The untracked case is the one that produced 48 when the
%%                  tree held 49.)
%%   code lines   : non-blank and non-**comment** lines. A comment line is one whose first
%%                  non-space characters are `%%'. Nothing else is subtracted: attribute
%%                  lines, `-include's and `-export's are code, and excluding them was
%%                  tried and gives a different number that is no more defensible.
%%   tests        : the count eunit prints, which cannot be derived statically.
%%   test total   : eunit's own summary line, re-read from a run, never guessed.
%%
%% Run from the repository root: `tools/counts.escript' or `make counts`.
-mode(compile).

main(_) ->
    Src = modules("apps/etherlang/src"),
    Test = modules("apps/etherlang/test"),
    io:format("~n"),
    io:format("  src modules    : ~p~n", [length(Src)]),
    io:format("  src code lines : ~p~n", [code_lines(Src)]),
    io:format("  test modules   : ~p~n", [length(Test)]),
    io:format("  test code lines: ~p~n", [code_lines(Test)]),
    io:format("~n  eunit tests    : run `make eunit` and read the summary.~n"),
    ok.

modules(Dir) ->
    Tracked = [F || F <- git(["ls-files", Dir ++ "/*.erl"]), filelib:is_regular(F)],
    OnDisk = filelib:wildcard(Dir ++ "/*.erl"),
    lists:usort(OnDisk ++ Tracked).

code_lines(Files) ->
    lists:sum([code_lines_of(F) || F <- Files]).

code_lines_of(File) ->
    {ok, Bin} = file:read_file(File),
    Lines = binary:split(Bin, [<<"\n">>], [global, trim_all]),
    length([L || L <- Lines, is_code(L)]).

is_code(Line) ->
    Trimmed = string:trim(binary_to_list(Line), both, " \t\r"),
    Trimmed =/= "" andalso not lists:prefix("%%", Trimmed).

%% `git' from Erlang rather than a shell pipeline, so the file list is exact. Called as a
%% list comprehension argument it is evaluated once.
git(Args) ->
    Out = os:cmd("git " ++ lists:join(" ", Args) ++ " 2>/dev/null"),
    [string:trim(L) || L <- string:split(string:trim(Out), "\n", all), L =/= ""].
