-module(eth_hex).

%% Helpers for Ethereum-style 0x-prefixed hex encoding/decoding.

-export([decode/1, decode_bytes/1, must_decode_bytes/1, encode/1, encode_int/1, encode_bytes/1, is_hex/1]).

%% decode/1 answers an *integer* -- it is a QUANTITY decoder, and a 32-byte hash
%% can never come out of it. It is therefore not the function to reach for when
%% reading a DATA value, and it has been reached for: three times in this codebase,
%% each time producing a check that could never succeed (eth_engine's
%% parentBeaconBlockRoot test, its expectedBlobVersionedHashes test, and this
%% module's own absence).
%%
%% decode_bytes/1 is the DATA decoder: 0x-prefixed hex, or the bytes themselves, to
%% the bytes. It answers {ok, Bytes} | error so a caller can tell "not DATA" from
%% "the zero-length DATA value", which are different.
decode_bytes(Value) when is_binary(Value) ->
    case Value of
        <<"0x">> -> {ok, <<>>};
        <<"0x", Rest/binary>> -> from_hex(Rest);
        <<"0X", Rest/binary>> -> from_hex(Rest);
        %% A bare binary is taken as the bytes it already is, which is what an
        %% in-process caller holds. eth_block:data/2 has the same tolerance, and
        %% the width check belongs to the caller in both.
        _ -> {ok, Value}
    end;
decode_bytes(Value) when is_list(Value) -> decode_bytes(iolist_to_binary(Value));
decode_bytes(_Value) -> error.

%% **The raising variant, here and not at the call sites.**
%%
%% **Named `must_decode_bytes/1' and not `decode_bytes!/1'`** because `!' is not a legal
%% character in an Erlang function name -- names are lowercase identifiers, so a `!' makes
%% the parser read an unbound variable. Which is this repository's own recorded lesson
%% about a function whose name is not a function, written in AGENTS.md as `~/T(...)'. Seven modules each carried a
%% two-clause `hex_to_bin/1' because `decode_bytes/1' answers `{ok, Bytes} | error' and a
%% caller that already knows the value is DATA has to unwrap. That is a good answer for a
%% parser and a bad one for eight call sites that do not want it, so the unwrap lives
%% here rather than eight times over.
%%
%% It raises rather than returning a default. **A default is the failure mode this
%% repository keeps paying for**: `eth_hex:decode/1' is the quantity decoder, and a zero
%% returned for a value it cannot read is indistinguishable from a zero it read.
must_decode_bytes(Value) ->
    case decode_bytes(Value) of
        {ok, Bytes} -> Bytes;
        error -> error({not_a_data_value, Value})
    end.

%% Lowercase, because that is what the rest of the codebase emits and what JSON
%% peers compare hex as text against: bin0x/1 in eth_tx lowercases, and a payload
%% whose blockHash is uppercase will not equal the blockHash the same node reports
%% through a path that lowercases. binary:encode_hex/1 emits uppercase.
encode_bytes(Bin) when is_binary(Bin) ->
    <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>;
encode_bytes(Int) when is_integer(Int) ->
    encode_int(Int).

from_hex(Hex) when byte_size(Hex) rem 2 =:= 0 ->
    case is_hex(Hex) of
        true -> {ok, binary:decode_hex(Hex)};
        false -> error
    end;
from_hex(_Hex) -> error.

%% Decode "0x..." (list or binary) into an integer. Bare integers pass through.
decode(Value) when is_integer(Value) -> Value;
decode(Value) when is_binary(Value) -> decode(binary_to_list(Value));
decode(Value) when is_list(Value) ->
    S = case Value of
            "0x" ++ Rest -> Rest;
            "0X" ++ Rest -> Rest;
            Rest -> Rest
        end,
    case S of
        [] -> 0;
        _ ->
            ok = check_hex(S),
            binary_to_integer(list_to_binary(S), 16)
    end.

%% Encode an integer as "0x" hex (lowercase, no leading zeros). Lowercase
%% because that is what the rest of the codebase emits -- bin0x/1 in eth_tx
%% lowercases, and JSON peers compare hex as text -- so a quantity built here
%% and a quantity decoded there have to agree on case.
encode(0) -> "0x0";
encode(Int) when is_integer(Int), Int > 0 ->
    "0x" ++ [digit(C) || C <- integer_to_list(Int, 16)].

digit(C) when C >= $0, C =< $9 -> C;
digit(C) when C >= $A, C =< $F -> C - $A + $a.

%% Binary variant of encode/1 (what JSON objects carry around).
encode_int(Int) when is_integer(Int) ->
    list_to_binary(encode(Int)).

is_hex(Value) when is_binary(Value) -> is_hex(binary_to_list(Value));
is_hex(Value) when is_list(Value) ->
    S = case Value of
            "0x" ++ Rest -> Rest;
            "0X" ++ Rest -> Rest;
            Rest -> Rest
        end,
    lists:all(fun(C) ->
        (C >= $0 andalso C =< $9) orelse
        (C >= $a andalso C =< $f) orelse
        (C >= $A andalso C =< $F)
    end, S);
is_hex(_) -> false.

check_hex(S) ->
    true = is_hex(S),
    ok.