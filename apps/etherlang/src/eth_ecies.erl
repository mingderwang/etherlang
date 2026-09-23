-module(eth_ecies).

%% ECIES as used by the RLPx handshake (secp256k1, NIST concat-KDF-SHA256,
%% AES-128-CTR, HMAC-SHA256 tag). Wire format: R(65) || iv(16) || c || d(32).
%%
%% Also exposes the raw ECDH x-coordinate used for the handshake's static
%% and ephemeral shared secrets (KDF output, 32 bytes, matching geth's
%% GenerateShared(pub, 16, 16)).

-export([encrypt/3, decrypt/3, ecdh/2, pubkey/1]).

-define(OVERHEAD, 113).

%% Encrypt Msg for the holder of the 64-byte node id RemoteID.
%% AuthData is covered by the tag but not transmitted (the 2-byte handshake
%% size prefix in RLPx).
encrypt(RemoteID, Msg, AuthData)
  when byte_size(RemoteID) =:= 64, is_binary(Msg), is_binary(AuthData) ->
    {R65, RPriv} = ephemeral(),
    S = ecdh_raw(RPriv, <<16#04, RemoteID/binary>>),
    {KE, KMAC} = kdf_keys(S),
    IV = crypto:strong_rand_bytes(16),
    C = crypto:crypto_one_time(aes_128_ctr, KE, IV, Msg, true),
    D = tag(KMAC, AuthData, IV, C),
    <<R65/binary, IV/binary, C/binary, D/binary>>.

%% Decrypt a packet with our 32-byte static private key.
decrypt(Priv, Packet, AuthData)
  when byte_size(Priv) =:= 32, is_binary(AuthData) ->
    case Packet of
        <<R:65/binary, IV:16/binary, Rest/binary>> when byte_size(Rest) >= 32 ->
            CSize = byte_size(Rest) - 32,
            <<C:CSize/binary, D:32/binary>> = Rest,
            case ecdh_catch(Priv, R) of
                {ok, S} ->
                    {KE, KMAC} = kdf_keys(S),
                    case hash_equals(D, tag(KMAC, AuthData, IV, C)) of
                        true ->
                            {ok, crypto:crypto_one_time(aes_128_ctr, KE, IV, C, false)};
                        false ->
                            {error, bad_tag}
                    end;
                {error, _} = E ->
                    E
            end;
        _ ->
            {error, bad_packet}
    end.

%% 32-byte shared secret between our Priv and a 65-byte uncompressed peer
%% public key (KDF output, for handshake secret derivation).
ecdh(Priv, Pub65) when byte_size(Priv) =:= 32, byte_size(Pub65) =:= 65 ->
    {ok, S} = ecdh_catch(Priv, Pub65),
    kdf(S, 32).

%% 64-byte node id for a private key.
pubkey(Priv) when byte_size(Priv) =:= 32 ->
    {Pub65, _} = crypto:generate_key(ecdh, secp256k1, Priv),
    <<16#04, ID:64/binary>> = Pub65,
    ID.

%% ---------------------------------------------------------------------------
%% Internals
%% ---------------------------------------------------------------------------

ephemeral() ->
    crypto:generate_key(ecdh, secp256k1).

ecdh_raw(Priv, Pub65) ->
    X = crypto:compute_key(ecdh, Pub65, Priv, secp256k1),
    pad32(X).

ecdh_catch(Priv, Pub65) ->
    try {ok, ecdh_raw(Priv, Pub65)}
    catch _:_ -> {error, bad_key}
    end.

pad32(X) when byte_size(X) =:= 32 -> X;
pad32(X) when byte_size(X) < 32 ->
    Pad = 32 - byte_size(X),
    <<0:(Pad * 8), X/binary>>.

%% kE (16) || sha256(kM) input split: KDF(S, 32), first half for AES,
%% sha256 of second half as HMAC key.
kdf_keys(S) ->
    <<KE:16/binary, KM:16/binary>> = kdf(S, 32),
    {KE, crypto:hash(sha256, KM)}.

%% NIST SP 800-56A concatenation KDF with SHA-256, empty OtherInfo.
kdf(S, Len) ->
    kdf(S, Len, 1, <<>>).

kdf(_S, Len, _Ctr, Acc) when byte_size(Acc) >= Len ->
    binary:part(Acc, 0, Len);
kdf(S, Len, Ctr, Acc) ->
    H = crypto:hash(sha256, <<Ctr:32/big, S/binary>>),
    kdf(S, Len, Ctr + 1, <<Acc/binary, H/binary>>).

tag(KMAC, AuthData, IV, C) ->
    crypto:mac(hmac, sha256, KMAC, [AuthData, IV, C]).

hash_equals(A, B) ->
    try crypto:hash_equals(A, B)
    catch _:_ -> A =:= B
    end.
