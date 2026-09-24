-module(eth_header).

%% Block-header hashing: extract the ordered header fields from a JSON-RPC
%% block object, RLP-encode them, and keccak-256 the result. This is what lets
%% the node verify a fetched block *without* trusting the upstream `hash'
%% field, and check parent linkage cryptographically.

-export([hash/1, hex_hash/1, verify/1, parent_hash/1, number/1, to_rlp_list/1]).

%% Ordered header layout (Ethereum JSON field names).
%% `sha3Uncles' is the ommers hash, `miner' the beneficiary.
header_fields() ->
    [{data, <<"parentHash">>},
     {data, <<"sha3Uncles">>},
     {data, <<"miner">>},
     {data, <<"stateRoot">>},
     {data, <<"transactionsRoot">>},
     {data, <<"receiptsRoot">>},
     {data, <<"logsBloom">>},
     {qty,  <<"difficulty">>},
     {qty,  <<"number">>},
     {qty,  <<"gasLimit">>},
     {qty,  <<"gasUsed">>},
     {qty,  <<"timestamp">>},
     {data, <<"extraData">>},
     {data, <<"mixHash">>},
     {data, <<"nonce">>},
     {opt_qty,  <<"baseFeePerGas">>},
     {opt_data, <<"withdrawalsRoot">>},
     {opt_qty,  <<"blobGasUsed">>},
     {opt_qty,  <<"excessBlobGas">>},
     {opt_data, <<"parentBeaconBlockRoot">>},
     {opt_data, <<"requestsHash">>}].

hash(Block) when is_map(Block) ->
    case header_term(Block) of
        {ok, List} -> {ok, eth_keccak:hash(eth_rlp:encode(List))};
        {error, _} = E -> E
    end.

%% Canonical 0x-prefixed lowercase hex form used for block `hash' values.
hex_hash(Block) ->
    case hash(Block) of
        {ok, H} -> {ok, hex0x(H)};
        {error, _} = E -> E
    end.

%% Returns {ok, 0xHexHash} when the claimed `hash' matches (or is absent),
%% otherwise {error, {bad_block_hash, Claimed, Actual}}.
verify(Block) when is_map(Block) ->
    case hash(Block) of
        {ok, H} ->
            Hex = hex0x(H),
            case maps:get(<<"hash">>, Block, undefined) of
                undefined -> {ok, Hex};
                Claimed ->
                    case string:lowercase(Claimed) =:= Hex of
                        true -> {ok, Hex};
                        false -> {error, {bad_block_hash, Claimed, Hex}}
                    end
            end;
        {error, _} = E ->
            E
    end.

hex0x(Bin) ->
    <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.

parent_hash(Block) -> maps:get(<<"parentHash">>, Block, undefined).

number(Block) ->
    try eth_hex:decode(maps:get(<<"number">>, Block)) catch _:_ -> undefined end.

%% Ordered RLP term for a header (for eth/68 BlockHeaders replies).
to_rlp_list(Block) when is_map(Block) ->
    header_term(Block).

%% ---------------------------------------------------------------------------

header_term(Block) ->
    try
        {ok, lists:foldr(fun(F, Acc) -> field(F, Block, Acc) end, [], header_fields())}
    catch
        throw:{missing_header_field, K} -> {error, {missing_header_field, K}}
    end.

%% Foldr with accumulation reversed building: prepend, so final list keeps order.
field({Kind, Key}, Block, Acc) ->
    case Kind of
        data ->
            [data_value(required(Key, Block)) | Acc];
        qty ->
            [qty_value(required(Key, Block)) | Acc];
        opt_data ->
            case maps:get(Key, Block, undefined) of
                undefined -> Acc;
                V -> [data_value(V) | Acc]
            end;
        opt_qty ->
            case maps:get(Key, Block, undefined) of
                undefined -> Acc;
                V -> [qty_value(V) | Acc]
            end
    end.

required(Key, Block) ->
    case maps:get(Key, Block, undefined) of
        undefined -> throw({missing_header_field, Key});
        V -> V
    end.

qty_value(V) when is_integer(V) -> V;
qty_value(V) -> eth_hex:decode(V).

data_value(V) -> hex_to_bin(V).

%% "0x"-prefixed hex (binary or list) -> raw bytes.
hex_to_bin(V) when is_binary(V) -> hex_to_bin(binary_to_list(V));
hex_to_bin(V) when is_integer(V) -> binary:encode_unsigned(V);
hex_to_bin("0x" ++ R) -> hex_to_bin(R);
hex_to_bin("0X" ++ R) -> hex_to_bin(R);
hex_to_bin(L) when is_list(L) -> list_to_binary(pairs(L)).

pairs([A, B | T]) -> [(hexval(A) bsl 4) bor hexval(B) | pairs(T)];
pairs([A]) -> [hexval(A)];
pairs([]) -> [].

hexval(C) when C >= $0, C =< $9 -> C - $0;
hexval(C) when C >= $a, C =< $f -> C - $a + 10;
hexval(C) when C >= $A, C =< $F -> C - $A + 10.
