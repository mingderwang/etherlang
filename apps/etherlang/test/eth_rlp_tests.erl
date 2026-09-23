-module(eth_rlp_tests).

-include_lib("eunit/include/eunit.hrl").

%% Canonical RLP examples.
scalar_test() ->
    ?assertEqual(<<16#80>>, eth_rlp:encode(0)),
    ?assertEqual(<<16#0F>>, eth_rlp:encode(15)),
    ?assertEqual(<<16#82, 16#04, 16#00>>, eth_rlp:encode(1024)),
    ?assertEqual(<<16#80>>, eth_rlp:encode(<<>>)),
    ?assertEqual(<<16#C0>>, eth_rlp:encode([])).

string_test() ->
    ?assertEqual(<<16#83, $d, $o, $g>>, eth_rlp:encode(<<"dog">>)),
    %% single byte < 0x80 is its own encoding
    ?assertEqual(<<$a>>, eth_rlp:encode(<<"a">>)),
    %% single byte >= 0x80 needs the short-string prefix
    ?assertEqual(<<16#81, 16#80>>, eth_rlp:encode(<<16#80>>)).

list_test() ->
    ?assertEqual(<<16#C8, 16#83, "cat", 16#83, "dog">>,
                 eth_rlp:encode([<<"cat">>, <<"dog">>])),
    ?assertEqual(<<16#C0>>, eth_rlp:encode([])).

long_string_test() ->
    S = binary:copy(<<"x">>, 56),
    Enc = eth_rlp:encode(S),
    ?assertEqual(<<16#B8, 56, S/binary>>, Enc),
    L = binary:copy(<<"y">>, 300),
    <<16#B9, Len:16, _/binary>> = eth_rlp:encode(L),
    ?assertEqual(300, Len).

decode_test() ->
    ?assertEqual({ok, <<15>>, <<>>}, eth_rlp:decode(<<16#0F>>)),
    ?assertEqual({ok, <<>>, <<>>}, eth_rlp:decode(<<16#80>>)),
    ?assertEqual({ok, <<"dog">>, <<>>}, eth_rlp:decode(<<16#83, $d, $o, $g>>)),
    ?assertEqual({ok, [<<"cat">>, <<"dog">>], <<>>},
                 eth_rlp:decode(<<16#C8, 16#83, "cat", 16#83, "dog">>)),
    ?assertEqual({ok, [], <<>>}, eth_rlp:decode(<<16#C0>>)),
    ?assertEqual({error, empty}, eth_rlp:decode(<<>>)),
    ?assertEqual({error, truncated}, eth_rlp:decode(<<16#83, $d, $o>>)).

roundtrip_test() ->
    Terms = [0, 15, 1024, <<"dog">>, <<>>, [],
             [<<"cat">>, <<"dog">>],
             [binary:copy(<<"x">>, 100), [1, 2, [3]]]],
    lists:foreach(fun(T) ->
        Enc = eth_rlp:encode(T),
        {ok, Back, <<>>} = eth_rlp:decode(Enc),
        %% integers decode as minimal big-endian binaries
        Expected = normalize(T),
        ?assertEqual(Expected, Back)
    end, Terms).

normalize(0) -> <<>>;
normalize(I) when is_integer(I) -> binary:encode_unsigned(I);
normalize(B) when is_binary(B) -> B;
normalize([]) -> [];
normalize(L) when is_list(L) -> [normalize(E) || E <- L].
