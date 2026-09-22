-module(eth_kzg).

%% EIP-4844 point-evaluation precompile (0x0A): pure-Erlang BLS12-381.
%%
%% Verifies a KZG proof that p(z) == y for the polynomial committed to by
%% `commitment`, checks the versioned hash, and returns
%%   FIELD_ELEMENTS_PER_BLOB (4096) || BLS_MODULUS
%% on success. Faithful port of the py_ecc "bls12_381" reference:
%%
%%   X_minus_z = [x]2 + (r - z) * G2
%%   P_minus_y = C + (r - y) * G1
%%   ok   <=>  e(P_minus_y, -G2) * e(proof, X_minus_z) == 1
%%
%% Field tower:
%%   Fp   = base field, p = 0x1A0111...AAAB   (381 bits)
%%   Fp2  = Fp[u]/(u^2 + 1)
%%   Fp12 = Fp[X]/(X^12 - 2*X^6 + 2),         i.e. X^K = 2*X^(K-6) - 2*X^(K-12)
%%
%% Honesty contract: only *definitive* verdicts are answered locally.
%% Every invalid structure, subgroup failure, arithmetic failure, or a proof
%% that fails the pairing check is returned as `unsupported`, and the caller
%% falls back to proxying the upstream node, whose verdict governs. Only
%% proofs that verify locally under the full Tate/ate pairing are served.

-export([point_evaluation/1, versioned_hash/1, g1_decompress/1, g1_mul/2,
         g2_mul/2, verify/4, pairing/2, fq12_eql/2, fq12_mul/2, fq12_one/0,
         fq12_inv/1, fq12_pow/2, twist/1, fq12_from_fq/1, fq12_sub/2,
         fq12_mul_int/2, fq12_double/1, fq12_add/2, bls_powmod/3]).

%% ---- BLS12-381 constants ----
-define(P, 16#1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab).
-define(R, 16#73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001).
%% ate loop count, 63 bits (bit 62..0, MSB first).
-define(ATE, 16#D201000000010000).

-define(G1X, 3685416753713387016781088315183077757961620795782546409894578378688607592378376318836054947676345821548104185464507).
-define(G1Y, 1339506544944476473020471379941921221584933875938349620426543736416511423956333506472724655353366534992391756441569).
%% Twisted curve y^2 = x^3 + b2, b2 = 4 + 4u, over Fp2 (py_ecc G2).
-define(G2X1, 352701069587466618187139116011060144890029952792775240219908644239793785735715026873347600343865175952761926303160).
-define(G2X2, 3059144344244213709971259814753781636986470325476647558659373206291635324768958432433509563104347017837885763365758).
-define(G2Y1, 1985150602287291935568054521177171638300868978215655730859378665066344726373823718423869104263333984641494340347905).
-define(G2Y2, 927553665492332455747201965776037880757740193453592970025027978793976877002675564980949289727957565575433344219582).
%% KZG trusted-setup monomial [x]2 = alpha * G2 (EIP-4844), used in
%% X_minus_z = [x]2 + (r - z)*G2. Affine coords of the compressed constant
%% KZG_SETUP_G2_MONOMIAL_1 from exec-specs (py_ecc signature_to_G2).
-define(G2SETUPX0, 3749701713850085193403383609513386037494151572263731328608276629425322978272408394373143740944003571525027436289778).
-define(G2SETUPX1, 3347537128081568434923729147580015899756771550835613107520576615563260658656019591232316627827007503930666726825842).
-define(G2SETUPY0, 194392958648403190675529552496435226424111592982833162118538452666741235889530674000225873281133418439621742897817).
-define(G2SETUPY1, 3447898402727835650716129438012169492682148398295533958400255525306573911008434577489634554212211450783070687991119).

-define(G1, {?G1X, ?G1Y}).
-define(G2, {{?G2X1, ?G2X2}, {?G2Y1, ?G2Y2}}).

%% ---------------------------------------------------------------------------
%% EIP-4844 precompile entry
%% ---------------------------------------------------------------------------

%% input: versioned_hash(32) | z(32) | y(32) | commitment(48) | proof(48)
point_evaluation(Data) when byte_size(Data) =:= 192 ->
    <<VH:32/binary, Z:256, Y:256, C:48/binary, Pr:48/binary>> = Data,
    case Z < ?R andalso Y < ?R of
        false -> unsupported;
        true ->
            case VH =:= versioned_hash(C) of
                false -> unsupported;
                true ->
                    case {g1_decompress(C), g1_decompress(Pr)} of
                        {{ok, Cpt}, {ok, Ppt}} ->
                            case g1_mul(Cpt, ?R) =:= infinity andalso
                                 g1_mul(Ppt, ?R) =:= infinity of
                                true ->
                                    case verify(Cpt, Z, Y, Ppt) of
                                        true -> {ok, <<4096:256, ?R:256>>, 50000};
                                        false -> unsupported
                                    end;
                                false ->
                                    unsupported
                            end;
                        _ ->
                            unsupported
                    end
            end
    end;
point_evaluation(_) ->
    unsupported.

%% versioned_hash = 0x01 || sha256(commitment)[1:33]
versioned_hash(C) ->
    <<_:8, Rest31/binary>> = crypto:hash(sha256, C),
    <<1:8, Rest31/binary>>.

verify(Cpt, Z, Y, Ppt) ->
    try
        PY = g1_add(Cpt, g1_mul(?G1, (?R - Y) rem ?R)),
        XMZ = g2_add(g2_setup(), g2_mul(?G2, (?R - Z) rem ?R)),
        P1 = pairing(g2_neg(?G2), PY),
        P2 = pairing(XMZ, Ppt),
        fq12_eql(fq12_mul(P1, P2), fq12_one())
    catch _:_ ->
        false
    end.

g2_setup() ->
    {{?G2SETUPX0, ?G2SETUPX1}, {?G2SETUPY0, ?G2SETUPY1}}.

%% ---------------------------------------------------------------------------
%% Fp arithmetic
%% ---------------------------------------------------------------------------

fq(N) -> ((N rem ?P) + ?P) rem ?P.

fq_inv(A) -> fq_egcd(fq(A), ?P, 1, 0).
fq_egcd(1, _B, X, _Y) -> (X rem ?P + ?P) rem ?P;
fq_egcd(0, _B, _X, _Y) -> 0;
fq_egcd(A, B, X, Y) ->
    Q = B div A,
    fq_egcd(B rem A, A, Y - Q * X, X).

bls_pow(_B, 0) -> 1;
bls_pow(B, E) -> bls_pow(B, E, 1).
bls_pow(_B, 0, Acc) -> Acc;
bls_pow(B, E, Acc) ->
    Acc1 = case E band 1 of
               1 -> Acc * B;
               0 -> Acc
           end,
    bls_pow(B * B, E bsr 1, Acc1).

%% Modular exponentiation (for field exponentiation with huge exponents).
bls_powmod(_B, 0, _M) -> 1;
bls_powmod(B, E, M) -> bls_powmod(B, E, M, 1).
bls_powmod(_B, 0, _M, Acc) -> Acc;
bls_powmod(B, E, M, Acc) ->
    Acc1 = case E band 1 of
               1 -> (Acc * B) rem M;
               0 -> Acc
           end,
    bls_powmod((B * B) rem M, E bsr 1, M, Acc1).

%% p == 3 (mod 4): y = t^((p+1)/4); = 0 or error.
fq_sqrt(0) -> 0;
fq_sqrt(T) ->
    Y = bls_powmod(T, (?P + 1) div 4, ?P),
    case (Y * Y) rem ?P of
        V when V =:= T rem ?P -> Y;
        _ -> error
    end.

%% ---------------------------------------------------------------------------
%% Fp2, u^2 == -1
%% ---------------------------------------------------------------------------

fq2_add({A, B}, {C, D}) -> {fq(A + C), fq(B + D)}.
fq2_sub({A, B}, {C, D}) -> {fq(A - C), fq(B - D)}.
fq2_neg({A, B}) -> {fq(-A), fq(-B)}.
fq2_mul({A, B}, {C, D}) -> {fq(A * C - B * D), fq(A * D + B * C)}.
fq2_mul_int({A, B}, N) -> {fq(A * N), fq(B * N)}.
fq2_inv({A, B}) ->
    NInv = fq_inv(fq(A * A + B * B)),
    {fq(A * NInv), fq(-B * NInv)}.
fq2_div(X, Y) -> fq2_mul(X, fq2_inv(Y)).
fq2_eq({A, B}, {C, D}) -> A =:= C andalso B =:= D.

%% ---------------------------------------------------------------------------
%% Fp12: coefficients [c0..c11], X^K = 2*X^(K-6) - 2*X^(K-12) for K >= 12
%% ---------------------------------------------------------------------------

%% Reduce coefficient index K (degree >= degree modulus) by the carry rule.
%% A coefficient at index K folds into K-6 (+2) and K-12 (-2); walk high-low.
reduce(T, K) when K < 12 ->
    [fq(nth00(T, I)) || I <- lists:seq(0, 11)];
reduce(T, 12) ->
    case nth00(T, 12) of
        0 -> reduce(T, 11);
        V ->
            T1 = set00(6, nth00(T, 6) + 2 * V, T),
            T2 = set00(0, nth00(T1, 0) - 2 * V, T1),
            reduce(T2, 11)
    end;
reduce(T, K) when K >= 12 ->
    case nth00(T, K) of
        0 -> reduce(T, K - 1);
        V ->
            T1 = set00(K - 6, nth00(T, K - 6) + 2 * V, T),
            T2 = set00(K - 12, nth00(T1, K - 12) - 2 * V, T1),
            reduce(T2, K - 1)
    end.

fq12_mul(A, B) ->
    T0 = lists:foldl(fun({I, J}, Acc) ->
                             set00(I + J, nth00(Acc, I + J) + nth00(A, I) * nth00(B, J),
                                   Acc)
                     end, lists:duplicate(23, 0),
                     [{I, J} || I <- lists:seq(0, 11), J <- lists:seq(0, 11)]),
    reduce(T0, 22).

fq12_mul_int(A, N) -> [fq(C * N) || C <- A].
fq12_sub(A, B) -> [fq(X - Y) || {X, Y} <- lists:zip(A, B)].
fq12_one() -> [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0].
fq12_eql(A, B) -> A =:= B.

%% Fp12 exponent: square-and-multiply.
fq12_pow(B, E) -> fq12_pow(B, E, fq12_one()).
fq12_pow(_B, 0, Acc) -> Acc;
fq12_pow(B, E, Acc) ->
    Acc1 = case E band 1 of
               1 -> fq12_mul(Acc, B);
               0 -> Acc
           end,
    fq12_pow(fq12_mul(B, B), E bsr 1, Acc1).

%% Inverse of an Fp12 element via extended Euclid over Fp[X], modulus
%% X^12 - 2X^6 + 2. gcd(X, M) = 1, so the Bezout coefficient is the inverse.
fq12_inv(X) ->
    M = [2, 0, 0, 0, 0, 0, fq(-2), 0, 0, 0, 0, 0, 1],
    {G, S, _T} = poly_eea(X, M),
    C = case trim(G) of
            [V] -> V;
            _ -> 1
        end,
    Factor = fq_inv(C),
    poly_to12([fq(Co * Factor) || Co <- S]).

w2() -> [0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0].
w3() -> [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0].

inv_w2() ->
    case persistent_term:get({?MODULE, inv_w2}, undefined) of
        undefined ->
            V = fq12_inv(w2()),
            persistent_term:put({?MODULE, inv_w2}, V),
            V;
        V -> V
    end.

inv_w3() ->
    case persistent_term:get({?MODULE, inv_w3}, undefined) of
        undefined ->
            V = fq12_inv(w3()),
            persistent_term:put({?MODULE, inv_w3}, V),
            V;
        V -> V
    end.

%% ---------------------------------------------------------------------------
%% Polynomial helpers (over Fp)
%% ---------------------------------------------------------------------------

nth00(L, I) when I >= 0, I < length(L) -> lists:nth(I + 1, L);
nth00(_, _) -> 0.

set00(I, V, L) when I >= 0, I < length(L) ->
    {A, B} = lists:split(I, L),
    A ++ [fq(V)] ++ tl(B);
set00(_, _, L) -> L.

trim(P) -> lists:reverse(lists:dropwhile(fun(C) -> C =:= 0 end, lists:reverse(P))).
deg(P) -> length(trim(P)) - 1.
leading(P) -> lists:last(trim(P)).

poly_add(A, B) ->
    L = max(length(A), length(B)),
    [fq(nth00(A, I) + nth00(B, I)) || I <- lists:seq(0, L - 1)].
poly_sub(A, B) ->
    L = max(length(A), length(B)),
    [fq(nth00(A, I) - nth00(B, I)) || I <- lists:seq(0, L - 1)].

poly_mul(A, B) ->
    As = trim(A), Bs = trim(B),
    L = max(1, length(As) + length(Bs) - 1),
    lists:foldl(fun({I, J}, Acc) ->
                        set00(I + J, nth00(Acc, I + J) + nth00(As, I) * nth00(Bs, J),
                              Acc)
                end, lists:duplicate(L, 0),
                [{I, J} || I <- lists:seq(0, length(As) - 1),
                            J <- lists:seq(0, length(Bs) - 1)]).

poly_to12(S) ->
    lists:sublist(S ++ lists:duplicate(12, 0), 12).

%% Return {G, S, T} with S*A + T*B = G.
poly_eea(A, B) ->
    case trim(B) of
        [] -> {trim(A), [1], []};
        _ ->
            {Q, R} = poly_divmod(A, B),
            {G, S1, T1} = poly_eea(B, R),
            {G, T1, poly_sub(S1, poly_mul(Q, T1))}
    end.

poly_divmod(A, B) ->
    Ar = trim(A),
    Br = trim(B),
    case Br of
        [] -> {[], []};
        _ ->
            Q0 = lists:duplicate(max(0, length(Ar) - length(Br) + 1), 0),
            poly_divmod(Ar, Br, Q0)
    end.

poly_divmod(A, B, Q) ->
    case trim(A) of
        [] -> {trim(Q), []};
        Ar ->
            Ad = deg(Ar),
            Bd = deg(B),
            case Ad >= Bd of
                false -> {trim(Q), trim(Ar)};
                true ->
                    LCInv = fq_inv(leading(B)),
                    Shift = Ad - Bd,
                    Term = lists:duplicate(Shift, 0) ++ [fq(leading(Ar) * LCInv)],
                    Q1 = poly_add(Q, Term),
                    A1 = poly_sub(Ar, poly_mul(Term, B)),
                    poly_divmod(A1, B, Q1)
            end
    end.

%% ---------------------------------------------------------------------------
%% G1 (Fp) point ops. infinity = atom.
%% ---------------------------------------------------------------------------

g1_double(infinity) -> infinity;
g1_double({X, Y}) ->
    M = fq(3 * X * X * fq_inv(fq(2 * Y))),
    X3 = fq(M * M - 2 * X),
    {X3, fq(-M * X3 + M * X - Y)}.

g1_add(infinity, P) -> P;
g1_add(P, infinity) -> P;
g1_add({X1, Y1}, {X2, Y2}) ->
    if
        X1 =:= X2, Y1 =:= Y2 -> g1_double({X1, Y1});
        X1 =:= X2 -> infinity;
        true ->
            M = fq((Y2 - Y1) * fq_inv(fq(X2 - X1))),
            X3 = fq(M * M - X1 - X2),
            {X3, fq(-M * X3 + M * X1 - Y1)}
    end.

g1_mul(_, 0) -> infinity;
g1_mul(infinity, _) -> infinity;
g1_mul(P, N) -> g1_mul(P, N, infinity).
g1_mul(_P, 0, Acc) -> Acc;
g1_mul(P, N, Acc) ->
    Acc1 = case N band 1 of
               1 -> g1_add(Acc, P);
               0 -> Acc
           end,
    g1_mul(g1_double(P), N bsr 1, Acc1).

%% ---------------------------------------------------------------------------
%% G2 (Fp2) point ops.
%% ---------------------------------------------------------------------------

g2_double(infinity) -> infinity;
g2_double({X, Y}) ->
    M = fq2_div(fq2_mul_int(fq2_mul(X, X), 3), fq2_mul_int(Y, 2)),
    X3 = fq2_sub(fq2_mul(M, M), fq2_mul_int(X, 2)),
    {X3, fq2_sub(fq2_mul(M, fq2_sub(X, X3)), Y)}.

g2_add(infinity, P) -> P;
g2_add(P, infinity) -> P;
g2_add({X1, Y1}, {X2, Y2}) ->
    SameX = fq2_eq(X1, X2),
    SameY = fq2_eq(Y1, Y2),
    if
        SameX, SameY -> g2_double({X1, Y1});
        SameX -> infinity;
        true ->
            M = fq2_div(fq2_sub(Y2, Y1), fq2_sub(X2, X1)),
            X3 = fq2_sub(fq2_mul(M, M), fq2_add(X1, X2)),
            {X3, fq2_sub(fq2_mul(M, fq2_sub(X1, X3)), Y1)}
    end.

g2_neg(infinity) -> infinity;
g2_neg({X, Y}) -> {X, fq2_neg(Y)}.

g2_mul(_, 0) -> infinity;
g2_mul(infinity, _) -> infinity;
g2_mul(P, N) -> g2_mul(P, N, infinity).
g2_mul(_P, 0, Acc) -> Acc;
g2_mul(P, N, Acc) ->
    Acc1 = case N band 1 of
               1 -> g2_add(Acc, P);
               0 -> Acc
           end,
    g2_mul(g2_double(P), N bsr 1, Acc1).

%% ---------------------------------------------------------------------------
%% Pairing (py_ecc bls12_381 structure)
%% ---------------------------------------------------------------------------

final_exp() ->
    case persistent_term:get({?MODULE, final_exp}, undefined) of
        undefined ->
            E = (bls_pow(?P, 12) - 1) div ?R,
            persistent_term:put({?MODULE, final_exp}, E),
            E;
        E ->
            E
    end.

fq12_from_fq(N) ->
    set00(0, fq(N), lists:duplicate(12, 0)).

cast12({X, Y}) ->
    {fq12_from_fq(X), fq12_from_fq(Y)}.

%% Map a twisted (Fp2) point into E(Fp12): xcoeffs = [x0 - x1, 0*5, x1, 0*5],
%% y likewise, then divide x by w^2 and y by w^3 (w = X).
twist(infinity) -> infinity;
twist({{X0, X1}, {Y0, Y1}}) ->
    Nx = [fq(X0 - X1), 0, 0, 0, 0, 0, fq(X1), 0, 0, 0, 0, 0],
    Ny = [fq(Y0 - Y1), 0, 0, 0, 0, 0, fq(Y1), 0, 0, 0, 0, 0],
    {fq12_mul(Nx, inv_w2()), fq12_mul(Ny, inv_w3())}.

%% Line function through P1/P2 (Fp12 points) evaluated at T.
linefunc({X1, Y1}, {X2, Y2}, {Xt, Yt}) ->
    XEq = fq12_eql(X1, X2),
    YEq = fq12_eql(Y1, Y2),
    if
        not XEq ->
            M = fq12_div(fq12_sub(Y2, Y1), fq12_sub(X2, X1)),
            fq12_sub(fq12_mul(M, fq12_sub(Xt, X1)), fq12_sub(Yt, Y1));
        YEq ->
            M = fq12_div(fq12_mul_int(fq12_mul(X1, X1), 3), fq12_mul_int(Y1, 2)),
            fq12_sub(fq12_mul(M, fq12_sub(Xt, X1)), fq12_sub(Yt, Y1));
        true ->
            fq12_sub(Xt, X1)
    end.

fq12_div(A, B) -> fq12_mul(A, fq12_inv(B)).

%% Point double / add over Fp12 coordinates.
fq12_double(P) ->
    {X, Y} = P,
    M = fq12_div(fq12_mul_int(fq12_mul(X, X), 3), fq12_mul_int(Y, 2)),
    X3 = fq12_sub(fq12_mul(M, M), fq12_mul_int(X, 2)),
    {X3, fq12_sub(fq12_mul(M, fq12_sub(X, X3)), Y)}.

fq12_add(P1, P2) ->
    {X1, Y1} = P1,
    {X2, Y2} = P2,
    XEq = fq12_eql(X1, X2),
    YEq = fq12_eql(Y1, Y2),
    if
        XEq, YEq -> fq12_double(P1);
        XEq -> infinity;
        true ->
            M = fq12_div(fq12_sub(Y2, Y1), fq12_sub(X2, X1)),
            X3 = fq12_sub(fq12_sub(fq12_mul(M, M), X1), X2),
            {X3, fq12_sub(fq12_mul(M, fq12_sub(X1, X3)), Y1)}
    end.

pairing(Q2, Pfq) ->
    case {Q2, Pfq} of
        {infinity, _} -> fq12_one();
        {_, infinity} -> fq12_one();
        _ -> miller_loop(twist(Q2), cast12(Pfq))
    end.

miller_loop(Q12, P12) ->
    F = miller_bits(Q12, P12, 62, fq12_one(), Q12),
    fq12_pow(F, final_exp()).

miller_bits(_Q, _P, I, F, _R) when I < 0 -> F;
miller_bits(Q, P, I, F, R) ->
    F1 = fq12_mul(fq12_mul(F, F), linefunc(R, R, P)),
    R1 = fq12_double(R),
    case (?ATE band (1 bsl I)) of
        0 ->
            miller_bits(Q, P, I - 1, F1, R1);
        _ ->
            F2 = fq12_mul(F1, linefunc(R1, Q, P)),
            miller_bits(Q, P, I - 1, F2, fq12_add(R1, Q))
    end.

%% ---------------------------------------------------------------------------
%% G1 decompression (48-byte ZCash/eth2 compressed encoding).
%%
%% Layout (big-endian bytes, bit numbering within the 384-bit integer):
%%   bits 0..380  : x coordinate
%%   bit  381     : sort flag (y parity)
%%   bit  382     : infinity flag
%%   bit  383     : compression flag (must be set)
%%   x must be < p; infinity encodes exactly bits 382+383 set.
%% ---------------------------------------------------------------------------

g1_decompress(Bin) ->
    B = binary:decode_unsigned(Bin),
    Cflag = (B bsr 383) band 1,
    Inf = (B bsr 382) band 1,
    Sort = (B bsr 381) band 1,
    X = B band ((1 bsl 381) - 1),
    case Inf of
        1 ->
            case B =:= ((1 bsl 383) bor (1 bsl 382)) of
                true -> {ok, infinity};
                false -> error
            end;
        0 ->
            case Cflag =:= 1 andalso X < ?P of
                false ->
                    error;
                true ->
                    Y2 = (bls_pow(X, 3) + 4) rem ?P,
                    case fq_sqrt(Y2) of
                        error -> error;
                        Y0 ->
                            Y = case (Y0 band 1) =:= Sort of
                                    true -> fq(Y0);
                                    false -> fq(?P - Y0)
                                end,
                            {ok, {X, Y}}
                    end
            end
    end.