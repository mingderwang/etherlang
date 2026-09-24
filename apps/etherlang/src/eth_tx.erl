-module(eth_tx).

%% Transaction RLP encoding (legacy, EIP-2930, EIP-1559) from JSON-RPC maps
%% and transaction-trie root computation for body verification.
%% EIP-4844/7702 and other types: encoding returns {error, unsupported};
%% such bodies are served/skipped accordingly, never fabricated.

-export([to_rlp/1, from_rlp/1, tx_root/1, sender/1]).

%% Encode a JSON-RPC transaction map to wire bytes (type prefix included
%% for typed transactions).
to_rlp(Tx) when is_map(Tx) ->
    case tx_type(Tx) of
        legacy ->
            {ok, eth_rlp:encode(
                   [q(Tx, <<"nonce">>), q(Tx, <<"gasPrice">>), q(Tx, <<"gas">>),
                    addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>),
                    q(Tx, <<"v">>), q(Tx, <<"r">>), q(Tx, <<"s">>)])};
        eip2930 ->
            {ok, <<16#01, (eth_rlp:encode(
                             [q(Tx, <<"chainId">>), q(Tx, <<"nonce">>),
                              q(Tx, <<"gasPrice">>), q(Tx, <<"gas">>),
                              addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>),
                              access_list(Tx),
                              q(Tx, <<"v">>), q(Tx, <<"r">>), q(Tx, <<"s">>)]))/binary>>};
        eip1559 ->
            {ok, <<16#02, (eth_rlp:encode(
                             [q(Tx, <<"chainId">>), q(Tx, <<"nonce">>),
                              q(Tx, <<"maxPriorityFeePerGas">>),
                              q(Tx, <<"maxFeePerGas">>),
                              q(Tx, <<"gas">>),
                              addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>),
                              access_list(Tx),
                              q(Tx, <<"v">>), q(Tx, <<"r">>), q(Tx, <<"s">>)]))/binary>>};
        unsupported ->
            {error, unsupported_tx_type}
    end.

%% Decode wire bytes to a JSON-style map (0x hex fields, type, hash).
%% Inverse of to_rlp for legacy/2930/1559 (no `from' recovery).
from_rlp(Bin) when is_binary(Bin) ->
    try do_from_rlp(Bin)
    catch _:_ -> {error, bad_tx} end.

do_from_rlp(<<16#01, _/binary>> = Bin) ->
    Rest = binary:part(Bin, 1, byte_size(Bin) - 1),
    case eth_rlp:decode(Rest) of
        {ok, [ChainID, Nonce, GasPrice, Gas, To, Value, Input, AL, V, R, S], <<>>} ->
            {ok, #{<<"type">> => <<"0x1">>,
                   <<"chainId">> => hexq(ChainID),
                   <<"nonce">> => hexq(Nonce),
                   <<"gasPrice">> => hexq(GasPrice),
                   <<"gas">> => hexq(Gas),
                   <<"to">> => hexdata(To),
                   <<"value">> => hexq(Value),
                   <<"input">> => hexdata(Input),
                   <<"accessList">> => from_access_list(AL),
                   <<"v">> => hexq(V), <<"r">> => hexq(R), <<"s">> => hexq(S),
                   <<"hash">> => hexdata(eth_keccak:hash(Bin))}};
        _ ->
            {error, bad_tx}
    end;
do_from_rlp(<<16#02, _/binary>> = Bin) ->
    Rest = binary:part(Bin, 1, byte_size(Bin) - 1),
    case eth_rlp:decode(Rest) of
        {ok, [ChainID, Nonce, MaxPrio, MaxFee, Gas, To, Value, Input, AL, V, R, S], <<>>} ->
            {ok, #{<<"type">> => <<"0x2">>,
                   <<"chainId">> => hexq(ChainID),
                   <<"nonce">> => hexq(Nonce),
                   <<"maxPriorityFeePerGas">> => hexq(MaxPrio),
                   <<"maxFeePerGas">> => hexq(MaxFee),
                   <<"gas">> => hexq(Gas),
                   <<"to">> => hexdata(To),
                   <<"value">> => hexq(Value),
                   <<"input">> => hexdata(Input),
                   <<"accessList">> => from_access_list(AL),
                   <<"v">> => hexq(V), <<"r">> => hexq(R), <<"s">> => hexq(S),
                   <<"hash">> => hexdata(eth_keccak:hash(Bin))}};
        _ ->
            {error, bad_tx}
    end;
do_from_rlp(Bin) ->
    case eth_rlp:decode(Bin) of
        {ok, [Nonce, GasPrice, Gas, To, Value, Input, V, R, S], <<>>} ->
            Base = #{<<"nonce">> => hexq(Nonce),
                     <<"gasPrice">> => hexq(GasPrice),
                     <<"gas">> => hexq(Gas),
                     <<"to">> => hexdata(To),
                     <<"value">> => hexq(Value),
                     <<"input">> => hexdata(Input),
                     <<"v">> => hexq(V), <<"r">> => hexq(R), <<"s">> => hexq(S),
                     <<"hash">> => hexdata(eth_keccak:hash(Bin))},
            {ok, maybe_chain_id(Base, V)};
        _ ->
            {error, bad_tx}
    end.

%% EIP-155 v from large V.
maybe_chain_id(Map, V) ->
    I = to_int(V),
    case I >= 35 of
        true -> Map#{<<"chainId">> => eth_hex:encode_int((I - 35) div 2)};
        false -> Map
    end.

from_access_list(AL) when is_list(AL) ->
    [#{<<"address">> => hexdata(A),
       <<"storageKeys">> => [hexdata(K) || K <- Keys]} || [A, Keys] <- AL];
from_access_list(_) ->
    throw(bad_tx).

hexq(I) when is_integer(I) -> eth_hex:encode_int(I);
hexq(B) when is_binary(B), byte_size(B) =:= 0 -> <<"0x0">>;
hexq(B) when is_binary(B) -> bin0x(B);
hexq(_) -> throw(bad_tx).

hexdata(B) when is_binary(B) -> bin0x(B);
hexdata(_) -> throw(bad_tx).

bin0x(<<>>) -> <<"0x">>;
bin0x(Bin) -> <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.

to_int(I) when is_integer(I) -> I;
to_int(B) when is_binary(B), byte_size(B) =:= 0 -> 0;
to_int(B) when is_binary(B) -> binary:decode_unsigned(B).

%% Recover the 20-byte sender address (EIP-155 legacy + EIP-2718 typed).
sender(Tx) when is_map(Tx) ->
    try do_sender(Tx)
    catch _:_ -> {error, bad_signature} end.

do_sender(Tx) ->
    {Digest, RecID} = sighash(Tx),
    R = q(Tx, <<"r">>),
    S = q(Tx, <<"s">>),
    {ok, Pub} = eth_secp256k1:recover(Digest, R, S, RecID),
    {ok, binary:part(eth_keccak:hash(Pub), 12, 20)}.

%% {Digest, RecoveryID} for the signature.
sighash(Tx) ->
    case tx_type(Tx) of
        legacy ->
            F = [q(Tx, <<"nonce">>), q(Tx, <<"gasPrice">>), q(Tx, <<"gas">>),
                 addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>)],
            V = q(Tx, <<"v">>),
            case V of
                V27 when V27 =:= 27; V27 =:= 28 ->
                    {eth_keccak:hash(eth_rlp:encode(F)), V27 - 27};
                _ when V >= 35 ->
                    ChainID = (V - 35) div 2,
                    {eth_keccak:hash(eth_rlp:encode(F ++ [ChainID, 0, 0])),
                     (V - 35) rem 2};
                _ ->
                    throw(bad_v)
            end;
        eip2930 ->
            Pay = [q(Tx, <<"chainId">>), q(Tx, <<"nonce">>),
                   q(Tx, <<"gasPrice">>), q(Tx, <<"gas">>),
                   addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>),
                   access_list(Tx)],
            {eth_keccak:hash(<<16#01, (eth_rlp:encode(Pay))/binary>>),
             q(Tx, <<"v">>)};
        eip1559 ->
            Pay = [q(Tx, <<"chainId">>), q(Tx, <<"nonce">>),
                   q(Tx, <<"maxPriorityFeePerGas">>),
                   q(Tx, <<"maxFeePerGas">>),
                   q(Tx, <<"gas">>),
                   addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>),
                   access_list(Tx)],
            {eth_keccak:hash(<<16#02, (eth_rlp:encode(Pay))/binary>>),
             q(Tx, <<"v">>)};
        unsupported ->
            throw(unsupported_tx_type)
    end.

tx_root(Txs) when is_list(Txs) ->
    try
        Pairs = lists:map(fun({Tx, I}) ->
            {ok, Enc} = to_rlp(Tx),
            {eth_rlp:encode(I), Enc}
        end, lists:zip(Txs, lists:seq(0, length(Txs) - 1))),
        {ok, eth_trie:root(Pairs)}
    catch _:_ ->
        {error, bad_tx}
    end.

%% ---------------------------------------------------------------------------

%% Type inference from fields: explicit `type' wins, else presence of
%% 1559/2930 fee fields decides; default legacy.
tx_type(Tx) ->
    case maps:get(<<"type">>, Tx, undefined) of
        <<"0x0">> -> legacy;
        <<"0x1">> -> eip2930;
        <<"0x2">> -> eip1559;
        <<"0x3">> -> unsupported;
        <<"0x4">> -> unsupported;
        undefined ->
            case maps:is_key(<<"maxFeePerGas">>, Tx) of
                true -> eip1559;
                false ->
                    case maps:is_key(<<"accessList">>, Tx) of
                        true -> eip2930;
                        false -> legacy
                    end
            end;
        _ ->
            unsupported
    end.

%% Quantity field -> integer (missing v/r/s default 0 for unsigned use).
q(Tx, K) ->
    case maps:get(K, Tx, undefined) of
        undefined -> 0;
        I when is_integer(I) -> I;
        B when is_binary(B) ->
            try eth_hex:decode(B) catch _:_ -> 0 end;
        _ -> 0
    end.

%% Destination: 20 bytes, empty for contract creation.
addr(Tx) ->
    case maps:get(<<"to">>, Tx, undefined) of
        undefined -> <<>>;
        null -> <<>>;
        B when is_binary(B) -> hex_bytes(B);
        _ -> <<>>
    end.

data(Tx, K) ->
    case maps:get(K, Tx, undefined) of
        undefined ->
            case maps:get(<<"data">>, Tx, <<>>) of
                B when is_binary(B) -> hex_bytes(B);
                _ -> <<>>
            end;
        B when is_binary(B) -> hex_bytes(B);
        _ -> <<>>
    end.

access_list(Tx) ->
    case maps:get(<<"accessList">>, Tx, []) of
        L when is_list(L) ->
            [[hex_bytes(maps:get(<<"address">>, E, <<>>)),
              [hex_bytes(K) || K <- maps:get(<<"storageKeys">>, E, [])]]
             || E <- L];
        _ ->
            []
    end.

hex_bytes(<<"0x", Rest/binary>>) -> hex_bytes(Rest);
hex_bytes(<<"0X", Rest/binary>>) -> hex_bytes(Rest);
hex_bytes(<<>>) -> <<>>;
hex_bytes(B) when is_binary(B) ->
    try binary:decode_hex(B) catch _:_ -> <<>> end;
hex_bytes(_) -> <<>>.
