#!/usr/bin/env escript
%% -*- erlang -*-
-mode(compile).

%% edoc_preview.escript -- what edoc's output would look like IF the source carried
%% `%% @doc' tags, without changing the source.
%%
%% WHY
%%
%% `apps/etherlang/doc/README.md' claims three things: that edoc on OTP 29 binds a
%% comment to a function only with an explicit `%% @doc' tag; that this tree has none, so
%% the whole comment corpus is absent from `make docs'; and that adding them
%% mechanically would be **wrong**, because most of this prose is rationale rather than
%% description, much of it sitting after the function it explains or spanning several
%% functions as a section banner.
%%
%% The first two were measured. The third is a claim about a hypothetical, and a claim
%% about a hypothetical should be runnable -- so this runs it, and the output is there to
%% disagree with if the claim is wrong.
%%
%% WHAT IT DOES
%%
%% Copies `apps/etherlang/src' into `doc/edoc-preview-src', inserts `%% @doc ' into the
%% comment blocks that would be defensible to tag, runs edoc over the copy, and writes
%% the result to `doc/edoc-preview'. **`apps/etherlang/src` is never opened for writing**
%% and `doc/` is gitignored, so nothing here can reach the repository.
%%
%% Which blocks get tagged:
%%
%%   default   only `precedes' -- the block whose next line of code is a function head.
%%             That is the most defensible subset: the ones a person would agree are
%%             about that function.
%%   --all     every block, `follows' and `banner' included. This is the mechanical
%%             version and it is here to be looked at: a section banner becomes the
%%             docstring of whichever function happens to follow it.
%%
%% The classification uses `erl_scan/string/3' with `{return_comments, true}' and **the
%% same three-way rule as `rationale.escript'**. That is not tidiness. If the two tools
%% classified differently, a comparison between their output would be confounded by the
%% classifier rather than by the tagging, and the exercise would measure nothing.
%%
%% Line numbers in the preview are shifted by the number of tags inserted, so a line
%% number in the HTML will not match the source. The scratch copy is left in place for
%% exactly that reason.
%%
%% USAGE
%%
%%   tools/edoc_preview.escript [--all]

-export([main/1]).

-define(SRC, "apps/etherlang/src").
-define(INCLUDE, "apps/etherlang/include").
-define(OUT, "doc/edoc-preview").
-define(SCRATCH, "doc/edoc-preview-src").

main(Args) ->
    All = lists:member("--all", Args),
    Files = filelib:wildcard(filename:join([?SRC, "*.erl"])),
    true = Files =/= [],
    ok = filelib:ensure_dir(filename:join([?SCRATCH, "x"])),
    %% Classify and rewrite **inside the per-file loop**, so a block never has to be
    %% attributed to a file it was not read from. An earlier version collected every
    %% file's blocks into one list and then asked which file each belonged to, with an
    %% `in_file/2' that returned `true' -- so every block was tagged into all 48 files.
    %% The bug is visible in the output, which is the argument for keeping the loop.
    Tagged = [tag_one(F, blocks(F), All) || F <- Files],
    AllBlocks = lists:append([blocks(F) || F <- Files]),
    Pages = run_edoc(),
    report(AllBlocks, lists:sum(Tagged), All, Pages),
    halt(0).

%% ---------------------------------------------------------------------------
%% Classify: one tokenizer pass, one shape out
%% ---------------------------------------------------------------------------

%% Returns [{FirstLine, LastLine, Kind}] in source order. Everything about the file
%% other than those three facts is discarded as it is scanned, which is what keeps this
%% linear on a 2,246-line module.
blocks(File) ->
    {ok, Bin} = file:read_file(File),
    Src = unicode:characters_to_list(Bin),
    {ok, Tokens, _} = erl_scan:string(Src, 1, [{text, true}, {return_comments, true}]),
    annotate(group(skeleton(Tokens, [], []), []), []).

%% Reduce the token stream to three things: comment lines, function heads, and the
%% ends of function bodies. Everything else -- punctuation, bodies, other attributes --
%% is dropped, because the only question ever asked of this is "what is next to this
%% comment".
%%
%% **`erl_scan` does not emit `{function, ...}` tokens.** That was the bug that made the
%% first version of this report 0 `precedes` out of 1,029 blocks: the clause that looked
%% for one was dead code, every function head was invisible, and every block therefore
%% had no adjacent head. The token is `erl_parse`'s, not the scanner's.
%%
%% Heads are therefore found **form-wise**: a `dot` ends a form, a form that begins with
%% an `atom` followed by `(` is a definition, and a form that begins with `-` is an
%% attribute. That is unambiguous, and it needs no application beyond the scanner.
skeleton([], _Form, Items) -> lists:reverse(Items);
skeleton([{dot, _} | Rest], Form, Items) ->
    Items1 = form_start(Form, Items),
    skeleton(Rest, [], Items1);
%% `Form' and `Items' are accumulated **separately**, and they have to be. An earlier
%% version wrote `[Form | Skel]` with `Skel' being the items list, so every token went
%% into `Items' as well as into `Form' -- `Items' came out as every token of the file
%% with comments interleaved, `form_start/2' was handed nonsense, no head was ever
%% recognised, and the classifier reported **0 `precedes' out of 1,101 blocks**. The
%% symptom was a plausible-looking number rather than an error, which is the worst kind.
skeleton([{comment, A, _} | Rest], Form, Items) ->
    skeleton(Rest, Form, [{comment, loc(A)} | Items]);
skeleton([T | Rest], Form, Items) ->
    skeleton(Rest, [T | Form], Items).

%% A form that ended without being classified. Only a leading `atom` + `(` can be a
%% definition; anything else is an attribute or something this does not care about.
%%
%% **`lists:reverse/1` first, because `Form' is accumulated as `[T | Form]' and is
%% therefore reversed.** Matching against it as-is tests the *last* token of the form
%% against the pattern for the first, which never matches anything -- so no head was
%% ever recognised and the classifier reported 0 `precedes' in 1,029 blocks while
%% looking entirely healthy. A pattern that cannot match and a pattern that should not
%% match produce the same output; the difference is only visible in what you expected.
form_start(FormRev, Items) ->
    case lists:reverse(FormRev) of
        %% **`{'(', Anno}' is a two-tuple, not `{atom, _, '('}`.** Reserved words and
        %% punctuation scan to `{Token, Anno}' while names and literals scan to
        %% `{Kind, Anno, Value}', so a pattern written for the latter cannot match the
        %% former. It never threw, it simply never matched, and the classifier reported
        %% 0 `precedes' in 1,029 blocks.
        [{atom, A, N}, {'(', _} | _] -> [{function, N, loc(A)} | Items];
        _ -> Items
    end.

loc(A) -> proplists:get_value(location, A, 0).

%% Runs of comment lines become one `{block, First, Last}' and **everything else is
%% kept**. The discarded-everything-else version is what made the classifier report 0
%% `precedes' in 1,029 blocks: `next_code/1' walks this list looking for the head above
%% a block, and the heads had been thrown away three functions earlier. A helper whose
%% job is to find the neighbouring item cannot be given a list the neighbour is not in.
group([], Acc) -> lists:reverse(Acc);
group([{comment, L} | Rest], Acc) ->
    {Run, Rest1} = take_run(Rest, [L], L),
    group(Rest1, [{block, hd(Run), lists:last(Run)} | Acc]);
group([T | Rest], Acc) -> group(Rest, [T | Acc]).

%% **The accumulator is the whole point of this function and an earlier version did not
%% have one.** It threaded the *threshold* and never the line, so every block came out
%% as a single line: `eth_word.erl' reported six blocks at {3,3}, {17,17}, {42,42} ...
%% rather than the six real runs, every `Last' was the block's own first line, and
%% `classify_one/3' therefore never saw an adjacent head -- **0 precedes out of 1,029
%% blocks**, which is how the classifier looked broken when it was the span arithmetic.
%% The symptom was a number that looked absurd rather than an error.
take_run([{comment, L} | Rest], Acc, Prev) when L =:= Prev + 1 ->
    take_run(Rest, [L | Acc], L);
take_run(Rest, Acc, _Prev) -> {lists:reverse(Acc), Rest}.

annotate([], _Prev) -> [];
annotate([{block, First, Last} | Rest], Prev) ->
    Kind = classify_one(last_code(Prev), next_code(Rest), Last),
    [{First, Last, Kind} | annotate(Rest, [{block, First, Last} | Prev])];
%% Non-block items -- the function heads -- pass straight through. They are in the list
%% precisely so `next_code/1' and `last_code/1' can see them; dropping them here would
%% undo that. **This clause has to come last**: with it first it matched every block
%% too, and the report said "0 of 0" -- a number that reads like a measurement and is
%% the result of never having run the thing it measures.
annotate([Item | Rest], Prev) -> annotate(Rest, [Item | Prev]).

%% Both neighbours are read off the *grouped* list, so a block is a three-tuple
%% `{block, First, Last}' here and not a two-tuple. Matching `{_, _}' for "any other
%% item" stopped matching the moment blocks were tagged, and the crash is a good deal
%% louder than the silent version it replaced.
last_code([{function, N, L} | _]) -> {function, N, L};
last_code([{block, F, _} | _]) -> {block, F};
last_code([_ | _]) -> other;
last_code([]) -> none.

next_code([{function, N, L} | _]) -> {function, N, L};
next_code([{block, F, _} | _]) -> {block, F};
next_code([_ | _]) -> other;
next_code([]) -> none.

%% The rule, stated once and used by both tools. `follows' when the previous code was a
%% function that ended before the block; `precedes' when the next code is a head on the
%% line immediately after it; `banner' otherwise -- which covers "the next code is not
%% adjacent" and "there is no next code at all".
%% **`precedes' is tested first, and that ordering is the point.** A comment sitting
%% between the end of one function and the head of the next, with no blank line
%% anywhere, satisfies *both* rules: the previous code is a function that ended, and the
%% next code is a head on the very next line. Testing `follows' first sent all of them
%% to `follows' and the report said 148 `precedes' where an independent count said 513 --
%% the 365 that vanished are precisely the comments in edoc's own canonical position for
%% a docstring. Adjacency to a head is the stronger and more specific claim, so it wins.
classify_one(_, {function, _, L}, Last) when L =< Last + 1 -> precedes;
classify_one({function, _, L}, _, Last) when L < Last -> follows;
classify_one(_, _, _) -> banner.

%% ---------------------------------------------------------------------------
%% Rewrite: into the scratch copy, never the source
%% ---------------------------------------------------------------------------

%% The `%%' is put on the **first** line of the block. EDoc takes the whole contiguous
%% comment run as the docstring once the run is opened with the tag, so the block's own
%% text is carried along verbatim and only the opening is rewritten -- which is the point
%% of the preview: the content is not being reinterpreted, only opened.
tag_one(File, Blocks, All) ->
    {ok, Bin} = file:read_file(File),
    Lines = string:split(binary_to_list(Bin), "\n", all),
    Heads = [F || {F, _L, Kind} <- Blocks, All orelse Kind =:= precedes],
    %% `lists:join/2' and not the bare list: `rewrite/4' returns lines with no
    %% separators between them, and writing that as a deep list concatenates the whole
    %% file onto one line. The symptom was 48 files of "module name missing" and
    %% "syntax error before: '.'" from edoc, which reads as a tagging problem and is a
    %% missing "\n".
    Out = lists:join("\n", rewrite(Lines, Heads, 1)),
    %% `unicode:characters_to_binary/1' before writing: `file:write_file/2' answers
    %% `badarg' on iodata that is not valid UTF-8, and the comments here are full of
    %% real characters. The error names neither encoding nor the offending byte.
    ok = file:write_file(filename:join([?SCRATCH, filename:basename(File)]),
                         unicode:characters_to_binary(Out)),
    %% **The number of blocks actually opened**, not the number of blocks. It reported
    %% `length(Blocks)' -- "1,101 of 1,101" -- while tagging none of them under the
    %% default, which is a summary that cannot be wrong by accident.
    length(Heads).

%% `open_doc/1' is applied **only where the line is a selected head**, and an earlier
%% version piped every line through it and consulted the head list merely to update an
%% accumulator it then discarded. With `--all' that looks identical; with the default
%% `-- no --all -- it tagged all 1,101 blocks while the summary reported 0 tagged, and
%% the two numbers were produced by the same run.
%%
%% The `Acc' is gone with it: `lists:member/2` over a list of block heads is linear in
%% the size of one file's block list, which is not a cost worth an accumulator that can
%% disagree with the decision it is supposed to be recording.
rewrite([], _Heads, _N) -> [];
rewrite([L | Rest], Heads, N) ->
    Out = case lists:member(N, Heads) of
              true -> [open_doc(L)];
              false -> [L]
          end,
    Out ++ rewrite(Rest, Heads, N + 1).

%% "%% Alpha does a thing." -> "%% @doc Alpha does a thing."; "%%" -> "%% @doc".
%% Leading indentation is preserved, because several of these blocks use it to show a
%% stack and dropping it would misrepresent them.
open_doc(L) ->
    case string:prefix(L, "%%") of
        nomatch -> L;
        %% **The space is load-bearing.** "%% @doc" ++ "Coerce ..." gives
        %% "%% @docCoerce ...", and edoc then reads the tag *name* as `docCoerce' and
        %% warns "tag @docCoerce not recognized" once per line -- 6,000 warnings that all
        %% say the same thing, none of which says the space is missing.
        Rest -> "%% @doc " ++ string:trim(Rest, leading)
    end.

%% ---------------------------------------------------------------------------

run_edoc() ->
    _ = filelib:ensure_dir(filename:join([?OUT, "x"])),
    _ = [file:delete(F) || F <- filelib:wildcard(filename:join([?OUT, "*.html"]))],
    _ = code:add_paths(filelib:wildcard(
                        filename:join(["_build", "default", "lib", "*", "ebin"]))),
    %% edoc:file/2 rather than edoc:application/2: the scratch copy is a bare directory
    %% with no `.app' and no beams of its own. The compiled beams are on the path only so
    %% the include resolves.
    %% `filelib:wildcard/2' returns paths that already include the directory, so the
    %% basename is what belongs here. Joining ?SCRATCH onto the result doubled it, and
    %% edoc reported "error reading file" 48 times, which is exactly as unhelpful as it
    %% sounds: the message names a path that does not exist rather than the one that does.
    lists:foreach(fun(Path) ->
        %% try/catch rather than `catch': `catch Expr' is deprecated, and an escript
        %% compiled with -mode(compile) is held to the same standard as the app.
        try edoc:file(Path,
                      [{dir, ?OUT}, {preprocess, true}, {includes, [?INCLUDE]}]) of
            _ -> ok
        catch
            _:_ -> ok
        end
    end, filelib:wildcard(filename:join([?SCRATCH, "*.erl"]))),
    length(filelib:wildcard(filename:join([?OUT, "*.html"]))).

count(K, L) -> length([X || X <- L, X =:= K]).

report(AllBlocks, Tagged, All, Pages) ->
    Kinds = [K || {_, _, K} <- AllBlocks],
    io:format("edoc preview -- ~s~n",
              [case All of
                   true -> "ALL blocks tagged (the mechanical version)";
                   false -> "only `precedes' blocks tagged (the defensible subset)"
               end]),
    io:format("  blocks: ~p precedes, ~p follows, ~p banner~n",
              [count(precedes, Kinds), count(follows, Kinds), count(banner, Kinds)]),
    io:format("  blocks opened with %% @doc: ~p of ~p~n", [Tagged, length(AllBlocks)]),
    %% A summary that says 0 tagged and does not say why is the failure mode this whole
    %% exercise ran into twice, so it is spelled out rather than left to be noticed.
    case {All, Tagged, length(AllBlocks), count(precedes, Kinds)} of
        {false, 0, _, 0} ->
            io:format("  **no block was tagged and none was classified `precedes'.** "
                      "That is a defect in the classifier, not a result -- check "
                      "`blocks/1' before believing anything else on this line.~n", []);
        {false, 0, _, P} ->
            io:format("  **nothing tagged although ~p blocks are `precedes'.** The "
                      "rewrite and the classifier have disagreed.~n", [P]);
        {false, T, _N, P} when T =:= P ->
            ok;
        {false, T, _, P} when T =/= P ->
            io:format("  tagged ~p but the classifier found ~p `precedes' -- "
                      "disagreement.~n", [T, P]);
        _ -> ok
    end,
    io:format("  edoc wrote ~p pages to ~s/ -- open ~s/index.html~n",
              [Pages, ?OUT, ?OUT]),
    io:format("  scratch sources at ~s (line numbers shifted by the tags)~n",
              [?SCRATCH]),
    ok.
