-module(eth_snappy_tests).

-include_lib("eunit/include/eunit.hrl").

roundtrip_test() ->
    Msgs = [<<>>, <<"a">>, <<"hello world">>, binary:copy(<<"x">>, 100),
            binary:copy(<<"abcdef">>, 1000), crypto:strong_rand_bytes(5000)],
    lists:foreach(fun(M) ->
        {ok, M} = eth_snappy:decompress(eth_snappy:compress(M))
    end, Msgs).

copy_token_test() ->
    %% Hand-crafted stream: length 4, literal 'a', 2-byte-offset copy
    %% of length 3 with offset 1.
    ?assertEqual({ok, <<"aaaa">>},
                 eth_snappy:decompress(<<4, 0, $a, 10, 1, 0>>)).

reject_test() ->
    ?assertEqual({error, bad_length}, eth_snappy:decompress(<<>>)),
    ?assertEqual({error, truncated}, eth_snappy:decompress(<<5, 0>>)),
    ?assertEqual({error, length_mismatch},
                 eth_snappy:decompress(<<5, 0, $a>>)),
    ?assertEqual({error, bad_copy},
                 eth_snappy:decompress(<<4, 0, $a, 1, 2>>)).

keccak_incremental_test() ->
    %% Incremental absorb matches one-shot and the known empty-string vector
    %% (also pinned in eth_keccak_tests).
    Empty = binary:decode_hex(
              <<"c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470">>),
    ?assertEqual(Empty, eth_keccak:hash(<<>>)),
    ?assertEqual(Empty, eth_keccak:digest(eth_keccak:init())),
    Data = crypto:strong_rand_bytes(500),
    <<A:200/binary, B/binary>> = Data,
    S0 = eth_keccak:init(),
    S1 = eth_keccak:update(S0, A),
    %% digest does not consume: further updates continue correctly.
    _ = eth_keccak:digest(S1),
    S2 = eth_keccak:update(S1, B),
    ?assertEqual(eth_keccak:hash(Data), eth_keccak:digest(S2)).
