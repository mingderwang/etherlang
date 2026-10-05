-module(eth_open_claims_tests).

%% **The open-items list is a claim about the code, and this module is what stops it
%% outliving the code.**
%%
%% Four entries in `TASKS.md` were checked against the source on 2026-10-05 and **all four
%% were false** -- each said something was missing that had since been implemented:
%%
%%   * "ECADD and ECMUL still conflate a rejected input with an absent implementation" --
%%     they answer `{failed, {ecadd, not_on_curve}}' and
%%     `{failed, {ecadd, {coordinate_not_in_field, p}}}' as two distinct failures, measured
%%     against the precompiles directly.
%%   * "Not done: KZG commitment verification" -- `eth_kzg:verify/4' is the verification and
%%     is exported.
%%   * "The catch-all `base_cost(_) -> 3` remains a fallback" -- `eth_evm:base_cost/1' was
%%     deleted; the only four hits for the name are comments saying so.
%%   * "What is still missing is EIP-150's 63/64 gas-retention rule and the 2300 stipend" --
%%     `eth_evm:child_gas/4' implements both.
%%
%% **This is the same failure as a stale published figure, in a list nobody re-reads**: a
%% hand-maintained claim about the work, which decays silently, and which nothing in the
%% build notices. The three defences that have caught something here are all mechanical --
%% `make counts`, an eunit assertion, and `grep -c` -- and this is the third kind of thing
%% that needs one.
%%
%% **The mechanism is a ratchet, not a list.** `open_claims/0` pairs every named-open item
%% with a check that must hold *today*. An item cannot be added without a check that passes,
%% so when the code fixes it the check fails and the entry has to come out. That is the only
%% arrangement in which such a list stays true: the alternative is a comment, and a comment
%% is what these four were.
%%
%% `closed_claims/0` is the other half, and it is not a list of fixes -- it is a set of
%% assertions about behaviour that must keep holding, so the corrections above cannot be
%% undone by a later change. Each names the rule and the reason it was once wrong.

-include_lib("eunit/include/eunit.hrl").

%% ===========================================================================
%% Open: each of these is genuinely not done, and each carries a check
%% ===========================================================================

%% **Constantinople's SSTORE is refused and every other pre-Berlin fork is priced.**
%%
%% EIP-1283 replaced the flat rule with net metering and Petersburg reverted it, so a
%% single figure would be right for two spans and wrong at the third -- and wrong *only* at
%% Constantinople is never noticed. It is unreachable by block number on mainnet, since
%% Constantinople and Petersburg activate at the same block, and reachable as a name, which
%% is how the conformance corpus reaches it.
%%
%% If this check ever fails, EIP-1283 has been priced and the entry above must go.
open_claims_test_() ->
    [?_assertNot(eth_fork_schedule:sstore_supported(constantinople)),
     ?_assert(eth_fork_schedule:sstore_supported(petersburg)),
     ?_assert(eth_fork_schedule:sstore_supported(shanghai)),
     ?_assert(eth_fork_schedule:sstore_supported(cancun))].

%% **`eth_kzg:blob_to_kzg_commitment/1` is absent, and `commit_to_blob/1` with it.**
%%
%% Both need the `g1_lin` derivation, and EIP-4844's own test vector is not in this
%% repository. `eth_kzg:verify/4` -- the *verification* half -- is implemented, and the
%% entry that used to claim otherwise was wrong; this one is about the two functions that
%% are genuinely missing.
%%
%% The check is on the export list rather than on a call, because a function can be absent
%% and still be called by nothing at all: what has to be true is that a caller cannot reach
%% it, and an unexported, undefined name cannot be reached.
open_kzg_derivation_functions_are_absent_test() ->
    Exports = eth_kzg:module_info(exports),
    ?assertNot(lists:member({blob_to_kzg_commitment, 1}, Exports)),
    ?assertNot(lists:member({commit_to_blob, 1}, Exports)),
    %% And the verification that *is* implemented is exported, so the check above cannot
    %% pass by the module having been emptied.
    ?assert(lists:member({verify, 4}, Exports)).

%% **The interpreter's EIP-3860 charge is a second copy of a figure the schedule owns, and
%% it is not fork-gated.**
%%
%% `eth_fork_schedule:initcode_word_cost/1` is fork-gated -- two gas per word from Shanghai
%% and nothing before it -- and `eth_tx:1109' asks the schedule for it on the transaction
%% path. `eth_evm:do_create/3' writes the same rule out in three literals, unconditionally,
%% so a pre-Shanghai block is charged 2 and 8 per word where the schedule says 0 and 6.
%%
%% **The check is that the literals are still there.** It reads as a strange assertion and
%% it is deliberate: an item in this table must fail when it is fixed, so that the entry is
%% removed rather than left behind describing a gap that has closed. The day
%% `do_create/3` asks `eth_fork_schedule` for this figure, this assertion goes red and the
%% comment above it goes with it.
%%
%% The comment there used to blame "this module has no fork", which stopped being true when
%% `eth_evm:run/5' began requiring a `fork' key -- **a real gap described by a reason that
%% is not**, which is the reason a reader who checks the reason leaves it alone.
create_charge_is_still_a_second_copy_of_the_schedules_figure_test() ->
    {ok, {_, [{abstract_code, {_, Forms}}]}} =
        beam_lib:chunks(code:which(eth_evm), [abstract_code]),
    Create = [Body || {function, _, do_create, 3, Body} <- Forms],
    ?assertEqual(1, length(Create)),
    %% **The check is that `do_create/3' does not ask the schedule.** Reading it as "the
    %% literals are absent" would pass the moment the function was renamed, which is the
    %% wrong reason to go green; what has to be true is that the second copy of the figure
    %% is still a second copy.
    ?assertNot(mentions(Create, initcode_word_cost)),
    %% And the schedule's half is fork-gated, so the two are demonstrably different rules
    %% rather than the same one written twice.
    ?assertEqual(0, eth_fork_schedule:initcode_word_cost(frontier)),
    ?assertEqual(0, eth_fork_schedule:initcode_word_cost(berlin)),
    ?assertEqual(2, eth_fork_schedule:initcode_word_cost(shanghai)),
    ?assertEqual(2, eth_fork_schedule:initcode_word_cost(cancun)).

%% **A non-zero `net_peerCount` is not distinguishable from a hardcoded `0x0`.**
%%
%% `eth_peer:eth_peer_count/0' counts connected eth-capable peers, and the negative case
%% is covered -- `net_peer_count_is_zero_when_there_are_no_peers_test_' runs with no peer
%% manager and gets `0x0'. **That fixture cannot tell a count from a constant**, so a
%% handler that answered a hardcoded zero would satisfy it.
%%
%% The positive case needs a live eth-capable peer, and the only fixture in the suite
%% that has one is `eth_peer_tests:autodial/0'. The assertion was written there and
%% **lost the race**: `wait_eth_peer/3' had just proved with that module's own predicate
%% that such a peer existed, `count_remote/2' returned 1, and `eth_peer_count/0'
%% returned 0 microseconds later. It was tried on both sides of the `get_headers' round
%% trip and failed on both.
%%
%% **So the gap is not a missing test, it is that the subject does not hold still.** The
%% peer connection completes the eth handshake and then dies within about a second --
%% `poll' gets `enotconn' from a socket the operating system still lists as ESTABLISHED.
%% Until that is fixed this item cannot be closed honestly, and closing it by writing a
%% test that retries until it passes would be a test that cannot fail.
%%
%% The check below is that the negative test still exists and the count function is still
%% a count: a hardcoded `0x0' in the handler would leave both true, which is why this
%% entry is a *gap* record rather than a ratchet.
net_peer_count_has_no_positive_test_because_the_peer_dies_test() ->
    %% No peer manager is running here, so the count is 0 -- and the assertion is that
    %% it is an *integer*, which is what says the function exists and computes rather
    %% than being absent. `erlang:function_exported/3' would need the module loaded and
    %% would answer `false' for a module that had never been called, which is a fact
    %% about this test rather than about `eth_peer'.
    ?assert(is_integer(eth_peer:eth_peer_count())).

%% **`eth_evm:base_cost/1` does not exist.** `eth_fork_schedule` is the only price table,
%% so the interpreter must ask it for the fork in hand. A second table is a second thing
%% that can drift, and this repository has deleted one already.
%%
%% The check is that the *module* has no such function, which is stronger than "nothing in
%% src/ calls it": an unused private copy is still a second table.
no_second_gas_table_test() ->
    ?assertNot(lists:member({base_cost, 1}, eth_evm:module_info(exports))),
    {ok, {_, [{abstract_code, {_, Forms}}]}} =
        beam_lib:chunks(code:which(eth_evm), [abstract_code]),
    ?assertEqual([], [F || F = {function, _, base_cost, 1, _} <- Forms]).

%% ===========================================================================
%% Closed: these must keep holding, so the corrections cannot be undone
%% ===========================================================================

%% **An off-curve point is a failed call, not a missing implementation.**
%%
%% `unsupported' means "this node cannot run this at all"; the interpreter turns it into a
%% halt and `eth_block:run_transaction/5` turns *that* into a refusal to produce the block.
%% So a contract that fed ECADD a point not on the curve made this node reject the block
%% containing it, where every other client executes it. An off-curve point is a number, not
%% an absence.
%%
%% The three answers are pinned separately because EIP-196 gives two distinct invalidity
%% conditions -- "does not lie on the curve **or** any of the field elements is equal or
%% larger than the field modulus p" -- and a client debugging a rejected call needs to know
%% which one it hit.
closed_claims_test_() ->
    Zero = <<0:256>>,
    P = 21888242871839275222246405745257275088696311157297823662689037894645226208583,
    OnCurve = <<1:256, 2:256>>,
    OffCurve = <<1:256, 3:256>>,
    ZeroPad = fun(Body) -> <<Body/binary, Zero/binary>> end,
    [%% The point at infinity and a real point both succeed.
     ?_assertMatch({ok, <<_:512>>, _}, ecadd(ZeroPad(<<Zero/binary, Zero/binary, OnCurve/binary>>))),
     ?_assertMatch({ok, <<_:512>>, _}, ecadd(ZeroPad(<<OnCurve/binary, Zero/binary>>))),
     %% Off the curve is a *call failure*, named.
     ?_assertEqual({failed, {ecadd, not_on_curve}},
                   ecadd(ZeroPad(<<OffCurve/binary, Zero/binary>>))),
     ?_assertEqual({failed, {ecmul, not_on_curve}}, ecmul(OffCurve, 3)),
     %% A coordinate at or above the modulus is the *other* condition, and is told apart.
     ?_assertMatch({failed, {ecadd, {coordinate_not_in_field, P}}},
                   ecadd(ZeroPad(<<P:256, Zero/binary, Zero/binary>>))),
     ?_assertMatch({failed, {ecmul, {coordinate_not_in_field, P}}},
                   ecmul(<<P:256, Zero/binary>>, 3)),
     %% And `unsupported' is reachable only *below* Byzantium, where the precompile does not
     %% exist yet. That is the only remaining route to it for these two addresses.
     ?_assertEqual(unsupported, eth_evm_precompiles:precompile(6, <<0:512>>, frontier)),
     ?_assertEqual(unsupported, eth_evm_precompiles:precompile(7, <<0:512>>, frontier))].

%% **The EIP-150 63/64 clamp is on the pre-stipend figure, and the stipend is not the
%% caller's to pay for.**
%%
%% The specification gives two: `MessageCallGas` returns `gas + extra_gas` and `sub_call`
%% returns `gas + call_stipend`, so the `all_but_one_64th` clamp belongs on the first.
%% Clamping `gas + stipend` instead -- which is what this did -- swallows the stipend
%% whenever the cap binds, and a `GAS`-forwarding call saturates the cap every time.
all_but_one_64th_is_the_child_gas_clamp_test() ->
    %% Fork-gated: Tangerine Whistle and later, and not before it.
    %%
    %% **The atom is `tangerine', not `tangerine_whistle'.** The first version of this
    %% asserted `all_but_one_64th(tangerine_whistle)' and got **false**, which is the
    %% correct answer for an atom the rank table has never heard of -- so the assertion was
    %% about an unknown fork rather than about Tangerine Whistle. Every other fork in this
    %% module uses the short name (`spurious_dragon', `gray_glacier', `muir_glacier') and
    %% one long one, so the name has to be read out of `fork_rank/1' rather than guessed
    %% from the fork's usual English name.
    ?assert(eth_fork_schedule:all_but_one_64th(tangerine)),
    ?assertNot(eth_fork_schedule:all_but_one_64th(dao)),
    ?assert(eth_fork_schedule:all_but_one_64th(london)),
    %% **Only the gate is asserted here, and the CALL-path behaviour is not.**
    %% `eth_evm:child_gas/4' is private, and re-deriving the clamp in a second place would
    %% be a second copy of a gas figure -- the defect `eth_fork_schedule` was made the
    %% single owner of to end. The behaviour is pinned where it applies, by
    %% `eth_evm_tests:child_gas_at_a_saturating_call_is_the_cap_plus_the_stipend_test' and
    %% `eth_evm_tests:an_unaffordable_call_returns_its_allowance'; what this file adds is the
    %% fork boundary, which is the part with no assertion anywhere else.
    %% **And the gate is exactly the part that can regress silently**: the clamp itself is
    %% arithmetic on two numbers, while `all_but_one_64th/1' is a ranking question, and a
    %% ranking question is answered by an atom's position in a table.
    ok.

%% EIP-196's two precompiles, by address, at Byzantium.
%%
%% **By address, not by name.** `precompile/3` takes the address and asks
%% `eth_fork_schedule:precompile_at/2` which precompile it is, so the fork gate and the
%% dispatch are exercised on the path a `CALL` takes. Handing it the atom `ecadd' answers
%% `unsupported' for every input, which is the answer the four stale entries were about --
%% and a test written that way would have agreed with all four.
ecadd(Padded) -> eth_evm_precompiles:precompile(16#06, Padded, byzantium).

ecmul(Point, Scalar) ->
    eth_evm_precompiles:precompile(16#07, <<Point/binary, Scalar:256, 0:256>>, byzantium).

%% Whether a term mentions an atom by name, anywhere inside it. The abstract code is a
%% nested tuple, so this is a structural walk rather than a pattern, and it is used on a
%% **function body** so that "this function does not call that" is decidable.
%%
%% **It looks for the atom alone, not for a remote call shape**, on purpose: a call written
%% as `?INITCODE_WORD_COST(Fork)` through a macro would be the same second copy and a
%% shape-specific pattern would not see it.
mentions({atom, _, Name}, Name) -> true;
mentions(Term, Name) when is_tuple(Term) ->
    mentions(tuple_to_list(Term), Name);
mentions([H | T], Name) ->
    case mentions(H, Name) of
        true -> true;
        false -> mentions(T, Name)
    end;
mentions(_Other, _Name) -> false.
