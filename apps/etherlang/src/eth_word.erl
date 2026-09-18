-module(eth_word).

%% 256-bit word arithmetic for the EVM. All values are Erlang big integers in
%% the unsigned range 0..2^256-1 unless noted; helpers for two's-complement
%% signed interpretation and byte encoding are provided.

-export([mask/1, add/2, sub/2, mul/2, udiv/2, sdiv/2, umod/2, smod/2,
         addmod/3, mulmod/3, exp/2, signextend/2,
         lt/2, gt/2, slt/2, sgt/2, eq/2, iszero/1,
         andb/2, orb/2, xorb/2, notb/1, byte/2, shl/2, shr/2, sar/2,
         signed/1, unsigned/1, to_bytes/1, to_bytes/2, from_bytes/1,
         powmod/3]).

-define(MASK, 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF).
-define(MOD, 16#10000000000000000000000000000000000000000000000000000000000000000).

mask(X) -> X band ?MASK.

add(A, B) -> (A + B) band ?MASK.
sub(A, B) -> (A - B) band ?MASK.
mul(A, B) -> (A * B) band ?MASK.

udiv(_A, 0) -> 0;
udiv(A, B) -> A div B.

sdiv(_A, 0) -> 0;
sdiv(A, B) -> unsigned(signed(A) div signed(B)).

umod(_A, 0) -> 0;
umod(A, B) -> A rem B.

smod(_A, 0) -> 0;
smod(A, B) -> unsigned(signed(A) rem signed(B)).

%% (A + B) mod N; EVM computes the sum in full precision, so no masking first.
addmod(_A, _B, 0) -> 0;
addmod(A, B, N) -> (A + B) rem N.

mulmod(_A, _B, 0) -> 0;
mulmod(A, B, N) -> (A * B) rem N.

exp(_Base, 0) -> 1;
exp(Base, E) -> powmod(Base band ?MASK, E, ?MOD).

signextend(B, X) when B >= 31 -> X band ?MASK;
signextend(B, X) ->
    Bits = 8 * B + 8,
    SignBit = 1 bsl (Bits - 1),
    case X band SignBit of
        0 -> X band (SignBit - 1);
        _ -> X bor (?MASK bxor (SignBit - 1)) band ?MASK
    end.

lt(A, B) -> bool(A < B).
gt(A, B) -> bool(A > B).
slt(A, B) -> bool(signed(A) < signed(B)).
sgt(A, B) -> bool(signed(A) > signed(B)).
eq(A, B) -> bool(A =:= B).
iszero(A) -> bool(A =:= 0).

andb(A, B) -> A band B.
orb(A, B) -> A bor B.
xorb(A, B) -> A bxor B.
notb(A) -> ?MASK bxor A.

%% BYTE(i, x): the i-th byte counting from the most significant.
byte(I, _X) when I >= 32 -> 0;
byte(I, X) -> (X bsr (8 * (31 - I))) band 16#FF.

shl(_X, S) when S >= 256 -> 0;
shl(X, S) -> (X bsl S) band ?MASK.

shr(_X, S) when S >= 256 -> 0;
shr(X, S) -> X bsr S.

sar(X, S) when S >= 256 ->
    case signed(X) < 0 of
        true -> ?MASK;
        false -> 0
    end;
sar(X, S) ->
    unsigned(signed(X) bsr S).

signed(X) when X >= 16#8000000000000000000000000000000000000000000000000000000000000000 ->
    X - ?MOD;
signed(X) -> X.

unsigned(N) -> N band ?MASK.

%% Minimal big-endian encoding (zero -> empty), as used by RLP/ABI lengths.
to_bytes(0) -> <<>>;
to_bytes(X) when X > 0 -> binary:encode_unsigned(X).

%% Fixed-width big-endian encoding (X is masked to N bytes).
to_bytes(X, N) ->
    B = binary:encode_unsigned(X band ((1 bsl (8 * N)) - 1)),
    Pad = N - byte_size(B),
    <<0:(Pad * 8), B/binary>>.

from_bytes(<<>>) -> 0;
from_bytes(Bin) when is_binary(Bin) -> binary:decode_unsigned(Bin).

powmod(_B, _E, M) when M =< 0 -> 0;
powmod(B, E, M) -> powmod(B rem M, E, M, 1).

powmod(_B, 0, _M, Acc) -> Acc;
powmod(B, E, M, Acc) ->
    Acc1 = case E band 1 of
               1 -> (Acc * B) rem M;
               0 -> Acc
           end,
    powmod((B * B) rem M, E bsr 1, M, Acc1).

bool(true) -> 1;
bool(false) -> 0.
