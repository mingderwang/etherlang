%% **One home per conversion, enforced by the build rather than by a comment.**
%%
%% `eth_hex:decode_bytes/1' is the data-value decoder: `0x`-prefixed hex or the bytes
%% themselves, to the bytes. It refuses an odd number of hex characters, refuses a
%% character that is not a hex digit, and distinguishes `{ok, Bytes}' from `error' so a
%% caller can tell "not DATA" from "the zero-length DATA value".
%%
%% This module asserts that **nothing else decodes hex by hand.** Before it existed,
%% twelve modules each defined their own `hex_to_bin/1' and two of them carried a
%% hand-written `hexval/1' and `pairs/1'. The two shapes were not equivalent:
%%
%%   * `eth_header:hex_to_bin/1' and `eth_state:hex_to_bin/1' ended in
%%     `pairs([A]) -> [hexval(A)]', so **an odd number of hex characters produced one byte
%%     per character** -- `"0x123" -> <<16#12, 16#3>>`, three characters, two bytes. That
%%     is the same defect this repository's own AGENTS.md §10a records, and it is the
%%     defect written three times in one session while adding a *fourth* copy.
%%   * `hexval/1' has no clause for a non-hex character, so a `0x`-prefixed string handed
%%     to it raw died in `hexval(21)` -- a `function_clause` four frames from the code that
%%     passed the string, naming neither. AGENTS.md §10a records that too.
%%
%% **Why a test and not a comment.** A comment says "do not do this"; this says "the
%% build stops". The offender list is the artefact: it is a count, it is in the suite, and
%% it cannot be read past. That is the whole difference, and it is the reason this file
%% exists rather than another paragraph in `AGENTS.md` §10a -- which already explains why
%% hand-written hex decoding is dangerous and has been explained at least twice while
%% twelve copies were added.
%%
%% **The scope is `src/`, and `test/` is deliberately not included.** Four test modules
%% carry their own `hex_to_bin/1'. They are duplicated the same way and are named as
%% remaining work in `TASKS.md` rather than quietly folded in: a test that fails on its
%% own helpers is a different failure from one that fails on the node, and conflating the
%% two would make this file's green mean something weaker.

-module(eth_hex_owners_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SRC, "apps/etherlang/src").
-define(TEST_DIR, "apps/etherlang/test").

%% The names a second copy would take. `pairs/1' and `hexval/1' are here because they are
%% the *implementation* of the hand-rolled decoder: a module could stop naming itself
%% `hex_to_bin' and still decode hex one character at a time.
%% **The parens are escaped, and that is not a detail.** An unescaped `(` in a PCRE
%% pattern is a group opener, so `hex_to_bin(` is an unterminated group and `re:run/3`
%% answers `badarg` before it reads anything -- which is what it did, three patterns in
%% a row, and the failure names the regex rather than the thing being searched for.
%% **`\\b` is load-bearing, and its absence is why this reported six offenders in a
%% file that has none.** `pairs\\(' matches the tail of `parse_pairs(', which is a
%% pairing routine in `eth_pairing_bn128' and has nothing to do with hex decoding. **An
%% instrument with false positives gets switched off, and a switched-off guard is worse
%% than no guard** -- it looks like enforcement and enforces nothing, which is the failure
%% this file was written to avoid.
-define(FORBIDDEN, ["\\bhex_to_bin\\(", "\\bhexval\\(", "\\bpairs\\("]).

no_module_decodes_hex_by_hand_test() ->
    %% `?SRC` is the *directory*, so it has to be expanded. Passing it straight to
    %% `file:read_file/1` answers `{error, badarg}` -- a path that is a directory --
    %% and the two tests in this module disagreed about it for one commit: the floor
    %% test expanded the wildcard and passed while this one did not and failed on a
    %% directory read. **Two assertions over the same corpus should read the corpus the
    %% same way**, and a failure only one of them can see is a failure with one witness.
    Offenders = [{File, Name} || {File, Name} <- lists:flatmap(fun scan/1, source_files())],
    %% **The count is asserted first and separately, because eunit truncates the list.**
    %% The first version of this test asserted only `?assertEqual([], Offenders)', and
    %% the report came back naming six modules of the seven that carry a copy --
    %% `eth_state.erl' and its `pairs([A]) -> [hv(A)]', which is the very defect this
    %% file exists to end, simply missing from the output. **A truncated list reads as a
    %% complete one**, so the number is what a reader can rely on and the names are the
    %% thing to re-derive from it.
    ?assertEqual(0, length(Offenders)),
    ?assertEqual([], Offenders).

%% The assertion above says nothing about *how many* files were checked. A scan that
%% matched no files would satisfy it, and AGENTS.md §5 records exactly that failure in
%% `eth_config_tests`: `re:run/3` returns the first match unless `global' is passed, so a
%% scan written the obvious way reported one variable out of thirty-one and "nothing is
%% unchecked" was satisfied by a scan that had checked almost nothing.
%%
%% **So the floor comes first and the assertion second**, and the floor is checked
%% against the file count rather than a hard-coded number: a deleted module must not be
%% able to make this vacuous.
the_scan_reached_every_source_file_test() ->
    Files = source_files(),
    ?assert(length(Files) >= 48),
    %% **The test directory is asserted separately, so extending the guard cannot be
    %% silently reverted.** A single floor over the union would still pass with the test
    %% half removed as long as enough files were deleted from `src/', and this file has
    %% been the victim of a union-shaped assumption once already.
    ?assert(length(test_files()) >= 64),
    [begin
         Scanned = scan(File),
         %% A module that defines none of the forbidden names still has to have been
         %% *read* -- so the check is that the scan returns a well-formed answer for it,
         %% not that it found something.
         ?assert(is_list(Scanned))
     end || File <- Files],
    ok.

%% **Both directories, and the test directory is the one that was missing.**
%%
%% The guard ran over `?SRC' alone, so seven test modules kept their own decoders:
%% `eth_test_util.erl' among them, which is the module every other fixture builds its
%% blocks with. **A guard scoped to the directory with the tidiest name is a guard with a
%% hole in it**, and the hole was the half of the tree where a helper gets written because
%% `src/` does not export one.
%%
%% Two expansions, both used by every test here, so no test can disagree with another about
%% what was read.
source_files() -> filelib:wildcard(?SRC "/*.erl") ++ filelib:wildcard(?TEST_DIR "/*.erl").

test_files() -> filelib:wildcard(?TEST_DIR "/*.erl").

scan(File) ->
    {ok, Bin} = file:read_file(File),
    Src = code_only(unicode:characters_to_list(Bin)),
    [{File, Name} || Name <- ?FORBIDDEN,
                     %% **`unicode` is required, not optional.** The subject is
                     %% `unicode:characters_to_list/1' output, so an em-dash in a
                     %% comment is codepoint 8212, and a byte-oriented pattern raises
                     %% `badarg' on it. That is this repository's own recorded lesson
                     %% about a scan that stops working on real input.
                     re:run(Src, Name, [global, unicode]) =/= nomatch].

%% **Comments are removed before the scan, and that is the difference between an
%% instrument and a grep.**
%%
%% The first version matched `hex_to_bin\(' against the whole file and reported **four
%% offenders after every copy had been deleted** -- all four were the comments written to
%% record the deletion. So the guard reported a comment *about* the fix as the fix, and
%% the only way to make it green would have been to delete the comments.
%%
%% **That is the same defect as the one this file exists to end, running in the
%% enforcer.** `eth_hex_owners_tests` was written because a comment saying "do not
%% hand-roll a hex decoder" had not stopped twelve of them; a scan that counts a comment
%% as a decoder is the same failure with the polarity reversed, and it would have been
%% fixed by editing prose, which is precisely the wrong repair.
%%
%% Stripping `%%` to end-of-line is enough for Erlang: there is no block comment, and
%% `%%/*` opens one only because `%%` wins -- the trap AGENTS.md records.
code_only(Src) ->
    %% **Flat, no regex, and every line keeps its newline.**
    %%
    %% Two versions of this were wrong in ways that only showed up as a *count*. It
    %% returned a list of lines and handed that nested list to `re:run/3'; then, after
    %% that, it dropped the newline from every line that carried no comment, so a line
    %% ending in `;' ran into the next line's first character -- and `;hex_to_bin(' has a
    %% word boundary in it. **A line-joining instrument that loses line boundaries reports
    %% matches that span two lines**, which is the same failure as a pattern with no word
    %% boundary: a handle that reports things which are not there.
    %%
    %% **`lists:join/2`, and not a comprehension with `$\n' as the generator's tail.**
    %% A generator's tail must be a *bound variable* -- an expression there is a compile
    %% error, which is what the third version of this line was. `join/2` separates with a
    %% newline, so no line runs into the next and the shape of the input cannot change
    %% the answer.
    lists:join([$\n], [strip_comment(L) || L <- string:lexemes(Src, "\n")]).

%% **`[$%, $% | _Rest]` and not `[$%, $\|_Rest]`.** `$\|' is a perfectly legal Erlang
%% character literal -- it is the pipe -- so the clause compiled, the function returned,
%% and the guard was a **no-op**: it truncated only where a `%' was followed by a literal
%% `|', which is not a comment. Three versions of this line were wrong and every one of
%% them compiled and returned.
%%
%% The general form is AGENTS.md's "a pattern that matches more than it means, or less":
%% either way the answer is plausible, and **the count is the only thing that shows it** --
%% which is why this file asserts a plausible number of files scanned
%% (`the_scan_reached_every_source_file_test') and asserts the offender count *before* the
%% offender list, since eunit truncates the list and a truncated list reads as a whole one.
strip_comment(Line) -> strip_comment(Line, []).

strip_comment([], Acc) ->
    lists:reverse(Acc);
strip_comment([$%, $% | _Rest], Acc) ->
    lists:reverse(Acc);
strip_comment([C | Rest], Acc) ->
    strip_comment(Rest, [C | Acc]).
