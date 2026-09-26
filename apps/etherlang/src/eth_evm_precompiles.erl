-module(eth_evm_precompiles).

%% EVM precompiled contracts. Implemented: 0x01 ECRECOVER, 0x02 SHA256,
%% 0x03 RIPEMD160, 0x04 IDENTITY, 0x05 MODEXP, 0x06 ECADD, 0x07 ECMUL,
%% 0x08 ECPAIRING (Tate, pure Erlang), 0x09 BLAKE2b-F (EIP-152).
%% 0x0A is EIP-4844's point evaluation, which eth_kzg implements against
%% BLS12-381 and the real trusted setup.

-export([precompile/2, is_precompile/1]).

is_precompile(1) -> true;
is_precompile(2) -> true;
is_precompile(3) -> true;
is_precompile(4) -> true;
is_precompile(5) -> true;
is_precompile(6) -> true;
is_precompile(7) -> true;
is_precompile(8) -> true;
is_precompile(9) -> true;
is_precompile(10) -> true;
is_precompile(_) -> false.

%% -> {ok, Output, GasCost} | unsupported
precompile(1, Data) ->
    ecrecover(Data);
precompile(2, Data) ->
    {ok, crypto:hash(sha256, Data), 60 + 12 * words(Data)};
precompile(3, Data) ->
    Hash = crypto:hash(ripemd160, Data),
    {ok, <<0:96, Hash/binary>>, 600 + 120 * words(Data)};
precompile(4, Data) ->
    {ok, Data, 15 + 3 * words(Data)};
precompile(5, Data) ->
    modexp(Data);
precompile(6, Data) ->
    bn128_add(Data);
precompile(7, Data) ->
    bn128_mul(Data);
precompile(8, Data) ->
    eth_pairing_bn128:check_pairing(Data);
precompile(9, Data) ->
    blake2f(Data);
precompile(10, Data) ->
    point_evaluation(Data);
precompile(_, _) ->
    unsupported.

%% EIP-4844: 50000 gas, and the success output is FIELD_ELEMENTS_PER_BLOB
%% followed by BLS_MODULUS, each a 32-byte big-endian integer.
%%
%% The distinction from `unsupported' is the whole point of this clause.
%% `unsupported' means "this node cannot run this, ask someone else", and
%% eth_call turns it into an upstream fallback. A point evaluation that fails is
%% not that: the input is invalid, the answer is a hard failure that consumes the
%% frame's gas, and falling back would substitute another node's verdict for this
%% one's. So a failure is reported as {error, {kzg, _}} and the EVM halts.
%%
%% The reason is deliberately not carried through from eth_kzg, which collapses
%% every failure mode to a bare `unsupported'. Each of those modes has its own
%% fixture in eth_kzg_tests -- short input, out-of-range z or y, a versioned hash
%% that does not match the commitment, a point not on the curve, a point not in
%% the subgroup, and a proof that does not verify -- so they are pinned there,
%% where the input that caused each one is visible. What the precompile needs to
%% know is only whether the evaluation succeeded.
point_evaluation(Data) ->
    case eth_kzg:point_evaluation(Data) of
        {ok, Out, Cost} -> {ok, Out, Cost};
        unsupported -> {error, {kzg, point_evaluation_failed}}
    end.

words(<<>>) -> 0;
words(Bin) -> (byte_size(Bin) + 31) div 32.

%% EIP-198: [lenB | lenE | lenM | B | E | M], result is B^E mod M zero-padded
%% to lenM bytes.
modexp(Data) ->
    case split_header(Data) of
        {ok, LenB, LenE, LenM, Rest} ->
            Total = LenB + LenE + LenM,
            case byte_size(Rest) >= Total of
                true ->
                    B = eth_word:from_bytes(slice(Rest, 0, LenB)),
                    E = eth_word:from_bytes(slice(Rest, LenB, LenE)),
                    M = eth_word:from_bytes(slice(Rest, LenB + LenE, LenM)),
                    Out = case M of
                              0 -> <<>>;
                              _ -> eth_word:to_bytes(eth_word:powmod(B, E, M), LenM)
                          end,
                    {ok, Out, modexp_gas(LenB, LenE, LenM, E)};
                false ->
                    {ok, <<>>, modexp_gas(LenB, LenE, LenM, 0)}
            end;
        error ->
            {ok, <<>>, 0}
    end.

split_header(Data) when byte_size(Data) < 96 ->
    {ok, 0, 0, 0, Data};
split_header(Data) ->
    <<LenB:256, LenE:256, LenM:256, Rest/binary>> = Data,
    {ok, LenB, LenE, LenM, Rest}.

slice(Bin, Off, Len) ->
    case byte_size(Bin) >= Off + Len of
        true -> binary:part(Bin, Off, Len);
        false -> binary:part(Bin, Off, max(0, byte_size(Bin) - Off))
    end.

modexp_gas(LenB, LenE, LenM, E) ->
    Max = max(LenB, LenM),
    Complexity = mult_complexity(Max),
    Adjusted = adjusted_exp_len(LenE, E),
    max(200, Complexity * max(Adjusted, 1) div 20).

mult_complexity(X) when X =< 64 -> X * X;
mult_complexity(X) when X =< 1024 -> X * X div 4 + 96 * X - 3072;
mult_complexity(X) -> X * X div 16 + 480 * X - 199680.

adjusted_exp_len(LenE, E) when LenE =< 32 ->
    %% EIP-198: index of the highest bit (1->0, 2->1, 255->7, 256->8),
    %% defined as 0 when the exponent is all zeros.
    case E of
        0 -> 0;
        _ -> bit_length(E) - 1
    end;
adjusted_exp_len(LenE, E) ->
    %% EIP-198: 8*(LenE-32) plus the bit index within the leading 32 bytes.
    Head = E bsr (8 * (LenE - 32)),
    8 * (LenE - 32) + max(bit_length(Head) - 1, 0).

bit_length(0) -> 0;
bit_length(N) when N > 0 -> bit_length(N, 0).
bit_length(0, Acc) -> Acc;
bit_length(N, Acc) -> bit_length(N bsr 1, Acc + 1).

%% ---------------------------------------------------------------------------
%% EIP-152 BLAKE2b-F compression function.
%% Input (exactly 213 bytes): rounds u32BE | h 8x u64LE | m 16x u64LE |
%% t0 u64LE | t1 u64LE | f u8 (0/1, else invalid). Gas = 1 per round.
%% Malformed input returns unsupported so the caller proxies upstream and
%% surfaces the canonical error.
%% ---------------------------------------------------------------------------

-define(BLAKE_MASK, 16#FFFFFFFFFFFFFFFF).
-define(BLAKE_IV, [16#6A09E667F3BCC908, 16#BB67AE8584CAA73B,
                   16#3C6EF372FE94F82B, 16#A54FF53A5F1D36F1,
                   16#510E527FADE682D1, 16#9B05688C2B3E6C1F,
                   16#1F83D9ABFB41BD6B, 16#5BE0CD19137E2179]).
-define(BLAKE_SIGMA,
        [[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],
         [14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3],
         [11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4],
         [7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8],
         [9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13],
         [2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9],
         [12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11],
         [13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10],
         [6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5],
         [10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0]]).

blake2f(Data) when byte_size(Data) =:= 213 ->
    <<Rounds:32, Rest/binary>> = Data,
    <<HBin:64/binary, MBin:128/binary, T0:64/little, T1:64/little, F:8,
      _/binary>> = Rest,
    case F of
        0 -> blake2f_run(Rounds, HBin, MBin, T0, T1, false);
        1 -> blake2f_run(Rounds, HBin, MBin, T0, T1, true);
        _ -> unsupported
    end;
blake2f(_) ->
    unsupported.

blake2f_run(Rounds, HBin, MBin, T0, T1, Final) ->
    H = [W || <<W:64/little>> <= HBin],
    M = [W || <<W:64/little>> <= MBin],
    V0 = blake2f_init(H, T0, T1, Final),
    V = blake2f_rounds(Rounds, V0, M, 0),
    Out = [blake2f_word(Hi, Vi, Vi8) || {Hi, Vi, Vi8} <- blake2f_zip3(H, V)],
    {ok, list_to_binary([<<W:64/little>> || W <- Out]), Rounds}.

blake2f_zip3(H, V) ->
    [{Hi, Vi, Vi8} || {{Hi, Vi}, Vi8} <- lists:zip(lists:zip(H, lists:sublist(V, 8)),
                                                   lists:sublist(V, 9, 8))].

blake2f_word(Hi, Vi, Vi8) -> (Hi bxor Vi bxor Vi8) band ?BLAKE_MASK.

blake2f_init(H, T0, T1, Final) ->
    [H0, H1, H2, H3, H4, H5, H6, H7] = H,
    [I0, I1, I2, I3, I4, I5, I6, I7] = ?BLAKE_IV,
    V12 = T0 bxor I4,
    V13 = T1 bxor I5,
    V14 = case Final of
              true -> I6 bxor ?BLAKE_MASK;
              false -> I6
          end,
    [H0, H1, H2, H3, H4, H5, H6, H7, I0, I1, I2, I3, V12, V13, V14, I7].

blake2f_rounds(0, V, _M, _R) -> V;
blake2f_rounds(N, V, M, R) ->
    S = lists:nth((R rem 10) + 1, ?BLAKE_SIGMA),
    blake2f_rounds(N - 1, blake2f_round(V, M, S), M, R + 1).

blake2f_round(V, M, S) ->
    [V0, V1, V2, V3, V4, V5, V6, V7, V8, V9, V10, V11, V12, V13, V14, V15] = V,
    [S0, S1, S2, S3, S4, S5, S6, S7, S8, S9, S10, S11, S12, S13, S14, S15] = S,
    {A0, B0, C0, D0} = blake2f_g(V0, V4, V8, V12,
                                 lists:nth(S0 + 1, M), lists:nth(S1 + 1, M)),
    {A1, B1, C1, D1} = blake2f_g(V1, V5, V9, V13,
                                 lists:nth(S2 + 1, M), lists:nth(S3 + 1, M)),
    {A2, B2, C2, D2} = blake2f_g(V2, V6, V10, V14,
                                 lists:nth(S4 + 1, M), lists:nth(S5 + 1, M)),
    {A3, B3, C3, D3} = blake2f_g(V3, V7, V11, V15,
                                 lists:nth(S6 + 1, M), lists:nth(S7 + 1, M)),
    {E0, E1, E2, E3} = blake2f_g(A0, B1, C2, D3,
                                 lists:nth(S8 + 1, M), lists:nth(S9 + 1, M)),
    {E4, E5, E6, E7} = blake2f_g(A1, B2, C3, D0,
                                 lists:nth(S10 + 1, M), lists:nth(S11 + 1, M)),
    {E8, E9, E10, E11} = blake2f_g(A2, B3, C0, D1,
                                   lists:nth(S12 + 1, M), lists:nth(S13 + 1, M)),
    {E12, E13, E14, E15} = blake2f_g(A3, B0, C1, D2,
                                     lists:nth(S14 + 1, M), lists:nth(S15 + 1, M)),
    [E0, E4, E8, E12, E13, E1, E5, E9, E10, E14, E2, E6, E7, E11, E15, E3].

blake2f_g(A, B, C, D, X, Y) ->
    M = ?BLAKE_MASK,
    A1 = (A + B + X) band M,
    D1 = blake2f_rotr(D bxor A1, 32),
    C1 = (C + D1) band M,
    B1 = blake2f_rotr(B bxor C1, 24),
    A2 = (A1 + B1 + Y) band M,
    D2 = blake2f_rotr(D1 bxor A2, 16),
    C2 = (C1 + D2) band M,
    B2 = blake2f_rotr(B1 bxor C2, 63),
    {A2, B2, C2, D2}.

blake2f_rotr(X, N) ->
    ((X bsr N) bor (X bsl (64 - N))) band ?BLAKE_MASK.

%% ---------------------------------------------------------------------------
%% ECRECOVER (0x01, gas 3000). Input: hash(32) | v(32) | r(32) | s(32)
%% (short input zero-padded, surplus ignored). Returns 32 bytes: 12 zero
%% bytes + recovered address, or 32 zero bytes on any invalid input
%% (bad v, r/s out of [1,N-1], non-residue x). Never errors: callers get a
%% honest zero address exactly like upstream.
%% ---------------------------------------------------------------------------

-define(SECP_P, 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F).
-define(SECP_N, 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141).
-define(SECP_GX, 16#79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798).
-define(SECP_GY, 16#483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8).

ecrecover(Data) ->
    <<H:256, V:256, R:256, S:256, _/binary>> = secp_pad(Data, 128),
    {ok, secp_recover(H, V, R, S), 3000}.

secp_pad(Data, N) when byte_size(Data) >= N -> Data;
secp_pad(Data, N) ->
    Pad = N - byte_size(Data),
    <<Data/binary, 0:(Pad * 8)>>.

secp_recover(H, V, R, S) ->
    N = ?SECP_N,
    P = ?SECP_P,
    case V =:= 27 orelse V =:= 28 of
        false -> <<>>;
        true ->
            case R >= 1 andalso R < N andalso S >= 1 andalso S < N of
                false -> <<>>;
                true ->
                    %% Decompress R: y^2 = x^3 + 7, parity from v.
                    Y2 = (secp_pow(R, 3, P) + 7) rem P,
                    case secp_sqrt(Y2) of
                        error -> <<>>;
                        Y0 ->
                            Y = case (Y0 band 1) =:= (V - 27) of
                                    true -> Y0;
                                    false -> P - Y0
                                end,
                            RPt = {R, Y},
                            case secp_on_curve(RPt) of
                                false -> <<>>;
                                true ->
                                    %% Q = r^-1 * (s*R - e*G).
                                    RInv = secp_inv(R, N),
                                    E = H rem N,
                                    SR = secp_mul_point(RPt, S),
                                    EG = secp_mul_point({?SECP_GX, ?SECP_GY}, E),
                                    Diff = secp_add_points(SR, secp_neg_point(EG)),
                                    case secp_mul_point(Diff, RInv) of
                                        infinity -> <<>>;
                                        {Qx, Qy} ->
                                            Addr = binary:part(eth_keccak:hash(
                                                                   <<Qx:256, Qy:256>>),
                                                               12, 20),
                                            <<0:96, Addr/binary>>
                                    end
                            end
                    end
            end
    end.

secp_on_curve(infinity) -> false;
secp_on_curve({X, Y}) ->
    P = ?SECP_P,
    ((Y * Y) rem P) =:= ((X * X * X + 7) rem P).

secp_neg_point(infinity) -> infinity;
secp_neg_point({X, Y}) -> {X, (?SECP_P - Y) rem ?SECP_P}.

secp_add_points(infinity, P) -> P;
secp_add_points(P, infinity) -> P;
secp_add_points({X1, Y1}, {X2, Y2}) ->
    P = ?SECP_P,
    case (X1 =:= X2) andalso ((Y1 + Y2) rem P =:= 0) of
        true ->
            infinity;
        false ->
            Num = case X1 =:= X2 of
                      true -> (3 * X1 * X1) rem P;
                      false -> ((Y2 - Y1) rem P + P) rem P
                  end,
            Den = case X1 =:= X2 of
                      true -> (2 * Y1) rem P;
                      false -> ((X2 - X1) rem P + P) rem P
                  end,
            S = ((Num * secp_inv(Den, P)) rem P + P) rem P,
            X3 = ((S * S - X1 - X2) rem P + P) rem P,
            Y3 = ((S * (X1 - X3) - Y1) rem P + P) rem P,
            {X3, Y3}
    end.

secp_mul_point(infinity, _) -> infinity;
secp_mul_point(_, 0) -> infinity;
secp_mul_point(P, S) -> secp_mul_loop(P, S, infinity).

secp_mul_loop(_, 0, Acc) -> Acc;
secp_mul_loop(P, S, Acc) ->
    Acc1 = case S band 1 of
               1 -> secp_add_points(Acc, P);
               0 -> Acc
           end,
    secp_mul_loop(secp_add_points(P, P), S bsr 1, Acc1).

%% y = sqrt(X) mod P (P = 3 mod 4); error if X is a non-residue.
secp_sqrt(X) ->
    P = ?SECP_P,
    Y = secp_pow(X rem P, (P + 1) div 4, P),
    case (Y * Y) rem P =:= X rem P of
        true -> Y;
        false -> error
    end.

secp_pow(B, E, M) -> eth_word:powmod(B rem M, E, M).

secp_inv(A, M) ->
    secp_egcd(((A rem M) + M) rem M, M, 1, 0, M).
secp_egcd(0, _, _, _, _) -> 0;
secp_egcd(1, _, X, _, M) -> ((X rem M) + M) rem M;
secp_egcd(A, B, X, Y, M) ->
    Q = B div A,
    secp_egcd(B rem A, A, Y - Q * X, X, M).
-define(BN128_P, 21888242871839275222246405745257275088696311157297823662689037894645226208583).

bn128_add(Data) ->
    <<X1:256, Y1:256, X2:256, Y2:256, _/binary>> = bn128_pad(Data, 128),
    case {bn128_point(X1, Y1), bn128_point(X2, Y2)} of
        {error, _} -> unsupported;
        {_, error} -> unsupported;
        {P1, P2} -> {ok, bn128_encode(bn128_add_points(P1, P2)), 150}
    end.

bn128_mul(Data) ->
    <<X:256, Y:256, S:256, _/binary>> = bn128_pad(Data, 96),
    case bn128_point(X, Y) of
        error -> unsupported;
        P -> {ok, bn128_encode(bn128_mul_point(P, S)), 6000}
    end.

%% Right-pad short input with zeros (CALLDATALOAD-compatible semantics).
bn128_pad(Data, N) when byte_size(Data) >= N -> Data;
bn128_pad(Data, N) ->
    Pad = N - byte_size(Data),
    <<Data/binary, 0:(Pad * 8)>>.

%% Valid G1 point or the atom error (infinity never errors).
bn128_point(0, 0) -> infinity;
bn128_point(X, Y) when X < ?BN128_P, Y < ?BN128_P ->
    case (Y * Y - (X * X * X + 3)) rem ?BN128_P of
        0 -> {X, Y};
        _ -> error
    end;
bn128_point(_, _) ->
    error.

bn128_encode(infinity) -> <<0:512>>;
bn128_encode({X, Y}) -> <<X:256, Y:256>>.

bn128_add_points(infinity, P) -> P;
bn128_add_points(P, infinity) -> P;
bn128_add_points({X1, Y1}, {X2, Y2}) ->
    P = ?BN128_P,
    case (X1 =:= X2) andalso ((Y1 + Y2) rem P =:= 0) of
        true ->
            infinity;
        false ->
            S = case X1 =:= X2 of
                    true -> %% doubling (Y =/= 0 guaranteed here)
                        ((3 * X1 * X1) * bn128_inv((2 * Y1) rem P)) rem P;
                    false ->
                        ((Y2 - Y1) * bn128_inv(((X2 - X1) rem P + P) rem P)) rem P
                end,
            SPos = ((S rem P) + P) rem P,
            X3 = ((SPos * SPos - X1 - X2) rem P + P) rem P,
            Y3 = ((SPos * (X1 - X3) - Y1) rem P + P) rem P,
            {X3, Y3}
    end.

bn128_mul_point(infinity, _) -> infinity;
bn128_mul_point(_, 0) -> infinity;
bn128_mul_point(P, S) -> bn128_mul_loop(P, S, infinity).

bn128_mul_loop(_, 0, Acc) -> Acc;
bn128_mul_loop(P, S, Acc) ->
    Acc1 = case S band 1 of
               1 -> bn128_add_points(Acc, P);
               0 -> Acc
           end,
    bn128_mul_loop(bn128_add_points(P, P), S bsr 1, Acc1).

%% Modular inverse via extended Euclid (A and P coprime in all call sites:
%% denominators are checked nonzero before dividing).
bn128_inv(A) -> bn128_inv(((A rem ?BN128_P) + ?BN128_P) rem ?BN128_P, ?BN128_P, 1, 0).
bn128_inv(0, _, _, _) -> 0;
bn128_inv(1, _, X, _) -> ((X rem ?BN128_P) + ?BN128_P) rem ?BN128_P;
bn128_inv(A, B, X, Y) ->
    Q = B div A,
    bn128_inv(B rem A, A, Y - Q * X, X).
