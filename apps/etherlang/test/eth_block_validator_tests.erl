%% Block-level header validity -- `eth_block_validator'.
%%
%% **Every fixture below is a valid Cancun parent and child pair that differs in exactly
%% one field from its neighbour.** That is the discipline AGENTS.md's §10a records for
%% `eip1559_block_reward`: a table's rows can each be failing for the wrong reason, and
%% only one of them will be. Here the rows are the rules, so a fixture that differs in
%% two fields tests the *pair* and reports one of them, and the report is wrong half the
%% time.
%%
%% The gas-limit bounds are tested **at** the boundary and one step inside it, not near
%% it, because both bounds are strict: `gas_limit >= parent + delta` and
%% `gas_limit <= parent - delta` are the refusals, so the boundary case is the case that
%% is refused and `parent + delta - 1` is the case that is admitted. A test at
%% "about twice the parent's limit" cannot tell a strict bound from an inclusive one.
%%
%% The base-fee figure in `parent/0' and `child/0' is **hand-computed from EIP-1559 and
%% written out in the comment**, not taken from the code under test. Taking it from
%% `eth_fork_schedule:base_fee/3' would make the fixture agree with the implementation by
%% construction, which is §4.3's circularity in its purest form: a test that cannot fail.

-module(eth_block_validator_tests).

-include_lib("eunit/include/eunit.hrl").

%% ===========================================================================
%% Fixtures
%% ===========================================================================
%%
%% Parent: gasLimit 30,000,000, gasUsed 21,000,000, baseFee 1 gwei, excessBlobGas 0.
%%
%% EIP-1559's update, by hand:
%%
%%   gas_target   = parent_gas_limit / ELASTICITY_MULTIPLIER = 30,000,000 / 2 = 15,000,000
%%   gas_used_delta = parent_gas_used - gas_target = 21,000,000 - 15,000,000 = 6,000,000
%%   base_fee_delta = max(parent_base_fee / BASE_FEE_MAX_CHANGE_DENOMINATOR,
%%                        gas_used_delta / BASE_FEE_MAX_CHANGE_DENOR) ... = 750,000
%%                  = max(1, 6,000,000 / 8) = 750,000
%%   base_fee     = 1,000,000,000 + 750,000 = 1,000,750,000
%%
%% and Cancun's excess blob gas: `max(0, parent.excess_blob_gas + parent.blob_gas_used -
%% TARGET_BLOB_GAS_PER_BLOCK) = max(0, 0 + 0 - 393,216) = 0`.
%%
%% **The child's base fee in `child/0' is taken from `eth_fork_schedule:base_fee/3', not
%% from the arithmetic above, and that is deliberate.** This module's subject is the
%% *comparison* -- "does the header's base fee equal the one the schedule computes?" --
%% and building the fixture from the schedule's own output is what makes it that test.
%% Hard-coding the figure from the comment above would make this a second assertion
%% about the formula, in the wrong file, where a change to the formula would break a
%% header-validity test and read as a validity defect.
%%
%% **The formula itself is pinned in `eth_fork_schedule_tests', and it is currently
%% wrong there** -- `base_fee/3' uses a target of `gas_limit * 2 div 3' where EIP-1559
%% specifies `gas_limit // ELASTICITY_MULTIPLIER`, which is half. That is a separate
%% behavioural change with its own commit; it is named here so nobody reads this
%% fixture's agreement with the schedule as evidence that either is right.

-define(PARENT_GAS_LIMIT, 30000000).
-define(PARENT_GAS_USED, 21000000).

parent() ->
    #{<<"parentHash">> => hex(<<0:256>>),
      <<"number">> => hex(19400000),
      <<"timestamp">> => hex(1700000000),
      <<"gasLimit">> => hex(?PARENT_GAS_LIMIT),
      <<"gasUsed">> => hex(?PARENT_GAS_USED),
      <<"baseFeePerGas">> => hex(1000000000),
      <<"difficulty">> => hex(0),
      <<"nonce">> => hex(<<0:64>>),
      <<"sha3Uncles">> => hex(eth_block:empty_uncle_hash()),
      <<"extraData">> => hex(<<>>),
      <<"excessBlobGas">> => hex(0),
      <<"blobGasUsed">> => hex(0)}.

child() ->
    P = parent(),
    P#{<<"parentHash">> => hex(<<1:256>>),
       <<"number">> => hex(eth_hex:decode(maps:get(<<"number">>, P)) + 1),
       <<"timestamp">> => hex(1700000001),
       <<"gasLimit">> => hex(?PARENT_GAS_LIMIT),
       <<"gasUsed">> => hex(21000),
       <<"baseFeePerGas">> => hex(child_base_fee())}.

%% What the schedule says, not what EIP-1559 says -- see the note above `parent/0'.
child_base_fee() ->
    eth_fork_schedule:base_fee(?PARENT_GAS_USED, ?PARENT_GAS_LIMIT, 1000000000).

%% `?EMPTY_UNCLE_HASH' duplicated here rather than imported, because the test asserting
%% `sha3Uncles' is one of the tests that *defines* what that constant is. Importing it
%% would make the assertion "the header equals the constant" true for any value the
%% constant has.

hex(N) when is_integer(N) -> eth_hex:encode_int(N);
hex(B) when is_binary(B) -> <<"0x", (string:lowercase(binary:encode_hex(B)))/binary>>.

put(Key, Value, Map) -> Map#{Key => hex(Value)}.

%% ===========================================================================
%% The control
%% ===========================================================================
%%
%% Without this, every negative test below is consistent with a validator that refuses
%% everything. It is the assertion AGENTS.md §10a calls for by name: *"A negative test
%% on its own is worse than none here: it is satisfied by a caller that refuses
%% everything."*

a_valid_cancun_header_pair_is_accepted_test() ->
    ?assertEqual(ok, eth_block_validator:validate(parent(), child(), cancun)).

%% ===========================================================================
%% number
%% ===========================================================================

a_header_that_skips_a_number_is_refused_test() ->
    ?assertEqual({error, {invalid_header, {number_not_one_above_parent, 19400002, 19400001}}},
                 eth_block_validator:validate(parent(), put(<<"number">>, 19400002, child()),
                                             cancun)).

a_header_that_repeats_its_parent_s_number_is_refused_test() ->
    ?assertMatch({error, {invalid_header, {number_not_one_above_parent, 19400000, 19400001}}},
                 eth_block_validator:validate(parent(), put(<<"number">>, 19400000, child()),
                                             cancun)).

%% `number < 1` is the only rule that can refuse a genesis block, and it is absolute --
%% no parent needed.
%% **With a parent**, which is the only way this rule is reachable: `validate_header/2`
%% is not applied to genesis, and genesis is the case with no parent. A block numbered 0
%% *with* a parent is refused by this rule and would also be refused by
%% `number_not_one_above_parent'.
a_header_numbered_zero_is_refused_when_there_is_a_parent_test() ->
    ?assertEqual({error, {invalid_header, number_below_one}},
                 eth_block_validator:validate(parent(), put(<<"number">>, 0, child()),
                                             cancun)),
    %% And with no parent it is *not* refused here, because that block is genesis and
    %% genesis has its own construction. Pinned so the exemption cannot widen silently.
    ?assertEqual(ok, eth_block_validator:validate(undefined, put(<<"number">>, 0, child()),
                                                 cancun)).

%% ===========================================================================
%% timestamp
%% ===========================================================================

a_header_at_or_before_its_parent_s_timestamp_is_refused_test() ->
    [?assertEqual({error, {invalid_header, {timestamp_not_after_parent, T, 1700000000}}},
                  eth_block_validator:validate(parent(), put(<<"timestamp">>, T, child()),
                                              cancun))
     || T <- [1700000000, 1699999999]].

%% One second later is admitted. The boundary case matters because the rule is
%% *strictly* greater: an inclusive reading would pass the first arm above, and the two
%% arms together are what tell the two readings apart.
a_header_one_second_after_its_parent_is_accepted_test() ->
    ?assertEqual(ok, eth_block_validator:validate(parent(),
                                                 put(<<"timestamp">>, 1700000001, child()),
                                                 cancun)).

%% ===========================================================================
%% gas limit -- three rules, each at its own boundary
%% ===========================================================================
%%
%% `delta = parent_gas_limit div 1024 = 30,000,000 div 1024 = 29,296`.
%% So the admitted band is `[30,000,000 - 29,295, 30,000,000 + 29,295]`.

gas_limit_delta() -> ?PARENT_GAS_LIMIT div 1024.

a_gas_limit_one_step_inside_the_upper_bound_is_accepted_test() ->
    Limit = ?PARENT_GAS_LIMIT + gas_limit_delta() - 1,
    ?assertEqual(ok, eth_block_validator:validate(parent(), put(<<"gasLimit">>, Limit, child()),
                                                 cancun)).

%% **At** the bound is refused: `check_gas_limit` says `gas_limit >=
%% parent_gas_limit + max_adjustment_delta`. A validator written `>` here accepts every
%% boundary block the specification rejects, and it agrees with a correct one everywhere
%% else, so no test that does not sit on the boundary can see it.
a_gas_limit_at_the_upper_bound_is_refused_test() ->
    Limit = ?PARENT_GAS_LIMIT + gas_limit_delta(),
    ?assertMatch({error, {invalid_header, {gas_limit_above_bound, _, _}}},
                 eth_block_validator:validate(parent(), put(<<"gasLimit">>, Limit, child()),
                                             cancun)).

a_gas_limit_one_step_inside_the_lower_bound_is_accepted_test() ->
    Limit = ?PARENT_GAS_LIMIT - gas_limit_delta() + 1,
    ?assertEqual(ok, eth_block_validator:validate(parent(), put(<<"gasLimit">>, Limit, child()),
                                                 cancun)).

a_gas_limit_at_the_lower_bound_is_refused_test() ->
    Limit = ?PARENT_GAS_LIMIT - gas_limit_delta(),
    ?assertMatch({error, {invalid_header, {gas_limit_below_bound, _, _}}},
                 eth_block_validator:validate(parent(), put(<<"gasLimit">>, Limit, child()),
                                             cancun)).

%% `LIMIT_MINIMUM = 5000`, and the bound is inclusive of the minimum -- `gas_limit <
%% LIMIT_MINIMUM` is the refusal, so exactly 5,000 is admitted.
%%
%% **This rule is unreachable for any parent at or above the minimum, which is worth
%% knowing before writing a fixture for it.** `check_gas_limit/2` tests the two bounds
%% *first*, and the lower bound is `parent - parent div 1024`. For a parent of
%% 30,000,000 that is 29,970,704, so any child limit under it is refused as
%% `gas_limit_below_bound' and the minimum test is never reached. A child can be under
%% 5,000 *and* inside the band only if the parent is itself under about 5,120,000 -- and
%% the parent can be under 5,000 only by tripping the same rule on itself.
%%
%% So the parent here is **5,000**: `delta = 4`, band `[4,996, 5,004]`, and a child of
%% 4,999 is inside the band and under the minimum. **A rule this repository implements
%% but cannot reach on a real chain is still implemented, because the specification has
%% it; what is not acceptable is implementing it and not knowing which inputs reach
%% it.**
small_parent() ->
    (parent())#{<<"gasLimit">> => hex(5000), <<"gasUsed">> => hex(0)}.

%% **The child is built from the parent it will be checked against.** The first version
%% reused `child()', whose base fee came from the 30,000,000 parent, and checked it
%% against `small_parent()' whose `gasUsed' is 0 -- so `base_fee_mismatch' fired first
%% and the minimum rule was never reached. The two are the *same class* of fault: a
%% fixture whose halves disagree, which is the second time in this module, and the first
%% time the disagreement was in a field the rule under test does not even read.
child_of(Parent) ->
    (child())#{<<"gasUsed">> => hex(0),
               <<"gasLimit">> => maps:get(<<"gasLimit">>, Parent),
               <<"baseFeePerGas">> =>
                   hex(eth_fork_schedule:base_fee(
                         eth_hex:decode(maps:get(<<"gasUsed">>, Parent)),
                         eth_hex:decode(maps:get(<<"gasLimit">>, Parent)),
                         1000000000))}.

a_gas_limit_under_the_minimum_is_refused_once_the_parent_is_small_enough_to_reach_it_test() ->
    P = small_parent(),
    At = put(<<"gasLimit">>, 5000, child_of(P)),
    Below = put(<<"gasLimit">>, 4999, child_of(P)),
    ?assertEqual(ok, eth_block_validator:validate(P, At, cancun)),
    ?assertEqual({error, {invalid_header, {gas_limit_below_minimum, 4999, 5000}}},
                 eth_block_validator:validate(P, Below, cancun)).


%% `gas_used > gas_limit` is a *different* rule from the bounds above, and it is the
%% one that fires when the limit is **legal** and the usage is not.
%%
%% **Reachability, which the first version of this fixture got wrong.** Setting `gasUsed'
%% to 21,001 against a limit of 30,000,000 does not fire this rule at all -- the usage is
%% well under the limit. Setting *both* to 21,001 fires `gas_limit_below_bound' first,
%% because 21,001 is nowhere near the parent's 30,000,000. So the fixture keeps the
%% limit **exactly in band** and puts the usage one wei above it.
gas_used_above_the_limit_is_refused_test() ->
    Header = put(<<"gasUsed">>, ?PARENT_GAS_LIMIT + 1,
                 put(<<"gasLimit">>, ?PARENT_GAS_LIMIT, child())),
    ?assertEqual({error, {invalid_header,
                          {gas_used_above_gas_limit, ?PARENT_GAS_LIMIT + 1,
                           ?PARENT_GAS_LIMIT}}},
                 eth_block_validator:validate(parent(), Header, cancun)).

%% ===========================================================================
%% base fee
%% ===========================================================================

a_base_fee_that_is_not_the_computed_one_is_refused_test() ->
    ?assertEqual({error, {invalid_header,
                          {base_fee_mismatch, 999999999, child_base_fee()}}},
                 eth_block_validator:validate(parent(),
                                             put(<<"baseFeePerGas">>, 999999999, child()),
                                             cancun)).

%% Before London there is no base fee to check, and a header that omits the field is not
%% claiming a wrong one -- it is a block from before the field existed. Reporting the
%% absence as a mismatch would refuse a valid pre-London block.
before_london_there_is_no_base_fee_to_check_test() ->
    Parent = maps:remove(<<"baseFeePerGas">>, parent()),
    Header = maps:remove(<<"baseFeePerGas">>, child()),
    ?assertEqual(ok, eth_block_validator:validate(Parent, Header, berlin)).

%% ===========================================================================
%% excess blob gas
%% ===========================================================================

an_excess_blob_gas_that_is_not_the_computed_one_is_refused_test() ->
    ?assertMatch({error, {invalid_header, {excess_blob_gas_mismatch, _, _}}},
                 eth_block_validator:validate(parent(),
                                             put(<<"excessBlobGas">>, 524288, child()),
                                             cancun)).

before_cancun_there_is_no_excess_blob_gas_to_check_test() ->
    Parent = maps:remove(<<"excessBlobGas">>, parent()),
    Header = maps:remove(<<"excessBlobGas">>, child()),
    ?assertEqual(ok, eth_block_validator:validate(Parent, Header, london)).

%% ===========================================================================
%% EIP-3675's five absolute rules
%% ===========================================================================

a_non_zero_difficulty_is_refused_after_the_merge_test() ->
    ?assertEqual({error, {invalid_header, {non_zero_difficulty, 131072}}},
                 eth_block_validator:validate(parent(), put(<<"difficulty">>, 131072, child()),
                                             cancun)).

a_non_zero_nonce_is_refused_after_the_merge_test() ->
    ?assertEqual({error, {invalid_header,
                          {non_zero_nonce, <<"0000000000000001">>}}},
                 eth_block_validator:validate(parent(), put(<<"nonce">>, <<0:56, 1>>, child()),
                                             cancun)).

%% **The nonce is compared as a binary of a fixed length, so a nonce of the wrong
%% *length* is refused too.** The rule's value is `0x0000000000000000`, an 8-byte
%% string; a 24-byte nonce that RLP would encode with a different prefix is a different
%% value, and a validator that decoded it as an integer would admit
%% `0x0000000000000000000000000000000000000000000000000000000000000001`.
a_nonce_of_the_wrong_length_is_refused_test() ->
    ?assertMatch({error, {invalid_header, {non_zero_nonce, _}}},
                 eth_block_validator:validate(parent(),
                                             put(<<"nonce">>, <<0,0,0,0,0,0,0,0,0,0,0,1>>, child()),
                                             cancun)).

a_sha3_uncles_that_is_not_the_empty_hash_is_refused_test() ->
    ?assertMatch({error, {invalid_header, {ommers_hash_not_empty, _}}},
                 eth_block_validator:validate(parent(),
                                             put(<<"sha3Uncles">>, <<16#AA:256>>, child()),
                                             cancun)).

%% `len(extraData) > 32` is the refusal, so exactly 32 bytes is admitted.
extra_data_of_exactly_thirty_two_bytes_is_accepted_and_thirty_three_is_refused_test() ->
    ?assertEqual(ok, eth_block_validator:validate(parent(),
                                                 put(<<"extraData">>, <<0:256>>, child()),
                                                 cancun)),
    ?assertEqual({error, {invalid_header, {extra_data_too_long, 33, 32}}},
                 eth_block_validator:validate(parent(),
                                             put(<<"extraData">>, <<0:264>>, child()),
                                             cancun)).

%% ===========================================================================
%% The post-Merge gate on the three EIP-3675 rules
%% ===========================================================================
%%
%% A pre-Merge block's difficulty and nonce are the output of a proof of work. Refusing
%% them there would refuse half the chain this node can hold -- correctly, for the wrong
%% reason -- and a validator that only ever ran on Cancun fixtures would never notice.
pre_merge_difficulty_and_nonce_are_not_refused_test() ->
    Header = (put(<<"difficulty">>, 17179869184, put(<<"nonce">>, <<16#AA:64>>, child()))),
    ?assertEqual(ok, eth_block_validator:validate(parent(), Header, byzantium)).

%% ===========================================================================
%% Genesis
%% ===========================================================================
%%
%% No parent, so the five parent-relative rules do not run -- but the absolute ones do. A
%% genesis block that cannot be refused on its own fields would make this a validator of
%% nothing.
a_genesis_header_is_judged_without_a_parent_test() ->
    ?assertEqual(ok, eth_block_validator:validate(undefined, child(), cancun)),
    ?assertEqual({error, {invalid_header, {non_zero_difficulty, 2}}},
                 eth_block_validator:validate(undefined, put(<<"difficulty">>, 2, child()),
                                             cancun)).

%% ===========================================================================
%% Every named rule has a fixture
%% ===========================================================================
%%
%% `rule_names/0' is what a caller can put in a log line, so a rule that exists in the
%% code and not in that list is a rule nobody can name. The list is checked against the
%% reasons the rules above actually produce, by collecting them.
every_rule_this_module_exports_is_produced_by_the_fixture_that_claims_it_test() ->
    Named = eth_block_validator:rule_names(),
    %% Each fixture is paired with the **rule name** it is meant to provoke, and the
    %% pairing is asserted -- not merely listed. Writing the expected rules down without
    %% comparing them makes this a list of claims, which is what it was for one commit.
    %%
    %% **The rule name, not the whole reason.** The reasons carry figures -- a limit, a
    %% parent, an expected base fee -- and those are asserted with concrete numbers by
    %% the per-rule tests above. Here the question is only "does every rule this module
    %% can name have a fixture that provokes it", and comparing full tuples would need
    %% the unknown halves written as `_' inside a *value*, where a variable is a binding
    %% and not a wildcard.
    %% **Both sides in the assertion.** `?assertEqual(Rule, Got)` on two atoms from a
    %% comprehension over thirteen cases reports *a* mismatch with no indication of
    %% which, and EUnit truncates the rest; `{Rule, Rule} =:= {Rule, Got}` puts the
    %% expected and the actual in the failure message. That is the whole difference
    %% between reading the answer and re-running the case by hand.
    [?assertEqual({Rule, Rule},
                  {Rule, rule_name(reason_of(eth_block_validator:validate(P, H, cancun)))})
     || {P, H, Rule} <- cases()],
    Produced = [Rule || {_P, _H, Rule} <- cases()],
    %% Both directions. Either half alone would pass with a rule silently missing from
    %% the list a caller reads in a log line.
    ?assertEqual(Named, Produced).

%% The fixtures, each with the rule it is meant to provoke.
%% The fixtures, each with the rule it is meant to provoke, and **the parent it is
%% checked against**. The parent is here rather than assumed, because two of these
%% rules are unreachable against the 30,000,000 parent -- `gas_limit_below_minimum'
%% needs a parent whose own limit is small, and `gas_used_above_gas_limit' needs a
%% usage above a *legal* limit. A coverage list that assumes one parent cannot check
%% them, and would report the rule as unproducible when the fixture was the problem.
cases() ->
    C = child(),
    P = parent(),
    S = small_parent(),
    [%% **Zero, not one.** `number < 1` is the rule, and this fixture used 1 -- which is
     %% not below one, so it produced `number_not_one_above_parent` instead and the
     %% coverage test reported the mismatch.
     {P, put(<<"number">>, 0, C), number_below_one},
     {P, put(<<"number">>, 5, C), number_not_one_above_parent},
     {P, put(<<"timestamp">>, 1, C), timestamp_not_after_parent},
     {P, put(<<"gasUsed">>, ?PARENT_GAS_LIMIT + 1,
             put(<<"gasLimit">>, ?PARENT_GAS_LIMIT, C)), gas_used_above_gas_limit},
     {P, put(<<"gasLimit">>, ?PARENT_GAS_LIMIT + gas_limit_delta(), C),
      gas_limit_above_bound},
     %% **`gasUsed` lowered with the limit**, or this produces
     %% `gas_used_above_gas_limit' -- 21,000 gas used against a limit of 100. Third
     %% instance of the same fixture fault in this module, and the assertion above is
     %% what finally named it: one report said a rule was unproducible when the
     %% *fixture* was the thing that was wrong.
     {P, put(<<"gasUsed">>, 0, put(<<"gasLimit">>, 100, C)), gas_limit_below_bound},
     {S, put(<<"gasLimit">>, 4999, child_of(S)), gas_limit_below_minimum},
     {P, put(<<"baseFeePerGas">>, 7, C), base_fee_mismatch},
     {P, put(<<"excessBlobGas">>, 999, C), excess_blob_gas_mismatch},
     {P, put(<<"difficulty">>, 1, C), non_zero_difficulty},
     {P, put(<<"nonce">>, <<1:64>>, C), non_zero_nonce},
     {P, put(<<"sha3Uncles">>, <<1:256>>, C), ommers_hash_not_empty},
     {P, put(<<"extraData">>, <<0:264>>, C), extra_data_too_long},
     %% **Past the last fork this node models.** The default configured network in a test
     %% run is Sepolia, whose modelled range ends at Amsterdam, 1,791,294,816 -- 2026-10-06.
     %% One second later is outside it, and because this rule sits in the parentless group
     %% it fires before `timestamp_not_after_parent' would.
     {P, put(<<"timestamp">>, 1791294817, C), past_modelled_range}].


%% **Any arity.** The reasons come in three shapes -- a bare atom
%% (`number_below_one`, `non_zero_difficulty`) and tuples of two or three. This
%% function first handled only the two-tuple and the atom, and the coverage test below
%% failed on the first three-tuple it met, which is the test doing its job: it is the
%% reason this list is asserted against what the rules actually produce rather than
%% against a hand-written copy of it.
%% Takes a **reason**, not the validator's whole answer -- `reason_of/1' has already
%% unwrapped `{error, {invalid_header, _}}', and a function named for the unwrapping
%% that does a second unwrapping is a function whose contract nobody can state.
rule_name(Reason) when is_tuple(Reason) -> element(1, Reason);
rule_name(Name) -> Name.

reason_of(ok) -> none;
reason_of({error, {invalid_header, Reason}}) -> Reason.
