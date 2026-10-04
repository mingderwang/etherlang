-module(eth_header).

%% Block-header hashing: extract the ordered header fields from a JSON-RPC
%% block object, RLP-encode them, and keccak-256 the result. This is what lets
%% the node verify a fetched block *without* trusting the upstream `hash'
%% field, and check parent linkage cryptographically.

-export([hash/1, hex_hash/1, verify/1, parent_hash/1, number/1, to_rlp_list/1,
         from_rlp/1]).

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

%% Inverse: decoded header RLP list -> JSON-style map (0x hex quantities
%% and data, as from the RPC). Accepts binaries or integers per field.
from_rlp(List) when is_list(List), length(List) >= 15 ->
    from_rlp_acc(List);
from_rlp(_) ->
    {error, bad_header}.

from_rlp_acc(List) ->
    Kinds = [K || {K, _} <- header_fields()],
    Names = [N || {_, N} <- header_fields()],
    try from_zip(Kinds, Names, List, #{}) of
        Map -> {ok, Map}
    catch _:_ ->
        {error, bad_header}
    end.

from_zip([], [], [], Acc) -> Acc;
from_zip([K | Ks], [_ | Ns], [], Acc) when K =:= opt_data; K =:= opt_qty ->
    from_zip(Ks, Ns, [], Acc);
from_zip([data | Ks], [N | Ns], [V | Vs], Acc) ->
    from_zip(Ks, Ns, Vs, Acc#{N => bin0x(to_bin(V))});
from_zip([qty | Ks], [N | Ns], [V | Vs], Acc) ->
    from_zip(Ks, Ns, Vs, Acc#{N => eth_hex:encode_int(to_int(V))});
from_zip([opt_data | Ks], [N | Ns], [V | Vs], Acc) ->
    from_zip(Ks, Ns, Vs, Acc#{N => bin0x(to_bin(V))});
from_zip([opt_qty | Ks], [N | Ns], [V | Vs], Acc) ->
    from_zip(Ks, Ns, Vs, Acc#{N => eth_hex:encode_int(to_int(V))});
from_zip(_, _, _, _) -> throw(bad_header).

to_bin(B) when is_binary(B) -> B;
to_bin(I) when is_integer(I), I >= 0 -> binary:encode_unsigned(I);
to_bin(_) -> throw(bad_header).

to_int(I) when is_integer(I), I >= 0 -> I;
to_int(B) when is_binary(B), byte_size(B) =:= 0 -> 0;
to_int(B) when is_binary(B) -> binary:decode_unsigned(B);
to_int(_) -> throw(bad_header).

bin0x(<<>>) -> <<"0x">>;
bin0x(Bin) -> <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.

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

data_value(V) -> data_bytes(V).

%% "0x"-prefixed hex (binary or list) -> raw bytes.
%%
%% **Renamed from `hex_to_bin/1'.** It no longer converts hex to bytes -- it does not
%% convert anything -- it accepts a DATA value that may arrive as bytes or as an integer.
%% The old name said what this function stopped doing, and `eth_hex_owners_tests' forbids
%% a module from *defining* a hand-rolled decoder, so a delegating wrapper called
%% `hex_to_bin/1' would have been indistinguishable from a real one. **A guard that
%% cannot tell a wrapper from a copy has to be switched off**, and then it catches
%% nothing.
%%
%% **The decoder is `eth_hex:decode_bytes/1' and this function only widens it.** Two
%% things are still needed here that it does not do: an **integer** is taken as a value
%% already in hand and encoded minimally, and a **bare binary** -- a 32-byte hash rather
%% than a `0x` string -- passes through. Everything else is delegated.
%%
%% The four lines this replaces were the second hand-written hex decoder in this
%% repository, and they had a defect the owner does not: `pairs([A]) -> [hexval(A)]` turns
%% an **odd** number of hex characters into one byte per character, so `"0x123"` decoded
%% to <<0x12, 0x03>>. `eth_hex:from_hex/1` refuses an odd length outright, so that class
%% of wrong answer cannot come out of it. The other half of the old shape is recorded in
%% `eth_rpc_extra_tests`: `hexval/1` had no clause for a non-hex character, so a
%% `0x`-prefixed string handed to it raw died in `hexval(21)` -- a `function_clause` four
%% frames from the code that passed it.
data_bytes(V) when is_integer(V) -> binary:encode_unsigned(V);
data_bytes(V) -> eth_hex:must_decode_bytes(V).
