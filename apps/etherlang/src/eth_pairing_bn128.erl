-module(eth_pairing_bn128).

%% Tate pairing check on alt_bn128 (EIP-197 0x08), pure Erlang.
%%
%% Tower (per EIP-197): Fp2 = Fp[u]/(u^2+1); Fp6 = Fp2[v]/(v^3-xi) with
%% xi = u+9; Fp12 = Fp6[w]/(w^2-v). D-type twist psi(x,y) = (x*w^2, y*w^3).
%% Wire order for Fp2 elements is (imag, real) per EIP-197 "(a, b)" encoding.
%%
%% The Miller loop runs over the group order (Tate formulation: no
%% correction terms), trading ~4x loop iterations for structural
%% simplicity — every term is directly auditable, and an optimal-ate
%% variant can be verified against this implementation in the future.
%%
%% Entry point check_pairing/1 takes the raw precompile input and returns
%% {ok, 32-byte 0/1, Gas} or `unsupported` (bad length, bad points, or any
%% internal error -> the caller proxies upstream, never wrong data).

-export([check_pairing/1]).

-define(P, 21888242871839275222246405745257275088696311157297823662689037894645226208583).
-define(Q, 21888242871839275222246405745257275088548364400416034343698204186575808495617).
%% xi = u + 9 as {Real, Imag}.
-define(XI_R, 9).
-define(XI_I, 1).

check_pairing(Data) when byte_size(Data) rem 192 =/= 0 ->
    unsupported;
check_pairing(Data) ->
    K = byte_size(Data) div 192,
    try parse_pairs(Data, K, []) of
        {ok, Pairs} ->
            Acc = lists:foldl(fun({P1, P2}, F) -> fp12_mul(F, miller(P2, P1)) end,
                              fp12_one(), Pairs),
            R = final_exp(Acc),
            V = case fp12_eq(R, fp12_one()) of
                    true -> 1;
                    false -> 0
                end,
            {ok, <<V:256>>, 34000 * K + 45000};
        unsupported ->
            unsupported
    catch _:_ ->
        unsupported
    end.

parse_pairs(<<>>, 0, Acc) -> {ok, lists:reverse(Acc)};
parse_pairs(Data, K, Acc) ->
    <<X1:256, Y1:256, Xa:256, Xb:256, Ya:256, Yb:256, Rest/binary>> = Data,
    case {g1_point(X1, Y1), g2_point(Xa, Xb, Ya, Yb)} of
        {infinity, _} -> parse_pairs(Rest, K - 1, Acc);
        {_, infinity} -> parse_pairs(Rest, K - 1, Acc);
        {P1, P2} when P1 =/= error, P2 =/= error ->
            parse_pairs(Rest, K - 1, [{P1, P2} | Acc]);
        _ ->
            unsupported
    end.

%% G1: prime-order curve, on-curve check suffices (EIP-197).
g1_point(0, 0) -> infinity;
g1_point(X, Y) when X < ?P, Y < ?P ->
    case (Y * Y - (X * X * X + 3)) rem ?P of
        0 -> {X, Y};
        _ -> error
    end;
g1_point(_, _) ->
    error.

%% G2: twisted curve Y^2 = X^3 + 3/xi, then subgroup check (EIP-197).
g2_point(0, 0, 0, 0) -> infinity;
g2_point(Xa, Xb, Ya, Yb) ->
    P = ?P,
    case Xa < P andalso Xb < P andalso Ya < P andalso Yb < P of
        false -> error;
        true ->
            X = {Xb, Xa},
            Y = {Yb, Ya},
            B = fp2_mul({3, 0}, fp2_inv(xi())),
            case fp2_eq(fp2_mul(Y, Y),
                        fp2_add(fp2_mul(fp2_mul(X, X), X), B)) of
                false -> error;
                true ->
                    case g2_mul({X, Y}, ?Q) of
                        infinity -> {X, Y};
                        _ -> error
                    end
            end
    end.

xi() -> {?XI_R, ?XI_I}.

%% ---------------------------------------------------------------------------
%% Miller loop (Tate: over the group order) + final exponentiation.
%% ---------------------------------------------------------------------------

miller(Q, {Xp, Yp}) ->
    {F1, _T1} = miller_bits(tate_bit_list(), Q, fp12_one(), {Xp, Yp}, Q),
    F1.

%% Bits of the group order below the top bit, MSB first.
tate_bit_list() ->
    L = bit_len(?Q) - 2,
    [((?Q bsr I) band 1) || I <- lists:seq(L, 0, -1)].

bit_len(0) -> 0;
bit_len(N) -> bit_len(N, 0).
bit_len(0, A) -> A;
bit_len(N, A) -> bit_len(N bsr 1, A + 1).

miller_bits([], T, F, _, _) -> {F, T};
miller_bits([B | Rest], T, F, P, Q) ->
    F1 = fp12_mul(fp12_mul(F, F), line_eval(T, T, P)),
    T1 = g2_double(T),
    {F2, T2} = case B of
                   1 ->
                       {fp12_mul(F1, line_eval(T1, Q, P)), g2_add(T1, Q)};
                   0 ->
                       {F1, T1}
               end,
    miller_bits(Rest, T2, F2, P, Q).

%% Final exponentiation by direct square-multiply: (p^12-1)/n.
final_exp(F) ->
    E = (pow_int(?P, 12) - 1) div ?Q,
    fp12_pow(F, E).

pow_int(_, 0) -> 1;
pow_int(B, E) -> pow_int(B, E, 1).
pow_int(_, 0, A) -> A;
pow_int(B, E, A) ->
    A1 = case E band 1 of
             1 -> A * B;
             0 -> A
         end,
    pow_int(B * B, E bsr 1, A1).

fp12_pow(_, 0) -> fp12_one();
fp12_pow(F, E) -> fp12_pow_loop(F, E, fp12_one()).
fp12_pow_loop(_, 0, A) -> A;
fp12_pow_loop(F, E, A) ->
    A1 = case E band 1 of
             1 -> fp12_mul(A, F);
             0 -> A
         end,
    fp12_pow_loop(fp12_mul(F, F), E bsr 1, A1).

%% ---------------------------------------------------------------------------
%% Line evaluation (D-twist), dense Fp12 form.
%% Non-vertical through T1,T2 evaluated at P:
%%   L = yp + (-m*xp)*w + (m*X1-Y1)*w^3, with w^3 = v*w.
%% Vertical (X1 == X2): L = xp - X1*v. Infinity steps return one
%% (pairs touching infinity are skipped by the caller anyway).
%% ---------------------------------------------------------------------------

line_eval(infinity, infinity, _) -> fp12_one();
line_eval(infinity, T2, P) -> vertical_line(T2, P);
line_eval(T1, infinity, P) -> vertical_line(T1, P);
line_eval({X1, Y1} = T1, {X2, Y2}, {Xp, Yp}) ->
    case X1 =:= X2 of
        true ->
            case fp2_eq(Y1, fp2_neg(Y2)) of
                true -> vertical_line(T1, {Xp, Yp});
                false ->
                    case fp2_is_zero(Y1) of
                        true -> vertical_line(T1, {Xp, Yp});
                        false ->
                            M = fp2_mul(fp2_mul({3, 0}, fp2_mul(X1, X1)),
                                        fp2_inv(fp2_add(Y1, Y1))),
                            tangent_line(M, T1, {Xp, Yp})
                    end
            end;
        false ->
            M = fp2_mul(fp2_sub(Y2, Y1), fp2_inv(fp2_sub(X2, X1))),
            tangent_line(M, T1, {Xp, Yp})
    end.

tangent_line(M, {XT, YT}, {Xp, Yp}) ->
    D0 = {{Yp, 0}, {0, 0}, {0, 0}},
    D1 = {fp2_neg(fp2_mul(M, {Xp, 0})),
          fp2_sub(fp2_mul(M, XT), YT),
          {0, 0}},
    {D0, D1}.

vertical_line({X, _}, {Xp, _}) ->
    D0 = {fp2_sub({Xp, 0}, X), {0, 0}, {0, 0}},
    D1 = {{0, 0}, {0, 0}, {0, 0}},
    {D0, D1}.

%% ---------------------------------------------------------------------------
%% G2 arithmetic on the twisted curve (affine, Fp2 coordinates).
%% ---------------------------------------------------------------------------

g2_add(infinity, P) -> P;
g2_add(P, infinity) -> P;
g2_add({X1, Y1}, {X2, Y2}) ->
    case X1 =:= X2 of
        true ->
            case fp2_eq(Y1, fp2_neg(Y2)) of
                true -> infinity;
                false -> g2_double({X1, Y1})
            end;
        false ->
            M = fp2_mul(fp2_sub(Y2, Y1), fp2_inv(fp2_sub(X2, X1))),
            X3 = fp2_sub(fp2_sub(fp2_mul(M, M), X1), X2),
            Y3 = fp2_sub(fp2_mul(M, fp2_sub(X1, X3)), Y1),
            {X3, Y3}
    end.

g2_double(infinity) -> infinity;
g2_double({X, Y}) ->
    M = fp2_mul(fp2_mul({3, 0}, fp2_mul(X, X)),
                fp2_inv(fp2_add(Y, Y))),
    X2 = fp2_sub(fp2_sub(fp2_mul(M, M), X), X),
    Y2 = fp2_sub(fp2_mul(M, fp2_sub(X, X2)), Y),
    {X2, Y2}.

g2_mul(_, 0) -> infinity;
g2_mul(infinity, _) -> infinity;
g2_mul(P, S) -> g2_mul_loop(P, S, infinity).
g2_mul_loop(_, 0, Acc) -> Acc;
g2_mul_loop(P, S, Acc) ->
    Acc1 = case S band 1 of
               1 -> g2_add(Acc, P);
               0 -> Acc
           end,
    g2_mul_loop(g2_double(P), S bsr 1, Acc1).

%% ---------------------------------------------------------------------------
%% Tower arithmetic. Fp = integer mod P. Fp2 = {Real, Imag} (u^2+1=0).
%% Fp6 = {C0, C1, C2} (v^3=xi). Fp12 = {D0, D1} (w^2=v).
%% ---------------------------------------------------------------------------

fp_norm(X) -> ((X rem ?P) + ?P) rem ?P.

fp2_add({A0, A1}, {B0, B1}) ->
    {fp_norm(A0 + B0), fp_norm(A1 + B1)}.
fp2_sub({A0, A1}, {B0, B1}) ->
    {fp_norm(A0 - B0), fp_norm(A1 - B1)}.
fp2_neg({A0, A1}) -> {(?P - A0) rem ?P, (?P - A1) rem ?P}.
fp2_mul({A0, A1}, {B0, B1}) ->
    {fp_norm(A0 * B0 - A1 * B1), fp_norm(A0 * B1 + A1 * B0)}.
fp2_inv({A0, A1}) ->
    Den = fp_norm(A0 * A0 + A1 * A1),
    Inv = fp_inv(Den),
    {fp_norm(A0 * Inv), fp_norm(-A1 * Inv)}.
fp2_eq({A0, A1}, {B0, B1}) ->
    fp_norm(A0 - B0) =:= 0 andalso fp_norm(A1 - B1) =:= 0.
fp2_is_zero({A0, A1}) -> fp_norm(A0) =:= 0 andalso fp_norm(A1) =:= 0.

fp_inv(A) ->
    egcd(fp_norm(A), ?P, 1, 0).
egcd(0, _, _, _) -> 0;
egcd(1, _, X, _) -> fp_norm(X);
egcd(A, B, X, Y) ->
    Q = B div A,
    egcd(B rem A, A, Y - Q * X, X).

%% xi * X for X in Fp2, xi = {9, 1}: (9a-b) + (a+9b)i.
fp2_mul_xi({A0, A1}) ->
    {fp_norm(9 * A0 - A1), fp_norm(A0 + 9 * A1)}.

fp6_add({A0, A1, A2}, {B0, B1, B2}) ->
    {fp2_add(A0, B0), fp2_add(A1, B1), fp2_add(A2, B2)}.
fp6_mul({A0, A1, A2}, {B0, B1, B2}) ->
    %% (a0+a1v+a2v^2)(b0+b1v+b2v^2), v^3 = xi.
    C0 = fp2_add(fp2_mul(A0, B0),
                 fp2_mul_xi(fp2_add(fp2_mul(A1, B2), fp2_mul(A2, B1)))),
    C1 = fp2_add(fp2_add(fp2_mul(A0, B1), fp2_mul(A1, B0)),
                 fp2_mul_xi(fp2_mul(A2, B2))),
    C2 = fp2_add(fp2_add(fp2_mul(A0, B2), fp2_mul(A1, B1)),
                 fp2_mul(A2, B0)),
    {C0, C1, C2}.

%% v * X = (c2*xi, c0, c1).
fp6_mul_v({C0, C1, C2}) -> {fp2_mul_xi(C2), C0, C1}.
fp6_zero() -> {{0, 0}, {0, 0}, {0, 0}}.
fp6_one() -> {{1, 0}, {0, 0}, {0, 0}}.

fp12_one() -> {fp6_one(), fp6_zero()}.
fp12_eq({A0, A1}, {B0, B1}) -> A0 =:= B0 andalso A1 =:= B1.
fp12_mul({A0, A1}, {B0, B1}) ->
    T = fp6_mul(A0, B0),
    U = fp6_mul(A1, B1),
    {fp6_add(T, fp6_mul_v(U)),
     fp6_add(fp6_mul(A0, B1), fp6_mul(A1, B0))}.
