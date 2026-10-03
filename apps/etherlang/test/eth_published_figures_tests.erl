%% `RELEASE-GATE.md` Tier 0.4: **"Every published figure has a corpus and a date"**
%% is RED, and the gate's own note says why the cell stays: *"the condition, not the
%% number, is what needs enforcing -- and because the pin itself was deleted twice
%% before the cause was found."*
%%
%% This module is that enforcement. It found three live figures disagreeing with the
%% pin the day it was written -- `250 of 266` in README's EVM-execution row, `254 of
%% 266` in TASKS.md's block-authoring item, and `250 of 266 now` in TASKS.md's
%% conformance item -- all three in prose that reads as current, and all three the
%% exact defect class the gate exists for. The gate's own header records the same
%% thing having happened before: *"four mutually unequal conformance figures"*.
%%
%% **The pin is read from the source, not written here.** `pinned_match_count/0`
%% parses `?EXPECTED' out of `eest_conformance_tests.erl', so this test tracks the
%% pin rather than a copy of it. A second copy of 255 in a test file is a second
%% thing to forget to update, and forgetting it in *this* file would turn the
%% enforcement into a second stale figure -- the defect, in the enforcer.

-module(eth_published_figures_tests).

-include_lib("eunit/include/eunit.hrl").

-define(READ, ["README.md", "TASKS.md", "AGENTS.md"]).

%% ===========================================================================
%% The pin
%% ===========================================================================

the_pin_is_read_from_the_source_and_not_written_down_here_test() ->
    ?assertEqual(255, pinned_match_count()).

%% ===========================================================================
%% Tier 0.4: every published figure is attributable
%% ===========================================================================
%%
%% **The rule is per *block*, not per figure, and getting that wrong is how the
%% first version of this test was useless.** A markdown table row is one block, so a
%% version tag belonging to one figure in the row dates every figure beside it. That
%% was measured, not reasoned about: three of six injections passed, and the three
%% that passed were exactly the three stale figures this module exists to catch --
%% `250 of 266' in README's EVM-execution row passed because the *other* figure in
%% that row (`6,786 of 15,660') carried `v1.49-full-corpus-measured'. **Per-figure
%% attribution inside a shared block is not mechanical**, and README's row was
%% rewritten so each figure is attributed where it is stated.
%%
%% So, per block:
%%
%%   **A block that publishes a conformance figure must either publish the pin, or
%%   carry an attribution** -- a version tag (`v1.N') or an ISO date.
%%
%% The pin needs no attribution because `eest_conformance_tests' asserts it on every
%% `rebar3 eunit', so its currency is *enforced* rather than narrated. Every other
%% figure is a claim about some particular measurement and has to say which.
%%
%% **This is the rule that bites.** Put `250 of 266' where the pin belongs, in prose
%% that reads as current, and the block has neither the pin nor an attribution --
%% which is the defect, stated as a property.
every_published_figure_is_attributable_test() ->
    %% **Three floors, not one.** A single `?assert(length(Figures) >= N)' with N
    %% just under the real count is a floor a future edit can walk under, and it says
    %% nothing about *which* file stopped being scanned.
    %%
    %% **An empty scan would make the assertion below vacuously true.** This is the
    %% failure `eth_config_tests:every_variable_eth_config_reads_is_in_the_table_test'
    %% already guards against: `re:run/3' returns the *first* match unless `global'
    %% is passed, so a scan written the obvious way reported one variable out of
    %% thirty-one and "nothing is unchecked" was satisfied by a scan that had checked
    %% almost nothing. **The property is a universal claim; the measurement was one
    %% example; the failure mode is silence.**
    PerFile = [{F, length(scan(F))} || F <- ?READ],
    [?assert(N >= 3) || {_, N} <- PerFile],
    ?assert(length(lists:flatmap(fun scan/1, ?READ)) >= 15),
    Unattributed = lists:flatmap(fun unattributed_blocks/1, ?READ),
    ?debugFmt("~n", []),
    %% `?debugFmt' rather than relying on the assertion's own report: eunit truncates
    %% assertion values, and "some block is unattributed" out of three files and
    %% thirty figures is a search rather than a fix.
    ?debugFmt("unattributed items:~n~p~n", [Unattributed]),
    ?assertEqual([], Unattributed).

unattributed_blocks(File) ->
    [#{file => File, head => hd(B), figures => [fmt(F) || F <- Fs]}
     || B <- blocks_of(File), Fs <- [figures_in(File, B)], Fs =/= [],
        not (has_pin(Fs) orelse has_version_tag(B))].

has_pin(Figures) ->
    lists:any(fun(#{a := A, b := B}) -> A =:= pinned_match_count() andalso B =:= 266 end,
              Figures).

has_version_tag(Block) ->
    re:run(string:join(Block, " "), "v[0-9]+\\.[0-9]+", [unicode, {capture, none}])
        =/= nomatch.

%% The defect the three stale figures shared was not that a number was wrong in the
%% abstract -- it was that *one file had been updated and another had not*. So the
%% pin has to be present in every file that publishes one, or a reader of any single
%% file is reading a figure nobody maintains.
the_pin_is_published_in_every_file_that_publishes_one_test() ->
    Missing = [{F, counts_in(F)} || F <- ?READ,
                                    not lists:member(pinned_match_count(), counts_in(F))],
    ?debugFmt("files not publishing the pin ~p:~n~p~n", [pinned_match_count(), Missing]),
    ?assertEqual([], Missing).

%% ===========================================================================
%% What this does NOT enforce, named because a test that silently under-covers is
%% worse than no test
%% ===========================================================================
%%
%%  * **A long prose block still launders.** The rule is per markdown *item*, and the
%%   longest item in these three files is **322 lines** (`TASKS.md`). A `v1.N' anywhere
%%   in 322 lines vouches for a stale figure anywhere else in them. Every figure
%%   currently in the tree is either the pin or in a short item, so nothing is
%%   laundered today -- but a new figure dropped into a long prose block would be
%%   attributed by a version tag 200 lines away. Closing this needs per-*sentence*
%%   attribution, which is not mechanical in markdown, and it is not attempted here.
%%   The item-count floor bounds how far this can go: a splitter that stops splitting
%%   is caught (injection F).
%%
%%  * **A figure attributed to the wrong item in the same item.** Unreachable by
%%   construction at this granularity, and listed only because the previous version of
%%   this test had exactly that hole and shipped with it -- see the `RELEASE-GATE.md`
%%   row for what it let through.
%%
%%  * **Figures that are not of the form "N of M"** -- test counts, line counts,
%%   injection counts, gas figures -- are out of scope. Tier 0.4 as written is about
%%   conformance figures; widening it is a decision, not an oversight, and the
%%   widening should come with its own scan.
%%
%%  * **A figure in any other file.** `RELEASE-GATE.md` itself and
%%   `doc/MEASUREMENTS.md` publish conformance numbers too and are not scanned.
%%   `RELEASE-GATE.md` is not scanned because it is the file that states the
%%   requirement, and a requirement that also has to satisfy itself is a harder thing
%%   to reason about than it is worth.
%%
%%  * **Whether an attributed figure is *correct*.** This checks that a number can be
%%   traced to a measurement, not that the measurement was right. The pin is what says
%%   255 is right, and that is `eest_conformance_tests'' job. **This module found three
%%   figures that disagreed with the pin and no figure that was merely wrong**, which
%%   is a statement about the defect class that had accumulated, not about the class
%%   that could.

%% ===========================================================================
%% The pin, read out of the runner's own source
%% ===========================================================================

pinned_match_count() ->
    Path = "apps/etherlang/test/eest_conformance_tests.erl",
    {ok, Bin} = file:read_file(Path),
    Src = unicode:characters_to_list(Bin),
    %% `-define(EXPECTED, #{match => 255, ... })'
    case re:run(Src, "match\\s*=>\\s*([0-9]+)", [{capture, all_but_first, list}]) of
        {match, [N]} ->
            list_to_integer(N);
        Other ->
            %% A scan that cannot find the pin must fail loudly rather than fall
            %% back to a default. "The pin moved and nobody noticed" is the failure
            %% this whole file exists to prevent, and a default of 0 or 255 would
            %% hide it.
            erlang:error({no_pin_in_expectED, Other})
    end.

%% ===========================================================================
%% Scanning
%% ===========================================================================

%% One entry per "<A> of <B>" whose B is a corpus this repository measures against.
%% The corpora are named rather than derived: a scan that inferred them would accept
%% a figure against a corpus nobody recognises, and the point of the corpus is that
%% it is a specific, countable thing.
scan(File) ->
    %% **All of the splitting lives in `blocks_of/1`, and it must.** There were two
    %% copies -- one here and one there -- for three commits, and when the
    %% `lexemes/2` injection below was applied to this one and not that one the two
    %% disagreed about where the paragraphs were and the suite went red for a reason
    %% that had nothing to do with the rule. **Two implementations of a scan is one
    %% too many, and the two that can disagree are the two an injection will find.**
    lists:flatmap(fun(B) -> figures_in(File, B) end, blocks_of(File)).

blocks_of(File) ->
    {ok, Bin} = file:read_file(File),
    %% **`string:split/3` with `all`, NOT `string:lexemes/2`.** `lexemes/2` *drops
    %% empty lexemes*: `string:lexemes("a\n\nb", "\n")` is `["a","b"]`, with the
    %% blank line gone. So every blank line vanished, every "paragraph" became the
    %% whole file, and the attribution check then found a date *somewhere in the
    %% document* for every figure in it -- **the test would have gone GREEN having
    %% enforced nothing.** That is the gate's own stated worst case: *"a gate that
    %% reports `PASS` for something nobody runs is worse than no gate: it stops the
    %% checking."* Third instance of one shape in this repository, after `re:run/3'
    %% returning the first match and `ip4/1' accepting a list of the right length
    %% with the wrong things in it: **a helper that quietly drops the thing you need
    %% it to keep makes a universal claim vacuously true, and the failure mode is
    %% silence.** `string:split/3' with `all' keeps the empty lexemes.
    Lines = string:split(unicode:characters_to_list(Bin), "\n", all),
    Blocks = blocks(Lines, [], []),
    %% The floor that distinguishes "split the document into its items" from "read the
    %% document once". **A figure-count floor does not catch it**: one whole-file
    %% block still contains every figure.
    %%
    %% 100, measured rather than guessed: the item rule produces **370** items from
    %% README's 1,306 lines, **156** from TASKS.md's 1,225 and **319** from AGENTS.md's
    %% 1,699. The floor is well under the smallest of those so it cannot fail on a
    %% correct document -- which is how a floor gets raised until it means nothing --
    %% and far above 1, which is what a splitter that does not split returns.
    ?assert(length(Blocks) >= 100),
    Blocks.

counts_in(File) ->
    lists:usort([A || #{a := A} <- scan(File)]).

%% A block ends at a blank line **or at the start of the next markdown item**, and
%% the second half is what makes this rule work at all.
%%
%% Blank lines alone were measured to be too coarse: TASKS.md's "Phase 8: Testing &
%% Verification" section has no blank lines between its list items, so the whole
%% section -- **68 lines, 8,505 characters** -- was one block, and it carried a `v1.N'
%% belonging to a *different* item. A stale figure injected into the Conformance-tests
%% item passed, because a version tag 40 lines away vouched for it. That is the third
%% time this repository has had a figure laundered by a neighbouring one: first a
%% table row vouching for the figure beside it, then a whole section.
%%
%% So the unit is one markdown item: a table row, a list item, a heading, a paragraph.
%% **Attribution is a property of a claim, and a claim is one item.** Continuation
%% lines -- indented, or continuing a sentence -- stay with the item they continue,
%% which is why the starter patterns all require the marker in column 1.
blocks([], Acc, Out) -> lists:reverse([lists:reverse(Acc) | Out]);
blocks([Line | Rest], Acc, Out) ->
    %% **The starter line opens the *next* block; it does not close one.** Written the
    %% other way round -- `blocks(Rest, [], [lists:reverse(Acc), Line])' -- the line
    %% lands in the output list and the accumulator restarts empty, so nothing after it
    %% is ever accumulated and the whole file collapses into a handful of blocks.
    %% Measured: 1,306 lines of README produced **5** blocks that way, against 144
    %% under blank lines alone. **A splitter that splits is easy to write and a
    %% splitter that silently does not split still returns a plausible list**, which
    %% is why the block-count floor below is an assertion and not a comment.
    case starts_item(Line) of
        true ->
            case Acc of
                [] -> blocks(Rest, [Line], Out);
                _ -> blocks(Rest, [Line], [lists:reverse(Acc) | Out])
            end;
        false ->
            case string:trim(Line) of
                "" -> blocks(Rest, [], [lists:reverse(Acc) | Out]);
                _ -> blocks(Rest, [Line | Acc], Out)
            end
    end.

%% Column 1 only. A wrapped table row or a list item's continuation is indented, and
%% treating it as a new item would put half a sentence in one block and the other half
%% in the next -- which is the same laundering with a different edge.
starts_item(Line) ->
    lists:any(fun(Mark) -> lists:prefix(Mark, Line) end,
              ["| ", "## ", "# ", "- [", "- ", "* ", "+ ", "1. ", "2. ", "3. ",
               "4. ", "5. ", "6. ", "7. ", "8. ", "9. "]).

figures_in(File, Block) ->
    Text = string:join(Block, " "),
    %% `global' because `re:run/3' returns the FIRST match without it -- see the
    %% note on the vacuous-scan assertion above.
    Matches = case re:run(Text, "([0-9][0-9,]*)\\s+of\\s+([0-9][0-9,]*)",
                          [global, unicode, {capture, all_but_first, list}]) of
                  {match, Ms} -> Ms;
                  nomatch -> []
              end,
    [figure(File, Block, Text, list_to_integer(normalise(A)),
            list_to_integer(normalise(B)))
     || [A, B] <- Matches, lists:member(normalise(B), corpora())].

normalise(N) -> string:trim([case C of $, -> $ ; C -> C end || C <- N]).

%% The corpus sizes this repository measures against, and what each one is. A
%% figure against any other denominator is not a conformance figure and is not this
%% test's business.
corpora() ->
    ["266",          %% the committed 25-file subset
     "15660",        %% the 229 non-`static' files
     "3884"].        %% the 22-file transaction-validity set

figure(File, Block, Text, A, B) ->
    #{file => File, a => A, b => B, head => first_line_of(File, Block, Text)}.

%% Reported so a failure names a place a reader can go. The first line of the block
%% is returned rather than a line number, because the block is the unit the rule is
%% about and a line number would imply a precision the scan does not have.
first_line_of(_File, Block, _Text) -> hd(Block).

fmt(#{a := A, b := B}) -> [integer_to_list(A), " of ", integer_to_list(B)].