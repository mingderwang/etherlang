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

ecrecover_unsupported_test() ->
    ?assertEqual(unsupported, eth_evm_precompiles:precompile(1, <<>>)).

unknown_precompile_test() ->
    ?assertEqual(false, eth_evm_precompiles:is_precompile(6)),
    ?assertEqual(unsupported, eth_evm_precompiles:precompile(6, <<>>)).
