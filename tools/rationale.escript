#!/usr/bin/env escript
%% -*- erlang -*-
%%! -pa _build/default/lib/*/ebin
-mode(compile).

%% rationale.escript -- render this repository's `%%' comment blocks as navigable HTML.
%%
%% WHY THIS EXISTS
%%
%% `make docs' runs edoc, and edoc on OTP 29 binds a comment to a function **only when
%% the comment carries an explicit `%% @doc' tag**. Plain `%%' prose is dropped, and it
%% is dropped *silently*. This tree has function heads with a `%%' block immediately
%% above them and **zero** `@doc' tags, so every comment line in `src' is absent from the
%% generated API reference. That is a property of the tool rather than of the comments
%% -- but the comments are where this project's knowledge actually is, so they should be
%% readable.
%%
%% WHAT IT IS NOT
%%
%% **This does not produce docstrings, and it does not pretend to.** Adding `%% @doc' to
%% these blocks by hand would be the native fix and is deliberately not done here: most
%% of this prose is *rationale* -- what an EIP says, what the node used to do, what the
%% symptom was -- and a good deal of it sits deliberately *after* the function it
%% explains, or spans several functions as a section banner. Tagging it mechanically
%% would make a design-decision essay the docstring of whichever function happened to
%% follow it, which is the same mistake as the three tests in this repository that
%% recorded a defect as a requirement -- and a quieter one, because a wrong docstring is
%% not a failing test.
%%
%% SO IT REPORTS ADJACENCY, NOT ATTRIBUTION
%%
%% For every block it reports **what the text around it actually is**, as observed:
%%
%%   * `precedes`  -- the next line of code is the one after the block
%%   * `follows`   -- the line before the block ended a function
%%   * `banner`    -- blank lines on both sides
%%
%% and, separately, the function a `precedes' block *resolves* to, where it resolves
%% unambiguously. Where it does not, the target reads `ambiguous' rather than picking.
%% The point is that every label is a fact about the source rather than an inference
%% dressed as one, so a reader can disagree with an attribution without it having been
%% hidden from them.
%%
%% HOW IT PARSES
%%
%% With `erl_scan:string/3' and `{return_comments, true}', not by reading lines. A
%% line-based scan cannot tell `%%' inside a string from a comment, and this codebase has
%% plenty of both. erl_scan is the compiler's own front end, so `"%% not a comment"' is
%% correctly not a comment, and a quote inside a `%%' comment cannot end it.
%%
%% USAGE
%%
%%   tools/rationale.escript [src-dir] [out-dir]
%%   (defaults: apps/etherlang/src, doc/rationale)

-export([main/1]).

-define(TITLE, "etherlang rationale index").
-define(DEFAULT_SRC, "apps/etherlang/src").
-define(DEFAULT_OUT, "doc/rationale").
-define(USAGE, "rationale.escript [src-dir] [out-dir]  (defaults: apps/etherlang/src  doc/rationale)").

main(Args) ->
    [Root, Out] = case Args of
                      [] -> [?DEFAULT_SRC, ?DEFAULT_OUT];
                      [D] -> [D, ?DEFAULT_OUT];
                      [D, O] -> [D, O];
                      _ -> io:format("usage: ~ts~n", [?USAGE]), halt(1)
                  end,
    case filelib:wildcard(filename:join([Root, "*.erl"])) of
        [] ->
            io:format("no .erl files under ~ts -- is that the right directory?~n", [Root]),
            halt(1);
        _ -> ok
    end,
    Mods = lists:sort([scan_file(F) || F <- filelib:wildcard(filename:join([Root, "*.erl"]))]),
    ok = filelib:ensure_dir(filename:join([Out, "x"])),
    ok = write_index(Out, Mods),
    [ok = write_module(Out, M) || M <- Mods],
    report(Out, Mods),
    halt(0).

%% ---------------------------------------------------------------------------
%% Scanning
%% ---------------------------------------------------------------------------

%% Returns {ModuleName, ExportsMap, Blocks}. Everything else about the file is
%% discarded as it is scanned, which is what keeps this linear: a 2,246-line module
%% yields a few hundred blocks and nothing else is retained.
scan_file(File) ->
    {ok, Bin} = file:read_file(File),
    Src = unicode:characters_to_list(Bin),
    {ok, Tokens, _} = erl_scan:string(Src, 1, [{text, true}, {return_comments, true}]),
    Name = module_name(Tokens),
    Exports = exports_of(Tokens),
    Skeleton = skeleton(Tokens, [], []),
    Blocks = annotate(group_comments(Skeleton, []), [], Exports),
    {Name, Exports, Blocks}.

module_name(Tokens) -> attr_value(Tokens, module, 'unnamed-module').

%% Walk forward from a `-Name' token to the first value token after it.
attr_value([], _Key, Default) -> Default;
attr_value([{atom, _, Key} | Rest], Key, Default) ->
    case take_value(Rest) of
        {ok, V} -> V;
        error -> attr_value(Rest, Key, Default)
    end;
attr_value([_ | Rest], Key, Default) -> attr_value(Rest, Key, Default).

take_value([{atom, _, V} | _]) -> {ok, V};
take_value([{integer, _, V} | _]) -> {ok, V};
%% **The tail, not the list.** `[_ | _] = L' binds `L' to the *whole* list, so
%% `take_value(L)' calls itself with the identical argument and spins forever. It hung
%% the tool on its first file, with no output and no files written, which is the least
%% diagnosable failure mode there is; `= L` here read as shorthand for "the rest" and is
%% not.
take_value([_ | Rest]) -> take_value(Rest);
take_value([]) -> error.

%% The `-export([...])' list, so a block can say whether the function it precedes is
%% part of the module's surface. Keyed on {Name, Arity}.
exports_of(Tokens) -> exports_scan(Tokens, #{}).

exports_scan([], Acc) -> Acc;
exports_scan([{atom, _, export} | Rest], Acc) ->
    case take_arity_list(Rest) of
        {ok, L} -> lists:foldl(fun({F, Ar}, M) -> M#{{F, Ar} => true} end, Acc, L);
        error -> exports_scan(Rest, Acc)
    end;
exports_scan([_ | Rest], Acc) -> exports_scan(Rest, Acc).

take_arity_list([{'(', _} | Rest]) -> take_pairs(Rest, []);
take_arity_list([_ | Rest]) -> take_arity_list(Rest);
take_arity_list([]) -> error.

take_pairs([{dot, _} | _], Acc) -> {ok, lists:reverse(Acc)};
take_pairs([{atom, _, F}, {integer, _, Ar} | Rest], Acc) -> take_pairs(Rest, [{F, Ar} | Acc]);
take_pairs([_ | Rest], Acc) -> take_pairs(Rest, Acc).

%% Reduce the token stream to comment lines, function heads and the ends of function
%% bodies. Everything else -- punctuation, bodies, other attributes -- is dropped,
%% because the only question ever asked of this is "what is next to this comment".
%%
%% Four things about this are wrong in the version it replaces, and every one of them
%% produced a *plausible number* rather than an error, which is why they are written
%% down rather than just fixed:
%%
%%   1. **`erl_scan` does not emit `{function, ...}` tokens.** That is `erl_parse`'s.
%%      The clause that looked for one was dead code, so every function head was
%%      invisible and **every block classified `banner`**. Heads are found form-wise
%%      instead: a `dot' ends a form, and a form beginning with an `atom` followed by
%%      `(` is a definition.
%%   2. **`{'(', Anno}' is a two-tuple**, while `{atom, Anno, Value}' is a three-tuple,
%%      so the pattern for a head never matched even once the token was looked for.
%%   3. **`Form` is accumulated as `[T | Form]`,** so it is reversed; the head test has
%%      to look at the *end* of it. Matching it as-is is a pattern that cannot match,
%%      which is indistinguishable from one that should not.
%%   4. **`Form` and `Items` were one list,** so every token went into the items as well
%%      and the head test was handed nonsense.
%%
%% `tools/edoc_preview.escript` carries the same classifier for the same reason, and the
%% two are meant to agree: if they classified differently, a comparison between their
%% output would be confounded by the classifier rather than by the thing being compared.
skeleton([], _Form, Items) -> lists:reverse(Items);
skeleton([{dot, _} | Rest], Form, Items) ->
    skeleton(Rest, [], form_start(Form, Items));
skeleton([{comment, A, T} | Rest], Form, Items) ->
    skeleton(Rest, Form, [{comment, loc(A), strip(T)} | Items]);
skeleton([T | Rest], Form, Items) ->
    skeleton(Rest, [T | Form], Items).

form_start(FormRev, Items) ->
    case lists:reverse(FormRev) of
        [{atom, A, N}, {'(', _} | _] -> [{function, N, loc(A)} | Items];
        _ -> Items
    end.

loc(A) -> proplists:get_value(location, A, 0).

%% Drop the leading `%%' and the space after it, and trim the ends.
%%
%% **No regular expression.** `re:replace/3' was the obvious way to do this and rejected
%% its own argument twice -- the comment token's text is a list, not a binary, and
%% `{return, list}' wants something it will accept. A two-line prefix strip has no such
%% opinions and cannot be wrong about either. Interior indentation is deliberately left
%% alone: several of these blocks use it to show a stack, and flattening it would
%% misrepresent them.
strip(Text) when is_binary(Text) -> strip(binary_to_list(Text));
strip([$%, $% | Rest]) -> string:trim(Rest);
strip(Text) -> string:trim(Text).

%% Runs of comment lines on consecutive lines are one block; a blank line between them
%% ends it, which is the rule a reader applies. **Everything else is kept**, because
%% `annotate/3' reads each block's neighbours off this very list: a version that dropped
%% the function heads made every block look like a banner, since the head it was about
%% to be compared against had been thrown away.
%%
%% The accumulator on `take_comment_run/3` is the whole point of that function. A version
%% threaded only the *threshold* and never the line, so every block came out as a single
%% line and every `Last' was the block's own first line.
group_comments([], Acc) -> lists:reverse(Acc);
group_comments([{comment, L, T} | Rest], Acc) ->
    {LinesRev, Rest1} = take_comment_run(Rest, [{L, T}], L),
    %% `take_comment_run/3' conses, so it hands back the run **reversed**; and each
    %% element is a `{Line, Text}' pair, so `hd/1' and `last/1' would be pairs and
    %% `element(3, Block)` in `annotate/3' would be a pair too. That surfaced as
    %% `io_lib:format("another block ending at line ~b", [{39, "reasoned about in."}])`
    %% -- a pair where a line number was expected, from a block whose first line was 38.
    Lines = lists:reverse(LinesRev),
    Acc1 = [{block, line_of(hd(Lines)), line_of(lists:last(Lines)),
             [Txt || {_, Txt} <- Lines]} | Acc],
    group_comments(Rest1, Acc1);
group_comments([T | Rest], Acc) -> group_comments(Rest, [T | Acc]).

take_comment_run([{comment, L, T} | Rest], Acc, Prev) when L =:= Prev + 1 ->
    take_comment_run(Rest, [{L, T} | Acc], L);
take_comment_run(Rest, Acc, _Prev) -> {Acc, Rest}.

%% The line number out of a `{Line, Text}' pair. `hd/1` and `last/1` on the run give
%% pairs, and the block's span is two integers.
line_of({L, _}) -> L.

%% Annotate each block with its adjacency, its two neighbours and -- for `precedes' --
%% the function it resolves to.
annotate([], _Prev, _Exports) -> [];
annotate([Block = {block, First, _Last, _Lines} | Rest], Prev, Exports) ->
    PrevCode = last_code(Prev),
    NextCode = next_code(Rest),
    Last = element(3, Block),
    Kind = classify_one(PrevCode, NextCode, Last),
    Target = case Kind of
                 precedes -> resolve_target(Rest);
                 _ -> none
             end,
    [annotated(Kind, First, Block, PrevCode, NextCode, Target)
     | annotate(Rest, [Block | Prev], Exports)];
%% Heads pass through untouched: they are in the list so the two neighbour functions can
%% see them. **This clause must come last** -- placed first it matches every block too,
%% and the index says "0 blocks" in a voice that sounds like a measurement.
annotate([Item | Rest], Prev, Exports) -> annotate(Rest, [Item | Prev], Exports).

annotated(Kind, First, {_b, _F, Last, Lines}, Prev, Next, Target) ->
    {Kind, First, Last, length(Lines), Lines, Prev, Next, Target}.

%% The two neighbours, read off the grouped list. A head is `{function, Name, Line}' --
%% no arity, because the skeleton never had one: `{function, ...}' is `erl_parse's`
%% token and this is not a parse tree.
last_code([{function, N, L} | _]) -> {function, N, L};
last_code([{block, F, _, _} | _]) -> {block, F};
last_code([_ | _]) -> other;
last_code([]) -> none.

next_code([{function, N, L} | _]) -> {function, N, L};
next_code([{block, F, _, _} | _]) -> {block, F};
next_code([_ | _]) -> other;
next_code([]) -> none.

%% **`precedes' is tested first, and the ordering is a decision rather than a detail.**
%% A comment between the end of one function and the head of the next, with no blank
%% line anywhere, satisfies both rules: the previous code is a function that ended, and
%% the next code is a head on the very next line. Testing `follows' first sent all of
%% them to `follows' and the index reported 148 `precedes' where an independent count
%% said 513 -- the difference is precisely the comments in edoc's own canonical position
%% for a docstring. Adjacency to a head is the more specific claim, so it wins.
classify_one(_, {function, _, L}, Last) when L =< Last + 1 -> precedes;
classify_one({function, _, L}, _, Last) when L < Last -> follows;
classify_one(_, _, _) -> banner.

%% From a block, walk forward to the function head it precedes.
%%
%% **Conservative on purpose, and the reason is worth stating.** The skeleton has every
%% attribute discarded, so this walk cannot tell a `-spec' from a function head: it only
%% asks whether the *next surviving item* is a head. That means a block separated from
%% its function by a blank line resolves to `ambiguous' rather than to the function,
%% because in this codebase a block above a blank line above a head is much more often a
%% section banner than a description. Claiming it would be the tool inventing an
%% attribution; declining is the tool reporting what it can see.
resolve_target([{function, N, L} | _]) -> {ok, {N, L}};
resolve_target(_) -> ambiguous.

%% ---------------------------------------------------------------------------
%% Rendering
%% ---------------------------------------------------------------------------

write_index(Out, Mods) ->
    Blocks = lists:append([Bs || {_, _, Bs} <- Mods]),
    Kinds = [element(1, B) || B <- Blocks],
    Lines = lists:sum([element(4, B) || B <- Blocks]),
    Body = io_lib:format(
      "<h1>etherlang rationale index</h1>~n"
      "<p>Every <code>%%</code> comment block in <code>apps/etherlang/src</code>, in "
      "source order, with <strong>what the source has on either side of it</strong>. "
      "<strong>~b blocks, ~b comment lines, ~b modules.</strong> None of this is in "
      "<code>make docs</code>' output.</p>~n"

      "<h2>What this is not</h2>~n"
      "<p><strong>These are not docstrings.</strong> edoc on OTP 29 binds a comment to a "
      "function only when the comment carries an explicit <code>%% @doc</code> tag, and "
      "this tree has none, so the whole corpus is absent from the generated API "
      "reference. That is a property of the tool rather than of the comments. It is also "
      "the right outcome: most of this prose is <em>rationale</em> &mdash; what an EIP "
      "says, what the node used to do, what the symptom was &mdash; and much of it sits "
      "deliberately <em>after</em> the function it explains, or spans several functions "
      "as a section banner. Tagging it mechanically would make a design-decision essay "
      "the docstring of whichever function happened to follow it.</p>~n"

      "<p>So every label below is a <strong>fact about the source</strong> rather than "
      "an inference presented as one. A reader can disagree with an attribution, and it "
      "will not have been hidden.</p>~n"

      "<h2>Adjacency</h2>~n"
      "<table>~n"
      "<tr><th>label</th><th>blocks</th><th>share</th><th>means</th></tr>~n"
      "<tr><td><code>precedes</code></td><td>~b</td><td>~ts</td>"
      "<td>the next line of code is the one after the block, and it is a function head</td></tr>~n"
      "<tr><td><code>follows</code></td><td>~b</td><td>~ts</td>"
      "<td>the block sits inside a function body, so it is trailing rationale for that "
      "function rather than a description of it</td></tr>~n"
      "<tr><td><code>banner</code></td><td>~b</td><td>~ts</td>"
      "<td>blank lines on both sides: a section banner, or a block belonging to no "
      "single function</td></tr>~n"
      "</table>~n"

      "<h2>Modules</h2>~n"
      "<table>~n"
      "<tr><th>module</th><th>blocks</th><th>comment lines</th><th>precedes</th>"
      "<th>follows</th><th>banner</th><th>exports</th></tr>~n~ts</table>~n"

      "<h2>On parsing</h2>~n"
      "<p>With <code>erl_scan:string/3</code> and "
      "<code>{return_comments, true}</code>, not by reading lines. A line-based scan "
      "cannot tell <code>%%</code> inside a string from a comment, and this codebase has "
      "plenty of both; erl_scan is the compiler's own front end, so "
      "<code>\"%% not a comment\"</code> is correctly not a comment.</p>~n"

      "<p>The <code>target</code> of a <code>precedes</code> block is resolved by walking "
      "the *skeleton* -- the token stream with every attribute and every body discarded -- "
      "to the next function head. Anything else in between reads "
      "<code>ambiguous</code>. That is conservative on purpose: a block that documents a "
      "section rather than a function is common here, and guessing would be worse than "
      "declining.</p>~n"

      "<p>Generated by <code>tools/rationale.escript</code>. The signature-level API "
      "reference is a separate artefact, from <code>make docs</code>.</p>~n",
      [length(Blocks), Lines, length(Mods),
       count(precedes, Kinds), pct(count(precedes, Kinds), length(Kinds)),
       count(follows, Kinds), pct(count(follows, Kinds), length(Kinds)),
       count(banner, Kinds), pct(count(banner, Kinds), length(Kinds)),
       [[module_row(M, E, Bs) || {M, E, Bs} <- Mods]]]),
    ok = write(filename:join(Out, "index.html"), page(?TITLE, Body)).

module_row(M, Exports, Blocks) ->
    K = [element(1, B) || B <- Blocks],
    Lines = lists:sum([element(4, B) || B <- Blocks]),
    io_lib:format("<tr><td><a href=\"~ts.html\">~ts</a></td><td>~b</td><td>~b</td>"
                  "<td>~b</td><td>~b</td><td>~b</td><td>~b</td></tr>",
                  [esc(M), esc(M), length(Blocks), Lines,
                   count(precedes, K), count(follows, K), count(banner, K),
                   maps:size(Exports)]).

write_module(Out, Mod) ->
    {M, _Exports, Blocks} = Mod,
    Lines = lists:sum([element(4, B) || B <- Blocks]),
    Body = io_lib:format(
      "<h1>~ts</h1>~n<p>~b comment blocks, ~b lines, in source order. "
      "<a href=\"index.html\">back to the index</a>.</p>~n~ts",
      [esc(M), length(Blocks), Lines, [[block_html(B) || B <- Blocks]]]),
    ok = write(filename:join(Out, esc(M) ++ ".html"), page(M, Body)).

block_html({Kind, First, Last, NLines, Lines, Prev, Next, Target}) ->
    io_lib:format(
      "<div class=\"blk\"><h3><code>~ts</code> &mdash; lines ~b&ndash;~b (~b)~ts</h3>~n"
      "<p class=\"where\"><strong>adjacency</strong> ~ts<br>"
      "<strong>line before</strong> ~ts<br>"
      "<strong>line after</strong> ~ts<br>"
      "<strong>target</strong> ~ts</p>~n"
      "<pre>~ts</pre>~n</div>~n",
      [Kind, First, Last, NLines, badge(Target),
       explain(Kind),
       describe(Prev), describe(Next), describe_target(Target),
       [[esc(L), "\n"] || L <- Lines]]).

badge(none) -> "";
badge(ambiguous) -> "";
badge(_) -> "".

explain(precedes) -> "<code>precedes</code> &mdash; the next line of code is the one "
                     "after this block";
explain(follows) -> "<code>follows</code> &mdash; this block sits inside a function "
                    "body, so it is trailing rationale for that function rather than a "
                    "description of it";
explain(banner) -> "<code>banner</code> &mdash; blank lines on both sides: a section "
                   "banner, or a block belonging to no single function".

describe(none) -> "&mdash; (start or end of file)";
describe({block, L}) -> io_lib:format("another block ending at line ~b", [L]);
describe({function, N, L}) -> io_lib:format("function <code>~p</code>, line ~b",
                                            [N, L]);
describe({dot, L}) -> io_lib:format("end of a function body, line ~b", [L]).

describe_target(none) -> "&mdash;";
describe_target(ambiguous) ->
    "<code>ambiguous</code> &mdash; the next item in the skeleton is not a function "
    "head, so this block is not claimed to document one";
describe_target({ok, {N, L}}) -> io_lib:format("<code>~p</code> at line ~b", [N, L]).

page(Title, Body) ->
    io_lib:format(
      "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
      "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
      "<title>~ts</title>~n<style>~n"
      "body{font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,sans-serif;"
      "max-width:62rem;margin:2.5rem auto;padding:0 1.1rem;color:#1b1b1b;"
      "background:#fff}~n"
      "code,pre{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}~n"
      "pre{background:#f7f7f4;padding:.7rem .9rem;border-left:3px solid #d5d5cd;"
      "overflow-x:auto;white-space:pre-wrap;word-wrap:break-word;font-size:.87rem}~n"
      "h1{font-size:1.5rem;margin:0 0 .3rem}~n"
      "h2{font-size:1.1rem;margin:2rem 0 .5rem;border-bottom:1px solid #e6e6df;"
      "padding-bottom:.2rem}~n"
      "table{border-collapse:collapse;margin:.8rem 0;font-size:.9rem;width:100%}~n"
      "th,td{border:1px solid #e0e0d8;padding:.32rem .6rem;text-align:left;vertical-align:top}~n"
      "th{background:#f4f4f0;font-weight:600}~n"
      ".blk{border-top:1px solid #ecece6;padding-top:1.1rem;margin-top:1.6rem}~n"
      ".blk:first-of-type{border-top:0}~n"
      ".blk h3{font-size:.95rem;margin:0 0 .35rem;font-weight:600}~n"
      ".where{color:#5c5c55;font-size:.85rem;margin:.15rem 0 0;line-height:1.45}~n"
      ".exp{color:#1a6b34;background:#eaf6ec;padding:0 .35rem;border-radius:2px;"
      "font-size:.8rem}~n"
      "a{color:#1a5fb4}~n</style></head><body>~n~ts~n</body></html>~n",
      [esc(Title), Body]).

%% `file:write_file/2' returns **badarg** on iodata that is not valid UTF-8, and these
%% comments are full of real characters -- `>=', `x', an en dash -- so the formatted page
%% has to go through `unicode:characters_to_binary/1'. The failure is a `badarg' from
%% `write_file' with no mention of encoding, which is not a helpful way to learn it.
write(Path, Data) -> file:write_file(Path, unicode:characters_to_binary(Data)).

esc(B) when is_binary(B) -> esc(binary_to_list(B));
esc(A) when is_atom(A) -> esc(atom_to_list(A));
esc(L) when is_list(L) ->
    lists:flatten([case C of
                      $& -> "&amp;";
                      $< -> "&lt;";
                      $> -> "&gt;";
                      $" -> "&quot;";
                      $' -> "&#39;";
                      _  -> C
                  end || C <- L]).

%% ---------------------------------------------------------------------------

count(K, L) -> length([X || X <- L, X =:= K]).

pct(_N, 0) -> "0%";
pct(N, T) -> io_lib:format("~.1f%", [100.0 * N / T]).

report(Out, Mods) ->
    Blocks = lists:append([Bs || {_, _, Bs} <- Mods]),
    Kinds = [element(1, B) || B <- Blocks],
    io:format("rationale: ~b modules, ~b blocks, ~b comment lines~n",
              [length(Mods), length(Blocks),
               lists:sum([element(4, B) || B <- Blocks])]),
    io:format("  precedes ~b  follows ~b  banner ~b~n",
              [count(precedes, Kinds), count(follows, Kinds), count(banner, Kinds)]),
    io:format("  -> ~ts/index.html~n", [Out]).
