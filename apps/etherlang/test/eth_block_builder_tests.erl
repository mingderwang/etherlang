-module(eth_block_builder_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CHAIN_ID, 11155111).

%% ---------------------------------------------------------------------------
%% Transaction validation
%% ---------------------------------------------------------------------------

%% Sign a legacy EIP-155 transaction so signature recovery is exercised
%% against a real key, not a stub.
sign_legacy(Tx, Priv) ->
    sign_legacy(Tx, Priv, ?CHAIN_ID).

sign_legacy(Tx, Priv, ChainID) ->
    F = [qty(maps:get(<<"nonce">>, Tx, 0)),
         qty(maps:get(<<"gasPrice">>, Tx, 0)),
         qty(maps:get(<<"gas">>, Tx, 0)),
         addr(maps:get(<<"to">>, Tx, <<>>)),
         qty(maps:get(<<"value">>, Tx, 0)),
         data(maps:get(<<"input">>, Tx, <<>>))],
    Digest = eth_keccak:hash(eth_rlp:encode(F ++ [ChainID, 0, 0])),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    Tx#{<<"v">> => eth_hex:encode_int(V + 35 + 2 * ChainID),
        <<"r">> => eth_hex:encode_int(R),
        <<"s">> => eth_hex:encode_int(S)}.

base_tx() ->
    #{<<"nonce">> => <<"0x0">>,
      <<"gasPrice">> => <<"0x3b9aca00">>,
      <<"gas">> => <<"0x5208">>,
      <<"to">> => <<"0x1000000000000000000000000000000000000001">>,
      <<"value">> => <<"0x0">>,
      <<"input">> => <<"0x">>,
      <<"chainId">> => eth_hex:encode_int(?CHAIN_ID)}.

%% Sign an EIP-2930 typed transaction. The sighash differs from legacy: it is
%% keccak(0x01 || rlp([chainId, nonce, gasPrice, gas, to, value, data, access]))
%% and `v` is a bare recovery id.
sign_2930(Tx, Priv) ->
    F = [qty(maps:get(<<"chainId">>, Tx, ?CHAIN_ID)),
         qty(maps:get(<<"nonce">>, Tx, 0)),
         qty(maps:get(<<"gasPrice">>, Tx, 0)),
         qty(maps:get(<<"gas">>, Tx, 0)),
         addr(maps:get(<<"to">>, Tx, <<>>)),
         qty(maps:get(<<"value">>, Tx, 0)),
         data(maps:get(<<"input">>, Tx, <<>>)),
         [[addr(maps:get(<<"address">>, E)),
           [slot(K) || K <- maps:get(<<"storageKeys">>, E, [])]]
          || E <- maps:get(<<"accessList">>, Tx, [])]],
    Digest = eth_keccak:hash(<<16#01, (eth_rlp:encode(F))/binary>>),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    Tx#{<<"v">> => eth_hex:encode_int(V),
        <<"r">> => eth_hex:encode_int(R),
        <<"s">> => eth_hex:encode_int(S)}.

slot(<<"0x", R/binary>>) -> binary:decode_hex(R);
slot(B) when is_binary(B) -> B.

signed_tx() ->
    Priv = eth_secp256k1:generate_key(),
    Tx = sign_legacy(base_tx(), Priv),
    {ok, Sender} = eth_tx:sender(Tx),
    {Tx#{<<"from">> => bin0x(Sender)}, Priv}.

%% A well-formed signed legacy transaction validates.
valid_legacy_tx_test() ->
    {Tx, _} = signed_tx(),
    ?assertEqual({ok, true}, eth_block_builder:validate_transaction(Tx)).

%% A transaction whose body was altered after signing must not validate.
%% Recovery from an altered digest succeeds but yields a *different* address,
%% so the declared `from` is what actually detects the tampering.
tampered_signature_test() ->
    {Tx, _} = signed_tx(),
    Bad = Tx#{<<"value">> => eth_hex:encode_int(999)},
    ?assertEqual({error, sender_mismatch},
                 eth_block_builder:validate_transaction(Bad)).

%% EIP-2: a signature with s >= N/2 is malleable and must be rejected even
%% though it sits inside the curve order.
malleable_signature_test() ->
    {Tx, _} = signed_tx(),
    N = 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141,
    S = qty(maps:get(<<"s">>, Tx)),
    %% Flip to the upper half of the order if the signature is in the lower half.
    Upper = case S < N div 2 of
        true -> N - S;
        false -> S
    end,
    ?assertEqual({error, bad_signature},
                 eth_block_builder:validate_transaction(
                   Tx#{<<"s">> => eth_hex:encode_int(Upper)})).

%% A signature with r = 0 is outside [1, N-1] and is rejected.
zero_r_test() ->
    {Tx, _} = signed_tx(),
    ?assertEqual({error, bad_signature},
                 eth_block_builder:validate_transaction(Tx#{<<"r">> => <<"0x0">>})).

%% A transaction whose r/s are zero cannot recover a sender.
zero_signature_test() ->
    Tx = (base_tx())#{<<"v">> => eth_hex:encode_int(37 + 2 * ?CHAIN_ID),
                      <<"r">> => <<"0x0">>, <<"s">> => <<"0x0">>},
    ?assertEqual({error, bad_signature}, eth_block_builder:validate_transaction(Tx)).

%% Intrinsic gas: a plain transfer needs 21000. Anything less is invalid.
intrinsic_gas_test() ->
    Priv = eth_secp256k1:generate_key(),
    TooLow = sign_legacy((base_tx())#{<<"gas">> => eth_hex:encode_int(20999)}, Priv),
    ?assertEqual({error, intrinsic_gas}, eth_block_builder:validate_transaction(TooLow)),
    Exact = sign_legacy((base_tx())#{<<"gas">> => eth_hex:encode_int(21000)}, Priv),
    ?assertEqual({ok, true}, eth_block_builder:validate_transaction(Exact)).

%% Calldata costs 4 gas per zero byte and 16 per non-zero byte. A zero byte is
%% the common case and the one most worth pinning, because matching a <<0>>
%% binary pattern against a list of integers would silently charge 16 instead.
intrinsic_gas_calldata_test() ->
    Priv = eth_secp256k1:generate_key(),
    %% 4 zero bytes -> 21000 + 4*4 = 21016.
    FourZeros = sign_legacy(
        (base_tx())#{<<"input">> => <<"0x00000000">>,
                     <<"gas">> => eth_hex:encode_int(21016)}, Priv),
    ?assertEqual({ok, true}, eth_block_builder:validate_transaction(FourZeros)),
    SameButTooLow = sign_legacy(
        (base_tx())#{<<"input">> => <<"0x00000000">>,
                     <<"gas">> => eth_hex:encode_int(21015)}, Priv),
    ?assertEqual({error, intrinsic_gas},
                 eth_block_builder:validate_transaction(SameButTooLow)),
    %% 4 non-zero bytes -> 21000 + 4*16 = 21064.
    FourOnes = sign_legacy(
        (base_tx())#{<<"input">> => <<"0x01010101">>,
                     <<"gas">> => eth_hex:encode_int(21064)}, Priv),
    ?assertEqual({ok, true}, eth_block_builder:validate_transaction(FourOnes)),
    FourOnesTooLow = sign_legacy(
        (base_tx())#{<<"input">> => <<"0x01010101">>,
                     <<"gas">> => eth_hex:encode_int(21063)}, Priv),
    ?assertEqual({error, intrinsic_gas},
                 eth_block_builder:validate_transaction(FourOnesTooLow)).

%% Contract creation pays 32000 on top of the 21000 transfer base.
intrinsic_gas_create_test() ->
    Priv = eth_secp256k1:generate_key(),
    Create = sign_legacy(
        (base_tx())#{<<"to">> => <<"0x">>, <<"input">> => <<"0x">>,
                     <<"gas">> => eth_hex:encode_int(53000)}, Priv),
    ?assertEqual({ok, true}, eth_block_builder:validate_transaction(Create)),
    TooLow = sign_legacy(
        (base_tx())#{<<"to">> => <<"0x">>, <<"input">> => <<"0x">>,
                     <<"gas">> => eth_hex:encode_int(52999)}, Priv),
    ?assertEqual({error, intrinsic_gas}, eth_block_builder:validate_transaction(TooLow)).

%% EIP-3860 init-code metering: creation pays 2 gas per init-code word *on top
%% of* the ordinary calldata cost. 32 zero bytes is 32*4 = 128 calldata gas
%% plus 2*1 = 2 init-code gas, so 53000 + 128 + 2 = 53130.
intrinsic_gas_initcode_test() ->
    Priv = eth_secp256k1:generate_key(),
    Code = binary:copy(<<0>>, 32),
    Ok = sign_legacy(
        (base_tx())#{<<"to">> => <<"0x">>, <<"input">> => bin0x(Code),
                     <<"gas">> => eth_hex:encode_int(53130)}, Priv),
    ?assertEqual({ok, true}, eth_block_builder:validate_transaction(Ok)),
    TooLow = sign_legacy(
        (base_tx())#{<<"to">> => <<"0x">>, <<"input">> => bin0x(Code),
                     <<"gas">> => eth_hex:encode_int(53129)}, Priv),
    ?assertEqual({error, intrinsic_gas}, eth_block_builder:validate_transaction(TooLow)).

%% A zero gas limit is never valid.
zero_gas_limit_test() ->
    {Tx, _} = signed_tx(),
    ?assertEqual({error, gas_limit_zero},
                 eth_block_builder:validate_transaction(Tx#{<<"gas">> => <<"0x0">>})).

%% A malformed destination address is rejected.
invalid_to_test() ->
    {Tx, _} = signed_tx(),
    ?assertMatch({error, _},
                 eth_block_builder:validate_transaction(
                   Tx#{<<"to">> => <<"0xdeadbeef">>})).

%% An EIP-1559 transaction must carry both fee fields and the priority fee may
%% not exceed the max fee.
eip1559_fee_fields_test() ->
    Priv = eth_secp256k1:generate_key(),
    Tx = sign_legacy((base_tx())#{
        <<"type">> => <<"0x2">>,
        <<"maxFeePerGas">> => <<"0x3b9aca00">>,
        <<"maxPriorityFeePerGas">> => <<"0x3b9aca00">>}, Priv),
    %% maxPriorityFee > maxFeePerGas is not a valid 1559 transaction.
    Bad = Tx#{<<"maxPriorityFeePerGas">> => <<"0x77359400">>},
    ?assertEqual({error, invalid_fee}, eth_block_builder:validate_transaction(Bad)).

%% A 1559 transaction whose maxFeePerGas is below the current base fee can
%% never be included.
fee_ceiling_test() ->
    {Tx, _} = signed_tx(),
    Ctx = #{base_fee => 100000000000},
    ?assertEqual({error, fee_too_low}, eth_block_builder:validate_transaction(Tx, Ctx)),
    %% Below the ceiling it is accepted (the signature still checks out).
    ?assertEqual({ok, true},
                 eth_block_builder:validate_transaction(Tx, #{base_fee => 1000000000})).

%% The sender must be able to cover gas*maxFee + value.
insufficient_balance_test() ->
    {Tx, _} = signed_tx(),
    Ctx = #{balance_of => fun(_A) -> {ok, 1} end},
    ?assertEqual({error, insufficient_balance}, eth_block_builder:validate_transaction(Tx, Ctx)).

enough_balance_test() ->
    {Tx, _} = signed_tx(),
    Ctx = #{balance_of => fun(_A) -> {ok, 100000000000000000000} end},
    ?assertEqual({ok, true}, eth_block_builder:validate_transaction(Tx, Ctx)).

%% The sender's account nonce must equal the transaction nonce.
bad_nonce_test() ->
    {Tx, _} = signed_tx(),
    Ctx = #{nonce_of => fun(_A) -> {ok, 7} end},
    ?assertEqual({error, bad_nonce}, eth_block_builder:validate_transaction(Tx, Ctx)),
    Matching = #{nonce_of => fun(_A) -> {ok, 0} end},
    ?assertEqual({ok, true}, eth_block_builder:validate_transaction(Tx, Matching)).

%% EIP-155 replay protection: a transaction signed for another chain is
%% rejected when the node's chain id is known.
wrong_chain_id_test() ->
    Priv = eth_secp256k1:generate_key(),
    Tx = sign_legacy(base_tx(), Priv, 1),
    ?assertEqual({error, wrong_chain_id},
                 eth_block_builder:validate_transaction(
                   Tx, #{chain_id => ?CHAIN_ID})),
    ?assertEqual({ok, true},
                 eth_block_builder:validate_transaction(Tx, #{chain_id => 1})).

%% An unprotected legacy transaction (v = 27/28) has no chain id, so it cannot
%% satisfy a chain-id check.
unprotected_legacy_test() ->
    Priv = eth_secp256k1:generate_key(),
    Tx0 = base_tx(),
    F = [qty(maps:get(<<"nonce">>, Tx0, 0)),
         qty(maps:get(<<"gasPrice">>, Tx0, 0)),
         qty(maps:get(<<"gas">>, Tx0, 0)),
         addr(maps:get(<<"to">>, Tx0, <<>>)),
         qty(maps:get(<<"value">>, Tx0, 0)),
         data(maps:get(<<"input">>, Tx0, <<>>))],
    Digest = eth_keccak:hash(eth_rlp:encode(F)),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    Tx = Tx0#{<<"v">> => eth_hex:encode_int(V + 27),
             <<"r">> => eth_hex:encode_int(R),
             <<"s">> => eth_hex:encode_int(S)},
    ?assertEqual({error, wrong_chain_id},
                 eth_block_builder:validate_transaction(Tx, #{chain_id => ?CHAIN_ID})),
    ?assertEqual({ok, true}, eth_block_builder:validate_transaction(Tx)).

%% An EIP-2930 access list must be well formed, and it costs 2400 per address
%% plus 1900 per storage key on top of the base cost.
access_list_test() ->
    Priv = eth_secp256k1:generate_key(),
    Addr = <<16#aa:160>>,
    Slot = <<16#bb:256>>,
    Tx = sign_2930((base_tx())#{
        <<"type">> => <<"0x1">>,
        <<"accessList">> => [#{<<"address">> => bin0x(Addr),
                              <<"storageKeys">> => [bin0x(Slot)]}],
        <<"gas">> => eth_hex:encode_int(21000 + 2400 + 1900)}, Priv),
    ?assertEqual({ok, true}, eth_block_builder:validate_transaction(Tx)),
    TooLow = Tx#{<<"gas">> => eth_hex:encode_int(21000 + 2400 + 1900 - 1)},
    ?assertEqual({error, intrinsic_gas}, eth_block_builder:validate_transaction(TooLow)).

%% An access-list entry with a malformed address or slot is rejected outright.
malformed_access_list_test() ->
    {Tx, _} = signed_tx(),
    Short = Tx#{<<"accessList">> => [#{<<"address">> => <<"0xaa">>,
                                      <<"storageKeys">> => []}]},
    ?assertEqual({error, invalid_access_list},
                 eth_block_builder:validate_transaction(Short)),
    BadSlot = Tx#{<<"accessList">> =>
                     [#{<<"address">> => <<"0x", (binary:encode_hex(<<16#aa:160>>))/binary>>,
                        <<"storageKeys">> => [<<"0x01">>]}]},
    ?assertEqual({error, invalid_access_list},
                 eth_block_builder:validate_transaction(BadSlot)).

%% EIP-7702 (type 0x4) is not implemented yet and must be refused outright
%% rather than being treated as a legacy transaction and mangled. Type 0x3
%% *is* implemented now and is covered by eth_4844_tests.
unsupported_type_test() ->
    {Tx, _} = signed_tx(),
    ?assertEqual({error, unsupported_type},
                 eth_block_builder:validate_transaction(Tx#{<<"type">> => <<"0x4">>})).

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

qty(I) when is_integer(I) -> I;
qty(B) when is_binary(B) ->
    try eth_hex:decode(B) catch _:_ -> 0 end.

addr(<<"0x", R/binary>>) -> binary:decode_hex(R);
addr(B) when is_binary(B), byte_size(B) =:= 40 -> binary:decode_hex(B);
addr(_) -> <<>>.

data(<<"0x", R/binary>>) -> binary:decode_hex(R);
data(B) when is_binary(B) -> B;
data(_) -> <<>>.

bin0x(Bin) -> <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.
