-module(eth_secp256k1_tests).

-include_lib("eunit/include/eunit.hrl").

roundtrip_test() ->
    Priv = eth_secp256k1:generate_key(),
    Digest = crypto:strong_rand_bytes(32),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    ?assert(V =:= 0 orelse V =:= 1),
    ?assertEqual({ok, eth_secp256k1:node_id(Priv)},
                 eth_secp256k1:recover(Digest, R, S, V)).

wrong_digest_test() ->
    Priv = eth_secp256k1:generate_key(),
    Digest = crypto:strong_rand_bytes(32),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    Other = crypto:strong_rand_bytes(32),
    ?assertNotEqual({ok, eth_secp256k1:node_id(Priv)},
                    eth_secp256k1:recover(Other, R, S, V)).

bad_sig_test() ->
    Digest = crypto:strong_rand_bytes(32),
    ?assertEqual({error, bad_sig}, eth_secp256k1:recover(Digest, 0, 1, 0)),
    ?assertEqual({error, bad_sig}, eth_secp256k1:recover(Digest, 1, 0, 1)),
    ?assertEqual({error, bad_sig}, eth_secp256k1:recover(Digest, 1, 1, 2)).
