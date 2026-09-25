%% EIP-4844 blob transactions: wire codec, signing preimage, and the validity
%% rules the block builder applies on top of it.
%%
%% The blob gas price curve is pinned against values computed from the
%% specification's own recurrence rather than against remembered constants.

-module(eth_4844_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CHAIN_ID, 11155111).
-define(GWEI, 1000000000).

%% ---------------------------------------------------------------------------
%% Wire format
%% ---------------------------------------------------------------------------

%% A blob transaction encodes as 0x03 || rlp of fourteen items: the 1559
%% fields, then the access list, then the two blob-specific fields, then the
%% signature. Getting the order wrong here is silent -- the bytes still decode
%% to *something* -- so the field list is checked item by item.
blob_tx_encoding_test() ->
    Hash = versioned_hash(1),
    Tx = base_tx(#{<<"blobVersionedHashes">> => [bin0x(Hash)],
                   <<"maxFeePerBlobGas">> => <<"0x3b9aca00">>}),
    {ok, <<16#03, Rest/binary>>} = eth_tx:to_rlp(Tx),
    {ok, Fields, <<>>} = rlp_list(Rest),
    [ChainID, Nonce, MaxPrio, MaxFee, Gas, To, Value, Data, AL,
     MaxFeePerBlobGas, Hashes, V, R, S] = Fields,
    ?assertEqual(?CHAIN_ID, to_int(ChainID)),
    ?assertEqual(0, to_int(Nonce)),
    ?assertEqual(3, to_int(MaxPrio)),
    ?assertEqual(2 * ?GWEI, to_int(MaxFee)),
    ?assertEqual(100000, to_int(Gas)),
    ?assertEqual(to_bin(<<"0x1000000000000000000000000000000000000001">>), To),
    ?assertEqual(7, to_int(Value)),
    ?assertEqual(<<16#de, 16#ad>>, Data),
    ?assertEqual([], AL),
    ?assertEqual(?GWEI, to_int(MaxFeePerBlobGas)),
    ?assertEqual([Hash], Hashes),
    ?assert(is_integer(to_int(V)) andalso is_integer(to_int(R))
            andalso is_integer(to_int(S))).

%% Decoding is the inverse of encoding, and the type byte must survive.
blob_tx_roundtrip_test() ->
    Tx = base_tx(#{<<"blobVersionedHashes">> => [bin0x(versioned_hash(1))],
                   <<"maxFeePerBlobGas">> => <<"0x3b9aca00">>}),
    {ok, Enc} = eth_tx:to_rlp(Tx),
    {ok, Decoded} = eth_tx:from_rlp(Enc),
    ?assertEqual(<<"0x3">>, maps:get(<<"type">>, Decoded)),
    ?assertEqual(maps:get(<<"maxFeePerBlobGas">>, Tx),
                 maps:get(<<"maxFeePerBlobGas">>, Decoded)),
    ?assertEqual(maps:get(<<"blobVersionedHashes">>, Tx),
                 maps:get(<<"blobVersionedHashes">>, Decoded)),
    ?assertEqual(maps:get(<<"nonce">>, Tx), maps:get(<<"nonce">>, Decoded)),
    ?assertEqual(maps:get(<<"value">>, Tx), maps:get(<<"value">>, Decoded)),
    %% The blob fields are part of the signed payload, so the decoded map must
    %% re-encode to exactly the same bytes or the signature would not verify.
    {ok, Reencoded} = eth_tx:to_rlp(Decoded),
    ?assertEqual(Enc, Reencoded).

%% A blob transaction's signing preimage is the encoding minus the three
%% signature items. This is checked against the bytes that were actually
%% hashed rather than against the field list, so a mismatch in either the
%% encoder or the signer shows up.
blob_tx_sighash_excludes_signature_test() ->
    Hash = versioned_hash(1),
    {Blob, Digest} = sign_with(
                       base_tx(#{<<"blobVersionedHashes">> => [bin0x(Hash)],
                                 <<"maxFeePerBlobGas">> => <<"0x3b9aca00">>}),
                       eth_secp256k1:generate_key()),
    {ok, Sender} = eth_tx:sender(Blob),
    ?assert(is_binary(Sender)),
    ?assertEqual(20, byte_size(Sender)),

    {ok, <<16#03, Rest/binary>>} = eth_tx:to_rlp(Blob),
    {ok, Fields, <<>>} = rlp_list(Rest),
    {Preimage, _Sig} = lists:split(length(Fields) - 3, Fields),
    ?assertEqual(3, length(_Sig)),
    ?assertEqual(Digest, eth_keccak:hash(<<16#03, (eth_rlp:encode(Preimage))/binary>>)).

%% ---------------------------------------------------------------------------
%% Versioned hashes
%% ---------------------------------------------------------------------------

%% A versioned hash is the version byte followed by the SHA-256 of the
%% commitment with its first byte removed.
versioned_hash_test() ->
    Commitment = <<16#c0:131072>>,
    %% The version byte *replaces* the first byte of the SHA-256 of the
    %% commitment, so the result is 1 + 31 bytes whatever the digest happens
    %% to start with.
    <<_First, Rest/binary>> = crypto:hash(sha256, Commitment),
    Hash = <<1, Rest/binary>>,
    ?assertEqual(32, byte_size(Hash)),
    ?assertEqual([Hash],
                 eth_tx:blob_versioned_hashes(
                   #{<<"blobVersionedHashes">> => [bin0x(Hash)]})).

%% Validity: non-empty, 32 bytes, KZG version byte, non-zero.
versioned_hash_validity_test() ->
    Good = #{<<"blobVersionedHashes">> => [bin0x(versioned_hash(1))]},
    ?assert(eth_tx:valid_versioned_hashes(Good)),
    ?assertNot(eth_tx:valid_versioned_hashes(#{})),
    ?assertNot(eth_tx:valid_versioned_hashes(
                 #{<<"blobVersionedHashes">> => []})),
    %% Wrong version byte.
    ?assertNot(eth_tx:valid_versioned_hashes(
                 #{<<"blobVersionedHashes">> => [<<2, (binary:copy(<<0>>, 31))/binary>>]})),
    %% All-zero remainder commits to nothing.
    ?assertNot(eth_tx:valid_versioned_hashes(
                 #{<<"blobVersionedHashes">> => [<<1, (binary:copy(<<0>>, 31))/binary>>]})),
    %% Too short.
    ?assertNot(eth_tx:valid_versioned_hashes(
                 #{<<"blobVersionedHashes">> => [<<1, 2, 3>>]})).

%% ---------------------------------------------------------------------------
%% Blob gas
%% ---------------------------------------------------------------------------

%% A block that used no more than the per-block target carries no excess, so
%% the price is the 1 wei minimum.
blob_gas_price_floor_test() ->
    ?assertEqual(1, eth_fork_schedule:blob_gas_price(0)),
    ?assertEqual(1, eth_fork_schedule:blob_base_fee(0, 0)),
    ?assertEqual(1, eth_fork_schedule:blob_base_fee(0, eth_fork_schedule:blob_gas_per_blob())).

%% Excess blob gas is the parent's excess plus what the parent's blobs used,
%% less the per-block target, floored at zero. The target is three blobs.
excess_blob_gas_test() ->
    PerBlob = eth_fork_schedule:blob_gas_per_blob(),
    ?assertEqual(131072, PerBlob),
    ?assertEqual(0, eth_fork_schedule:excess_blob_gas(0, 0)),
    ?assertEqual(0, eth_fork_schedule:excess_blob_gas(0, 3 * PerBlob)),
    ?assertEqual(PerBlob, eth_fork_schedule:excess_blob_gas(0, 4 * PerBlob)),
    %% Parent excess is carried forward, not recomputed from zero.
    ?assertEqual(PerBlob, eth_fork_schedule:excess_blob_gas(PerBlob, 3 * PerBlob)),
    ?assertEqual(2 * PerBlob, eth_fork_schedule:excess_blob_gas(PerBlob, 4 * PerBlob)).

%% The price curve is fake_exponential(1, excess, 3338477). Rather than quote a
%% remembered constant, the expected value is recomputed here by an independent
%% transcription of the specification's recurrence.
blob_gas_price_matches_spec_test() ->
    lists:foreach(fun(Excess) ->
        ?assertEqual(spec_blob_price(Excess), eth_fork_schedule:blob_gas_price(Excess))
    end, [0, 1, 2, 131072, 131073, 393216, 1000000, 5000000, 100000000]).

%% The price rises with excess blob gas, but the curve is flat near zero: the
%% first several orders of magnitude of excess are swallowed by the integer
%% division inside fake_exponential, so the price stays at 1 wei. Asserting
%% strict growth from zero would be asserting something the specification does
%% not promise.
blob_gas_price_is_monotonic_test() ->
    Points = lists:seq(0, 400000, 20000) ++ [10, 1000, 100000, 10000000,
                                              1000000000, 100000000000],
    Prices = [eth_fork_schedule:blob_gas_price(P) || P <- Points],
    ?assertEqual(Prices, lists:sort(Prices)),
    ?assertEqual(1, hd(Prices)),
    %% Once the curve clears the truncation it grows, and it keeps growing.
    ?assert(eth_fork_schedule:blob_gas_price(10000000) >
           eth_fork_schedule:blob_gas_price(100000)),
    ?assert(eth_fork_schedule:blob_gas_price(1000000000) >
           eth_fork_schedule:blob_gas_price(10000000)),
    ?assert(eth_fork_schedule:blob_gas_price(100000000000) >
           eth_fork_schedule:blob_gas_price(1000000000)).

%% ---------------------------------------------------------------------------
%% Block builder integration
%% ---------------------------------------------------------------------------

blob_tx_accepted_test() ->
    Tx = sign(base_tx(#{<<"blobVersionedHashes">> => [bin0x(versioned_hash(1))],
                        <<"maxFeePerBlobGas">> => <<"0x3b9aca00">>})),
    Ctx = #{chain_id => ?CHAIN_ID, base_fee => ?GWEI, blob_base_fee => 1},
    ?assertEqual({ok, true}, eth_block_builder:validate_transaction(Tx, Ctx)).

%% The blob gas floor is separate from the execution base fee: a transaction
%% that easily covers the base fee is still invalid if it underbids the blob.
blob_tx_fee_floor_test() ->
    Tx = sign(base_tx(#{<<"blobVersionedHashes">> => [bin0x(versioned_hash(1))],
                        <<"maxFeePerBlobGas">> => <<"0x3b9aca00">>})),
    %% One wei offered against a two-wei blob price.
    Underbid = Tx#{<<"maxFeePerBlobGas">> => <<"0x1">>},
    Ctx = #{chain_id => ?CHAIN_ID, base_fee => ?GWEI, blob_base_fee => 2},
    ?assertEqual({error, blob_fee_too_low},
                 eth_block_builder:validate_transaction(Underbid, Ctx)),
    %% The same transaction is fine once the block's blob price drops to the
    %% one wei being offered: the blob floor is independent of the base fee.
    ?assertEqual({ok, true},
                 eth_block_builder:validate_transaction(Underbid,
                     Ctx#{blob_base_fee => 1})).

blob_tx_without_hashes_rejected_test() ->
    Tx = sign(base_tx(#{<<"maxFeePerBlobGas">> => <<"0x3b9aca00">>})),
    ?assertEqual({error, bad_blob_hashes},
                 eth_block_builder:validate_transaction(Tx, #{chain_id => ?CHAIN_ID})).

blob_tx_without_blob_fee_rejected_test() ->
    Tx = sign(base_tx(#{<<"blobVersionedHashes">> => [bin0x(versioned_hash(1))]})),
    ?assertEqual({error, invalid_blob_fee},
                 eth_block_builder:validate_transaction(Tx, #{chain_id => ?CHAIN_ID})).

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

base_tx(Extra) ->
    maps:merge(#{<<"type">> => <<"0x3">>,
                 <<"chainId">> => eth_hex:encode_int(?CHAIN_ID),
                 <<"nonce">> => <<"0x0">>,
                 <<"maxPriorityFeePerGas">> => <<"0x3">>,
                 %% Comfortably above the 1 gwei base fee used in the block
                 %% builder tests, so fee failures are not what is under test.
                 <<"maxFeePerGas">> => eth_hex:encode_int(2 * ?GWEI),
                 <<"gas">> => <<"0x186a0">>,
                 <<"to">> => <<"0x1000000000000000000000000000000000000001">>,
                 <<"value">> => <<"0x7">>,
                 <<"input">> => <<"0xdead">>}, Extra).

%% RLP decodes integers to binaries, so a test that wants to compare against
%% integers folds the scalars back with to_int/1. Byte fields (an address,
%% calldata, a versioned hash) stay binaries, because a 20-byte address is not
%% a number here.
rlp_list(Rest) ->
    {ok, Fields, Tail} = eth_rlp:decode(Rest),
    {ok, Fields, Tail}.

to_int(B) when is_binary(B) -> binary:decode_unsigned(B);
to_int(I) when is_integer(I) -> I.

%% Sign a blob transaction the same way a wallet would: hash the preimage, sign
%% it, then attach the signature fields. sign_with/2 also returns the digest
%% that was signed, so a test can check the preimage itself.
sign(Tx) ->
    {Signed, _Digest} = sign_with(Tx, eth_secp256k1:generate_key()),
    Signed.

sign_with(Tx, Priv) ->
    Digest = eth_keccak:hash(<<16#03, (eth_rlp:encode(preimage_fields(Tx)))/binary>>),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    {Tx#{<<"v">> => eth_hex:encode_int(V),
         <<"r">> => eth_hex:encode_int(R),
         <<"s">> => eth_hex:encode_int(S)}, Digest}.

preimage_fields(Tx) ->
    [q(maps:get(<<"chainId">>, Tx)),
     q(maps:get(<<"nonce">>, Tx)),
     q(maps:get(<<"maxPriorityFeePerGas">>, Tx)),
     q(maps:get(<<"maxFeePerGas">>, Tx)),
     q(maps:get(<<"gas">>, Tx)),
     to_bin(maps:get(<<"to">>, Tx)),
     q(maps:get(<<"value">>, Tx)),
     to_bin(maps:get(<<"input">>, Tx)),
     [],
     q(maps:get(<<"maxFeePerBlobGas">>, Tx, <<"0x0">>)),
     eth_tx:blob_versioned_hashes(Tx)].

q(I) when is_integer(I) -> I;
q(B) when is_binary(B) -> eth_hex:decode(B).

to_bin(<<"0x", Rest/binary>>) -> binary:decode_hex(Rest);
to_bin(B) when is_binary(B) -> B.

bin0x(B) -> <<"0x", (string:lowercase(binary:encode_hex(B)))/binary>>.

versioned_hash(Tag) ->
    <<1, (binary:copy(<<Tag>>, 31))/binary>>.

%% Independent transcription of EIP-4844's fake_exponential, used to pin
%% eth_fork_schedule:blob_gas_price/1 without trusting a quoted constant.
spec_blob_price(Excess) ->
    spec_fe(1, Excess, 3338477, 1, 0, 1 * 3338477).

spec_fe(_F, _N, D, _I, Output, Acc) when Acc =< 0 -> Output div D;
spec_fe(F, N, D, I, Output, Acc) ->
    spec_fe(F, N, D, I + 1, Output + Acc, (Acc * N) div (D * I)).
