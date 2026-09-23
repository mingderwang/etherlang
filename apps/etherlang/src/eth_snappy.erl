-module(eth_snappy).

%% Minimal Snappy framing for RLPx capability messages: a general
%% decompressor (literals + 1/2/4-byte-offset copies) and a literal-only
%% compressor (valid Snappy, no match search). 16 MiB output cap.

-export([compress/1, decompress/1]).

-define(MAX_OUT, 16#FFFFFF).

%% Compress: single stream of literal chunks (<= 60 bytes each so the tag
%% stays one byte), prefixed by the varint stream length.
compress(Data) when is_binary(Data) ->
    <<(varint(byte_size(Data)))/binary, (literals(Data))/binary>>.

literals(<<>>) ->
    <<>>;
literals(Data) when byte_size(Data) =< 60 ->
    N = byte_size(Data),
    <<((N - 1) bsl 2):8, Data/binary>>;
literals(Data) ->
    <<Chunk:60/binary, Rest/binary>> = Data,
    <<(((60 - 1) bsl 2)):8, Chunk/binary, (literals(Rest))/binary>>.

%% Decompress: {ok, Plain} | {error, Reason}.
decompress(Bin) when is_binary(Bin) ->
    case get_varint(Bin) of
        {Len, Rest} when Len =< ?MAX_OUT ->
            case decode(Rest, <<>>, Len) of
                {ok, Out, <<>>} when byte_size(Out) =:= Len ->
                    {ok, Out};
                {ok, Out, _} when byte_size(Out) =:= Len ->
                    %% Trailing bytes are not valid snappy; reject.
                    {error, trailing_bytes};
                {ok, _, _} ->
                    {error, length_mismatch};
                {error, _} = E ->
                    E
            end;
        {_Len, _} ->
            {error, too_large};
        error ->
            {error, bad_length}
    end.

decode(<<>>, Out, _Len) ->
    {ok, Out, <<>>};
decode(<<Tag:8, Rest/binary>>, Out, Len) ->
    case Tag band 16#03 of
        0 ->
            literal(Tag bsr 2, Rest, Out, Len);
        1 ->
            copy1(Tag bsr 2, Rest, Out, Len);
        2 ->
            copy2(Tag bsr 2, Rest, Out, Len);
        3 ->
            copy4(Tag bsr 2, Rest, Out, Len)
    end;
decode(_, _, _) ->
    {error, truncated}.

literal(L, Rest, Out, Len) when L < 60 ->
    take_literal(L + 1, Rest, Out, Len);
literal(60, <<N:8, Rest/binary>>, Out, Len) ->
    take_literal(N + 1, Rest, Out, Len);
literal(61, <<N:16/little, Rest/binary>>, Out, Len) ->
    take_literal(N + 1, Rest, Out, Len);
literal(62, <<N:24/little, Rest/binary>>, Out, Len) ->
    take_literal(N + 1, Rest, Out, Len);
literal(63, <<N:32/little, Rest/binary>>, Out, Len) ->
    take_literal(N + 1, Rest, Out, Len);
literal(_, _, _, _) ->
    {error, truncated}.

take_literal(N, Rest, Out, Len) ->
    case byte_size(Out) + N > ?MAX_OUT of
        true ->
            {error, too_large};
        false ->
            case Rest of
                <<Lit:N/binary, Rest1/binary>> ->
                    case byte_size(Out) + N > Len of
                        true -> {error, length_mismatch};
                        false -> decode(Rest1, <<Out/binary, Lit/binary>>, Len)
                    end;
                _ ->
                    {error, truncated}
            end
    end.

copy1(N, <<OffLo:8, Rest/binary>>, Out, Len) ->
    %% Tag holds 3 length bits + 3 offset-high bits; one more offset byte.
    do_copy((N bsr 3) + 4, ((N band 16#07) bsl 8) bor OffLo,
            Rest, Out, Len);
copy1(_, _, _, _) ->
    {error, truncated}.

copy2(N, <<Off:16/little, Rest/binary>>, Out, Len) ->
    do_copy(N + 1, Off, Rest, Out, Len);
copy2(_, _, _, _) ->
    {error, truncated}.

copy4(N, <<Off:32/little, Rest/binary>>, Out, Len) ->
    do_copy(N + 1, Off, Rest, Out, Len);
copy4(_, _, _, _) ->
    {error, truncated}.

do_copy(LenC, Off, Rest, Out, Total) ->
    Pos = byte_size(Out),
    case Off =:= 0 orelse Off > Pos orelse Pos + LenC > Total of
        true ->
            {error, bad_copy};
        false ->
            decode(Rest, append_copy(Out, Pos - Off, LenC), Total)
    end.

append_copy(Out, _From, 0) ->
    Out;
append_copy(Out, From, N) ->
    B = binary:at(Out, From),
    append_copy(<<Out/binary, B>>, From + 1, N - 1).

varint(N) when N < 128 -> <<N>>;
varint(N) ->
    B = 16#80 bor (N band 16#7F),
    Rest = varint(N bsr 7),
    <<B:8, Rest/binary>>.

get_varint(Bin) -> get_varint(Bin, 0, 0).
get_varint(<<0:1, V:7, Rest/binary>>, Shift, Acc) ->
    {Acc bor (V bsl Shift), Rest};
get_varint(<<1:1, V:7, Rest/binary>>, Shift, Acc) when Shift < 35 ->
    get_varint(Rest, Shift + 7, Acc bor (V bsl Shift));
get_varint(_, _, _) ->
    error.
