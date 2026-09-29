%% -*- erlang -*-
%% Properties of `eth_word', the EVM's 256-bit arithmetic.
%%
%% Every property is a mathematical identity about the operation, not a restatement of its
%% implementation. `addmod(A,B,N)' is *defined* as `(A + B) rem N', so asserting
%% `addmod(A,B,N) =:= (A+B) rem N' is a tautology that would survive replacing the module
%% with a comment. What is worth asserting is that the result is **congruent to A + B
%% modulo N**, that it is a valid word, and that it is a valid word for every modulus
%% including zero.
%%
%% **This file records nine properties that turned out to be false as first written, and
%% in every case the code was right.** They are kept in the comments rather than deleted,
%% because each one is a property somebody will reach for, and the reason it is false is
%% the useful part:
%%
%%   * `lt/gt/eq/iszero` return **1 or 0**, not `true`/`false`. `bool/1' is
%%     `bool(true) -> 1; bool(false) -> 0` and that is the yellow paper's convention:
%%     a comparison pushes 0 or 1. So `lt(A,A) =:= false` fails, and
%%     `lt(A,B) =:= not gt(B,A)` fails twice over -- both sides are 0/1 and `not' is a
%%     boolean operator applied to one. The 0/1 form is `lt(A,B) + gt(B,A) =:= 1'.
%%   * `to_bytes/1' is **big**-endian, so `from_bytes(<<N/little>>) =:= N' is false. The
%%     round trip is fine; the assumed byte order was not.
%%   * `signextend(0, X)' is the identity **only when bit 7 of X is clear**. Byte 0 of
%%     `0x5889' is `0x89', whose top bit is set, so the correct answer is the 256-bit word
%%     with every bit above 7 set -- and that is what the module returns. "Extend from
%%     byte 0" and "leave alone" are different questions and only coincide sometimes.
%%   * `signed/1' and `unsigned/1' are **not** inverses. `unsigned/1' is a mask,
%%     `signed/1' maps a word to a signed *integer*, and `signed(unsigned(?MIN))' is
%%     `-2^255', not `?MIN'. Only `unsigned(signed(X)) =:= X' holds.
%%   * `shr(shl(X, S), S) = X' is **false in general** -- a left shift by S destroys
%%     everything above bit `255 - S' -- and `shl(shr(X, S), S) = X' is false in general
%%     too, because a right shift destroys the low S bits. Each needs its precondition
%%     stated, and stating it is what makes the property informative: the naive version
%%     fails, and *why* it fails is the shift semantics.
%%   * `addmod(A,B,M) =:= addmod(A,B,2*M)' is **false**: `(A+B) rem 4` and `(A+B) rem 8`
%%     are unrelated. Congruent modulo M is not equal. It was a tempting property and it
%%     is not one.
%%
%% And one defect in this file's own first version, which is the warning above applied to
%% itself: the signextend cross-check computed `1 bsl (8*B + 7)`, which is the expression
%% `eth_word:signextend/2' uses, so it agreed with the module by construction. It is now
%% derived arithmetically instead -- low N bits as a signed integer, then one mask -- which
%% is a different route to the same number rather than the same route twice.
%%
%% On the generator's boundary bias: it is **not** load-bearing for these properties, and
%% an injection that removed it caught nothing. That is expected -- an algebraic identity
%% either holds for all inputs or for none, so uniform words test it completely, and the
%% interesting values are not where these fail. The bias is kept as insurance for a future
%% property whose failure region *is* narrow, and it is recorded here as unproven rather
%% than claimed as a safeguard that has earned its place.
-module(eth_word_properties_tests).

-include_lib("eunit/include/eunit.hrl").

%% **`?MASK` is a hex literal and must stay one.**
%%
%% This file first defined it as `(1 bsl 256) - 1`, which is the obvious way to write it
%% and is **wrong in every bitwise context**. `band` binds tighter than `-`, so
%%
%%     X band ?MASK          ==>  (X band (1 bsl 256)) - 1  ==>  X - 1
%%
%% and for any word below 2^256 that is `X - 1` -- so `X band ?MASK` is `-1`, which is
%% what it answered. Nine of `eth_word''s own functions use `?MASK' in exactly this way,
%% which is why **that** module defines it as `16#FFFF...FF' -- a single token, with no
%% operators for precedence to reorder. "Simplifying" it to an arithmetic expression there
%% would silently corrupt `add/2`, `sub/2`, `mul/2`, `mask/1`, `shl/2`, `unsigned/1`,
%% `exp/2' and `signextend/2' simultaneously, and `shl(1, 0) = 0' would look like an
%% off-by-one in the shift rather than a macro.
%%
%% It was caught here by the signextend cross-check below, which computes
%% `AsSigned band ?MASK' and compares it against the module. That check failed with
%% `want => -1, got => 22657, as => 22657, mask => 115792...935` -- a "want" that could
%% not be derived from the inputs by any arithmetic, which is what finally said the
%% *harness* was wrong rather than the module.
-define(MASK, 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF).
-define(MIN, 1 bsl 255).
-define(MOD, 1 bsl 256).
-define(CASES, 400).

%% ---------------------------------------------------------------------------
%% Argument order. **Pinned first, because everything below depends on it.**

%% `eth_word:shl/2' is `shl(Value, Shift)'. The yellow paper writes `SHL(shift, value)' and
%% the two are not the same function. The interpreter is right -- `eth_evm:shift_op/3'
%% pops Amount, pops Value, and calls `Fun(Value, Amount)' -- so the code is correct and
%% only the notation is a trap.
%%
%% A probe written against the spec's notation reported **six** confident failures from
%% this one. `shl(0, X)' is "zero shifted left by X", not "X shifted left by zero", so
%% `shl(0, 1) = 0' is the correct answer and the probe expected 1. Six failures that all
%% said the code was broken; none of them it was.
shl_takes_the_value_first_and_the_shift_second_test() ->
    ?assertEqual(1, eth_word:shl(1, 0)),
    ?assertEqual(2, eth_word:shl(1, 1)),
    ?assertEqual(4, eth_word:shl(2, 1)),
    %% 1 bsl 255 is 2^255, which is ?MIN and **not** ?MASK. Written as ?MASK it fails,
    %% and the failure looks like a masking bug.
    ?assertEqual(?MIN, eth_word:shl(1, 255)),
    ?assertEqual(0, eth_word:shl(1, 256)).

shr_takes_the_value_first_and_the_shift_second_test() ->
    ?assertEqual(1, eth_word:shr(1, 0)),
    ?assertEqual(0, eth_word:shr(1, 1)),
    ?assertEqual(?MASK, eth_word:shr(?MASK, 0)),
    ?assertEqual(?MASK bsr 8, eth_word:shr(?MASK, 8)).

%% ---------------------------------------------------------------------------
%% Shifts

%% `shr(shl(X, S), S) = X` **only if the left shift destroyed nothing**, i.e. if X's most
%% significant bit is at or below `255 - S'. Without the guard this is false and
%% uninformative: `shl(?MIN, 200)' masks to 0 and there is nothing left to shift back.
a_shift_right_undoes_a_shift_left_that_lost_no_bits_test() ->
    eth_prop:for_all(shl_shr_is_the_identity_when_no_bits_are_lost,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:shift()] end,
                      fun([X, S]) ->
                          case no_bits_lost(X, S) of
                              true -> eth_word:shr(eth_word:shl(X, S), S) =:= X;
                              false -> true
                          end
                      end}).

%% And `shl(shr(X, S), S) = X` only if the *low* S bits were zero, since a right shift
%% discards them. This is the mirror image of the property above and it fails for a
%% different reason, which is the point of having both: "shifting right then left" and
%% "shifting left then right" are not the same round trip.
a_shift_left_undoes_a_shift_right_that_discarded_nothing_test() ->
    eth_prop:for_all(shr_shl_is_the_identity_when_no_low_bits_are_lost,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:shift()] end,
                      fun([X, S]) ->
                          case low_bits_are_zero(X, S) of
                              true -> eth_word:shl(eth_word:shr(X, S), S) =:= X;
                              false -> true
                          end
                      end}).

a_shift_past_the_word_is_zero_test() ->
    eth_prop:for_all(shifts_of_256_or_more_are_zero,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:shift()] end,
                      fun([X, S]) ->
                          case S >= 256 of
                              true ->
                                  eth_word:shl(X, S) =:= 0 andalso eth_word:shr(X, S) =:= 0;
                              false -> true
                          end
                      end}).

%% `SAR' saturates rather than zeroing, and **which** way it saturates is the sign. The
%% EVM's answer for a negative word is all ones; a node answering 0 there diverges on
%% every arithmetic shift of a signed value, which is every signed comparison in Solidity
%% compiled before 0.8.
an_arithmetic_shift_right_saturates_to_the_sign_test() ->
    eth_prop:for_all(sar_saturates_at_256,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:shift()] end,
                      fun([X, S]) ->
                          case S >= 256 of
                              true ->
                                  eth_word:sar(X, S) =:=
                                      (case eth_word:signed(X) < 0 of
                                           true -> ?MASK;
                                           false -> 0
                                       end);
                              false -> true
                          end
                      end}).

sar_of_a_negative_word_stays_negative_test() ->
    eth_prop:for_all(sar_keeps_the_sign,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:shift()] end,
                      fun([X, S]) ->
                          case S < 256 andalso eth_word:signed(X) < 0 of
                              true -> eth_word:signed(eth_word:sar(X, S)) =< 0;
                              false -> true
                          end
                      end}).

%% ---------------------------------------------------------------------------
%% Addition, subtraction, multiplication

subtracting_y_gives_back_x_test() ->
    eth_prop:for_all(sub_then_add_is_the_identity,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:word()] end,
                      fun([X, Y]) -> eth_word:add(eth_word:sub(X, Y), Y) =:= X end}).

adding_is_commutative_test() ->
    eth_prop:for_all(add_is_commutative,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:word()] end,
                      fun([X, Y]) -> eth_word:add(X, Y) =:= eth_word:add(Y, X) end}).

multiplication_is_commutative_test() ->
    eth_prop:for_all(mul_is_commutative,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:word()] end,
                      fun([X, Y]) -> eth_word:mul(X, Y) =:= eth_word:mul(Y, X) end}).

%% Every result is a word. `add/2' and `mul/2' are the two places a 257-bit intermediate
%% could escape, and a 257-bit result is not a value this EVM can hold.
every_arithmetic_result_is_a_word_test() ->
    eth_prop:for_all(results_are_masked,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:word()] end,
                      fun([X, Y]) ->
                          W = fun(Z) -> is_integer(Z) andalso Z >= 0 andalso Z =< ?MASK end,
                          W(eth_word:add(X, Y)) andalso W(eth_word:sub(X, Y)) andalso
                          W(eth_word:mul(X, Y)) andalso W(eth_word:notb(X))
                      end}).

%% ---------------------------------------------------------------------------
%% Division and remainder

unsigned_divmod_reconstructs_the_dividend_test() ->
    eth_prop:for_all(udiv_umod_reconstruct,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:word()] end,
                      fun([A, B]) ->
                          case B of
                              0 -> eth_word:udiv(A, 0) =:= 0 andalso eth_word:umod(A, 0) =:= 0;
                              _ ->
                                  eth_word:add(eth_word:mul(eth_word:udiv(A, B), B),
                                               eth_word:umod(A, B)) =:= A
                          end
                      end}).

signed_divmod_agrees_with_signed_erlang_arithmetic_test() ->
    eth_prop:for_all(sdiv_smod_agree,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:word()] end,
                      fun([A, B]) ->
                          case B of
                              0 -> eth_word:sdiv(A, 0) =:= 0 andalso eth_word:smod(A, 0) =:= 0;
                              _ ->
                                  S = eth_word:signed(A),
                                  D = eth_word:signed(B),
                                  Q = eth_word:sdiv(A, B),
                                  M = eth_word:smod(A, B),
                                  eth_word:signed(Q) =:= S div D andalso
                                  eth_word:signed(M) =:= S rem D andalso
                                  is_integer(M) andalso M >= 0 andalso M =< ?MASK
                          end
                      end}).

%% The one place signed division overflows. `sdiv(?MIN, -1)' is `?MIN' and does not trap.
%% Erlang's `div' on that pair is 2^255, whose unsigned bit pattern *is* `?MIN' -- so the
%% two agree, but only because 2^255 and 2^255-1 differ in exactly the bit that overflows.
%% A rewrite of `sdiv/2' in terms of `udiv/2' would break this silently.
min_int_divided_by_minus_one_is_min_int_test() ->
    ?assertEqual(?MIN, eth_word:sdiv(?MIN, ?MASK)),
    ?assertEqual(0, eth_word:smod(?MIN, ?MASK)).

%% ---------------------------------------------------------------------------
%% ADDMOD and MULMOD. **Congruence**, which is a real property; restatement is not.

addmod_is_congruent_to_the_sum_test() ->
    eth_prop:for_all(addmod_congruence,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:word(), eth_prop:modulus()] end,
                      fun([A, B, M]) ->
                          case M of
                              0 -> eth_word:addmod(A, B, 0) =:= 0;
                              _ ->
                                  K = eth_word:addmod(A, B, M),
                                  (A + B - K) rem M =:= 0 andalso K >= 0 andalso K < M
                          end
                      end}).

mulmod_is_congruent_to_the_product_test() ->
    eth_prop:for_all(mulmod_congruence,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:word(), eth_prop:modulus()] end,
                      fun([A, B, M]) ->
                          case M of
                              0 -> eth_word:mulmod(A, B, 0) =:= 0;
                              _ ->
                                  K = eth_word:mulmod(A, B, M),
                                  (A * B - K) rem M =:= 0 andalso K >= 0 andalso K < M
                          end
                      end}).

%% `(A+B) rem M` and `(A+B) rem 2M` are **unrelated** -- 7 rem 4 is 3 and 7 rem 8 is 7 --
%% so "a smaller modulus that divides the larger gives the same answer" is false and was
%% written here before being caught. Congruent modulo M is not equal. Kept as a comment
%% because it is a natural thing to reach for and it is not a property of any remainder.
%% What *is* one: the result does not depend on the sign convention of a multiple.

addmod_is_unchanged_by_adding_a_multiple_of_the_modulus_test() ->
    eth_prop:for_all(addmod_ignores_a_whole_multiple,
                     200,
                     {fun(_) -> [eth_prop:word(), eth_prop:word(), eth_prop:small()] end,
                      fun([A, B, M]) ->
                          case M > 0 andalso A + B >= M of
                              true -> eth_word:addmod(A, B, M) =:= eth_word:addmod(A + M, B, M);
                              false -> true
                          end
                      end}).

%% ---------------------------------------------------------------------------
%% Bitwise

xorb_of_a_word_with_itself_is_zero_test() ->
    eth_prop:for_all(xorb_self_is_zero,
                     ?CASES,
                     {fun(_) -> [eth_prop:word()] end,
                      fun([X]) -> eth_word:xorb(X, X) =:= 0 end}).

or_of_a_word_with_its_complement_is_all_ones_test() ->
    eth_prop:for_all(orb_notb_is_the_mask,
                     ?CASES,
                     {fun(_) -> [eth_prop:word()] end,
                      fun([X]) -> eth_word:orb(X, eth_word:notb(X)) =:= ?MASK end}).

notb_is_its_own_inverse_test() ->
    eth_prop:for_all(notb_involutive,
                     ?CASES,
                     {fun(_) -> [eth_prop:word()] end,
                      fun([X]) -> eth_word:notb(eth_word:notb(X)) =:= X end}).

andb_orb_and_xorb_satisfy_the_ring_identity_test() ->
    eth_prop:for_all(xorb_is_orb_minus_andb,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:word()] end,
                      fun([A, B]) ->
                          %% (A|B) - (A&B) = A^B. No borrows cross the boundary because
                          %% A&B has a 1 only where A|B also has one, so the subtraction
                          %% is per-bit.
                          eth_word:xorb(A, B) =:= eth_word:sub(eth_word:orb(A, B),
                                                               eth_word:andb(A, B))
                      end}).

%% ---------------------------------------------------------------------------
%% Comparison. **0 or 1**, as the EVM requires. Antisymmetry, trichotomy and transitivity
%% together, because a comparison that mishandled one of them could satisfy the other two.

a_comparison_is_zero_or_one_test() ->
    eth_prop:for_all(predicates_are_zero_or_one,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:word()] end,
                      fun([A, B]) ->
                          ZO = fun(V) -> V =:= 0 orelse V =:= 1 end,
                          ZO(eth_word:lt(A, B)) andalso ZO(eth_word:gt(A, B)) andalso
                          ZO(eth_word:eq(A, B)) andalso ZO(eth_word:slt(A, B)) andalso
                          ZO(eth_word:sgt(A, B)) andalso ZO(eth_word:iszero(A))
                      end}).

%% Exactly one of lt, gt and eq holds -- the trichotomy, and the form that survives equal
%% arguments. Two narrower versions were written first and both are false:
%%
%%   * `lt(A,B) + gt(B,A) = 1` -- `gt(B,A)` is the same predicate as `lt(A,B)`, so the sum
%%     is `2 * lt(A,B)`, i.e. 0 or 2, never 1. It failed on the first generated pair.
%%   * `lt(A,B) + gt(A,B) = 1` -- correct except when `A =:= B`, where both are 0 and the
%%     sum is 0. It failed on the first *equal* pair, at case 254 of 400 with the default
%%     seed, which is late enough to look like an intermittent failure.
%%
%% Both failures look like a broken comparison. Neither was one.
exactly_one_of_lt_gt_and_eq_holds_test() ->
    eth_prop:for_all(trichotomy,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:word()] end,
                      fun([A, B]) ->
                          eth_word:lt(A, B) + eth_word:gt(A, B) + eth_word:eq(A, B) =:= 1
                      end}).

lt_is_irreflexive_test() ->
    eth_prop:for_all(lt_is_irreflexive,
                     ?CASES,
                     {fun(_) -> [eth_prop:word()] end,
                      fun([A]) -> eth_word:lt(A, A) =:= 0 andalso eth_word:slt(A, A) =:= 0 end}).

%% Transitivity is the **implication** `(A<B and B<C) -> A<C`, not the biconditional.
%% `A<C` holds perfectly well without `A<B and B<C`: for A=0, B=2, C=1 it is true while
%% the antecedent is false. Asserting the biconditional makes the property false for
%% ordinary integers, and it failed on the first triple the generator produced -- which
%% reads as a broken comparison and is not one.
comparison_is_a_strict_total_order_test() ->
    eth_prop:for_all(antisymmetric_trichotomy_transitive,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:word(), eth_prop:word()] end,
                      fun([A, B, C]) ->
                          Anti = eth_word:lt(A, B) + eth_word:lt(B, A) =< 1,
                          Tri = eth_word:lt(A, B) + eth_word:lt(B, A) +
                                eth_word:eq(A, B) =:= 1,
                          Trans = (eth_word:lt(A, B) =:= 1 andalso
                                   eth_word:lt(B, C) =:= 1) =:= false orelse
                                  eth_word:lt(A, C) =:= 1,
                          Anti andalso Tri andalso Trans
                      end}).

signed_comparison_orders_by_signed_value_test() ->
    eth_prop:for_all(slt_orders_by_signed_value,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:word()] end,
                      fun([A, B]) ->
                          eth_word:slt(A, B) =:= bit(eth_word:signed(A) < eth_word:signed(B))
                      end}).

iszero_is_equality_with_zero_test() ->
    eth_prop:for_all(iszero_is_equality_with_zero,
                     ?CASES,
                     {fun(_) -> [eth_prop:word()] end,
                      fun([A]) -> eth_word:iszero(A) =:= bit(A =:= 0) end}).

%% ---------------------------------------------------------------------------
%% Signedness. `unsigned/1' is a mask and is the identity on a word; `signed/1' maps a
%% word to a signed *integer*, so the two are **not** inverses and the property that
%% says so is one-directional. `signed(unsigned(?MIN))' is `-2^255', not `?MIN'.

unsigned_is_the_identity_on_a_word_test() ->
    eth_prop:for_all(unsigned_is_identity,
                     ?CASES,
                     {fun(_) -> [eth_prop:word()] end,
                      fun([X]) -> eth_word:unsigned(X) =:= X end}).

unsigned_undoes_signed_test() ->
    eth_prop:for_all(unsigned_signed_inverse,
                     ?CASES,
                     {fun(_) -> [eth_prop:word()] end,
                      fun([X]) -> eth_word:unsigned(eth_word:signed(X)) =:= X end}).

signed_of_a_word_is_in_range_test() ->
    eth_prop:for_all(signed_is_a_signed_integer,
                     ?CASES,
                     {fun(_) -> [eth_prop:word()] end,
                      fun([X]) ->
                          S = eth_word:signed(X),
                          is_integer(S) andalso S >= -?MIN andalso S =< ?MIN - 1
                      end}).

%% ---------------------------------------------------------------------------
%% BYTE

byte_selects_the_nth_most_significant_byte_test() ->
    eth_prop:for_all(byte_is_a_byte_extract,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:shift()] end,
                      fun([X, I]) ->
                          case I < 32 of
                              true ->
                                  eth_word:byte(I, X) =:= ((X bsr (8 * (31 - I))) band 16#FF);
                              false -> eth_word:byte(I, X) =:= 0
                          end
                      end}).

%% ---------------------------------------------------------------------------
%% SIGNEXTEND

%% `SIGNEXTEND(0, X)' is the identity only when `X < 128` -- **not** merely when bit 7 is
%% clear, which was the first attempt and is too weak. With `X = 2^200` the top bit of
%% byte 0 *is* clear, so the module returns `X band 127`, i.e. 0, because sign-extending
%% from byte 0 keeps only that byte. That is the correct answer: `SIGNEXTEND(0, 2^200)' is
%% 0 on every EVM. "Extend from byte 0" and "leave alone" agree only when the whole word
%% fits in byte 0.
signextend_by_zero_is_the_identity_only_below_128_test() ->
    eth_prop:for_all(signextend_0_is_identity_below_128,
                     ?CASES,
                     {fun(_) -> [eth_prop:word()] end,
                      fun([X]) ->
                          case X < 16#80 of
                              true -> eth_word:signextend(0, X) =:= X;
                              false -> true
                          end
                      end}).

%% For b >= 31 the value is unchanged, and that is a **spec clause** rather than a
%% degenerate case of the formula: the formula's sign bit would sit at 8*31+8 = 256,
%% which is outside the word.
signextend_past_the_last_byte_is_the_identity_test() ->
    eth_prop:for_all(signextend_31_is_identity,
                     ?CASES,
                     {fun(_) -> [eth_prop:word()] end,
                      fun([X]) -> eth_word:signextend(31, X) =:= X andalso
                                  eth_word:signextend(32, X) =:= X end}).

%% **This is the cross-check that is not a restatement.** The module computes
%% `SignBit = 1 bsl (8*B + 7)' and then branches on `X band SignBit', using `bor`/`bxor`.
%% A first version of this test computed `1 bsl (8*B + 7)` as well -- the *same expression*
%% -- so it agreed with the module by construction and would have survived a bit-manipulation
%% bug in it. That is the tautology this file's header warns about, written by the person
%% writing the warning.
%%
%% Here the expected value is derived arithmetically instead: take the low `8*(B+1)` bits
%% as an N-bit **signed integer** (subtract 2^N when the top bit is set) and fold it back
%% into the word with a single mask. `rem`, `-` and `band` against `bor`/`bxor` is a
%% genuinely different route to the same number, so a wrong bit in either one shows up.
signextend_agrees_with_an_arithmetic_derivation_test() ->
    eth_prop:for_all(signextend_matches_signed_arithmetic,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:small()] end,
                      fun([X, B0]) ->
                          B = B0 rem 32,
                          case B < 32 of
                              true ->
                                  N = 8 * (B + 1),
                                  V = X rem (1 bsl N),
                                  AsSigned = case V >= (1 bsl (N - 1)) of
                                                 true -> V - (1 bsl N);
                                                 false -> V
                                             end,
                                  Got = eth_word:signextend(B, X),
                                  Want = AsSigned band ?MASK,
                                  case Got =:= Want of
                                      true -> true;
                                      false -> {false, #{got => Got, want => Want,
                                                        b => B, n => N, v => V}}
                                  end;
                              false -> true
                          end
                      end}).

%% Extending twice changes nothing further. Not the definition, and it is the property
%% that would catch an off-by-one in the sign bit: the first extension has already filled
%% every bit above `8B+7`, so a second one is reading bits it has itself written.
signextend_is_idempotent_test() ->
    eth_prop:for_all(signextend_idempotent,
                     ?CASES,
                     {fun(_) -> [eth_prop:word(), eth_prop:small()] end,
                      fun([X, B]) ->
                          Once = eth_word:signextend(B, X),
                          eth_word:signextend(B, Once) =:= Once
                      end}).

%% ---------------------------------------------------------------------------
%% EXP

exp_of_zero_is_one_test() ->
    eth_prop:for_all(exp_0_is_1,
                     ?CASES,
                     {fun(_) -> [eth_prop:word()] end,
                      fun([X]) -> eth_word:exp(X, 0) =:= 1 end}).

exp_of_one_is_the_base_test() ->
    eth_prop:for_all(exp_1_is_the_base,
                     ?CASES,
                     {fun(_) -> [eth_prop:word()] end,
                      fun([X]) -> eth_word:exp(X, 1) =:= X end}).

%% A homomorphism from addition to multiplication, in the ring modulo 2^256. It fails if
%% the masking or the modulus is wrong, and no example-based test finds that.
exp_is_a_homomorphism_from_addition_test() ->
    eth_prop:for_all(exp_adds_the_exponents,
                     200,
                     {fun(_) -> [eth_prop:small() band 255, eth_prop:small() band 255,
                                 eth_prop:small() band 255] end,
                      fun([X, A, B]) ->
                          eth_word:exp(X, A + B) =:= eth_word:mul(eth_word:exp(X, A),
                                                                 eth_word:exp(X, B))
                      end}).

%% ---------------------------------------------------------------------------
%% Conversions

to_bytes_and_from_bytes_are_inverses_test() ->
    eth_prop:for_all(bytes_round_trip,
                     ?CASES,
                     {fun(_) -> [eth_prop:word()] end,
                      fun([X]) -> eth_word:from_bytes(eth_word:to_bytes(X)) =:= X end}).

%% `to_bytes/1' is `binary:encode_unsigned/1', which is **big**-endian, and `to_bytes(0)'
%% is `<<>>'. So the encoding of a word is its big-endian minimal form with no leading
%% zeroes, and a short binary decodes back to the same integer.
from_bytes_of_a_short_binary_is_the_same_integer_test() ->
    eth_prop:for_all(short_binaries_decode,
                     ?CASES,
                     {fun(_) -> [eth_prop:small() band 16#FFFFFF] end,
                      fun([N]) ->
                          eth_word:from_bytes(binary:encode_unsigned(N, big)) =:= N
                      end}).

%% ---------------------------------------------------------------------------
%% Helpers. Both are about **how many bits a value occupies**, which is the precondition
%% the two shift round trips need and the only thing either of them was missing.

%% A left shift by S loses everything above bit `255 - S', so the round trip is the
%% identity exactly when the value fits in the bits that survive.
no_bits_lost(X, S) ->
    bits_used(X) + S =< 256.

low_bits_are_zero(X, S) ->
    X band ((1 bsl S) - 1) =:= 0.

%% 0 occupies no bits, which `integer_to_binary(0, 2)' would report as one.
bits_used(0) -> 0;
bits_used(X) -> byte_size(integer_to_binary(X, 2)) * 8.

%% The EVM's 0-or-1.
bit(true) -> 1;
bit(false) -> 0.
