-module(eth_keccak).

%% Pure-Erlang Keccak-256 (Ethereum's variant, original Keccak padding 0x01,
%% *not* NIST SHA3-256). Used to recompute block-header hashes so the node
%% verifies fetched data instead of trusting the upstream `hash' field.
%%
%% State is 25 x 64-bit lanes held in a 25-tuple; lane (X,Y) lives at index
%% X + 5*Y + 1. Rate = 136 bytes, output = 32 bytes.

-export([hash/1]).

-define(MASK, 16#FFFFFFFFFFFFFFFF).
-define(RATE, 136).

hash(Bin) when is_binary(Bin) ->
    S = absorb(pad(Bin), erlang:make_tuple(25, 0)),
    <<Out:32/binary, _/binary>> =
        << <<Lane:64/little>> || Lane <- tuple_to_list(S) >>,
    Out.

%% ---------------------------------------------------------------------------
%% Sponge
%% ---------------------------------------------------------------------------

pad(M) ->
    L = byte_size(M),
    PadLen = ?RATE - (L rem ?RATE),
    case PadLen of
        1 -> <<M/binary, 16#81>>;
        _ -> <<M/binary, 16#01, (binary:copy(<<0>>, PadLen - 2))/binary, 16#80>>
    end.

absorb(<<Block:?RATE/binary, Rest/binary>>, S) ->
    absorb(Rest, keccak_f(xor_block(S, Block)));
absorb(<<>>, S) ->
    S.

xor_block(S, Block) ->
    lists:foldl(
      fun(I, Acc) ->
          Word = binary:decode_unsigned(binary:part(Block, I * 8, 8), little),
          setelement(I + 1, Acc, element(I + 1, Acc) bxor Word)
      end, S, lists:seq(0, 16)).

%% ---------------------------------------------------------------------------
%% Keccak-f[1600]
%% ---------------------------------------------------------------------------

keccak_f(S) -> rounds(S, 0).

rounds(S, 24) ->
    S;
rounds(S, R) ->
    rounds(iota(chi(rho_pi(theta(S))), R), R + 1).

%% C[x] = xor over y of A[x,y];  D[x] = C[x-1] xor rotl(C[x+1], 1)
theta(S) ->
    C = [lists:foldl(fun(Y, Acc) -> Acc bxor element(X + 5 * Y + 1, S) end,
                     0, lists:seq(0, 4))
         || X <- lists:seq(0, 4)],
    D = [lists:nth(((X + 4) rem 5) + 1, C) bxor rotl(lists:nth(((X + 1) rem 5) + 1, C), 1)
         || X <- lists:seq(0, 4)],
    list_to_tuple(
      [element(X + 5 * Y + 1, S) bxor lists:nth(X + 1, D)
       || Y <- lists:seq(0, 4), X <- lists:seq(0, 4)]).

%% rho + pi (FIPS 202): A'[x,y] = rotl(A[(x+3y) mod 5, x], r[(x+3y) mod 5, x]).
rho_pi(S) ->
    Pairs = [{X + 5 * Y + 1,
              rotl(element(XS + 5 * X + 1, S), rot(XS, X))}
             || X <- lists:seq(0, 4), Y <- lists:seq(0, 4),
                XS <- [(X + 3 * Y) rem 5]],
    lists:foldl(fun({I, V}, Acc) -> setelement(I, Acc, V) end,
                erlang:make_tuple(25, 0), Pairs).

%% chi: A[x][y] = B[x][y] xor ((not B[x+1][y]) and B[x+2][y])
chi(S) ->
    list_to_tuple(
      [element(X + 5 * Y + 1, S)
       bxor ((bnot element(((X + 1) rem 5) + 5 * Y + 1, S))
             band element(((X + 2) rem 5) + 5 * Y + 1, S))
       || Y <- lists:seq(0, 4), X <- lists:seq(0, 4)]).

iota(S, R) ->
    setelement(1, S, element(1, S) bxor element(R + 1, round_constants())).

rotl(V, 0) -> V band ?MASK;
rotl(V, N) -> ((V bsl N) bor (V bsr (64 - N))) band ?MASK.

%% r[x][y] rotation offsets, indexed by X + 5*Y + 1.
rot(X, Y) -> element(X + 5 * Y + 1, rot_table()).

rot_table() ->
    {0, 1, 62, 28, 27,
     36, 44, 6, 55, 20,
     3, 10, 43, 25, 39,
     41, 45, 15, 21, 8,
     18, 2, 61, 56, 14}.

round_constants() ->
    {16#0000000000000001, 16#0000000000008082,
     16#800000000000808A, 16#8000000080008000,
     16#000000000000808B, 16#0000000080000001,
     16#8000000080008081, 16#8000000000008009,
     16#000000000000008A, 16#0000000000000088,
     16#0000000080008009, 16#000000008000000A,
     16#000000008000808B, 16#800000000000008B,
     16#8000000000008089, 16#8000000000008003,
     16#8000000000008002, 16#8000000000000080,
     16#000000000000800A, 16#800000008000000A,
     16#8000000080008081, 16#8000000000008080,
     16#0000000080000001, 16#8000000080008008}.
