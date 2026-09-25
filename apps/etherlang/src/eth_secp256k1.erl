-module(eth_secp256k1).

%% Minimal secp256k1 for devp2p discovery: ECDSA sign and public-key
%% recovery from (digest, R, S, V). Pure Erlang; only used on the low-rate
%% discovery packet path, not in block sync.

-export([generate_key/0, node_id/1, sign/2, recover/4]).

-define(P, 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F).
-define(N, 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141).
-define(GX, 16#79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798).
-define(GY, 16#483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8).

%% Fresh private key as a 32-byte binary, in [1, N-1].
generate_key() ->
    K = crypto:strong_rand_bytes(32),
    case binary:decode_unsigned(K) of
        I when I > 0, I < ?N -> K;
        _ -> generate_key()
    end.

%% 64-byte node id (x || y) for a private key.
node_id(Priv) when byte_size(Priv) =:= 32 ->
    {Pub65, _} = crypto:generate_key(ecdh, secp256k1, Priv),
    <<16#04, ID:64/binary>> = Pub65,
    ID.

%% Sign a 32-byte digest. Returns {R, S, V} with V in {0, 1} (raw recovery
%% id, as used by discv4 packet signatures).
%%
%% The OpenSSL backend makes no promise about which half of the s range it
%% emits, so the result is canonicalized to a *low-s* signature as EIP-2
%% requires. Negating s maps the signature onto the point (R, -s) rather than
%% (R, s), which flips the parity of the recovery id; without flipping the
%% parity alongside it the recovered address would not match the signer.
sign(Digest, Priv) when byte_size(Digest) =:= 32, byte_size(Priv) =:= 32 ->
    DER = crypto:sign(ecdsa, sha256, {digest, Digest}, [Priv, secp256k1]),
    {R0, S0} = der_rs(Digest, DER),
    {R, S, V0} =
        case [V || V <- [0, 1], recover(Digest, R0, S0, V) =:= {ok, node_id(Priv)}] of
            [V | _] -> {R0, S0, V};
            [] -> error(bad_recovery)
        end,
    case S > ?N div 2 of
        true -> {R, ?N - S, 1 - V0};
        false -> {R, S, V0}
    end.

%% Recover the 64-byte node id from a signature over a 32-byte digest.
recover(Digest, R, S, V)
  when byte_size(Digest) =:= 32, is_integer(R), is_integer(S), (V =:= 0 orelse V =:= 1) ->
    N = ?N,
    case R < 1 orelse R >= N orelse S < 1 orelse S >= N of
        true ->
            {error, bad_sig};
        false ->
            X = R + (V bsr 1) * N,
            case X < ?P of
                false ->
                    {error, bad_point};
                true ->
                    case decompress(X, V band 1) of
                        {ok, RPt} ->
                            D = binary:decode_unsigned(Digest),
                            RInv = mod_inv(R, N),
                            U1 = mod(-(D rem N) * RInv, N),
                            U2 = mod(S * RInv, N),
                            case padd(pmul(U1, {?GX, ?GY}), pmul(U2, RPt)) of
                                infinity -> {error, bad_point};
                                {Qx, Qy} -> {ok, <<Qx:256, Qy:256>>}
                            end;
                        {error, _} = E ->
                            E
                    end
            end
    end;
recover(_, _, _, _) ->
    {error, bad_sig}.

%% ---------------------------------------------------------------------------
%% Internals
%% ---------------------------------------------------------------------------

der_rs(Digest, <<16#30, _Len, 16#02, RL, R:RL/binary, 16#02, SL, S:SL/binary>>) ->
    _ = Digest,
    {binary:decode_unsigned(R), binary:decode_unsigned(S)};
der_rs(_, _) ->
    error(bad_der).

decompress(X, Odd) ->
    Y0 = mod_pow(X * X rem ?P * X rem ?P + 7, (?P + 1) div 4, ?P),
    case (Y0 * Y0) rem ?P =:= (X * X rem ?P * X rem ?P + 7) rem ?P of
        false ->
            {error, bad_point};
        true ->
            case Y0 rem 2 =:= Odd of
                true -> {ok, {X, Y0}};
                false -> {ok, {X, ?P - Y0}}
            end
    end.

mod(A, M) ->
    ((A rem M) + M) rem M.

mod_inv(A, M) ->
    mod_pow(A rem M, M - 2, M).

mod_pow(A, E, M) ->
    binary:decode_unsigned(
      crypto:mod_pow(binary:encode_unsigned(A), binary:encode_unsigned(E),
                     binary:encode_unsigned(M))).

padd(infinity, P) -> P;
padd(P, infinity) -> P;
padd({X1, Y1}, {X2, Y2}) when X1 =:= X2, Y1 =:= Y2 -> pdbl({X1, Y1});
padd({_X1, _Y1}, {_X2, _Y2} = Q) ->
    {X1, Y1} = {_X1, _Y1},
    {X2, Y2} = Q,
    case mod(X2 - X1, ?P) of
        0 ->
            infinity;
        Dx ->
            L = mod((mod(Y2 - Y1, ?P)) * mod_inv(Dx, ?P), ?P),
            X3 = mod(L * L - X1 - X2, ?P),
            {X3, mod(L * (X1 - X3) - Y1, ?P)}
    end.

pdbl(infinity) -> infinity;
pdbl({X, Y}) ->
    case mod(2 * Y, ?P) of
        0 ->
            infinity;
        Dy ->
            L = mod(3 * X * X * mod_inv(Dy, ?P), ?P),
            X2 = mod(L * L - 2 * X, ?P),
            {X2, mod(L * (X - X2) - Y, ?P)}
    end.

pmul(0, _) -> infinity;
pmul(K, Pt) when K > 0 -> pmul(K, Pt, infinity).

pmul(0, _, Acc) -> Acc;
pmul(K, Pt, Acc) ->
    Acc1 = case K band 1 of
               1 -> padd(Acc, Pt);
               0 -> Acc
           end,
    pmul(K bsr 1, pdbl(Pt), Acc1).
