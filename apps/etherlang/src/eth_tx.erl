-module(eth_tx).

%% Transaction RLP encoding (legacy, EIP-2930, EIP-1559) from JSON-RPC maps
%% and transaction-trie root computation for body verification.
%% EIP-4844/7702 and other types: encoding returns {error, unsupported};
%% such bodies are served/skipped accordingly, never fabricated.

-export([to_rlp/1, tx_root/1]).

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

%% Merkle root over [TxMap]: trie key = RLP(index), value = RLP(tx).
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
