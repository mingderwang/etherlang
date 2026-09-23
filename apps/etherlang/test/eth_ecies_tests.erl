-module(eth_ecies_tests).

-include_lib("eunit/include/eunit.hrl").

roundtrip_test() ->
    Priv = eth_secp256k1:generate_key(),
    ID = eth_ecies:pubkey(Priv),
    Msg = crypto:strong_rand_bytes(200),
    Auth = <<0, 113>>,
    Pkt = eth_ecies:encrypt(ID, Msg, Auth),
    ?assertEqual({ok, Msg}, eth_ecies:decrypt(Priv, Pkt, Auth)).

wrong_key_test() ->
    Priv = eth_secp256k1:generate_key(),
    Other = eth_secp256k1:generate_key(),
    ID = eth_ecies:pubkey(Priv),
    Pkt = eth_ecies:encrypt(ID, <<"hello">>, <<>>),
    ?assertMatch({error, _}, eth_ecies:decrypt(Other, Pkt, <<>>)).

wrong_authdata_test() ->
    Priv = eth_secp256k1:generate_key(),
    ID = eth_ecies:pubkey(Priv),
    Pkt = eth_ecies:encrypt(ID, <<"hello">>, <<"a">>),
    ?assertEqual({error, bad_tag}, eth_ecies:decrypt(Priv, Pkt, <<"b">>)).

tamper_test() ->
    Priv = eth_secp256k1:generate_key(),
    ID = eth_ecies:pubkey(Priv),
    Pkt = eth_ecies:encrypt(ID, <<"hello world">>, <<>>),
    Last = binary:at(Pkt, byte_size(Pkt) - 1) bxor 16#01,
    Bad = <<(binary:part(Pkt, 0, byte_size(Pkt) - 1))/binary, Last>>,
    ?assertEqual({error, bad_tag}, eth_ecies:decrypt(Priv, Bad, <<>>)),
    ?assertEqual({error, bad_packet}, eth_ecies:decrypt(Priv, <<1, 2, 3>>, <<>>)).

ecdh_symmetry_test() ->
    A = eth_secp256k1:generate_key(),
    B = eth_secp256k1:generate_key(),
    {PubA65, _} = crypto:generate_key(ecdh, secp256k1, A),
    {PubB65, _} = crypto:generate_key(ecdh, secp256k1, B),
    ?assertEqual(eth_ecies:ecdh(A, PubB65), eth_ecies:ecdh(B, PubA65)).
