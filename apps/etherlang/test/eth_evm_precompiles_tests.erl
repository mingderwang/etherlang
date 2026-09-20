-module(eth_evm_precompiles_tests).

-include_lib("eunit/include/eunit.hrl").

%% EIP-198/2565 MODEXP vectors.

modexp_small_test() ->
    %% 3^2 mod 5 = 4; Max=1 -> complexity 1, adjusted(2)=1 -> floor 200.
    Data = <<1:256, 1:256, 1:256, 3:8, 2:8, 5:8>>,
    ?assertEqual({ok, <<4>>, 200}, eth_evm_precompiles:precompile(5, Data)).

modexp_zero_exponent_test() ->
    %% 3^0 mod 5 = 1; adjusted(0) is defined as 0, not -1.
    Data = <<1:256, 1:256, 1:256, 3:8, 0:8, 5:8>>,
    ?assertEqual({ok, <<1>>, 200}, eth_evm_precompiles:precompile(5, Data)).

modexp_gas_counts_exponent_bits_test() ->
    %% 32-byte sizes, exponent 2^255: adjusted = 255, complexity = 1024,
    %% gas = max(200, 1024*255 div 20) = 13056. The old code ignored the
    %% exponent value entirely and charged 200 here.
    E = <<16#80, 0:248>>,
    M = binary:copy(<<16#FF>>, 32),
    Data = <<32:256, 32:256, 32:256, 2:256, E/binary, M/binary>>,
    {ok, Out, Gas} = eth_evm_precompiles:precompile(5, Data),
    ?assertEqual(32, byte_size(Out)),
    ?assertEqual(13056, Gas).

modexp_zero_modulus_test() ->
    %% M = 0 -> empty output (gas still charged per EIP-198).
    Data = <<1:256, 1:256, 1:256, 3:8, 2:8, 0:8>>,
    {ok, Out, Gas} = eth_evm_precompiles:precompile(5, Data),
    ?assertEqual(<<>>, Out),
    ?assertEqual(200, Gas).

modexp_long_exponent_head_bits_test() ->
    %% LenE = 33, leading byte 0x80: E = 2^263, adjusted = 8*1 + 255 = 263.
    %% 3^(2^263) mod 5 = 1 (2^263 = 0 mod 4 = phi(5), exponent > 0).
    %% Max = 1 -> complexity 1 -> gas floor 200 either way; asserts output.
    E = <<16#80, 0:256>>,
    Data = <<1:256, 33:256, 1:256, 3:8, E/binary, 5:8>>,
    ?assertEqual({ok, <<1>>, 200}, eth_evm_precompiles:precompile(5, Data)).

identity_test() ->
    ?assertEqual({ok, <<"abc">>, 15 + 3}, eth_evm_precompiles:precompile(4, <<"abc">>)).

ecrecover_recognized_test() ->
    ?assertEqual(true, eth_evm_precompiles:is_precompile(1)).

%% ECRECOVER vectors recorded live from Sepolia upstream. Failure returns
%% empty output (geth parity), never an error.
ecrecover_valid_test() ->
    In = binary:decode_hex(<<"7a8f2ee29035e823ebcfe3a0427ea15aebed523a6212bfd802221cc78555e465"
                              "000000000000000000000000000000000000000000000000000000000000001b"
                              "a30aeebf19b0dc75fb8e4457cd9069b30051021bd3f6c7bd5603512bc4231842"
                              "99c02cd178b7772ce623c6224c7177c52dfcd733244455d1453c90e0f81a5eb1">>),
    {ok, Out, Gas} = eth_evm_precompiles:precompile(1, In),
    ?assertEqual(binary:decode_hex(<<"00000000000000000000000094d553c07966b312c542034bf66c71bdb929202d">>),
                 Out),
    ?assertEqual(3000, Gas).

ecrecover_valid_v28_test() ->
    In = binary:decode_hex(<<"ff0926163e832beb39e5d040baa5aa9751dac0562ceda41429c919c4b47ea1db"
                              "000000000000000000000000000000000000000000000000000000000000001c"
                              "cc13d8fe87dcd5a9d291dcf94781a2a9a9350e85ad0fc33666072b27c2a249d"
                              "af7421999a698278f99413b1d9f76b858831c000bd753d1a13183df600c1a469f">>),
    {ok, Out, Gas} = eth_evm_precompiles:precompile(1, In),
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
                       1, <<H/binary, 0:256, RS/binary>>),
    ?assertEqual(<<>>, Out),
    ?assertEqual(3000, Gas).

ecrecover_zero_r_test() ->
    {ok, Out, _} = eth_evm_precompiles:precompile(1, binary:copy(<<0>>, 128)),
    ?assertEqual(<<>>, Out).

ecrecover_short_input_test() ->
    %% Short input zero-pads (v field becomes 0 -> invalid -> empty).
    {ok, Out, _} = eth_evm_precompiles:precompile(1, <<1:256>>),
    ?assertEqual(<<>>, Out).

unknown_precompile_test() ->
    ?assertEqual(false, eth_evm_precompiles:is_precompile(10)),
    ?assertEqual(unsupported, eth_evm_precompiles:precompile(10, <<>>)).

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
    {ok, Out, Gas} = eth_evm_precompiles:precompile(9, blake2f_input(0, 1)),
    ?assertEqual(binary:decode_hex(<<"08c9bcf367e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5"
                                      "d282e6ad7f520e511f6c3e2b8c68059b9442be0454267ce079217e1319cde05b">>),
                 Out),
    ?assertEqual(0, Gas).

blake2f_vector5_twelve_rounds_test() ->
    {ok, Out, Gas} = eth_evm_precompiles:precompile(9, blake2f_input(12, 1)),
    ?assertEqual(binary:decode_hex(<<"ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1"
                                      "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923">>),
                 Out),
    ?assertEqual(12, Gas).

blake2f_vector6_unset_final_flag_test() ->
    {ok, Out, Gas} = eth_evm_precompiles:precompile(9, blake2f_input(12, 0)),
    ?assertEqual(binary:decode_hex(<<"75ab69d3190a562c51aef8d88f1c2775876944407270c42c9844252c26d2875298"
                                      "743e7f6d5ea2f2d3e8d226039cd31b4e426ac4f2d3d666a610c2116fde4735">>),
                 Out),
    ?assertEqual(12, Gas).

blake2f_vector7_single_round_test() ->
    {ok, Out, Gas} = eth_evm_precompiles:precompile(9, blake2f_input(1, 1)),
    ?assertEqual(binary:decode_hex(<<"b63a380cb2897d521994a85234ee2c181b5f844d2c624c002677e9703449d2fba55"
                                      "1b3a8333bcdf5f2f7e08993d53923de3d64fcc68c034e717b9293fed7a421">>),
                 Out),
    ?assertEqual(1, Gas).

blake2f_bad_length_test() ->
    ?assertEqual(unsupported, eth_evm_precompiles:precompile(9, <<>>)),
    ?assertEqual(unsupported,
                 eth_evm_precompiles:precompile(9, binary:part(blake2f_input(12, 1), 0, 212))),
    ?assertEqual(unsupported,
                 eth_evm_precompiles:precompile(9, <<(blake2f_input(12, 1))/binary, 0>>)).

blake2f_bad_flag_test() ->
    Good = blake2f_input(12, 1),
    Bad = binary:part(Good, 0, 212),
    ?assertEqual(unsupported, eth_evm_precompiles:precompile(9, <<Bad/binary, 2>>)).

blake2f_recognized_test() ->
    ?assertEqual(true, eth_evm_precompiles:is_precompile(9)).

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
                 eth_evm_precompiles:precompile(6, In)).

ecmul_g1_times_two_test() ->
    In = <<(bn128_u(1))/binary, (bn128_u(2))/binary, (bn128_u(2))/binary>>,
    ?assertEqual({ok, ?BN128_DOUBLE_G1, 6000},
                 eth_evm_precompiles:precompile(7, In)).

ecadd_infinity_identity_test() ->
    Zeros = binary:copy(<<0>>, 128),
    {ok, Out, Gas} = eth_evm_precompiles:precompile(6, Zeros),
    ?assertEqual(binary:copy(<<0>>, 64), Out),
    ?assertEqual(150, Gas).

ecmul_zero_scalar_test() ->
    In = <<(bn128_u(1))/binary, (bn128_u(2))/binary, (bn128_u(0))/binary>>,
    {ok, Out, Gas} = eth_evm_precompiles:precompile(7, In),
    ?assertEqual(binary:copy(<<0>>, 64), Out),
    ?assertEqual(6000, Gas).

ecadd_coordinate_at_field_test() ->
    P = 21888242871839275222246405745257275088696311157297823662689037894645226208583,
    In = <<(bn128_u(P))/binary, (bn128_u(0))/binary,
           (bn128_u(0))/binary, (bn128_u(0))/binary>>,
    ?assertEqual(unsupported, eth_evm_precompiles:precompile(6, In)).

ecadd_off_curve_test() ->
    %% (2,2): 4 =/= 11 mod p.
    In = <<(bn128_u(2))/binary, (bn128_u(2))/binary,
           (bn128_u(0))/binary, (bn128_u(0))/binary>>,
    ?assertEqual(unsupported, eth_evm_precompiles:precompile(6, In)).

ecmul_short_input_padded_test() ->
    %% 64 bytes (no scalar): zero-padded scalar 0 -> infinity.
    In = <<(bn128_u(1))/binary, (bn128_u(2))/binary>>,
    {ok, Out, _} = eth_evm_precompiles:precompile(7, In),
    ?assertEqual(binary:copy(<<0>>, 64), Out).

ecadd_recognized_test() ->
    ?assertEqual(true, eth_evm_precompiles:is_precompile(6)),
    ?assertEqual(true, eth_evm_precompiles:is_precompile(7)).

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
                 eth_evm_precompiles:precompile(8, <<>>)).

pairing_bad_length_test() ->
    ?assertEqual(unsupported,
                 eth_evm_precompiles:precompile(8, binary:copy(<<0>>, 191))),
    ?assertEqual(unsupported,
                 eth_evm_precompiles:precompile(8, binary:copy(<<0>>, 193))).

pairing_single_nondegenerate_test() ->
    %% e(G1,G2) =/= 1 (non-degeneracy): check returns 0.
    {ok, Out, Gas} = eth_evm_precompiles:precompile(
                       8, <<(pairing_g1())/binary, (pairing_g2())/binary>>),
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
    {ok, Out, Gas} = eth_evm_precompiles:precompile(8, In),
    ?assertEqual(<<1:256>>, Out),
    ?assertEqual(113000, Gas).

pairing_bad_g1_test() ->
    %% x = p is not a valid encoding.
    P = 21888242871839275222246405745257275088696311157297823662689037894645226208583,
    Bad = <<P:256, 0:256, (pairing_g2())/binary>>,
    ?assertEqual(unsupported, eth_evm_precompiles:precompile(8, Bad)).

pairing_off_curve_g2_test() ->
    %% Flip a Y bit of the generator: on-wire valid, off the twisted curve.
    <<Xa:256, Xb:256, Ya:256, Yb:256>> = pairing_g2(),
    Bad = <<(pairing_g1())/binary, Xa:256, Xb:256, (Ya + 1):256, Yb:256>>,
    ?assertEqual(unsupported, eth_evm_precompiles:precompile(8, Bad)).

pairing_recognized_test() ->
    ?assertEqual(true, eth_evm_precompiles:is_precompile(8)).
