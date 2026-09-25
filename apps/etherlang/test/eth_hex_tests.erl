-module(eth_hex_tests).

-include_lib("eunit/include/eunit.hrl").

roundtrip_test() ->
    Nums = [0, 1, 15, 16, 255, 256, 1171152, 16777215, 123456789012345678901234567890,
            2200000000],
    lists:foreach(fun(N) ->
        ?assertEqual(N, eth_hex:decode(eth_hex:encode(N))),
        ?assertEqual(N, eth_hex:decode(eth_hex:encode_int(N)))
    end, Nums).

decode_variants_test() ->
    ?assertEqual(0, eth_hex:decode("0x0")),
    ?assertEqual(0, eth_hex:decode(<<"0x0">>)),
    ?assertEqual(0, eth_hex:decode("0x")),
    ?assertEqual(10, eth_hex:decode("0xa")),
    ?assertEqual(10, eth_hex:decode(<<"0xA">>)),
    ?assertEqual(255, eth_hex:decode(<<"0xff">>)),
    ?assertEqual(255, eth_hex:decode(<<"0xFF">>)),
    ?assertEqual(16#b2d6b7, eth_hex:decode(<<"0xb2d6b7">>)),
    ?assertEqual(42, eth_hex:decode("2a")),
    ?assertEqual(eth_hex:decode(<<"0xdeadbeefdeadbeefdeadbeefdeadbeef">>),
                 eth_hex:decode(<<"0xdeadbeefdeadbeefdeadbeefdeadbeef">>)).

%% Encoding is lowercase, matching the bin0x/1 form that eth_tx emits for byte
%% fields, so a quantity and a data field built by this codebase agree on case.
encode_format_test() ->
    ?assertEqual("0x0", eth_hex:encode(0)),
    ?assertEqual("0x2a", eth_hex:encode(42)),
    ?assertEqual(<<"0x2a">>, eth_hex:encode_int(42)),
    ?assertEqual(<<"0xdeadbeef">>, eth_hex:encode_int(16#deadbeef)),
    ?assertEqual("0x100", eth_hex:encode(256)).

is_hex_test() ->
    ?assert(eth_hex:is_hex(<<"0x1234abcd">>)),
    ?assert(eth_hex:is_hex(<<"0x1234ABCD">>)),
    ?assertNot(eth_hex:is_hex(<<"0x123z">>)),
    ?assertNot(eth_hex:is_hex(<<"0xgg">>)),
    ?assert(eth_hex:is_hex(<<"0x">>)).

bad_hex_test() ->
    ?assertError({badmatch, false}, eth_hex:decode(<<"0xg">>)).