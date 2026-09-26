-module(eth_tx).

%% Transaction RLP encoding (legacy, EIP-2930, EIP-1559, EIP-4844) from
%% JSON-RPC maps and transaction-trie root computation for body verification.
%% EIP-7702 and other types: encoding returns {error, unsupported}; such
%% bodies are served/skipped accordingly, never fabricated.
%%
%% Also the single place transaction *validity* is decided. The block builder,
%% the transaction pool and block finalization all had their own answer to this
%% question, and the three did not agree: the builder and the pool each carried
%% their own intrinsic-gas computation, and finalization checked nothing at all.
%% Two rules that disagree about intrinsic gas charge different fees for the
%% same transaction, so this has to be one function called from one place.

-export([to_rlp/1, from_rlp/1, tx_root/1, sender/1,
         blob_versioned_hashes/1, valid_versioned_hashes/1,
         validate/1, validate/2, intrinsic_gas/1, intrinsic_gas/3, tx_type/1]).

%% The first byte of every versioned hash, per EIP-4844. Only the KZG-commitment
%% variant is defined, so a transaction carrying anything else is invalid.
-define(VERSIONED_HASH_KZG, 16#01).
-define(SECP256K1_N, 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141).

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
        eip4844 ->
            {ok, <<16#03, (eth_rlp:encode(
                             [q(Tx, <<"chainId">>), q(Tx, <<"nonce">>),
                              q(Tx, <<"maxPriorityFeePerGas">>),
                              q(Tx, <<"maxFeePerGas">>),
                              q(Tx, <<"gas">>),
                              addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>),
                              access_list(Tx),
                              q(Tx, <<"maxFeePerBlobGas">>),
                              blob_versioned_hashes(Tx),
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
do_from_rlp(<<16#03, _/binary>> = Bin) ->
    Rest = binary:part(Bin, 1, byte_size(Bin) - 1),
    case eth_rlp:decode(Rest) of
        {ok, [ChainID, Nonce, MaxPrio, MaxFee, Gas, To, Value, Input, AL,
              MaxFeePerBlobGas, VersionedHashes, V, R, S], <<>>} ->
            {ok, #{<<"type">> => <<"0x3">>,
                   <<"chainId">> => hexq(ChainID),
                   <<"nonce">> => hexq(Nonce),
                   <<"maxPriorityFeePerGas">> => hexq(MaxPrio),
                   <<"maxFeePerGas">> => hexq(MaxFee),
                   <<"gas">> => hexq(Gas),
                   <<"to">> => hexdata(To),
                   <<"value">> => hexq(Value),
                   <<"input">> => hexdata(Input),
                   <<"accessList">> => from_access_list(AL),
                   <<"maxFeePerBlobGas">> => hexq(MaxFeePerBlobGas),
                   <<"blobVersionedHashes">> => [hexdata(H) || H <- VersionedHashes],
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

%% A quantity, in the minimal hex form JSON-RPC requires ("0x0", "0x7", never
%% "0x07"). RLP decodes an integer to a binary, so the bytes are folded back
%% into an integer here; emitting bin0x/1 directly would produce leading zeros
%% for any quantity whose top byte happens to be zero.
hexq(I) when is_integer(I) -> eth_hex:encode_int(I);
hexq(B) when is_binary(B), byte_size(B) =:= 0 -> <<"0x0">>;
hexq(B) when is_binary(B) -> eth_hex:encode_int(binary:decode_unsigned(B));
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
        %% EIP-4844: the signing preimage stops at the versioned hashes. Unlike
        %% legacy/2930/1559 there is no "unsigned" flag byte -- the type prefix
        %% already distinguishes the preimage from the full encoding, because
        %% the full encoding simply has three more RLP items appended.
        eip4844 ->
            Pay = [q(Tx, <<"chainId">>), q(Tx, <<"nonce">>),
                   q(Tx, <<"maxPriorityFeePerGas">>),
                   q(Tx, <<"maxFeePerGas">>),
                   q(Tx, <<"gas">>),
                   addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>),
                   access_list(Tx),
                   q(Tx, <<"maxFeePerBlobGas">>),
                   blob_versioned_hashes(Tx)],
            {eth_keccak:hash(<<16#03, (eth_rlp:encode(Pay))/binary>>),
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
%% Validity
%% ---------------------------------------------------------------------------

%% Every rule a transaction must satisfy to be includable in a block, and the one
%% function that answers the question. Returns ok or {error, Reason}.
%%
%% The context supplies what cannot be read off the transaction alone:
%%
%%   base_fee      :: integer() | undefined   this block's base fee
%%   blob_base_fee :: integer() | undefined   the blob gas price
%%   chain_id      :: integer() | undefined   the configured chain
%%   gas_limit     :: integer()               the block's gas limit
%%   gas_used      :: integer() | undefined   gas already spent in this block
%%   balance_of    :: fun((Address) -> {ok, integer()})
%%   nonce_of      :: fun((Address) -> {ok, integer()})
%%
%% A context key that is absent is a rule that is not checked, not a rule that
%% passes by default. That is the right bias for the checks that need state: a
%% caller with no view of the sender cannot confirm the nonce, and reporting ok
%% for "cannot tell" would be indistinguishable from "valid". The base fee and
%% chain id are the exception -- a caller that does not supply them is a caller
%% that has not told us the rules, so nothing is invented.
%%
%% `from' is deliberately not consulted. It is a JSON-RPC annotation, not part of
%% the signed transaction, and no consensus rule mentions it: a block whose
%% transactions carry a `from' that disagrees with the recovered signer is still
%% a valid block, and the sender is whatever the signature says. Checking it here
%% would reject valid blocks. A proposer assembling a block from an untrusted
%% source is a different question, and eth_block_builder asks it separately.
validate(Tx) ->
    validate(Tx, #{}).

validate(Tx, Ctx) when is_map(Tx), is_map(Ctx) ->
    try
        ensure(tx_type(Tx) =/= unsupported, {error, unsupported_type}),
        Gas = field(Tx, <<"gas">>),
        Value = field(Tx, <<"value">>),
        Nonce = field(Tx, <<"nonce">>, 0),
        GasPrice = field(Tx, <<"gasPrice">>, 0),
        MaxFee = field(Tx, <<"maxFeePerGas">>, undefined),
        MaxPriority = field(Tx, <<"maxPriorityFeePerGas">>, undefined),
        ensure(Gas > 0, {error, gas_limit_zero}),
        ensure(Value >= 0, {error, negative_value}),
        ensure(Nonce >= 0, {error, negative_nonce}),
        {To, IsCreate} = to_field(Tx),
        ensure(valid_to(To), {error, invalid_to}),
        Data = data_field(Tx),
        AccessList = access_list_field(Tx),
        ensure(fee_fields_ok(Tx, GasPrice, MaxFee, MaxPriority),
               {error, invalid_fee}),
        ensure(fee_ceiling_ok(Tx, MaxFee, GasPrice, Ctx), {error, fee_too_low}),
        ok = check_blobs(Tx, Ctx),
        ensure(Gas >= intrinsic_gas(Data, IsCreate, AccessList),
               {error, intrinsic_gas}),
        ensure(valid_signature(Tx), {error, bad_signature}),
        ok = check_chain_id(Tx, Ctx),
        ok = check_block_gas(Gas, Ctx),
        ok = check_state(Tx, Nonce, Gas, Value, MaxFee, GasPrice, Ctx),
        ok
    catch
        throw:{error, _} = Err -> Err;
        throw:Reason -> {error, Reason};
        Class:Reason -> {error, {invalid_transaction, Class, Reason}}
    end;
validate(_Tx, _Ctx) ->
    {error, invalid_transaction}.

ensure(true, _Ok) -> ok;
ensure(false, Err) -> throw(Err).

%% Strict field decoding. q/2 above is lenient -- it answers 0 for a value it
%% cannot read, which is right for the wire codec (a transaction it cannot parse
%% should not crash the caller) and wrong for validation, where "I could not read
%% this nonce" and "the nonce is zero" must not be the same answer. A transaction
%% whose quantity has a leading zero or a non-hex digit is malformed, and
%% JSON-RPC requires the minimal form, so both are rejected.
field(Tx, Key) ->
    field(Tx, Key, undefined).

field(Tx, Key, Default) ->
    case maps:get(Key, Tx, Default) of
        undefined -> undefined;
        I when is_integer(I), I >= 0 -> I;
        B when is_binary(B) -> decode_quantity(B, Key);
        _ -> throw({error, {bad_field, Key}})
    end.

decode_quantity(<<"0x">>, _Key) -> 0;
decode_quantity(<<"0x", S/binary>>, Key) -> decode_hex_quantity(S, Key);
decode_quantity(<<"0X", S/binary>>, Key) -> decode_hex_quantity(S, Key);
decode_quantity(B, _Key) when is_binary(B) ->
    try binary:decode_unsigned(B)
    catch _:_ -> throw({error, bad_uint}) end;
decode_quantity(_, Key) ->
    throw({error, {bad_field, Key}}).

%% binary:decode_hex/1 rejects an odd-length digit string and raises badarg, and
%% JSON-RPC quantities have no leading zeros, so "0x1" has one digit.
decode_hex_quantity(S, Key) ->
    case all_hex_digits(S) of
        false ->
            throw({error, {bad_field, Key}});
        true ->
            case non_canonical_digits(S) of
                true -> throw({error, {non_canonical_quantity, Key}});
                false -> hex_to_int(pad_even(S))
            end
    end.

%% binary:decode_unsigned/1 reads its argument as *bytes*, so handing it the
%% digit string "01546d72" yields the integer 0x3031353436643731 -- the ASCII
%% codes of the digits, not the number they spell. The hex decode has to come
%% first.
hex_to_int(Padded) ->
    binary:decode_unsigned(binary:decode_hex(Padded)).

%% Canonicity is a property of the *digit string*, not of the decoded bytes. A
%% one-digit "0" is the canonical spelling of zero, and it decodes to a single
%% zero byte, so a check on the bytes would reject the number zero itself. A
%% longer string beginning with '0' is a different, non-minimal spelling of the
%% same number and is malformed.
non_canonical_digits(<<>>) -> false;
non_canonical_digits(<<C, _/binary>>) when C =/= $0 -> false;
non_canonical_digits(<<_>>) -> false;
non_canonical_digits(_) -> true.

pad_even(S) ->
    case byte_size(S) rem 2 of
        0 -> S;
        1 -> <<"0", S/binary>>
    end.

all_hex_digits(<<>>) -> true;
all_hex_digits(<<C, Rest/binary>>) ->
    is_hex_digit(C) andalso all_hex_digits(Rest).

%% Written with ranges rather than a list of character literals because $A
%% through $F are *variables* in Erlang -- an upper-case letter after $ binds a
%% variable rather than naming a character -- so a case listing all sixteen
%% digits as literals silently binds C, D, E and F and stops being a pattern
%% list at all.
is_hex_digit(C) when is_integer(C) ->
    (C >= $0 andalso C =< $9) orelse
    (C >= $a andalso C =< $f) orelse
    (C >= $A andalso C =< $F).

%% The destination is classified before it is validated, because a JSON-RPC "0x"
%% is a two-byte binary that would otherwise look like a malformed address rather
%% than the empty destination meaning contract creation.
to_field(Tx) ->
    case maps:get(<<"to">>, Tx, undefined) of
        undefined -> {<<>>, true};
        null -> {<<>>, true};
        B when is_binary(B) ->
            case data_bytes(B) of
                <<>> -> {<<>>, true};
                Addr -> {Addr, false}
            end;
        _ -> throw({error, invalid_to})
    end.

valid_to(<<>>) -> true;
valid_to(B) when is_binary(B), byte_size(B) =:= 20 -> true;
valid_to(_) -> false.

data_field(Tx) ->
    case maps:get(<<"input">>, Tx, maps:get(<<"data">>, Tx, <<>>)) of
        B when is_binary(B) -> data_bytes(B);
        _ -> throw({error, bad_data})
    end.

data_bytes(<<"0x", S/binary>>) -> hex_bytes_or(S, bad_data);
data_bytes(<<"0X", S/binary>>) -> hex_bytes_or(S, bad_data);
data_bytes(B) when is_binary(B) -> B;
data_bytes(_) -> throw({error, bad_data}).

hex_bytes_or(S, Err) ->
    Padded = case byte_size(S) rem 2 of
        0 -> S;
        1 -> <<"0", S/binary>>
    end,
    case all_hex_digits(Padded) of
        false -> throw({error, Err});
        true -> binary:decode_hex(Padded)
    end.

%% An access list arrives as a list of objects over JSON-RPC and as [Address,
%% [Slot...]] pairs on the wire. Both are normalized so validation sees one
%% shape.
access_list_field(Tx) ->
    case maps:get(<<"accessList">>, Tx, []) of
        L when is_list(L) -> [normalize_access_entry(E) || E <- L];
        _ -> throw({error, invalid_access_list})
    end.

normalize_access_entry({Addr, Slots}) when is_list(Slots) ->
    {access_address(Addr), [access_slot(S) || S <- Slots]};
normalize_access_entry(#{<<"address">> := Addr, <<"storageKeys">> := Slots})
  when is_list(Slots) ->
    {access_address(Addr), [access_slot(S) || S <- Slots]};
normalize_access_entry(_) ->
    throw({error, invalid_access_list}).

access_address(B) when is_binary(B) ->
    case data_bytes(B) of
        <<Addr:20/binary>> -> Addr;
        _ -> throw({error, invalid_access_list})
    end;
access_address(_) ->
    throw({error, invalid_access_list}).

access_slot(B) when is_binary(B) ->
    case data_bytes(B) of
        <<Slot:32/binary>> -> Slot;
        _ -> throw({error, invalid_access_list})
    end;
access_slot(_) ->
    throw({error, invalid_access_list}).

%% EIP-2718/1559: a typed transaction must carry both fee fields and a legacy one
%% must not. maxPriorityFeePerGas above maxFeePerGas is also malformed -- the
%% tip could never be paid out.
fee_fields_ok(Tx, GasPrice, MaxFee, MaxPriority) ->
    case tx_type(Tx) of
        eip1559 -> valid_1559_fees(MaxFee, MaxPriority);
        eip4844 -> valid_1559_fees(MaxFee, MaxPriority);
        _ -> is_integer(GasPrice) andalso GasPrice >= 0
    end.

valid_1559_fees(MaxFee, MaxPriority) ->
    is_integer(MaxFee) andalso is_integer(MaxPriority) andalso
        MaxPriority =< MaxFee.

%% Under EIP-1559 a transaction is only includable when its ceiling covers the
%% base fee. Pre-London there is no base fee and so no floor.
fee_ceiling_ok(Tx, MaxFee, GasPrice, Ctx) ->
    case maps:get(base_fee, Ctx, undefined) of
        BaseFee when is_integer(BaseFee) ->
            Ceiling = case tx_type(Tx) of
                eip1559 -> MaxFee;
                eip4844 -> MaxFee;
                _ -> GasPrice
            end,
            is_integer(Ceiling) andalso Ceiling >= BaseFee;
        _ ->
            true
    end.

%% EIP-4844 blob rules. Three of them, and they are separate failures so a caller
%% can tell why a blob transaction was rejected:
%%
%%   * at least one blob, and every versioned hash a well-formed KZG commitment
%%     hash;
%%   * maxFeePerBlobGas is mandatory;
%%   * maxFeePerBlobGas must cover the block's blob gas price, or the blobs are
%%     not purchasable. That price comes from the context because it depends on
%%     the parent block's excess blob gas; when the caller cannot supply it the
%%     floor is not checked rather than guessed.
check_blobs(Tx, Ctx) ->
    case tx_type(Tx) of
        eip4844 ->
            ensure(valid_versioned_hashes(Tx), {error, bad_blob_hashes}),
            MaxFeePerBlobGas = field(Tx, <<"maxFeePerBlobGas">>),
            ensure(is_integer(MaxFeePerBlobGas), {error, invalid_blob_fee}),
            case maps:get(blob_base_fee, Ctx, undefined) of
                undefined -> ok;
                Price when is_integer(Price) ->
                    ensure(MaxFeePerBlobGas >= Price, {error, blob_fee_too_low})
            end;
        _ ->
            ok
    end.

%% Intrinsic gas: the floor a transaction pays whatever it does, from the
%% transaction's own shape. 21000 for a call, 53000 for contract creation, 4 per
%% zero byte and 16 per non-zero byte of calldata, plus EIP-2930 access list costs
%% (2400 per address, 1900 per storage key), plus EIP-3860 init code word cost
%% (Shanghai).
%%
%% Note that binary_to_list/1 yields integers, so the zero-byte case must match
%% the integer 0. A <<0>> pattern would silently charge every byte the non-zero
%% rate.
intrinsic_gas(Tx) ->
    {_To, IsCreate} = to_field(Tx),
    intrinsic_gas(data_field(Tx), IsCreate, access_list_field(Tx)).

intrinsic_gas(Data, IsCreate, AccessList) when is_binary(Data), is_list(AccessList) ->
    Base = case IsCreate of
        true -> 53000;
        false -> 21000
    end,
    DataGas = lists:foldl(fun(0, A) -> A + 4;
                             (_, A) -> A + 16
                          end, 0, binary_to_list(Data)),
    AccessGas = lists:foldl(fun({_Addr, Slots}, A) ->
        A + 2400 + 1900 * length(Slots)
    end, 0, AccessList),
    Base + DataGas + AccessGas + initcode_gas(Data, IsCreate);
intrinsic_gas(_Data, _IsCreate, _AccessList) ->
    0.

initcode_gas(_Data, false) -> 0;
initcode_gas(Data, true) -> 2 * ((byte_size(Data) + 31) div 32).

%% Signature validity has two independent parts, and only the second is usually
%% noticed:
%%
%%   1. The EIP-2 malleability bound. r must lie in [1, N-1] and s in [1, N/2].
%%      The upper half of s is malleable -- replacing s with N-s gives a second
%%      valid signature over the same message -- so those are rejected outright.
%%      This is what makes a transaction hash a stable identifier rather than one
%%      of many.
%%
%%   2. That recovery succeeds at all. Public-key recovery succeeds for almost
%%      any (r, s, v); it just yields a different address, so "recovery
%%      succeeded" on its own proves nothing about the signature being any good.
valid_signature(Tx) ->
    R = word32(Tx, <<"r">>),
    S = word32(Tx, <<"s">>),
    V = field(Tx, <<"v">>),
    case {in_group_range(R), low_half_s(S), valid_recovery_id(Tx, V)} of
        {true, true, true} ->
            case sender(Tx) of
                {ok, _} -> true;
                _ -> false
            end;
        _ ->
            false
    end.

in_group_range(I) when is_integer(I) -> I >= 1 andalso I < ?SECP256K1_N;
in_group_range(_) -> false.

%% `r' and `s' are DATA, not QUANTITY. This is the one place where applying the
%% JSON-RPC quantity rule to a transaction field is simply wrong: the spec spells
%% both as 32-byte values, so a real node returns them zero-padded to 66 hex
%% characters, and "0x00a1b2..." is the *correct* encoding of a signature whose top
%% byte happens to be zero. Treating them as quantities -- rejecting any leading
%% zero -- would refuse roughly one transaction in 256 for no protocol reason.
%%
%% Their *width* is deliberately not policed either. Recovery depends only on the
%% integer value, so a short spelling of the same r recovers the same address, and
%% refusing it would be a liveness bug with no security benefit. What does have to
%% hold is the range, and in_group_range/1 checks that: anything at or above the
%% group order is not a signature component however it was spelled. A missing
%% component is a bad signature and an unreadable one is a bad field, because
%% absent and corrupt are different faults.
word32(Tx, Key) ->
    case maps:get(Key, Tx, undefined) of
        undefined -> undefined;
        I when is_integer(I), I >= 0 -> I;
        B when is_binary(B) -> decode_word32(B, Key);
        _ -> throw({error, {bad_field, Key}})
    end.

decode_word32(<<>>, _Key) -> 0;
decode_word32(<<"0x", S/binary>>, Key) -> decode_word32_hex(S, Key);
decode_word32(<<"0X", S/binary>>, Key) -> decode_word32_hex(S, Key);
decode_word32(B, Key) when is_binary(B) ->
    case byte_size(B) =< 32 of
        true -> binary:decode_unsigned(B);
        false -> throw({error, {bad_field, Key}})
    end;
decode_word32(_, Key) -> throw({error, {bad_field, Key}}).

decode_word32_hex(S, Key) ->
    case all_hex_digits(S) of
        false -> throw({error, {bad_field, Key}});
        true -> hex_to_int(pad_even(S))
    end.

low_half_s(S) when is_integer(S) -> S >= 1 andalso S =< ?SECP256K1_N div 2;
low_half_s(_) -> false.

%% Legacy v is the unprotected 27/28 or EIP-155's chainId*2+35+recid. Typed
%% transactions carry a bare recovery id.
valid_recovery_id(Tx, V) when is_integer(V) ->
    case tx_type(Tx) of
        legacy -> V =:= 27 orelse V =:= 28 orelse V >= 35;
        _ -> V =:= 0 orelse V =:= 1
    end;
valid_recovery_id(_Tx, _V) ->
    false.

%% EIP-155 replay protection. A legacy transaction carries the chain id inside v
%% as chainId*2+35+recid, a typed one carries it explicitly. An *unprotected*
%% legacy transaction has no chain id at all, and on a chain that has a chain id
%% that is exactly what replay protection exists to prevent -- so it is rejected
%% rather than treated as "chain id absent, therefore fine".
check_chain_id(Tx, Ctx) ->
    case maps:get(chain_id, Ctx, undefined) of
        undefined -> ok;
        Expected -> ensure(tx_chain_id(Tx) =:= Expected, {error, wrong_chain_id})
    end.

tx_chain_id(Tx) ->
    case tx_type(Tx) of
        legacy ->
            case field(Tx, <<"v">>) >= 35 of
                true -> (field(Tx, <<"v">>) - 35) div 2;
                false -> undefined
            end;
        _ ->
            field(Tx, <<"chainId">>)
    end.

%% A block's gas limit bounds the whole block, so a transaction that does not fit
%% in what is left cannot be in the block at all -- regardless of whether the
%% transaction would succeed on its own. This is checked against the gas already
%% consumed by the transactions before it, which is the only point at which the
%% running total is the block's.
check_block_gas(Gas, Ctx) ->
    case {maps:get(gas_limit, Ctx, undefined), maps:get(gas_used, Ctx, 0)} of
        {Limit, Used} when is_integer(Limit), is_integer(Used) ->
            ensure(Used + Gas =< Limit, {error, exceeds_block_gas_limit});
        _ ->
            ok
    end.

%% The payer is whoever the signature recovers to. The cost ceiling is
%% maxFeePerGas (the worst case, since the block's tip is at most that much
%% above the base fee) for a typed transaction and gasPrice for a legacy one,
%% plus the value transferred.
check_state(Tx, Nonce, Gas, Value, MaxFee, GasPrice, Ctx) ->
    case sender(Tx) of
        {ok, Payer} ->
            Price = validation_price(MaxFee, GasPrice),
            check_balance(Payer, Gas * Price + Value, Ctx),
            check_nonce(Payer, Nonce, Ctx);
        _ ->
            %% valid_signature/1 has already rejected a transaction whose sender
            %% does not recover, so this is unreachable; leaving it as ok rather
            %% than throwing keeps the failure attributable to bad_signature.
            ok
    end.

validation_price(MaxFee, _GasPrice) when is_integer(MaxFee) -> MaxFee;
validation_price(_MaxFee, GasPrice) when is_integer(GasPrice) -> GasPrice;
validation_price(_, _) -> 0.

check_balance(Payer, Total, Ctx) ->
    case maps:get(balance_of, Ctx, undefined) of
        Fun when is_function(Fun, 1) ->
            case Fun(Payer) of
                {ok, Balance} when is_integer(Balance) ->
                    ensure(Balance >= Total, {error, insufficient_balance});
                _ -> ok
            end;
        _ ->
            ok
    end.

%% The sender's account nonce must equal the transaction nonce. A higher nonce
%% stalls the account behind a gap; a lower one is a replay of a transaction the
%% sender has already had accepted.
check_nonce(Payer, Nonce, Ctx) ->
    case maps:get(nonce_of, Ctx, undefined) of
        Fun when is_function(Fun, 1) ->
            case Fun(Payer) of
                {ok, AccountNonce} when is_integer(AccountNonce) ->
                    ensure(AccountNonce =:= Nonce, {error, bad_nonce});
                _ -> ok
            end;
        _ ->
            ok
    end.

%% ---------------------------------------------------------------------------

%% Type inference from fields: explicit `type' wins, else presence of
%% 1559/2930 fee fields decides; default legacy.
tx_type(Tx) ->
    case maps:get(<<"type">>, Tx, undefined) of
        <<"0x0">> -> legacy;
        <<"0x1">> -> eip2930;
        <<"0x2">> -> eip1559;
        <<"0x3">> -> eip4844;
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

%% EIP-4844 blob versioned hashes, as 32-byte binaries. A transaction with no
%% blob hashes is a malformed blob transaction rather than a valid one, but
%% this helper only performs the shape conversion: whether a hash is
%% well-formed, and whether the transaction pays enough for the blobs it
%% references, are validity rules enforced by the block builder, not part of
%% the wire codec.
blob_versioned_hashes(Tx) ->
    case maps:get(<<"blobVersionedHashes">>, Tx,
                  maps:get(<<"blob_versioned_hashes">>, Tx, [])) of
        L when is_list(L) -> [blob_versioned_hash(H) || H <- L];
        _ -> []
    end.

%% A versioned hash is the version byte followed by the SHA-256 of the
%% commitment, minus that hash's first byte. It commits to the blob's
%% commitment without revealing it.
blob_versioned_hash(<<Version, Rest/binary>>) when byte_size(Rest) =:= 31 ->
    <<Version, Rest/binary>>;
blob_versioned_hash(B) when is_binary(B), byte_size(B) =:= 32 ->
    B;
blob_versioned_hash(<<"0x", B/binary>>) when byte_size(B) =:= 64 ->
    <<Version, Rest/binary>> = hex_bytes(B),
    <<Version, Rest/binary>>;
blob_versioned_hash(H) when is_integer(H), H >= 0 ->
    <<H:256>>;
blob_versioned_hash(_) ->
    <<>>.

%% EIP-4844 validity for the versioned hashes themselves. A blob transaction
%% must reference at least one blob, and every referenced hash must be exactly
%% 32 bytes, carry the KZG-commitment version byte, and be non-zero -- a
%% zero hash would commit to nothing. The blob *gas* price floor is a separate
%% rule that depends on the block, and lives in the block builder.
valid_versioned_hashes(Tx) ->
    Hashes = blob_versioned_hashes(Tx),
    Hashes =/= [] andalso
    lists:all(fun
                  (<<?VERSIONED_HASH_KZG, Rest/binary>>) when byte_size(Rest) =:= 31 ->
                      Rest =/= <<0:248>>;
                  (_) ->
                      false
              end, Hashes).

hex_bytes(<<"0x", Rest/binary>>) -> hex_bytes(Rest);
hex_bytes(<<"0X", Rest/binary>>) -> hex_bytes(Rest);
hex_bytes(<<>>) -> <<>>;
hex_bytes(B) when is_binary(B) ->
    try binary:decode_hex(B) catch _:_ -> <<>> end;
hex_bytes(_) -> <<>>.
