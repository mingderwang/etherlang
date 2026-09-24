-module(eth_receipt).

%% Receipt RLP (legacy + EIP-2718 typed) and receipt-trie roots.
%% Wire receipts carry no tx/block context; serving attaches it from the
%% block. JSON maps use 0x hex fields like the RPC.

-export([to_rlp/1, from_rlp/1, to_map/1, receipt_root/1, logs_bloom/1]).

%% Encode a receipt map to wire bytes (type prefix for typed receipts).
%% Map keys: type ("0x0"/"0x1"/"0x2", default legacy), status,
%% cumulative gas (cumulative_gas_used/cumulativeGasUsed), logs_bloom
%% (computed when absent), logs ([log maps]).
to_rlp(R) when is_map(R) ->
    Status = status_val(R),
    Gas = cumulative_gas(R),
    Logs = [log_term(L) || L <- maps:get(<<"logs">>, R, [])],
    Bloom = case maps:get(<<"logs_bloom">>, R, maps:get(<<"logsBloom">>, R, undefined)) of
                undefined -> logs_bloom(Logs);
                B -> hex_bytes(B)
            end,
    case receipt_type(R) of
        legacy ->
            {ok, eth_rlp:encode([Status, Gas, Bloom, Logs])};
        T when T =:= 16#01; T =:= 16#02; T =:= 16#03 ->
            {ok, <<T, (eth_rlp:encode([Status, Gas, Bloom, Logs]))/binary>>};
        _ ->
            {error, unsupported_receipt_type}
    end.

%% Decode wire bytes to a map (status, gas_used, logs_bloom, logs, type).
from_rlp(Bin) when is_binary(Bin) ->
    try do_from_rlp(Bin)
    catch _:_ -> {error, bad_receipt} end.

do_from_rlp(<<T, Rest/binary>>) when T =:= 16#01; T =:= 16#02; T =:= 16#03 ->
    case eth_rlp:decode(Rest) of
        {ok, [Status, Gas, Bloom, Logs], <<>>} ->
            {ok, #{<<"type">> => eth_hex:encode_int(T),
                   <<"status">> => hexq(Status),
                   <<"cumulative_gas_used">> => hexq(Gas),
                   <<"logs_bloom">> => bin0x(Bloom),
                   <<"logs">> => [from_log(L) || L <- Logs]}};
        _ ->
            {error, bad_receipt}
    end;
do_from_rlp(Bin) ->
    case eth_rlp:decode(Bin) of
        {ok, [Status, Gas, Bloom, Logs], <<>>} ->
            {ok, #{<<"type">> => <<"0x0">>,
                   <<"status">> => hexq(Status),
                   <<"cumulative_gas_used">> => hexq(Gas),
                   <<"logs_bloom">> => bin0x(Bloom),
                   <<"logs">> => [from_log(L) || L <- Logs]}};
        _ ->
            {error, bad_receipt}
    end.

%% Decode wire bytes or RLP terms to a map.
to_map(B) when is_binary(B) -> from_rlp(B);
to_map(L) when is_list(L) ->
    try from_rlp(eth_rlp:encode(L)) catch _:_ -> {error, bad_receipt} end;
to_map(_) ->
    {error, bad_receipt}.

%% Trie root over receipt wire encodings (key = RLP(index)).
receipt_root(Receipts) when is_list(Receipts) ->
    try
        Pairs = lists:map(fun({R, I}) ->
            {eth_rlp:encode(I), to_wire(R)}
        end, lists:zip(Receipts, lists:seq(0, length(Receipts) - 1))),
        {ok, eth_trie:root(Pairs)}
    catch _:_ ->
        {error, bad_receipt}
    end.

%% Wire bytes for a receipt map or already-encoded binary.
to_wire(B) when is_binary(B) -> B;
to_wire(R) when is_map(R) ->
    {ok, Enc} = to_rlp(R),
    Enc.

%% Bloom over receipt logs given as RLP log terms [Addr, Topics, Data].
logs_bloom(Logs) ->
    lists:foldl(fun([Addr, Topics, _], Acc) ->
        Acc1 = eth_bloom:add(Acc, Addr),
        lists:foldl(fun(T, A) -> eth_bloom:add(A, T) end, Acc1, Topics)
    end, eth_bloom:new(), Logs).

%% ---------------------------------------------------------------------------

receipt_type(R) ->
    case maps:get(<<"type">>, R, undefined) of
        undefined ->
            legacy;
        <<"0x0">> -> legacy;
        <<"0x1">> -> 16#01;
        <<"0x2">> -> 16#02;
        <<"0x3">> -> 16#03;
        _ -> unsupported
    end.

%% Cumulative gas used (the receipt field), strictly preferred over the
%% per-transaction gas values which do NOT go on the wire.
cumulative_gas(R) ->
    case maps:get(<<"cumulative_gas_used">>, R,
                  maps:get(<<"cumulativeGasUsed">>, R, undefined)) of
        undefined -> throw(bad_receipt);
        V -> qty(V)
    end.

status_val(R) ->
    case maps:get(<<"status">>, R, 1) of
        1 -> 1;
        <<"0x1">> -> 1;
        _ -> 0
    end.

log_term(L) when is_map(L) ->
    [hex_bytes(maps:get(<<"address">>, L, <<>>)),
     [hex_bytes(T) || T <- maps:get(<<"topics">>, L, [])],
     hex_bytes(maps:get(<<"data">>, L, <<>>))];
log_term([_, _, _] = L) ->
    L.

from_log([Addr, Topics, Data]) ->
    #{<<"address">> => bin0x(Addr),
      <<"topics">> => [bin0x(T) || T <- Topics],
      <<"data">> => bin0x(Data)};
from_log(_) ->
    throw(bad_receipt).

qty(I) when is_integer(I) -> I;
qty(B) when is_binary(B) ->
    try eth_hex:decode(B) catch _:_ -> 0 end;
qty(_) -> 0.

hexq(I) when is_integer(I) -> eth_hex:encode_int(I);
hexq(B) when is_binary(B), byte_size(B) =:= 0 -> <<"0x0">>;
hexq(B) when is_binary(B) -> eth_hex:encode_int(binary:decode_unsigned(B));
hexq(_) -> throw(bad_receipt).

bin0x(<<>>) -> <<"0x">>;
bin0x(Bin) -> <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.

hex_bytes(<<"0x", Rest/binary>>) -> hex_bytes(Rest);
hex_bytes(<<"0X", Rest/binary>>) -> hex_bytes(Rest);
hex_bytes(<<>>) -> <<>>;
hex_bytes(B) when is_binary(B) ->
    try binary:decode_hex(B) catch _:_ -> <<>> end;
hex_bytes(_) -> <<>>.
