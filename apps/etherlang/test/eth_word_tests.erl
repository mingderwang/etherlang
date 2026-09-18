-module(eth_word_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MASK, 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF).

arith_test() ->
    ?assertEqual(5, eth_word:add(2, 3)),
    ?assertEqual(0, eth_word:add(?MASK, 1)),
    ?assertEqual(?MASK, eth_word:sub(0, 1)),
    ?assertEqual(6, eth_word:sub(10, 4)),
    ?assertEqual(?MASK - 1, eth_word:mul(?MASK, 2)).

division_test() ->
    ?assertEqual(2, eth_word:udiv(5, 2)),
    ?assertEqual(0, eth_word:udiv(5, 0)),
    ?assertEqual(1, eth_word:umod(5, 2)),
    ?assertEqual(0, eth_word:umod(5, 0)).

signed_division_test() ->
    ?assertEqual(0, eth_word:sdiv(?MASK, 2)),
    ?assertEqual(1, eth_word:sdiv(?MASK, -1 bsr 0)),
    ?assertEqual(?MASK, eth_word:smod(?MASK, 2)).

modular_test() ->
    ?assertEqual(0, eth_word:addmod(?MASK, 1, 2)),
    ?assertEqual(0, eth_word:mulmod(-1 bsr 0, 50, 10)),
    ?assertEqual(0, eth_word:addmod(1, 2, 0)).

exp_test() ->
    ?assertEqual(1, eth_word:exp(0, 0)),
    ?assertEqual(1024, eth_word:exp(2, 10)),
    ?assertEqual(0, eth_word:exp(2, 256)).

signextend_test() ->
    ?assertEqual(16#7F, eth_word:signextend(0, 16#7F)),
    ?assertEqual(?MASK - 127, eth_word:signextend(0, 16#80)),
    ?assertEqual(?MASK, eth_word:signextend(0, 16#FF)).

comparison_test() ->
    ?assertEqual(1, eth_word:lt(1, 2)),
    ?assertEqual(0, eth_word:gt(1, 2)),
    ?assertEqual(1, eth_word:eq(7, 7)),
    ?assertEqual(1, eth_word:iszero(0)),
    ?assertEqual(1, eth_word:slt(?MASK, 0)),
    ?assertEqual(0, eth_word:sgt(?MASK, 0)).

bitwise_test() ->
    ?assertEqual(2, eth_word:andb(6, 3)),
    ?assertEqual(7, eth_word:orb(6, 3)),
    ?assertEqual(5, eth_word:xorb(6, 3)),
    ?assertEqual(?MASK - 1, eth_word:notb(1)),
    ?assertEqual(2, eth_word:shl(1, 1)),
    ?assertEqual(1, eth_word:shr(2, 1)),
    ?assertEqual(?MASK, eth_word:sar(?MASK, 1)).

byte_test() ->
    ?assertEqual(16#12, eth_word:byte(0, 16#12 bsl 248)),
    ?assertEqual(0, eth_word:byte(1, 16#1200)),
    ?assertEqual(16#12, eth_word:byte(30, 16#1200)),
    ?assertEqual(0, eth_word:byte(32, 16#1200)).

bytes_test() ->
    ?assertEqual(0, eth_word:from_bytes(<<>>)),
    ?assertEqual(256, eth_word:from_bytes(<<1, 0>>)),
    ?assertEqual(<<>>, eth_word:to_bytes(0)),
    ?assertEqual(<<1, 0>>, eth_word:to_bytes(256)),
    ?assertEqual(<<0, 0, 1>>, eth_word:to_bytes(1, 3)).

powmod_test() ->
    ?assertEqual(4, eth_word:powmod(2, 2, 5)),
    ?assertEqual(0, eth_word:powmod(2, 2, 0)),
    ?assertEqual(1, eth_word:powmod(3, 0, 7)).
