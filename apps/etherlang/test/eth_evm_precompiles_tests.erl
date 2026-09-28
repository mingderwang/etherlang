-module(eth_evm_precompiles_tests).

-include_lib("eunit/include/eunit.hrl").

%% The newest fork, named rather than defaulted. Every test here used to call
%% `precompile/2', which took no fork, and so asserted against a schedule belonging
%% to no fork at all -- and several were half right in a way worth recording:
%% `precompile(8, Data)' for a pairing check paired a Byzantium *address* with an
%% Istanbul *price'. A default here would let the next such mixture go unnoticed.
-define(FORK, cancun).

%% EIP-198/2565 MODEXP vectors.

modexp_small_test() ->
    %% 3^2 mod 5 = 4; Max=1 -> complexity 1, adjusted(2)=1 -> floor 200.
    Data = <<1:256, 1:256, 1:256, 3:8, 2:8, 5:8>>,
    ?assertEqual({ok, <<4>>, 200}, eth_evm_precompiles:precompile(5, Data, ?FORK)).

modexp_zero_exponent_test() ->
    %% 3^0 mod 5 = 1; adjusted(0) is defined as 0, not -1.
    Data = <<1:256, 1:256, 1:256, 3:8, 0:8, 5:8>>,
    ?assertEqual({ok, <<1>>, 200}, eth_evm_precompiles:precompile(5, Data, ?FORK)).

modexp_gas_counts_exponent_bits_test() ->
    %% 32-byte sizes, exponent 2^255: adjusted = 255, complexity = 1024,
    %% gas = max(200, 1024*255 div 20) = 13056. The old code ignored the
    %% exponent value entirely and charged 200 here.
    E = <<16#80, 0:248>>,
    M = binary:copy(<<16#FF>>, 32),
    Data = <<32:256, 32:256, 32:256, 2:256, E/binary, M/binary>>,
    {ok, Out, Gas} = eth_evm_precompiles:precompile(5, Data, byzantium),
    ?assertEqual(32, byte_size(Out)),
    ?assertEqual(13056, Gas).

modexp_zero_modulus_test() ->
    %% M = 0 -> empty output (gas still charged per EIP-198).
    Data = <<1:256, 1:256, 1:256, 3:8, 2:8, 0:8>>,
    {ok, Out, Gas} = eth_evm_precompiles:precompile(5, Data, ?FORK),
    ?assertEqual(<<>>, Out),
    ?assertEqual(200, Gas).

modexp_long_exponent_head_bits_test() ->
    %% LenE = 33, leading byte 0x80: E = 2^263, adjusted = 8*1 + 255 = 263.
    %% 3^(2^263) mod 5 = 1 (2^263 = 0 mod 4 = phi(5), exponent > 0).
    %% Max = 1 -> complexity 1 -> gas floor 200 either way; asserts output.
    E = <<16#80, 0:256>>,
    Data = <<1:256, 33:256, 1:256, 3:8, E/binary, 5:8>>,
    ?assertEqual({ok, <<1>>, 200}, eth_evm_precompiles:precompile(5, Data, ?FORK)).

identity_test() ->
    ?assertEqual({ok, <<"abc">>, 15 + 3}, eth_evm_precompiles:precompile(4, <<"abc">>, ?FORK)).

ecrecover_recognized_test() ->
    ?assertEqual(true, eth_evm_precompiles:is_precompile(1, ?FORK)).

%% ECRECOVER vectors recorded live from Sepolia upstream. Failure returns
%% empty output (geth parity), never an error.
ecrecover_valid_test() ->
    In = binary:decode_hex(<<"7a8f2ee29035e823ebcfe3a0427ea15aebed523a6212bfd802221cc78555e465"
                              "000000000000000000000000000000000000000000000000000000000000001b"
                              "a30aeebf19b0dc75fb8e4457cd9069b30051021bd3f6c7bd5603512bc4231842"
                              "99c02cd178b7772ce623c6224c7177c52dfcd733244455d1453c90e0f81a5eb1">>),
    {ok, Out, Gas} = eth_evm_precompiles:precompile(1, In, ?FORK),
    ?assertEqual(binary:decode_hex(<<"00000000000000000000000094d553c07966b312c542034bf66c71bdb929202d">>),
                 Out),
    ?assertEqual(3000, Gas).

ecrecover_valid_v28_test() ->
    In = binary:decode_hex(<<"ff0926163e832beb39e5d040baa5aa9751dac0562ceda41429c919c4b47ea1db"
                              "000000000000000000000000000000000000000000000000000000000000001c"
                              "cc13d8fe87dcd5a9d291dcf94781a2a9a9350e85ad0fc33666072b27c2a249d"
                              "af7421999a698278f99413b1d9f76b858831c000bd753d1a13183df600c1a469f">>),
    {ok, Out, Gas} = eth_evm_precompiles:precompile(1, In, ?FORK),
    ?assertEqual(binary:decode_hex(<<"000000000000000000000000665903e06d6382f5ea7ddaa0a6dfd99bcfc860f4">>),
                 Out),
    ?assertEqual(3000, Gas).

ecrecover_bad_v_test() ->
    Base = binary:decode_hex(<<"7a8f2ee29035e823ebcfe3a0427ea15aebed523a6212bfd802221cc78555e465"
                               "000000000000000000000000000000000000000000000000000000000000001b"
                               "a30aeebf19b0dc75fb8e4457cd9069b30051021bd3f6c7bd5603512bc4231842"
                               "99c02cd178b7772ce623c6224c7177c52dfcd733244455d1453c90e0f81a5eb1">>),
    <<H:32/binary, _:32/binary, RS:64/binary>> = Base,
    {ok, Out, Gas} = eth_evm_precompiles:precompile(
                       1, <<H/binary, 0:256, RS/binary>>, ?FORK),
    ?assertEqual(<<>>, Out),
    ?assertEqual(3000, Gas).

ecrecover_zero_r_test() ->
    {ok, Out, _} = eth_evm_precompiles:precompile(1, binary:copy(<<0>>, 128), ?FORK),
    ?assertEqual(<<>>, Out).

ecrecover_short_input_test() ->
    %% Short input zero-pads (v field becomes 0 -> invalid -> empty).
    {ok, Out, _} = eth_evm_precompiles:precompile(1, <<1:256>>, ?FORK),
    ?assertEqual(<<>>, Out).

%% The precompile set is 0x01..0x0A and nothing else. 0x0A used to be missing
%% from it, which is why eth_kzg -- a complete point evaluation verified against
%% mainnet exec-specs fixtures -- was unreachable from execution.
precompile_set_is_one_through_ten_test() ->
    ?assertEqual([true, true, true, true, true, true, true, true, true, true],
                 [eth_evm_precompiles:is_precompile(N, ?FORK) || N <- lists:seq(1, 10)]),
    ?assertNot(eth_evm_precompiles:is_precompile(0, ?FORK)),
    ?assertNot(eth_evm_precompiles:is_precompile(11, ?FORK)),
    ?assertEqual(unsupported, eth_evm_precompiles:precompile(11, <<>>, ?FORK)).

%% A precompile that is not implemented returns `unsupported', which eth_call
%% turns into an upstream fallback. A precompile that ran and rejected its input
%% must not, because that would substitute another node's verdict for this one's.
%% 0x0A is the first precompile with the second behaviour, so the distinction is
%% pinned here rather than left to the reader of two case clauses.
kzg_failure_is_not_a_fallback_test() ->
    ?assertEqual({error, {kzg, point_evaluation_failed}},
                 eth_evm_precompiles:precompile(10, <<>>, ?FORK)),
    ?assertNotEqual(unsupported, eth_evm_precompiles:precompile(10, <<>>, ?FORK)).

%% ---------------------------------------------------------------------------
%% EIP-196 ECADD / ECMUL. The arithmetic was always right; the *error* branch was not.
%% ---------------------------------------------------------------------------

%% A curve point, as the EIP encodes one: two 32-byte big-endian field elements.
pt(X, Y) -> <<X:256, Y:256>>.

%% **The property that matters is that a block is still produced.** `unsupported` is a
%% halt, and `eth_block:run_transaction/5' turns a halt into a refusal to produce the
%% block at all -- so a contract feeding ECADD a point not on the curve made this node
%% reject the block containing it, where every other client executes it. EIP-196 says
%% only: "Fails on invalid input and consumes all gas provided."
an_off_curve_point_is_a_call_failure_and_not_a_refusal_test() ->
    ?assertEqual({failed, {ecadd, not_on_curve}},
                 eth_evm_precompiles:precompile(6, <<(pt(1,1))/binary,
                                                       (pt(0,0))/binary>>, ?FORK)),
    ?assertEqual({failed, {ecmul, not_on_curve}},
                 eth_evm_precompiles:precompile(7, <<(pt(1,1))/binary, 1:256>>,
                                                ?FORK)),
    %% And the shape is a *call failure*, which `eth_evm:run_call/10' handles by
    %% consuming the forwarded gas and letting the caller carry on -- not the
    %% `unsupported' clause, which is the one that refuses.
    ?assertNotEqual(unsupported,
                    eth_evm_precompiles:precompile(6, <<(pt(1,1))/binary,
                                                       (pt(0,0))/binary>>, ?FORK)).

%% A point off the curve, which is the whole reason the branch above exists. `(1,1)` is
%% off it: `1^2 = 1` but `1^3 + 3 = 4`. `(1,2)` is on it, and the two are one digit
%% apart, so a test that gets them the wrong way round is a test that asserts nothing.
one_one_is_off_the_curve_and_one_two_is_on_it_test() ->
    ?assertMatch({ok, _, _}, eth_evm_precompiles:precompile(6, <<(pt(1,2))/binary,
                                                            (pt(0,0))/binary>>, ?FORK)),
    ?assertMatch({failed, _}, eth_evm_precompiles:precompile(6, <<(pt(1,1))/binary,
                                                               (pt(0,0))/binary>>, ?FORK)).

%% Adding the point at infinity is the identity, and the point at infinity is `(0,0)` --
%% which is **not** on the curve, so it has to be a special case or a correct ECADD
%% would reject its own encoding. EIP-196's encoding section says so directly.
the_point_at_infinity_is_the_identity_element_test() ->
    ?assertEqual(<<(pt(1,2))/binary>>,
                 ok_out(eth_evm_precompiles:precompile(6, <<(pt(1,2))/binary,
                                                        (pt(0,0))/binary>>, ?FORK))),
    ?assertEqual(<<(pt(0,0))/binary>>,
                 ok_out(eth_evm_precompiles:precompile(6, <<(pt(0,0))/binary,
                                                        (pt(0,0))/binary>>, ?FORK))),
    ?assertEqual(<<(pt(1,2))/binary>>,
                 ok_out(eth_evm_precompiles:precompile(7, <<(pt(1,2))/binary, 1:256>>,
                                                      ?FORK))).

%% A real doubling, pinned to the value rather than to a formula. `(1,2) + (1,2)` on
%% alt_bn128 is `03 0644E7...` for x and `ED 73...` for y, and that constant is the
%% check: a test that recomputes it with this repository's own `bn128_add_points/2' and
%% compares the two would pass with the addition formula itself wrong.
ecadd_doubles_a_point_on_the_curve_test() ->
    ?assertEqual(
       binary:decode_hex(
         <<"030644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd315"
           "ed738c0e0a7c92e7845f96b2ae9c0a68a6a449e3538fc7ff3ebf7a5a18a2c4">>),
       ok_out(eth_evm_precompiles:precompile(6, <<(pt(1,2))/binary, (pt(1,2))/binary>>,
                                             ?FORK))).

%% EIP-196's own test-case list includes "Both contracts should succeed on empty
%% input", which is true because short input is "virtually padded with zeros" and
%% `(0,0)` is the point at infinity. It is pinned because the opposite reading -- that
%% empty input is a length error -- is a plausible thing to add, and adding it would
%% break every fixture that calls a precompile with no arguments.
empty_input_succeeds_because_it_pads_to_the_point_at_infinity_test() ->
    [?assertMatch({ok, <<_:512>>, _}, eth_evm_precompiles:precompile(N, <<>>, ?FORK))
     || N <- [6, 7]].

%% ---------------------------------------------------------------------------
%% EIP-152 BLAKE2b-F vectors (inputs built from parts, outputs verbatim).
%% ---------------------------------------------------------------------------

blake2f_input(Rounds, F) ->
    H = binary:decode_hex(<<"48c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5"
                            "d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b">>),
    M = <<16#61, 16#62, 16#63, 0:(125 * 8)>>,
    T = binary:decode_hex(<<"03000000000000000000000000000000">>),
    <<Rounds:32, H/binary, M/binary, T/binary, F:8>>.

blake2f_vector4_rounds_zero_test() ->
    {ok, Out, Gas} = eth_evm_precompiles:precompile(9, blake2f_input(0, 1), istanbul),
    ?assertEqual(binary:decode_hex(<<"08c9bcf367e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5"
                                      "d282e6ad7f520e511f6c3e2b8c68059b9442be0454267ce079217e1319cde05b">>),
                 Out),
    ?assertEqual(0, Gas).

blake2f_vector5_twelve_rounds_test() ->
    {ok, Out, Gas} = eth_evm_precompiles:precompile(9, blake2f_input(12, 1), istanbul),
    ?assertEqual(binary:decode_hex(<<"ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1"
                                      "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923">>),
                 Out),
    ?assertEqual(12, Gas).

blake2f_vector6_unset_final_flag_test() ->
    {ok, Out, Gas} = eth_evm_precompiles:precompile(9, blake2f_input(12, 0), istanbul),
    ?assertEqual(binary:decode_hex(<<"75ab69d3190a562c51aef8d88f1c2775876944407270c42c9844252c26d2875298"
                                      "743e7f6d5ea2f2d3e8d226039cd31b4e426ac4f2d3d666a610c2116fde4735">>),
                 Out),
    ?assertEqual(12, Gas).

blake2f_vector7_single_round_test() ->
    {ok, Out, Gas} = eth_evm_precompiles:precompile(9, blake2f_input(1, 1), istanbul),
    ?assertEqual(binary:decode_hex(<<"b63a380cb2897d521994a85234ee2c181b5f844d2c624c002677e9703449d2fba55"
                                      "1b3a8333bcdf5f2f7e08993d53923de3d64fcc68c034e717b9293fed7a421">>),
                 Out),
    ?assertEqual(1, Gas).

%% EIP-152 fixes the input at exactly 213 bytes, and input it rejects is a **call
%% failure** -- the call returns nothing and consumes its forwarded gas -- which is not
%% the same as this node lacking the contract. These asserted `unsupported', and the
%% consequence was that seven `eip152_blake2' fixtures reported a missing
%% implementation the node has: the fixture DELEGATECALLs 0x09 with *zero-length*
%% calldata, the call should fail, and the node was refusing the whole block.
blake2f_bad_length_test() ->
    [?assertMatch({failed, {blake2f, {input_length, Len, 213}}},
                  eth_evm_precompiles:precompile(9, D, istanbul))
     || {Len, D} <- [{0, <<>>},
                     {212, binary:part(blake2f_input(12, 1), 0, 212)},
                     {214, <<(blake2f_input(12, 1))/binary, 0>>}]].

blake2f_bad_flag_test() ->
    Good = blake2f_input(12, 1),
    Bad = binary:part(Good, 0, 212),
    ?assertMatch({failed, {blake2f, {final_flag, 2}}},
                 eth_evm_precompiles:precompile(9, <<Bad/binary, 2>>, istanbul)).

blake2f_recognized_test() ->
    ?assertEqual(true, eth_evm_precompiles:is_precompile(9, ?FORK)).

%% ---------------------------------------------------------------------------
%% EIP-196 alt_bn128 vectors (outputs recorded from Sepolia upstream;
%% EIP-1108 Istanbul gas: ECADD 150, ECMUL 6000).
%% ---------------------------------------------------------------------------

%% 2*G1, recorded live: ADD((1,2),(1,2)) == MUL((1,2),2).
-define(BN128_DOUBLE_G1,
        binary:decode_hex(<<"030644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd3"
                            "15ed738c0e0a7c92e7845f96b2ae9c0a68a6a449e3538fc7ff3ebf7a5a18a2c4">>)).

bn128_u(X) -> <<X:256>>.

ecadd_g1_double_test() ->
    In = <<(bn128_u(1))/binary, (bn128_u(2))/binary,
           (bn128_u(1))/binary, (bn128_u(2))/binary>>,
    ?assertEqual({ok, ?BN128_DOUBLE_G1, 150},
                 eth_evm_precompiles:precompile(6, In, ?FORK)).

ecmul_g1_times_two_test() ->
    In = <<(bn128_u(1))/binary, (bn128_u(2))/binary, (bn128_u(2))/binary>>,
    ?assertEqual({ok, ?BN128_DOUBLE_G1, 6000},
                 eth_evm_precompiles:precompile(7, In, ?FORK)).

ecadd_infinity_identity_test() ->
    Zeros = binary:copy(<<0>>, 128),
    {ok, Out, Gas} = eth_evm_precompiles:precompile(6, Zeros, ?FORK),
    ?assertEqual(binary:copy(<<0>>, 64), Out),
    ?assertEqual(150, Gas).

ecmul_zero_scalar_test() ->
    In = <<(bn128_u(1))/binary, (bn128_u(2))/binary, (bn128_u(0))/binary>>,
    {ok, Out, Gas} = eth_evm_precompiles:precompile(7, In, ?FORK),
    ?assertEqual(binary:copy(<<0>>, 64), Out),
    ?assertEqual(6000, Gas).

%% **These two asserted `unsupported', which is the defect this change fixes.** EIP-196
%% lists the two ways a coordinate is invalid in one sentence and separates them: "if any
%% input point does not lie on the curve **or any of the field elements (point
%% coordinates) is equal or larger than the field modulus p**". Both are a *failed call*
%% -- "Fails on invalid input and consumes all gas provided" -- and neither is a missing
%% implementation.
%%
%% `unsupported` is not a smaller wrong answer. `eth_evm:run_call/10' halts on it and
%% `eth_block:run_transaction/5' turns that halt into a refusal to produce the block, so
%% a contract that fed ECADD a bad point made this node **reject the block containing
%% it** while every other client executed it. These two fixtures assert the difference.
ecadd_coordinate_at_field_test() ->
    P = 21888242871839275222246405745257275088696311157297823662689037894645226208583,
    In = <<(bn128_u(P))/binary, (bn128_u(0))/binary,
           (bn128_u(0))/binary, (bn128_u(0))/binary>>,
    ?assertMatch({failed, {ecadd, {coordinate_not_in_field, P}}},
                 eth_evm_precompiles:precompile(6, In, ?FORK)),
    ?assertNotEqual(unsupported, eth_evm_precompiles:precompile(6, In, ?FORK)).

ecadd_off_curve_test() ->
    %% (2,2): 4 =/= 11 mod p.  A *different* failure from the one above -- the
    %% coordinate is in the field, the point is not on the curve -- and it is told apart
    %% so a caller can say which.
    In = <<(bn128_u(2))/binary, (bn128_u(2))/binary,
           (bn128_u(0))/binary, (bn128_u(0))/binary>>,
    ?assertEqual({failed, {ecadd, not_on_curve}},
                 eth_evm_precompiles:precompile(6, In, ?FORK)),
    ?assertNotEqual(unsupported, eth_evm_precompiles:precompile(6, In, ?FORK)).

ecmul_short_input_padded_test() ->
    %% 64 bytes (no scalar): zero-padded scalar 0 -> infinity.
    In = <<(bn128_u(1))/binary, (bn128_u(2))/binary>>,
    {ok, Out, _} = eth_evm_precompiles:precompile(7, In, ?FORK),
    ?assertEqual(binary:copy(<<0>>, 64), Out).

ecadd_recognized_test() ->
    ?assertEqual(true, eth_evm_precompiles:is_precompile(6, ?FORK)),
    ?assertEqual(true, eth_evm_precompiles:is_precompile(7, ?FORK)).

%% ---------------------------------------------------------------------------
%% EIP-197 pairing check (0x08). G2 generator wire bytes from the EIP
%% ((imag,real) order per "(a, b)" encoding).
%% ---------------------------------------------------------------------------

pairing_g1() -> <<1:256, 2:256>>.
pairing_g2() ->
    binary:decode_hex(<<"198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2"
                        "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed"
                        "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b"
                        "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa">>).

pairing_empty_test() ->
    ?assertEqual({ok, <<1:256>>, 45000},
                 eth_evm_precompiles:precompile(8, <<>>, istanbul)).

pairing_bad_length_test() ->
    %% EIP-197, like EIP-152: a length that is not a whole number of pairs is input
    %% the check rejects, so the call fails. `unsupported' here said the node could not
    %% run the check, and refusing the block over it turned a correct rejection into a
    %% refusal that looked like a gap.
    [?assertMatch({failed, {ecpairing, {length_not_a_multiple_of_192, Len}}},
                  eth_evm_precompiles:precompile(8, binary:copy(<<0>>, Len), istanbul))
     || Len <- [191, 193]].

pairing_single_nondegenerate_test() ->
    %% e(G1,G2) =/= 1 (non-degeneracy): check returns 0.
    {ok, Out, Gas} = eth_evm_precompiles:precompile(
                       8, <<(pairing_g1())/binary, (pairing_g2())/binary>>, istanbul),
    ?assertEqual(<<0:256>>, Out),
    ?assertEqual(79000, Gas).

pairing_cancel_test() ->
    %% e(G1,G2)*e(G1,-G2) = e(G1, inf) = 1. Bilinearity anchor.
    P = 21888242871839275222246405745257275088696311157297823662689037894645226208583,
    <<Xa:256, Xb:256, Ya:256, Yb:256>> = pairing_g2(),
    NYa = (P - Ya) rem P,
    NYb = (P - Yb) rem P,
    NG2 = <<Xa:256, Xb:256, NYa:256, NYb:256>>,
    In = <<(pairing_g1())/binary, (pairing_g2())/binary,
           (pairing_g1())/binary, NG2/binary>>,
    {ok, Out, Gas} = eth_evm_precompiles:precompile(8, In, istanbul),
    ?assertEqual(<<1:256>>, Out),
    ?assertEqual(113000, Gas).

pairing_bad_g1_test() ->
    %% x = p is not a valid encoding.
    P = 21888242871839275222246405745257275088696311157297823662689037894645226208583,
    Bad = <<P:256, 0:256, (pairing_g2())/binary>>,
    ?assertMatch({failed, {ecpairing, {off_curve_point, 1}}},
                 eth_evm_precompiles:precompile(8, Bad, istanbul)).

pairing_off_curve_g2_test() ->
    %% Flip a Y bit of the generator: on-wire valid, off the twisted curve.
    <<Xa:256, Xb:256, Ya:256, Yb:256>> = pairing_g2(),
    Bad = <<(pairing_g1())/binary, Xa:256, Xb:256, (Ya + 1):256, Yb:256>>,
    ?assertMatch({failed, {ecpairing, {off_curve_point, 1}}},
                 eth_evm_precompiles:precompile(8, Bad, istanbul)).

pairing_recognized_test() ->
    ?assertEqual(true, eth_evm_precompiles:is_precompile(8, ?FORK)).

%% ---------------------------------------------------------------------------
%% The pairing check's *price*, per fork, at the precompile rather than the table
%% ---------------------------------------------------------------------------
%% `eth_pairing_bn128:check_pairing/1` used to return `{ok, Out, 34000*K + 45000}` --
%% EIP-1108's Istanbul column, hard-coded in a module that has no fork and cannot
%% know one. `eth_evm_precompiles:run/3` matched a two-element `{ok, Out}`, so a
%% three-element reply matched nothing and fell through to the catch-all, handing the
%% caller that figure unchanged. Byzantium's pairing check therefore cost 45,000
%% instead of 100,000, and the fork plumbing added in its place was never reached.
%%
%% The test that should have caught it pinned `eth_fork_schedule:bn128_cost/2` at every
%% fork and passed. **Pinning a table is not pinning a caller**, and that is the whole
%% lesson: the table was right, the test was green, and the code that should have read
%% the table was dead. So these are at the precompile.
%%
%% The corpus found it as the largest single divergence it had: two fixtures
%% (`byzantium/eip197_ec_pairing/test_gas_costs`, the `enough_gas_False` cases) where
%% the node spent its whole 1,000,000 gas limit and the chain spent 56,723. The callee
%% forwards `0xafc7` = 44,999 gas to 0x08 with **empty input**, and Istanbul's empty
%% pairing check costs 45,000 -- so the call must fail by **one gas**. Priced at
%% 45,000 by a module that could not know the fork, the Byzantium case failed to fail.

the_pairing_check_is_priced_by_the_fork_and_not_by_its_own_module_test() ->
    %% Empty input, so `k = 0` and the figure is the base alone: 100,000 at
    %% Byzantium, 45,000 from Istanbul.
    [?assertEqual({ok, <<1:256>>, 100000},
                  eth_evm_precompiles:precompile(8, <<>>, F))
     || F <- [byzantium, constantinople, petersburg]],
    [?assertEqual({ok, <<1:256>>, 45000},
                  eth_evm_precompiles:precompile(8, <<>>, F))
     || F <- [istanbul, london, berlin, cancun, prague]],
    %% And the pairing check does not exist before Byzantium at all. I listed
    %% `spurious_dragon' on the Byzantium side first, and it answered `unsupported',
    %% which looked like a bug in the price table and was not: Spurious Dragon is mainnet
    %% block 2,675,000 and Byzantium is 4,370,000, so Spurious Dragon is the earlier of
    %% the two. (5,280,000, which is what I remembered, is Constantinople.) The fork
    %% table's order is right and my recollection of the block numbers was not, which
    %% is the same lesson as the layout, arriving from the other direction.
    [?assertEqual(unsupported, eth_evm_precompiles:precompile(8, <<>>, F))
     || F <- [frontier, homestead, tangerine, spurious_dragon]].

the_pairing_check_adds_eighty_thousand_a_pair_at_byzantium_test() ->
    %% One pair of G1 and G2: the generator, which is on both curves, so the check is
    %% well formed and the difference from the base is exactly the per-pair term.
    One = <<(pairing_g1())/binary, (pairing_g2())/binary>>,
    ?assertEqual(100000 + 80000,
                 element(3, eth_evm_precompiles:precompile(8, One, byzantium))),
    ?assertEqual(45000 + 34000,
                 element(3, eth_evm_precompiles:precompile(8, One, istanbul))).

the_pairing_module_does_not_price_anything_test() ->
    %% The shape, not just the number. A three-element reply is what fell through the
    %% match and bypassed the fork, so the arity is the thing that has to be pinned.
    ?assertEqual({ok, <<1:256>>}, eth_pairing_bn128:check_pairing(<<>>)),
    ?assertEqual(2, tuple_size(eth_pairing_bn128:check_pairing(<<>>))).

ok_out({ok, Out, _Cost}) -> Out.
