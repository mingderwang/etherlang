-module(eth_hex).

%% Helpers for Ethereum-style 0x-prefixed hex encoding/decoding.

-export([decode/1, encode/1, encode_int/1, is_hex/1]).

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

%% Encode an integer as "0x" hex (lowercase, no leading zeros).
encode(0) -> "0x0";
encode(Int) when is_integer(Int), Int > 0 ->
    "0x" ++ integer_to_list(Int, 16).

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