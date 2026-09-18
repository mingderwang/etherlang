-module(eth_keccak_tests).

-include_lib("eunit/include/eunit.hrl").

lower_hex(Bin) -> string:lowercase(binary_to_list(binary:encode_hex(Bin))).

hash_test() ->
    ?assertEqual("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
                 lower_hex(eth_keccak:hash(<<>>))),
    ?assertEqual("4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45",
                 lower_hex(eth_keccak:hash(<<"abc">>))),
    ?assertEqual("4d741b6f1eb29cb2a9b9911c82f56fa8d73b04959d3d9d222895df6c0b28aa15",
                 lower_hex(eth_keccak:hash(
                             <<"The quick brown fox jumps over the lazy dog">>))).

%% 136-byte rate boundary: a full block and one extra byte.
rate_boundary_test() ->
    A = eth_keccak:hash(binary:copy(<<0>>, 135)),
    B = eth_keccak:hash(binary:copy(<<0>>, 136)),
    C = eth_keccak:hash(binary:copy(<<0>>, 137)),
    ?assertEqual(32, byte_size(A)),
    ?assertNotEqual(A, B),
    ?assertNotEqual(B, C),
    %% deterministic
    ?assertEqual(C, eth_keccak:hash(binary:copy(<<0>>, 137))).
