-module(eth_rlp).

%% Minimal RLP encoder (Ethereum Recursive Length Prefix), enough for block
%% header hashing: binaries (byte strings), non-negative integers (quantities),
%% and lists (headers).

-export([encode/1]).

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
