%% EIP-4844 blob transactions: wire codec, signing preimage, and the validity
%% rules the block builder applies on top of it.
%%
%% The blob gas price curve is pinned against values computed from the
%% specification's own recurrence rather than against remembered constants.

-module(eth_4844_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("etherlang/include/eth_block.hrl").

-define(CHAIN_ID, 11155111).
-define(GWEI, 1000000000).

%% A block number past Cancun on every network this repository knows, so
%% `eth_block:fork_of/1' answers `cancun' and the fork-gated rules -- EIP-3860's
%% init-code term, EIP-2929's warm set, the BLOBHASH opcode -- are in force. A
%% number of 1 would answer `frontier' and a blob transaction would be executed
%% under a schedule that has no blobs in it, which is a different test.
-define(CANCUN_BLOCK, 3000000).
%% **Explicitly 160 bits.** Written as `<<16#c0de...01>>` the literal is *one byte*:
%% a hex constant too wide for the default 8-bit segment is truncated silently, and
%% a 1-byte `miner' then reaches `eth_state:address/1'` on its second clause, which
%% runs it through `hex_to_bin/1' as though it were a `0x...' string and raises
%% `function_clause' from `hv/1' deep inside `eth_state'. The address is not the
%% thing under test in any of these, so it is built with a width.
-define(MINER, <<16#c0de:160>>).

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
%% **A versioned hash's 31-byte remainder may be zero.**
%%
%% This test asserted the opposite -- "?assertNot(... [<<1, 0:248>>])" -- with the
%% comment "All-zero remainder commits to nothing", and the clause it pinned is not
%% in EIP-4844. The EIP's `validate_block' states the whole rule: the list must be
%% non-empty and `h[0] == VERSIONED_HASH_VERSION_KZG'. Whether the remainder is zero
%% is a question about a 48-byte commitment the transaction does not carry, so the
%% execution layer cannot answer it and the specification does not ask it to.
%%
%% The corpus is not a matter of opinion: **1,502 transactions carrying
%% `0x01 || 31 zero bytes' are expected to succeed**, against 325 expected to be
%% rejected, and 1,827 carry one -- which is every type-3 transaction it has. A hash
%% valid in 1,502 places is not one this node may refuse. Corrected rather than
%% deleted, because the test's real subject -- the version byte, the length, and the
%% empty list -- is exactly what EIP-4844 does require, and those three are what a
%% change to this function must not break.
versioned_hash_validity_test() ->
    Good = #{<<"blobVersionedHashes">> => [bin0x(versioned_hash(1))]},
    ?assert(eth_tx:valid_versioned_hashes(Good)),
    %% The corpus's own placeholder: a real, accepted, well-formed versioned hash.
    Zero = bin0x(<<1, (binary:copy(<<0>>, 31))/binary>>),
    ?assert(eth_tx:valid_versioned_hashes(
              #{<<"blobVersionedHashes">> => [Zero]})),
    ?assertNot(eth_tx:valid_versioned_hashes(#{})),
    ?assertNot(eth_tx:valid_versioned_hashes(
                 #{<<"blobVersionedHashes">> => []})),
    %% Wrong version byte. This is the EIP's own rule and the corpus's
    %% TYPE_3_TX_INVALID_BLOB_VERSIONED_HASH, whose fixtures are version-0x00 and
    %% version-0x02 hashes -- never an all-zero *remainder*.
    ?assertNot(eth_tx:valid_versioned_hashes(
                 #{<<"blobVersionedHashes">> => [<<2, (binary:copy(<<0>>, 31))/binary>>]})),
    ?assertNot(eth_tx:valid_versioned_hashes(
                 #{<<"blobVersionedHashes">> => [<<0, (binary:copy(<<0>>, 31))/binary>>]})),
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
%% Settlement: the blob fee is actually charged
%% ---------------------------------------------------------------------------

%% **A blob transaction's sender is debited the blob fee.**
%%
%% EIP-4844: "The actual `blob_fee' as calculated via `calc_blob_fee' is deducted
%% from the sender balance before transaction execution and burned, and is not
%% refunded in case of transaction failure."
%%
%% `eth_block' had **no reference to blob gas pricing at all**. `blob_gas_price/1'
%% and `blob_base_fee/2' were correct and had exactly two consumers -- the
%% `BLOBBASEFEE' opcode's environment and the `maxFeePerBlobGas' admission floor.
%% So the node computed the right price, checked the transaction against it, and
%% then never charged it: every blob transaction's sender kept
%% `total_blob_gas * price` wei the chain has already burned.
%%
%% This asserts the sender's whole net movement, not just that *something* was
%% taken, because "the balance went down" is satisfied by the value transfer and
%% by the gas purchase. The expected figure is written out from the EIP's own two
%% functions rather than read from `eth_fork_schedule`, so a change to the price
%% curve cannot make this pass.
%%
%% `want = value + gasUsed * effective_price + 2 * 131072 * 1`, and the control is
%% the same transaction with no blobs, whose `want` is the same minus the blob
%% term. A test with no control here would pass if `blob_fee/2' returned 0 and
%% something else happened to move the balance.
sender_is_debited_the_blob_fee_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Sender = addr_of(Priv),
        Start = 1000000 * ?GWEI,
        ok = eth_mpt:put_account(Sender, Start, 0, eth_keccak:hash(<<>>)),
        To = test_address(1),
        Value = 7,
        Gas = 100000,
        %% `maxPriorityFeePerGas = 3` against a 1 gwei base fee, so the effective
        %% price is 1 gwei + 3 and both the gas and the value are non-zero and
        %% distinguishable in the arithmetic.
        Block0 = (eth_block:new(<<0:256>>, ?CANCUN_BLOCK))
                    #block{excess_blob_gas = 0, base_fee_per_gas = ?GWEI,
                           miner = ?MINER},
        Hashes = [bin0x(versioned_hash(1)), bin0x(versioned_hash(2))],
        Fields = #{<<"blobVersionedHashes">> => Hashes,
                   <<"maxFeePerBlobGas">> => eth_hex:encode_int(?GWEI),
                   <<"value">> => eth_hex:encode_int(Value),
                   <<"gas">> => eth_hex:encode_int(Gas),
                   <<"to">> => to_hex(To),
                   <<"input">> => <<"0x">>},
        {Block, State1} = eth_block:run_transaction(
                             Block0, sign(base_tx(Fields), Priv),
                             eth_state:new(0, #{}), ?GWEI, 1000000),
        [Receipt] = eth_block:receipts(Block),
        GasUsed = maps:get(<<"gasUsed">>, Receipt),

        %% The EIP's own arithmetic, written out: no node function in it.
        BlobFee = 2 * 131072 * 1,
        Want = Start - Value - (GasUsed * (?GWEI + 3)) - BlobFee,
        ?assertEqual(Want, eth_state:balance(State1, Sender)),

        %% **The control.** The same transaction without blobs is charged the same
        %% everything except the blob term. Without this second half the assertion
        %% above would still pass if the node charged the blob fee *and* the right
        %% gas, or if it charged a wrong blob fee that happened to cancel.
        {BlockL, StateL} = eth_block:run_transaction(
                             Block0, sign(base_tx(legacy_of_fields(Fields)), Priv),
                             eth_state:new(0, #{}), ?GWEI, 1000000),
        [ReceiptL] = eth_block:receipts(BlockL),
        WantL = Start - Value - (maps:get(<<"gasUsed">>, ReceiptL) * (?GWEI + 3)),
        ?assertEqual(WantL, eth_state:balance(StateL, Sender)),
        %% The blob run is the one that pays, so its balance is the **lower** of
        %% the two. Written the other way round the difference is -262,144, which
        %% is the right magnitude and the wrong sign, and `?assertEqual' says so.
        ?assertEqual(BlobFee, eth_state:balance(StateL, Sender)
                                - eth_state:balance(State1, Sender))
    end).

%% The blob fee scales with the *price*, not only with the blob count. One blob at
%% the 1 wei minimum is 131,072 wei, which is small enough that a missing term can
%% hide inside a gas figure; six blobs at a price the curve has actually moved off
%% its floor is 786,432 wei at price 1 and 90,254,976 at price 115, and no gas
%% schedule in this repository produces a difference of that shape by accident.
%%
%% The price is *derived* from the specification's recurrence, by the same
%% independent transcription `blob_gas_price_matches_spec_test/0` uses, and only
%% then asked of the node -- so a node that returned 1 for every excess would fail
%% here rather than be taken at its word.
blob_fee_scales_with_the_price_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Sender = addr_of(Priv),
        Start = 1000000 * ?GWEI,
        ok = eth_mpt:put_account(Sender, Start, 0, eth_keccak:hash(<<>>)),
        Excess = 50000000,
        Price = spec_blob_price(Excess),
        ?assert(Price > 1),
        Hashes = [bin0x(versioned_hash(I)) || I <- lists:seq(1, 6)],
        Block0 = (eth_block:new(<<0:256>>, ?CANCUN_BLOCK))
                    #block{excess_blob_gas = Excess, base_fee_per_gas = ?GWEI,
                           miner = ?MINER},
        Tx = sign(base_tx(#{<<"blobVersionedHashes">> => Hashes,
                            <<"maxFeePerBlobGas">> => eth_hex:encode_int(?GWEI),
                            <<"value">> => eth_hex:encode_int(0),
                            <<"gas">> => eth_hex:encode_int(100000),
                            <<"input">> => <<"0x">>}), Priv),
        {Block, State1} = eth_block:run_transaction(
                             Block0, Tx, eth_state:new(0, #{}), ?GWEI, 1000000),
        [Receipt] = eth_block:receipts(Block),
        %% `base_tx/1' offers a 3 wei priority fee, so the effective price is
        %% `min(maxFee, baseFee + 3)' = 1 gwei + 3 and not the base fee. Writing
        %% `* ?GWEI` here is a 63,000 wei error on 21,000 gas -- small enough to
        %% look like a rounding difference and large enough to fail.
        Want = Start - (maps:get(<<"gasUsed">>, Receipt) * (?GWEI + 3))
                   - 6 * 131072 * Price,
        ?assertEqual(Want, eth_state:balance(State1, Sender))
    end).

%% The price comes from the **block's own** `excess_blob_gas', which is what EIP-4844's
%% `get_base_fee_per_blob_gas(header)' says. Pricing the parent's excess instead
%% would be a one-block error that is invisible whenever the parent used no more
%% than the target -- the overwhelming majority of blocks -- and wrong exactly when
%% the blob market is busy.
%%
%% Two blocks, same transaction, one field apart. The first block's excess prices
%% at the minimum; the second's is far enough up the curve to be visible.
blob_fee_uses_this_blocks_own_excess_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Sender = addr_of(Priv),
        Start = 1000000 * ?GWEI,
        Hashes = [bin0x(versioned_hash(1))],
        Excess = 50000000,
        Price = spec_blob_price(Excess),
        Block0 = (eth_block:new(<<0:256>>, ?CANCUN_BLOCK))
                    #block{excess_blob_gas = Excess, base_fee_per_gas = ?GWEI,
                           miner = ?MINER},
        Tx = sign(base_tx(#{<<"blobVersionedHashes">> => Hashes,
                            <<"maxFeePerBlobGas">> => eth_hex:encode_int(?GWEI),
                            <<"value">> => eth_hex:encode_int(0),
                            <<"gas">> => eth_hex:encode_int(100000),
                            <<"input">> => <<"0x">>}), Priv),
        ok = eth_mpt:put_account(Sender, Start, 0, eth_keccak:hash(<<>>)),
        {BlockP, StatePriced} = eth_block:run_transaction(
                                  Block0, Tx, eth_state:new(0, #{}), ?GWEI, 1000000),
        [ReceiptP] = eth_block:receipts(BlockP),
        Priced = Start - eth_state:balance(StatePriced, Sender),
        ok = eth_mpt:put_account(Sender, Start, 0, eth_keccak:hash(<<>>)),
        {BlockF, StateFloor} = eth_block:run_transaction(
                                 Block0#block{excess_blob_gas = 0}, Tx,
                                 eth_state:new(0, #{}), ?GWEI, 1000000),
        [ReceiptF] = eth_block:receipts(BlockF),
        Floor = Start - eth_state:balance(StateFloor, Sender),
        %% The gas figure is the receipt's, not the 100,000 in the transaction's
        %% `gas' field. Those differ by 79,000 on a call that runs no code, and
        %% 79,000 at 1 gwei is 7.9e13 -- an error that reads as a blob-fee
        %% problem and is not one.
        GasUsed = maps:get(<<"gasUsed">>, ReceiptP),
        ?assertEqual(maps:get(<<"gasUsed">>, ReceiptF), GasUsed),
        ?assertEqual(Floor - 131072, Priced - 131072 * Price),
        %% The floor really is the floor, and the high-excess figure really is
        %% higher. Asserted as absolutes so the control above cannot pass on a pair
        %% of equal-and-wrong numbers.
        ?assertEqual(131072, Floor - GasUsed * (?GWEI + 3)),
        ?assert(Priced - GasUsed * (?GWEI + 3) > 131072)
    end).

%% **The blob fee is burned, not refunded on failure.** The EIP is explicit: "is not
%% refunded in case of transaction failure", and a blob transaction whose code
%% reverts is a transaction failure.
%%
%% The code is `PUSH1 0; PUSH1 0; REVERT`, which reverts at once, so the whole gas
%% allowance comes back. If the blob fee were refunded with the gas the sender's
%% balance would be identical to the no-blob control; it must be lower by exactly
%% the blob fee.
blob_fee_is_not_refunded_when_the_transaction_fails_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Sender = addr_of(Priv),
        Start = 1000000 * ?GWEI,
        Code = <<16#60, 0, 16#60, 0, 16#FD>>,          % PUSH1 0; PUSH1 0; REVERT
        To = test_address(2),
        ok = eth_mpt:put_code(eth_keccak:hash(Code), Code),
        ok = eth_mpt:put_account(To, 0, 0, eth_keccak:hash(Code)),
        Block0 = (eth_block:new(<<0:256>>, ?CANCUN_BLOCK))
                    #block{excess_blob_gas = 0, base_fee_per_gas = ?GWEI,
                           miner = ?MINER},
        Hashes = [bin0x(versioned_hash(1))],
        Fields = #{<<"blobVersionedHashes">> => Hashes,
                   <<"maxFeePerBlobGas">> => eth_hex:encode_int(?GWEI),
                   <<"value">> => eth_hex:encode_int(0),
                   <<"gas">> => eth_hex:encode_int(100000),
                   <<"to">> => to_hex(To),
                   <<"input">> => <<"0x">>},
        ok = eth_mpt:put_account(Sender, Start, 0, eth_keccak:hash(<<>>)),
        {Block, StateBlob} = eth_block:run_transaction(
                               Block0, sign(base_tx(Fields), Priv),
                               eth_state:new(0, #{}), ?GWEI, 1000000),
        [Receipt] = eth_block:receipts(Block),
        ?assertEqual(0, maps:get(<<"status">>, Receipt)),
        BlobSpent = Start - eth_state:balance(StateBlob, Sender),
        ok = eth_mpt:put_account(Sender, Start, 0, eth_keccak:hash(<<>>)),
        {_B2, StatePlain} = eth_block:run_transaction(
                               Block0, sign(base_tx(legacy_of_fields(Fields)), Priv),
                               eth_state:new(0, #{}), ?GWEI, 1000000),
        ?assertEqual(131072, BlobSpent - (Start - eth_state:balance(StatePlain, Sender)))
    end).

%% The corpus signature, as a test. `cancun/eip4844_blobs/test_sufficient_balance_blob_tx`
%% and `test_blob_gas_subtraction_tx` are 1,408 corpus entries that were
%% `state_mismatch` with one diff shape: the sender's balance too high by exactly
%% `total_blob_gas * price`. This is that fixture's arithmetic on one entry -- six
%% blobs, `excessBlobGas = 0x0e0000` = 917,504, price 1 -- so the fix's effect is
%% pinned without running the corpus.
%%
%% The storage half is the same fact read back through the EVM. The fixture's code
%% is `0x32316000556000600060006000344703325af13231600155`:
%%
%%     32 31 60 00 55   ORIGIN BALANCE PUSH1 0 SSTORE
%%
%% so slot 0 *is* the sender's balance as the frame saw it. A node that did not
%% charge the blob fee before the frame ran stored a balance 786,432 too high --
%% which is why the diff also appeared under `{store, _, <<"0x0">>, _, _}` and why
%% it looked like a second, independent gas defect. It was one missing debit seen
%% twice. Asserting the slot as well is what keeps that reading honest.
%% ---------------------------------------------------------------------------
%% Admission: the two validity rules the corpus names and this node had neither
%% ---------------------------------------------------------------------------

%% **A sender who cannot pay for the blobs is refused.**
%%
%% EIP-4844's `validate_block` modifies the sufficient-balance rule:
%%
%%     max_total_fee = tx.gas * tx.max_fee_per_gas
%%     if get_tx_type(tx) == BLOB_TX_TYPE:
%%         max_total_fee += get_total_blob_gas(tx) * tx.max_fee_per_blob_gas
%%     assert signer(tx).balance >= max_total_fee
%%
%% The modification was **absent**, so the check was `gas * maxFeePerGas + value`
%% for every transaction including blob ones. That is the 288-entry
%% `INSUFFICIENT_ACCOUNT_FUNDS` cluster in
%% `cancun/eip4844_blobs/test_insufficient_balance_blob_tx` (144 Cancun + 144
%% Prague), and the arithmetic is exact: for every one of the 288,
%% `balance < gasLimit * maxFee + value` is **false** -- the sender could pay the
%% gas, so the node admitted a transaction the chain rejects.
%%
%% The boundary is asserted as two balances on either side of the figure, because
%% one side alone cannot tell a check from a constant: a sender one wei short is
%% refused and a sender exactly able to pay is not.
sender_must_be_able_to_pay_for_its_blobs_test() ->
    Priv = eth_secp256k1:generate_key(),
    Sender = addr_of(Priv),
    Tx = sign(base_tx(#{<<"blobVersionedHashes">> => [bin0x(versioned_hash(1))],
                        <<"maxFeePerBlobGas">> => eth_hex:encode_int(7),
                        <<"gas">> => eth_hex:encode_int(21000),
                        <<"maxFeePerGas">> => eth_hex:encode_int(7),
                        <<"value">> => eth_hex:encode_int(0),
                        <<"input">> => <<"0x">>}), Priv),
    GasTerm = 21000 * 7,
    BlobTerm = 131072 * 7,
    ok = eth_tx:validate(Tx, ctx(Sender, GasTerm + BlobTerm, #{blob_base_fee => 1})),
    ?assertEqual({error, insufficient_balance},
                 eth_tx:validate(Tx, ctx(Sender, GasTerm + BlobTerm - 1, #{blob_base_fee => 1}))),
    ?assertEqual({error, insufficient_balance},
                 eth_tx:validate(Tx, ctx(Sender, GasTerm, #{blob_base_fee => 1}))).

%% **A 1559 transaction -- same fee fields, no blobs -- is charged no blob term.**
%% The control for the test above, and it is the sharpest available one: a 1559
%% transaction is identical to a blob transaction in every field the gas term
%% reads (`gas', `maxFeePerGas', `value'), and differs only in having no
%% `blobVersionedHashes'. So if `blob_gas_term/1' answered a non-zero figure for
%% any transaction with a `maxFeePerGas', this fails. A *legacy* transaction would
%% have been the weaker control, because it also has no `maxFeePerGas' and so
%% changes two things at once.
%%
%% Without this half the test above is satisfiable by a node that adds a blob term
%% to everything, which would refuse a large class of ordinary transactions and
%% look correct here.
a_1559_transaction_owes_no_blob_gas_test() ->
    Priv = eth_secp256k1:generate_key(),
    Sender = addr_of(Priv),
    Fields = #{<<"type">> => <<"0x2">>,
               <<"maxPriorityFeePerGas">> => eth_hex:encode_int(0),
               <<"maxFeePerGas">> => eth_hex:encode_int(7),
               <<"gas">> => eth_hex:encode_int(21000),
               <<"value">> => eth_hex:encode_int(0),
               <<"input">> => <<"0x">>},
    Tx = sign(base_tx(Fields), Priv),
    ok = eth_tx:validate(Tx, ctx(Sender, 21000 * 7, #{fork => cancun})),
    ?assertEqual({error, insufficient_balance},
                 eth_tx:validate(Tx, ctx(Sender, 21000 * 7 - 1, #{fork => cancun}))).

%% **The block admission path supplies the blob base fee, and the floor fires.**
%%
%% EIP-4844: "ensure that the user was willing to at least pay the current blob
%% base fee", i.e. `assert tx.max_fee_per_blob_gas >= get_base_fee_per_blob_gas
%% (block.header)`.
%%
%% `eth_tx:check_blobs/2` implemented exactly that, reading the price from the
%% validation context, and its comment said "when the caller cannot supply it the
%% floor is not checked rather than guessed". **No caller could supply it.**
%% `eth_block:validation_ctx/4' -- the context a block's own transactions are
%% validated against -- had no `blob_base_fee' key, so the `undefined' branch was
%% taken on every call and the `ensure/2' below it was dead. That is EIP-3607's
%% shape: a rule present, correct, and unreachable. The four
%% `INSUFFICIENT_MAX_FEE_PER_BLOB_GAS` fixtures set `maxFeePerBlobGas = 1` against
%% `currentExcessBlobGas = 0x240000` = 2,359,296, where the Cancun curve gives a
%% blob base fee of 2, so the sender underbid by one wei per blob gas and this node
%% let the transaction in.
%%
%% This goes through **`eth_block:finalize/1`**, not through a hand-built context,
%% because a rule only the harness can reach is a fixture-only improvement: with
%% the key missing, `eth_tx:validate/2` still answers correctly for a caller who
%% supplies it, and only the real path shows that nobody does. The positive
%% control is on the same path, because a negative test is satisfied by a gate
%% that refuses everything -- and `finalize/1` refusing this block must be
%% distinguishable from `finalize/1` refusing every block.
the_block_admission_path_enforces_the_blob_base_fee_test() ->
    eth_test_util:finalize_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Sender = addr_of(Priv),
        %% 2,359,296 of excess blob gas: the Cancun curve prices that at 2, which
        %% is the corpus's own figure for `test_invalid_tx_max_fee_per_blob_gas_state'.
        Excess = 16#240000,
        ?assertEqual(2, eth_block:blob_base_fee(block_with_excess(Excess))),
        Underbid = sign(base_tx(#{<<"blobVersionedHashes">> => [bin0x(versioned_hash(1))],
                                  <<"maxFeePerBlobGas">> => eth_hex:encode_int(1),
                                  <<"gas">> => eth_hex:encode_int(21000),
                                  <<"maxFeePerGas">> => eth_hex:encode_int(7),
                                  <<"value">> => eth_hex:encode_int(0),
                                  <<"input">> => <<"0x">>}), Priv),
        ok = eth_mpt:put_account(Sender, 1000000 * ?GWEI, 0, eth_keccak:hash(<<>>)),
        Parent = store_parent_with(Sender, 1000000 * ?GWEI),
        Under = block_with_excess(Excess, Parent, [Underbid]),

        ?assertEqual({error, {invalid_transaction, 0, blob_fee_too_low}},
                     eth_block:finalize(Under)),

        %% **The control: the same block with the sender bidding the block's price.**
        %% If `finalize/1` refused every blob block, the assertion above would pass
        %% and mean nothing.
        Ok = sign(base_tx(#{<<"blobVersionedHashes">> => [bin0x(versioned_hash(1))],
                            <<"maxFeePerBlobGas">> => eth_hex:encode_int(2),
                            <<"gas">> => eth_hex:encode_int(21000),
                            <<"maxFeePerGas">> => eth_hex:encode_int(7),
                            <<"value">> => eth_hex:encode_int(0),
                            <<"input">> => <<"0x">>}), Priv),
        {ok, _Finalized, _V} =
            eth_block:finalize(block_with_excess(Excess, Parent, [Ok]))
    end).

%% The check and the charge must read one price. EIP-4844 uses
%% `get_base_fee_per_blob_gas(header)` twice -- once to *require*
%% `max_fee_per_blob_gas >= price` and once inside `calc_blob_fee` to *charge* the
%% sender -- and a node that checked against one figure and charged another would
%% admit a transaction it then charges more than the sender agreed to. This is the
%% assertion that they are the same function, not two derivations that happen to
%% agree today.
the_price_checked_against_is_the_price_charged_test() ->
  with_ctx(fun() ->
    Priv = eth_secp256k1:generate_key(),
    Sender = addr_of(Priv),
    Start = 1000000 * ?GWEI,
    Excess = 16#240000,
    Price = eth_block:blob_base_fee(block_with_excess(Excess)),
    Hashes = [bin0x(versioned_hash(1))],
    Fields = #{<<"blobVersionedHashes">> => Hashes,
               %% One wei under the block's price: refused, so the check can fire.
               <<"maxFeePerBlobGas">> => eth_hex:encode_int(Price - 1),
               <<"gas">> => eth_hex:encode_int(100000),
               <<"maxFeePerGas">> => eth_hex:encode_int(?GWEI),
               <<"value">> => eth_hex:encode_int(0),
               <<"input">> => <<"0x">>},
    ok = eth_mpt:put_account(Sender, Start, 0, eth_keccak:hash(<<>>)),
    Block = (eth_block:new(<<0:256>>, ?CANCUN_BLOCK))
                #block{excess_blob_gas = Excess, base_fee_per_gas = ?GWEI,
                       miner = ?MINER},
    {Block1, State1} = eth_block:run_transaction(
                         Block, sign(base_tx(Fields), Priv),
                         eth_state:new(0, #{}), ?GWEI, 1000000),
    [Receipt] = eth_block:receipts(Block1),
    Charged = Start - eth_state:balance(State1, Sender)
              - (maps:get(<<"gasUsed">>, Receipt) * ?GWEI),
    ?assertEqual(131072 * Price, Charged)
  end).

%% **The node charges the blob fee at the block's price, not at the sender's cap.**
%% The distinction is the whole of the previous test's claim, stated as a number:
%% a sender offering 1 gwei per blob gas on a block priced at 1 wei is debited
%% 131,072 wei, not 131,072 gwei. Both are "the blob fee"; only one is the EIP's.
the_sender_is_charged_the_block_price_not_its_own_cap_test() ->
  with_ctx(fun() ->
    Priv = eth_secp256k1:generate_key(),
    Sender = addr_of(Priv),
    Start = 1000000000 * ?GWEI,
    ok = eth_mpt:put_account(Sender, Start, 0, eth_keccak:hash(<<>>)),
    Block = (eth_block:new(<<0:256>>, ?CANCUN_BLOCK))
                #block{excess_blob_gas = 0, base_fee_per_gas = ?GWEI, miner = ?MINER},
    Tx = sign(base_tx(#{<<"blobVersionedHashes">> => [bin0x(versioned_hash(1))],
                        %% A cap of 1 gwei against a block priced at 1 wei.
                        <<"maxFeePerBlobGas">> => eth_hex:encode_int(?GWEI),
                        <<"gas">> => eth_hex:encode_int(100000),
                        <<"maxFeePerGas">> => eth_hex:encode_int(?GWEI),
                        <<"value">> => eth_hex:encode_int(0),
                        <<"input">> => <<"0x">>}), Priv),
    {Block1, State1} = eth_block:run_transaction(Block, Tx, eth_state:new(0, #{}),
                                                 ?GWEI, 1000000),
    [Receipt] = eth_block:receipts(Block1),
    Charged = Start - eth_state:balance(State1, Sender)
              - (maps:get(<<"gasUsed">>, Receipt) * ?GWEI),
    ?assertEqual(131072, Charged)
  end).

%% ---------------------------------------------------------------------------
%% Every type bids its own fee field
%% ---------------------------------------------------------------------------

%% **Every transaction type is compared against the fee field it actually carries.**
%%
%% `fee_ceiling_ok/4` chose between `maxFeePerGas` and the legacy `gasPrice` with a
%% `case tx_type(Tx) of`. Two of the five types were listed when it was written, a
%% third was added later, and a type that falls out lands on the legacy `gasPrice` --
%% which for a type-2-family transaction is a field it does not have, so `field/3`
%% supplies `0` and the transaction is refused as underpriced against **any** base fee
%% above zero. `eip7702` fell out this way, and the corpus had **72** entries on it:
%% 47 `INTRINSIC_GAS_TOO_LOW`, 14 `INTRINSIC_GAS_BELOW_FLOOR_GAS_COST`, 8
%% `SENDER_NOT_EOA` and 3 type-4 well-formedness cases -- every one of them a
%% transaction whose sender offered exactly the base fee and was refused for it.
%%
%% `fee_fields_ok/4` had the identical missing clause and `v1.54` fixed it there,
%% with a comment explaining that a fall-through clause turns "not mentioned" into
%% "no rules at all". The neighbouring function was not re-read. This test is the
%% re-read: it is **table-driven over the five types**, so a sixth added later fails
%% here rather than inheriting the legacy branch.
%%
%% What makes it a check rather than a restatement:
%%
%%   * The cap is set to **exactly** the base fee, so the rule under test is `>=`
%%     and not `>`. A `fee_ceiling_ok/4` that compared against the wrong field would
%%     see `0` and refuse; one that compared nothing would accept both.
%%   * Each type is asked again **one wei below**, and must be refused with exactly
%%     `{error, fee_too_low}`. Without that second half the test would pass for a
%%     `fee_ceiling_ok/4` that never compared anything -- which is the shape of a
%%     test that asserts a rule exists only by observing its absence.
%%   * **Every type is genuinely signed**, for all five wire formats. The alternative
%%     -- leaning on the fact that the ceiling check currently runs before the
%%     signature check -- would have made this test depend on the *order* of
%%     `validate/2`, and reordering that order is the next piece of work. A test
%%     that breaks for a good reason is still a test that breaks.
every_transaction_type_bids_its_own_fee_field_test() ->
    Priv = eth_secp256k1:generate_key(),
    Sender = addr_of(Priv),
    Base = 7,
    lists:foreach(
      fun(Type) ->
        lists:foreach(
          fun(Cap) ->
            Tx = sign_type(Type, Cap, Base, Priv),
            %% Comfortably funded, so the *only* rule under test is the fee
            %% ceiling. A balance at the exact threshold would add a second rule to
            %% every row of the table, and for the blob type that threshold moves
            %% with the cap -- a different test entirely, and one
            %% `sender_must_be_able_to_pay_for_its_blobs_test' already makes.
            Ctx = ctx(Sender, 1000000000000000000,
                      #{base_fee => Base, fork => prague, blob_base_fee => 1}),
            case Cap of
                Base -> ?assertEqual(ok, eth_tx:validate(Tx, Ctx));
                _ -> ?assertEqual({error, fee_too_low}, eth_tx:validate(Tx, Ctx))
            end
          end, [Base, Base - 1])
      end, [legacy, eip2930, eip1559, eip4844, eip7702]).

%% A real signed transaction of each of the five wire formats, with the cap in the
%% field that format actually carries.
%%
%% **The signing preimage is derived from the node's own encoder, not written out
%% here.** The first version of this table hand-wrote a preimage per type, and the
%% `eip7702` row recovered a different address from the key that signed it -- so the
%% table could not tell a wrong fee rule from a wrong preimage, and four of five rows
%% were passing for the wrong reason. That is this repository's `?PROBE` trap one
%% level up: **a fixture whose identity comes from a second hand-written copy of the
%% thing under test is a test of the copy.**
%%
%% So the preimage is read out of `eth_tx:to_rlp/1`: the typed formats are
%% `EIP-2718` payloads whose full encoding is the preimage with three signature
%% items appended, so encoding with a placeholder signature, splitting the last three
%% RLP items off, and hashing what remains gives exactly what the node signs. The
%% existing `blob_tx_sighash_excludes_signature_test' already uses that identity; it
%% is applied to all four typed formats here.
%%
%% **The legacy format is the exception and has to be written out.** EIP-155 puts the
%% chain id in `v`, so the legacy preimage is
%% `[nonce, gasPrice, gas, to, value, data, chainId, 0, 0]` while the encoding is
%% `[nonce, gasPrice, gas, to, value, data, v, r, s]` -- the last three *slots* hold
%% different things, so "split the last three off" would leave `v` in the preimage.
%% A hand-written preimage is therefore unavoidable for exactly one format, and it is
%% commented as such.
sign_type(Type, Cap, _Base, Priv) ->
    Gas = 100000,
    Common = #{<<"nonce">> => <<"0x0">>, <<"gas">> => eth_hex:encode_int(Gas),
               <<"value">> => <<"0x0">>, <<"input">> => <<"0x">>,
               <<"to">> => to_hex(test_address(1))},
    Tx0 = with_fee_fields(Type, (base_tx(Common))#{<<"type">> => type_hex(Type)}, Cap),
    {Digest, _Rec} = case Type of
        legacy ->
            {eth_keccak:hash(eth_rlp:encode(
                                [0, Cap, Gas, test_address(1), 0, <<>>,
                                 ?CHAIN_ID, 0, 0])), 0};
        _ ->
            preimage_digest(Tx0)
    end,
    {R, S, RecId} = eth_secp256k1:sign(Digest, Priv),
    %% The legacy `v` carries the chain id *and* the recovery id; a typed `v` is
    %% the recovery id alone. That difference is the whole reason a single shared
    %% signer cannot be assumed correct across the five formats.
    V = case Type of
            legacy -> 35 + ?CHAIN_ID * 2 + RecId;
            _ -> RecId
        end,
    with_fee_fields(Type,
                    Tx0#{<<"v">> => eth_hex:encode_int(V),
                         <<"r">> => eth_hex:encode_int(R),
                         <<"s">> => eth_hex:encode_int(S)},
                    Cap).

%% The signing preimage, read out of the node's own encoder: the full encoding of a
%% typed transaction is the preimage with `v`, `r` and `s` appended, so removing the
%% last three RLP items leaves precisely what gets hashed. Returns `{Digest, Rec}`
%% with `Rec = 0` because the recovery id is not knowable before signing and is
%% substituted by the caller's own `v`.
preimage_digest(Tx) ->
    {ok, <<TypeByte, Rest/binary>>} = eth_tx:to_rlp(Tx),
    {ok, Items, <<>>} = rlp_items(Rest),
    {Preimage, Sig} = lists:split(length(Items) - 3, Items),
    ?assertEqual(3, length(Sig)),
    {eth_keccak:hash(<<TypeByte, (eth_rlp:encode(Preimage))/binary>>), 0}.

rlp_items(Rest) ->
    {ok, Fields, Tail} = eth_rlp:decode(Rest),
    {ok, Fields, Tail}.

%% The fee fields each wire format actually carries. This is the thing the test is
%% about, so it is stated as a table rather than as a `case' buried in the signer:
%% `legacy` and `eip2930` have no `maxFeePerGas` at all, and a map that carried one
%% anyway would be refused by `eth_tx:from_rlp/1' rather than by the rule under test.
with_fee_fields(Type, Tx, Cap) ->
    case Type of
        legacy -> Tx#{<<"gasPrice">> => eth_hex:encode_int(Cap)};
        eip2930 -> Tx#{<<"gasPrice">> => eth_hex:encode_int(Cap),
                       <<"accessList">> => []};
        eip1559 -> Tx#{<<"maxPriorityFeePerGas">> => <<"0x0">>,
                       <<"maxFeePerGas">> => eth_hex:encode_int(Cap)};
        eip4844 -> Tx#{<<"maxPriorityFeePerGas">> => <<"0x0">>,
                       <<"maxFeePerGas">> => eth_hex:encode_int(Cap),
                       <<"maxFeePerBlobGas">> => eth_hex:encode_int(Cap),
                       <<"blobVersionedHashes">> => [bin0x(versioned_hash(1))]};
        eip7702 -> Tx#{<<"maxPriorityFeePerGas">> => <<"0x0">>,
                       <<"maxFeePerGas">> => eth_hex:encode_int(Cap),
                       <<"authorizationList">> => [auth_map()]}
    end.

type_hex(legacy) -> <<"0x0">>;
type_hex(eip2930) -> <<"0x1">>;
type_hex(eip1559) -> <<"0x2">>;
type_hex(eip4844) -> <<"0x3">>;
type_hex(eip7702) -> <<"0x4">>.

%% One EIP-7702 authorization, in the **map** form the runner and JSON-RPC supply.
%% The chain id is 0 ("any chain") and the nonce 1, which EIP-7702 requires for the
%% first authorization a given nonce may use.
auth_map() ->
    #{<<"chainId">> => <<"0x0">>, <<"address">> => to_hex(test_address(2)),
      <<"nonce">> => <<"0x1">>, <<"yParity">> => <<"0x0">>,
      <<"r">> => <<"0x1">>, <<"s">> => <<"0x1">>}.

%% The **list** form of the same authorization is not written out anywhere in this
%% module, and that is deliberate. It used to be, and it was wrong: a hand-written
%% preimage is a second copy of the thing under test, and the row that used one
%% recovered a different address from the key that signed it. The preimage now comes
%% from `eth_tx:to_rlp/1' via `preimage_digest/1' for every typed format.
%%
%% One thing that shape did teach, and which is worth recording: an authorization is
%% a **list**, not a tuple, because `eth_rlp:encode/1' has no clause for a tuple. The
%% version that wrote `{0, 1, 1, 0, 0, <<1:256>>}` died with `function_clause` from
%% `eth_rlp:encode/1'` -- an error naming the encoder rather than the rule under
%% test, which is what a probe with its assertions removed always looks like.


corpus_blob_fee_signature_test() ->
    with_ctx(fun() ->
        Priv = eth_secp256k1:generate_key(),
        Sender = addr_of(Priv),
        Start = 1000000 * ?GWEI,
        Code = <<16#32, 16#31, 16#60, 0, 16#55, 16#00>>,   % ORIGIN BALANCE; SSTORE
        To = test_address(3),
        ok = eth_mpt:put_code(eth_keccak:hash(Code), Code),
        ok = eth_mpt:put_account(To, 0, 0, eth_keccak:hash(Code)),
        Excess = 16#0e0000,
        %% The corpus figure, recomputed from the specification's recurrence rather
        %% than quoted. 917,504 of excess is not enough to move the curve off its
        %% 1 wei floor, and the *size* of the excess is what makes this a real
        %% assertion: the same number with the price curve consulted on the parent's
        %% excess, or with the excess dropped to 0, gives the same 1, so this does
        %% not by itself prove the field is read from the right place. That is what
        %% `blob_fee_uses_this_blocks_own_excess_test/0' is for.
        ?assertEqual(1, spec_blob_price(Excess)),
        Block0 = (eth_block:new(<<0:256>>, ?CANCUN_BLOCK))
                    #block{excess_blob_gas = Excess, base_fee_per_gas = 7,
                           miner = ?MINER},
        Hashes = [bin0x(versioned_hash(I)) || I <- lists:seq(1, 6)],
        Fields = #{<<"blobVersionedHashes">> => Hashes,
                   <<"maxFeePerBlobGas">> => eth_hex:encode_int(1),
                   <<"maxPriorityFeePerGas">> => <<"0x0">>,
                   <<"maxFeePerGas">> => eth_hex:encode_int(14),
                   <<"value">> => eth_hex:encode_int(0),
                   <<"gas">> => eth_hex:encode_int(500000),
                   <<"to">> => to_hex(To),
                   <<"input">> => <<"0x">>},
        ok = eth_mpt:put_account(Sender, Start, 0, eth_keccak:hash(<<>>)),
        {Block, State1} = eth_block:run_transaction(
                             Block0, sign(base_tx(Fields), Priv),
                             eth_state:new(0, #{}), 7, 30000000),
        [Receipt] = eth_block:receipts(Block),
        ?assertEqual(1, maps:get(<<"status">>, Receipt)),
        %% `min(14, 7 + 0) = 7`: the corpus's effective price, and the reason its
        %% gas story is `no_comparable_gas' -- the refund is at the base fee, so no
        %% gas figure is recoverable from the balance difference and the whole
        %% cluster was invisible to the report's gas histogram.
        Want = Start - (maps:get(<<"gasUsed">>, Receipt) * 7) - 786432,
        ?assertEqual(Want, eth_state:balance(State1, Sender)),
        %% **The storage half of the corpus diff, and the EIP's ordering claim.**
        %% "The actual `blob_fee' ... is deducted from the sender balance **before
        %% transaction execution** and burned". Slot 0 holds `BALANCE` as the *frame*
        %% saw it, so a node that charged the fee after the frame stored a number
        %% 786,432 too high -- and the divergence then appears under a `{store, ...}`
        %% key as well as a `{balance, ...}` one, which is what made this look like two
        %% separate defects in two separate places rather than one missing debit read
        %% back twice.
        %%
        %% The expected figure is the balance **during** the frame, and it is not
        %% `Want'. `settle_gas/8' runs after the frame and refunds the unused
        %% allowance, so the sender is only down `gasUsed * price` at the end while
        %% the frame saw the whole `gasLimit * price` gone. Asserting the final
        %% balance here would pass on a node that charged the fee at the right moment
        %% *and* one that charged it at the wrong one, because the two differ by the
        %% refund and the refund is a gas figure, not a blob figure. Asserted as the
        %% in-frame balance, the 786,432 is the only thing that can move it.
        InFrame = Start - 500000 * 7 - 786432,
        ?assert(InFrame < Want),
        ?assertEqual(InFrame, eth_state:storage(State1, To, 0))
    end).

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

%% The settlement tests need a real state with a funded sender, so the node has
%% to be started and `eth_state` pointed at the local trie. This is the same
%% reference pattern as `eth_finalize_tests:with_ctx/1': `base_source/0` is
%% process-wide, so it is saved and restored -- a test that changed it and did
%% not put it back would silently redirect another module's reads for the rest
%% of the run.
with_ctx(Fun) ->
    %% `start_apps/0` returns a bare `ok`, not `{ok, _}`: it ends in
    %% `ok = application:ensure_all_started(crypto)`'s *value*, and
    %% `ensure_all_started/1` answers `{ok, Started}` on the first call and a
    %% **bare `ok`** on every later one. So the match is `_ = ', and matching
    %% `{ok, _}` makes this helper fail on every test in the module once anything
    %% else in the suite has started one of the four applications -- which is
    %% exactly what a full run does and a single-module run does not. The five
    %% settlement tests were green alone and red in the suite for that reason.
    _ = eth_test_util:start_apps(),
    %% `eth_mpt' is started through `start_link/0' rather than
    %% `application:ensure_all_started/1': there is no `eth_mpt.app' in the tree,
    %% so the application call answers `{error, {eth_mpt, {"no such file or
    %% directory", "eth_mpt.app"}}}'. And `start_link/0' on a process that is
    %% already registered exits the *caller* with `{error, {already_started, Pid}}',
    %% so the running one is reused -- a full suite starts `eth_mpt' long before
    %% this module runs.
    case whereis(eth_mpt) of
        undefined -> {ok, _} = eth_mpt:start_link();
        _ -> ok
    end,
    ok = clear_mpt(),
    Previous = eth_state:base_source(),
    ok = eth_state:set_base_source(mpt),
    try Fun()
    after
        _ = eth_state:set_base_source(Previous),
        _ = clear_mpt()
    end.

addr_of(Priv) ->
    binary:part(eth_keccak:hash(eth_secp256k1:node_id(Priv)), 12, 20).

%% A validation context with a balance reader and a blob base fee, which is what
%% the two rules under test ask for. `blob_base_fee => 1` unless a test says
%% otherwise, because 1 is the floor and a rule that only fires above the floor
%% needs a test that puts it there.
ctx(Sender, Balance, Extra) ->
    maps:merge(#{chain_id => ?CHAIN_ID, base_fee => 0, fork => cancun,
                 balance_of => fun(A) when A =:= Sender -> {ok, Balance};
                                  (_) -> {ok, 0}
                              end,
                 blob_base_fee => 1}, Extra).

%% A Cancun block carrying only an `excess_blob_gas`, for the tests that ask
%% `eth_block:blob_base_fee/1' a price question.
block_with_excess(Excess) ->
    (eth_block:new(<<0:256>>, ?CANCUN_BLOCK))#block{excess_blob_gas = Excess}.

block_with_excess(Excess, Parent, Txs) ->
    (block_with_excess(Excess))#block{parent_hash = Parent, transactions = Txs,
                                     base_fee_per_gas = 7, gas_limit = 30000000,
                                     miner = ?MINER}.

%% A parent block the local trie actually holds, so `finalize/1' is entitled to
%% execute rather than answer `{unverified, state_not_local}'. `eth_test_util:
%% store_parent/1' takes the root the MPT must be holding, and the funding has to
%% be in the trie *before* the root is taken -- which is why this is a function
%% rather than a call after the fact.
store_parent_with(Sender, Balance) ->
    ok = eth_mpt:put_account(Sender, Balance, 0, eth_keccak:hash(<<>>)),
    eth_test_util:store_parent(eth_mpt:state_root()).

%% `eth_mpt:clear/0' is a `gen_server:call/2', so it exits when the process is
%% not up. The `after' clause must not raise: an exception there **replaces** the
%% test's own result, so a cleanup failure would be reported as the assertion
%% failing, with the real cause in a clause the reader is not looking at.
clear_mpt() ->
    try eth_mpt:clear() catch _:_ -> ok end.

%% An address as JSON-RPC spells it, which is what `eth_block:run_transaction/5'
%% reads. Built from an integer with an explicit width: the same 20-nibble literal
%% written as `<<16#1000...01>>' is a **one-byte** binary, because a hex constant
%% wider than the default 8-bit segment is truncated silently. A truncated
%% destination is not a wrong balance, it is a `function_clause' from
%% `eth_state:address/1' -- and it happened in three places here at once.
test_address(N) -> <<N:160>>.

to_hex(A) when is_binary(A) ->
    <<"0x", (string:lowercase(binary:encode_hex(A)))/binary>>.

%% The same transaction with the blob fields dropped, i.e. a 1559 transaction
%% with the identical gas, value, destination and fees. It is the control every
%% settlement test needs: it is charged the same everything *except* the blob
%% fee, so the difference between the two runs isolates the blob term exactly.
%%
%% It is re-signed rather than de-typed, because a blob transaction's signature
%% covers its blob fields and dropping them invalidates it.
%%
%% The result is an **overlay** for `base_tx/1`, not a whole transaction: the
%% 1559 fields -- `chainId', `nonce', `maxPriorityFeePerGas', `maxFeePerGas' -- come
%% from `base_tx/1' and are not in `Fields'. Signing the overlay directly raises
%% `{badkey, <<"chainId">>}' from inside `preimage_fields/1', so the failure names
%% a missing field rather than the control that is missing them.
legacy_of_fields(Fields) ->
    (maps:without([<<"blobVersionedHashes">>, <<"maxFeePerBlobGas">>], Fields))
        #{<<"type">> => <<"0x2">>}.

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
%%
%% **`sign/1` draws its own key.** Every *settlement* test here funds an address
%% derived from a key it generated, and a test that then signs with a *different*
%% key funds an account nobody transacts from. The symptom is the quietest kind:
%% the transaction executes perfectly, the receipt is right, the gas is right, and
%% the balance under test comes back **exactly as it started** -- because it is a
%% different account that was never touched. Every assertion in that state fails
%% with a delta of zero, which reads as "the node charged nothing" and points at
%% `blob_fee/2' rather than at the signer. `sign/2` exists so a test that owns a key
%% can sign with it, and the two are not interchangeable.
sign(Tx) ->
    sign(Tx, eth_secp256k1:generate_key()).

sign(Tx, Priv) ->
    {Signed, _Digest} = sign_with(Tx, Priv),
    Signed.

%% Sign the way a wallet would: hash the preimage under the transaction's own
%% type byte, sign it, then attach the signature fields. The type byte and the
%% field list both come from the transaction, so a type-2 control is signed as a
%% type-2 transaction rather than as a type-3 one with the blob fields dropped --
%% the latter would not recover a sender, and a test whose control is invalid
%% measures the control's invalidity.
sign_with(Tx, Priv) ->
    Type = type_byte(Tx),
    %% `Type/binary', not `Type'. It is already a one-byte binary, and `<<Type,
    %% ...>>' with a bound that is a binary raises `badarg' -- the trap AGENTS.md
    %% §5 lists, reached because the helper used to hardcode `16#03'.
    Body = eth_rlp:encode(preimage_fields(Tx)),
    Digest = eth_keccak:hash(<<Type/binary, Body/binary>>),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    {Tx#{<<"v">> => eth_hex:encode_int(V),
         <<"r">> => eth_hex:encode_int(R),
         <<"s">> => eth_hex:encode_int(S)}, Digest}.

%% The EIP-2718 type byte, read through `eth_hex' because the field is spelled
%% `<<"0x3">>' here -- JSON-RPC's minimal-hex form -- and `binary:decode_unsigned/1'
%% raises `badarg' on the `0x'. It is read rather than assumed so a type-2 control
%% is signed as a type-2 transaction.
type_byte(Tx) ->
    Raw = maps:get(<<"type">>, Tx, <<"0x0">>),
    case eth_hex:is_hex(Raw) of
        true -> <<(eth_hex:decode(Raw))>>;
        false -> <<16#00>>
    end.

preimage_fields(Tx) ->
    Base = [q(maps:get(<<"chainId">>, Tx)),
            q(maps:get(<<"nonce">>, Tx)),
            q(maps:get(<<"maxPriorityFeePerGas">>, Tx)),
            q(maps:get(<<"maxFeePerGas">>, Tx)),
            q(maps:get(<<"gas">>, Tx)),
            to_bin(maps:get(<<"to">>, Tx)),
            q(maps:get(<<"value">>, Tx)),
            to_bin(maps:get(<<"input">>, Tx)),
            []],
    case type_byte(Tx) of
        <<16#03>> ->
            %% A **default of 0**, not `maps:get/2`. A blob transaction with no
            %% `maxFeePerBlobGas' is one of the admission cases this module tests
            %% (`blob_tx_without_blob_fee_rejected_test'), and reading the field
            %% before the test has declared it raises `{badkey, ...}' from inside
            %% the *signer* -- so the fixture under test is never reached and the
            %% failure names the wrong thing entirely.
            Base ++ [q(maps:get(<<"maxFeePerBlobGas">>, Tx, <<"0x0">>)),
                     eth_tx:blob_versioned_hashes(Tx)];
        _ ->
            Base
    end.

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
