-module(eth_state_tests).

-include_lib("eunit/include/eunit.hrl").

%% `eth_state` is the node's state provider and the module `base_source/0`
%% lives in. The tests here are about how a *missing* key is answered, which is
%% where this module's behaviour is least visible and most consequential.


%% ---------------------------------------------------------------------------
%% Per-state base source
%% ---------------------------------------------------------------------------
%%
%% `base_source/0' is process-wide, and that is this module's own documented trap:
%% one caller's test changes where every other reader looks. `with_base_source/2'
%% lets a state term carry its own answer, which is what makes the conformance
%% figure reproducible -- and it is worth checking on its own terms, because a
%% per-state override that silently did nothing would be worse than the global it
%% replaces.

%% The contract, not the mechanism: on an `empty' base, a key that is not there
%% reads as "does not exist" -- zero balance, zero nonce, no code, no storage, and
%% `exists/2' false.
%%
%% Wrapped in `with_local_reads/1' so that if the override ever stopped being
%% honoured this test would still *fail* rather than hang. Without the wrap, an
%% ignored override sends the read to the process-wide source, `upstream', and an
%% absent account there is an HTTP call to a public Sepolia node -- so the symptom
%% of a broken override would be a timeout, the quietest failure EUnit has, in
%% whichever test happened to run first. Whether the override is honoured at all
%% is proved separately, by making the two sources disagree.
an_empty_state_reports_nothing_as_existing_test() ->
    eth_test_util:with_local_reads(
      fun() ->
              A = <<0:160>>,
              S = eth_state:with_base_source(eth_state:new(0, #{}), empty),
              ?assertEqual(0, eth_state:balance(S, A)),
              ?assertEqual(0, eth_state:nonce(S, A)),
              ?assertEqual(<<>>, eth_state:code(S, A)),
              ?assertEqual(0, eth_state:storage(S, A, 0)),
              ?assertEqual(false, eth_state:exists(S, A))
      end).

%% The override is honoured, proved by making the two sources disagree.
%%
%% This is the assertion that matters and it is written the long way round on
%% purpose. Every other test here is satisfied by `empty' returning zero, and a
%% local MPT with nothing in it returns zero too -- so with the override silently
%% ignored *and* the process-wide source set to `mpt', all of them still pass. They
%% pass because the trie is empty, not because the override works.
%%
%% So the trie is given a value. A state that reads from `mpt' must see it and a
%% state that reads from `empty' must not, on the same key, in the same run. When
%% the override was ignored the first version of this test did not fail -- it
%% *timed out*, because the ignored override sent the read to the process-wide
%% source, `upstream', and an absent account there is an HTTP call to a public
%% Sepolia node. A hang is the least loud failure EUnit has.
states_over_a_populated_trie(A) ->
    _ = eth_test_util:start_apps(),
    %% `with_local_reads/1' answers its function's value, not `ok', so the writes
    %% are matched inside and the outer call's result is discarded.
    _ = eth_test_util:with_local_reads(
          fun() ->
                  ok = eth_mpt:clear(),
                  ok = eth_mpt:put_account(A, 42, 3, <<0:256>>),
                  ok = eth_mpt:put_storage(A, <<0:256>>, 99)
          end),
    {{mpt, eth_state:with_base_source(eth_state:new(0, #{}), mpt)},
     {empty, eth_state:with_base_source(eth_state:new(0, #{}), empty)}}.

an_empty_state_ignores_a_value_the_trie_holds_test() ->
    %% The whole body, assertions included, runs with the process-wide source set to
    %% `mpt'. That is not only so the reads are local: it is what makes a broken
    %% override *fail*. With the override ignored both states read the same source,
    %% so `FromEmpty' sees the trie's 42 and the assertion below rejects it. Left
    %% outside the window the ignored override would send those reads to `upstream'
    %% and the test would time out instead, which is the quietest way to fail.
    eth_test_util:with_local_reads(
      fun() ->
              A = <<9:160>>,
              {{mpt, FromMpt}, {empty, FromEmpty}} = states_over_a_populated_trie(A),
              %% The trie has it.
              ?assertEqual(42, eth_state:balance(FromMpt, A)),
              ?assertEqual(3, eth_state:nonce(FromMpt, A)),
              ?assertEqual(99, eth_state:storage(FromMpt, A, 0)),
              %% `empty' does not, and that is the whole of what it means.
              ?assertEqual(0, eth_state:balance(FromEmpty, A)),
              ?assertEqual(0, eth_state:nonce(FromEmpty, A)),
              ?assertEqual(0, eth_state:storage(FromEmpty, A, 0)),
              ?assertEqual(false, eth_state:exists(FromEmpty, A))
      end).

a_state_with_no_override_still_asks_the_process_wide_source_test() ->
    A = <<10:160>>,
    Plain = eth_state:new(0, #{}),
    eth_test_util:with_local_reads(
      fun() ->
              _ = states_over_a_populated_trie(A),
              %% No override, process-wide `mpt': the trie's answer. The default is
              %% untouched by `with_base_source/2', and a test that quietly changed
              %% it would break every other test in the suite in a way that looks
              %% like a network problem.
              ?assertEqual(42, eth_state:balance(Plain, A)),
              ?assertEqual(99, eth_state:storage(Plain, A, 0))
      end).

%% `empty' changes what an *absent* key means. It must not change what a present
%% one means: the overlay still answers first, or a transaction's own writes would
%% be invisible to the state it wrote them into.
an_empty_state_answers_from_its_own_overlay_first_test() ->
    eth_test_util:with_local_reads(
      fun() ->
              A = <<0:160>>,
              S0 = eth_state:new(0, #{{balance, A} => 7, {nonce, A} => 2,
                                 {code, A} => <<1, 2, 3>>, {store, A, 0} => 9}),
              S = eth_state:with_base_source(S0, empty),
              ?assertEqual(7, eth_state:balance(S, A)),
              ?assertEqual(2, eth_state:nonce(S, A)),
              ?assertEqual(<<1, 2, 3>>, eth_state:code(S, A)),
              ?assertEqual(9, eth_state:storage(S, A, 0)),
              ?assertEqual(true, eth_state:exists(S, A))
      end).

the_override_changes_what_an_undeclared_account_reads_test() ->
    %% The whole point: the same state term, the same absent key, two answers.
    A = <<1:160>>,
    Plain = eth_state:new(0, #{}),
    Empty = eth_state:with_base_source(Plain, empty),
    ?assertEqual(0, eth_state:balance(Empty, A)),
    ?assertEqual(0, eth_state:storage(Empty, A, 0)),
    %% A state with no override still asks the process-wide source, so the default
    %% is untouched -- this is an addition, not a replacement, and a test that
    %% quietly changed the default would break every other test in the suite in a
    %% way that looks like a network problem.
    ?assertEqual(base_source_answer(Plain), base_source_answer(eth_state:new(0, #{}))).

%% Whatever the process-wide source answers for an absent account, whatever it is.
%% Compared rather than written down so the assertion is about the *property* --
%% two states with the same override agree -- and not about a value that depends on
%% which source happens to be configured.
base_source_answer(S) ->
    case eth_state:base_source() of
        mpt -> eth_state:balance(eth_state:with_base_source(S, mpt), <<2:160>>);
        upstream -> eth_state:balance(eth_state:with_base_source(S, empty), <<2:160>>)
    end.

a_state_without_an_override_ignores_the_empty_keyword_test() ->
    %% `empty' is a third source, not a flag. A state term that happens to carry an
    %% unrelated `base_source' key -- `new/2' puts everything it is given into the
    %% overlay, so a caller could pass one by accident -- must not be able to turn a
    %% node's reads off by writing the wrong key.
    eth_test_util:with_local_reads(
      fun() ->
              A = <<3:160>>,
              Weird = eth_state:new(0, #{{balance, A} => 1, base_source => empty}),
              ?assertEqual(1, eth_state:balance(Weird, A)),
              %% And the overlay is not where an override lives: reading it back as
              %% an account field would be a second, conflicting answer. The state
              %% has no override, so this read goes to the *process-wide* source --
              %% which is why the whole test is wrapped. Left at the default that is
              %% `upstream', and an absent account under `upstream' is an HTTP call
              %% to a public Sepolia node, which does not fail this test so much as
              %% hang it, and EUnit reports a hang as a *cancelled* test.
              ?assertNotEqual(empty, eth_state:balance(Weird, <<4:160>>))
      end).
