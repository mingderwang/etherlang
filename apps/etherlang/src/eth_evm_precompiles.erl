-module(eth_evm_precompiles).

%% EVM precompiled contracts at addresses 0x01..0x09. Only the stateless,
%% dependency-free ones are implemented; ecrecover (0x01) is intentionally
%% left unsupported so callers fall back to the upstream node.

-export([precompile/2, is_precompile/1]).

is_precompile(1) -> true;
is_precompile(2) -> true;
is_precompile(3) -> true;
is_precompile(4) -> true;
is_precompile(5) -> true;
is_precompile(_) -> false.

%% -> {ok, Output, GasCost} | unsupported
precompile(2, Data) ->
    {ok, crypto:hash(sha256, Data), 60 + 12 * words(Data)};
precompile(3, Data) ->
    Hash = crypto:hash(ripemd160, Data),
    {ok, <<0:96, Hash/binary>>, 600 + 120 * words(Data)};
precompile(4, Data) ->
    {ok, Data, 15 + 3 * words(Data)};
precompile(5, Data) ->
    modexp(Data);
precompile(_, _) ->
    unsupported.

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

adjusted_exp_len(LenE, _E) when LenE =< 32 -> 0;
adjusted_exp_len(LenE, _E) -> 8 * (LenE - 32).
