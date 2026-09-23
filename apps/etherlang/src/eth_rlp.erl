-module(eth_rlp).

%% Minimal RLP encoder (Ethereum Recursive Length Prefix), enough for block
%% header hashing: binaries (byte strings), non-negative integers (quantities),
%% and lists (headers).

-export([encode/1, decode/1]).

encode(0) ->
    <<16#80>>;
encode(I) when is_integer(I), I > 0 ->
    encode(binary:encode_unsigned(I));
encode(Bin) when is_binary(Bin) ->
    case Bin of
        <<B>> when B < 16#80 -> <<B>>;
        _ -> length_prefixed(Bin)
    end;
encode([]) ->
    <<16#C0>>;
encode(List) when is_list(List) ->
    list_prefix(iolist_to_binary([encode(E) || E <- List])).

length_prefixed(Bin) ->
    Len = byte_size(Bin),
    if
        Len < 56 ->
            <<(16#80 + Len), Bin/binary>>;
        true ->
            LBin = binary:encode_unsigned(Len),
            <<(16#B7 + byte_size(LBin)), LBin/binary, Bin/binary>>
    end.

list_prefix(Bin) ->
    Len = byte_size(Bin),
    if
        Len < 56 ->
            <<(16#C0 + Len), Bin/binary>>;
        true ->
            LBin = binary:encode_unsigned(Len),
            <<(16#F7 + byte_size(LBin)), LBin/binary, Bin/binary>>
    end.

%% Full RLP decode. Returns {ok, Value, Rest} where Value is a binary
%% (strings/integers stay encoded; callers convert with
%% binary:decode_unsigned/1 where a quantity is expected) or a list.
decode(Bin) when is_binary(Bin) ->
    decode_one(Bin).

decode_one(<<>>) ->
    {error, empty};
decode_one(<<B, Rest/binary>>) when B < 16#80 ->
    {ok, <<B>>, Rest};
decode_one(<<16#80, Rest/binary>>) ->
    {ok, <<>>, Rest};
decode_one(<<B, Rest/binary>>) when B > 16#80, B =< 16#B7 ->
    take(B - 16#80, Rest);
decode_one(<<B, Rest/binary>>) when B > 16#B7, B =< 16#BF ->
    case take(B - 16#B7, Rest) of
        {ok, LBin, Rest1} -> take(binary:decode_unsigned(LBin), Rest1);
        {error, _} = E -> E
    end;
decode_one(<<B, Rest/binary>>) when B >= 16#C0, B =< 16#F7 ->
    take_list(B - 16#C0, Rest);
decode_one(<<B, Rest/binary>>) when B >= 16#F8 ->
    case take(B - 16#F7, Rest) of
        {ok, LBin, Rest1} -> take_list(binary:decode_unsigned(LBin), Rest1);
        {error, _} = E -> E
    end.

take(0, Rest) ->
    {ok, <<>>, Rest};
take(N, Bin) when N > 0 ->
    case Bin of
        <<S:N/binary, Rest/binary>> -> {ok, S, Rest};
        _ -> {error, truncated}
    end.

take_list(N, Bin) ->
    case Bin of
        <<Seg:N/binary, Rest/binary>> -> map_list(Seg, Rest);
        _ -> {error, truncated}
    end.

map_list(Seg, Rest) ->
    case decode_all(Seg, []) of
        {ok, Items} -> {ok, Items, Rest};
        {error, _} = E -> E
    end.

decode_all(<<>>, Acc) ->
    {ok, lists:reverse(Acc)};
decode_all(Bin, Acc) ->
    case decode_one(Bin) of
        {ok, V, Rest} -> decode_all(Rest, [V | Acc]);
        {error, _} = E -> E
    end.
