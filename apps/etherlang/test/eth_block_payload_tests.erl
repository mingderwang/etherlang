%% Tests for decoding an ExecutionPayload into a #block{} and for the block hash
%% the payload's own fields imply.
%%
%% The fixtures are real Sepolia blocks (`eth_payload_fixture'), one per header
%% shape: Paris, Shanghai and Cancun. The point of using real ones is that the
%% expected values are the chain's, so a test fails when this code's arithmetic
%% disagrees with the network rather than when it disagrees with itself.
-module(eth_block_payload_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("etherlang/include/eth_block.hrl").

%% ===========================================================================
%% The block hash, against the network's own
%% ===========================================================================
%%
%% `blockHash' is the payload's claim about its own header, and the engine API
%% requires it to be validated in all cases -- including while syncing. The check
%% has to encode the header with exactly the fields the payload carries, so this
%% pins all three lengths: get one wrong and the hash comes out different from
%% the one 6.5 million blocks ago were computed against.

paris_payload_hashes_to_the_blocks_hash_test() ->
    assert_hash(eth_payload_fixture:paris()).

shanghai_payload_hashes_to_the_blocks_hash_test() ->
    assert_hash(eth_payload_fixture:shanghai()).

cancun_payload_hashes_to_the_blocks_hash_test() ->
    assert_hash(eth_payload_fixture:cancun()).

assert_hash(Fx) ->
    Payload = maps:get(payload, Fx),
    Expected = hex_to_bytes(maps:get(block_hash, Fx)),
    ?assertEqual({ok, Expected}, eth_block:payload_block_hash(Payload)).

%% The two roots the payload asserts but does not carry. These are the values the
%% transactions trie and the withdrawals trie must produce, checked against the
%% chain rather than against this code.

payload_transactions_root_matches_the_network_test() ->
    lists:foreach(
      fun({Fork, Fx}) ->
              Payload = maps:get(payload, Fx),
              Expected = hex_to_bytes(maps:get(transactions_root, Fx)),
              {ok, Block} = eth_block:from_payload(Payload),
              ?assertEqual({Fork, Expected},
                           {Fork, eth_block:tx_root(Block#block.transactions)})
      end, eth_payload_fixture:all()).

payload_withdrawals_root_matches_the_network_test() ->
    lists:foreach(
      fun({Fork, Fx}) ->
              case maps:get(withdrawals_root, Fx) of
                  undefined -> ok;
                  Hex ->
                      Payload = maps:get(payload, Fx),
                      {ok, Block} = eth_block:from_payload(Payload),
                      ?assertEqual(
                         {Fork, hex_to_bytes(Hex)},
                         {Fork, eth_fork_schedule:withdrawals_root(
                                  Block#block.withdrawals)})
              end
      end, eth_payload_fixture:all()).

%% ===========================================================================
%% Decoding the fields
%% ===========================================================================

payload_fields_decode_test() ->
    lists:foreach(
      fun({Fork, Fx}) ->
              Payload = maps:get(payload, Fx),
              {ok, B} = eth_block:from_payload(Payload),
              ?assertEqual({Fork, maps:get(number, Fx)}, {Fork, B#block.number}),
              ?assertEqual({Fork, hex_to_bytes(maps:get(<<"parentHash">>, Payload))},
                           {Fork, B#block.parent_hash}),
              ?assertEqual({Fork, hex_to_bytes(maps:get(<<"stateRoot">>, Payload))},
                           {Fork, B#block.state_root}),
              ?assertEqual({Fork, hex_to_bytes(maps:get(<<"receiptsRoot">>, Payload))},
                           {Fork, B#block.receipts_root}),
              ?assertEqual({Fork, hex_to_bytes(maps:get(<<"logsBloom">>, Payload))},
                           {Fork, B#block.logs_bloom}),
              %% The payload's `feeRecipient' is the header's `miner', and its
              %% `prevRandao' is the header's `mixHash'. Getting these two
              %% backwards would still produce a stable hash for a payload the
              %% node also decodes, so they are named explicitly.
              ?assertEqual({Fork, hex_to_bytes(maps:get(<<"feeRecipient">>, Payload))},
                           {Fork, B#block.miner}),
              ?assertEqual({Fork, hex_to_bytes(maps:get(<<"prevRandao">>, Payload))},
                           {Fork, B#block.mix_hash}),
              ?assertEqual({Fork, eth_hex:decode(maps:get(<<"gasUsed">>, Payload))},
                           {Fork, B#block.gas_used}),
              ?assertEqual({Fork, eth_hex:decode(maps:get(<<"baseFeePerGas">>, Payload))},
                           {Fork, B#block.base_fee_per_gas}),
              %% After the Merge these three are constants, not payload fields.
              ?assertEqual({Fork, <<0:64>>}, {Fork, B#block.nonce}),
              ?assertEqual({Fork, 0}, {Fork, B#block.difficulty})
      end, eth_payload_fixture:all()).

payload_transactions_decode_test() ->
    lists:foreach(
      fun({Fork, Fx}) ->
              Payload = maps:get(payload, Fx),
              Wire = maps:get(<<"transactions">>, Payload),
              {ok, B} = eth_block:from_payload(Payload),
              ?assertEqual({Fork, length(Wire)}, {Fork, length(B#block.transactions)}),
              lists:foreach(
                fun(Tx) ->
                        ?assert(maps:is_key(<<"hash">>, Tx))
                end, B#block.transactions)
      end, eth_payload_fixture:all()).

%% `extraData' is 0 to 32 bytes, so the empty case has to be a value rather than
%% a missing field.
payload_empty_extra_data_is_not_a_missing_field_test() ->
    {ok, B} = eth_block:from_payload(payload(eth_payload_fixture:paris())),
    ?assert(is_binary(B#block.extra_data)),
    ?assert(byte_size(B#block.extra_data) =< 32).

%% A Paris payload has no withdrawals; a Cancun one has them and the blob gas
%% fields. Defaulting the absent ones to the Cancun values would be inventing a
%% header the network never sent.
payload_optional_fields_are_absent_unless_present_test() ->
    {ok, Paris} = eth_block:from_payload(payload(eth_payload_fixture:paris())),
    ?assertEqual([], Paris#block.withdrawals),
    ?assertEqual(0, Paris#block.blob_gas_used),
    ?assertEqual(undefined, Paris#block.parent_beacon_block_root),
    {ok, Cancun} = eth_block:from_payload(payload(eth_payload_fixture:cancun())),
    ?assertEqual(16, length(Cancun#block.withdrawals)),
    ?assertEqual(0, Cancun#block.blob_gas_used),
    ?assertNotEqual(undefined, Cancun#block.parent_beacon_block_root).

%% ===========================================================================
%% The two constants post-Merge fixes
%% ===========================================================================
%%
%% Both of these were wrong, and both had the same disguise: a 32-byte value of
%% the right length that hashes to something. They were found by decoding a real
%% block and asking why a header that matched the block's own fields field for
%% field did not hash to the block's own hash -- so they are pinned here against
%% the values the network uses, and the hashes above are what actually proves it.

%% Keccak256(RLP([])), the hash of an empty ommers list. It was the *empty trie*
%% root, which is a different 32-byte value entirely.
empty_ommers_hash_is_the_empty_ommers_hash_test() ->
    ?assertEqual(<<16#1d, 16#cc, 16#4d, 16#e8, 16#de, 16#c7, 16#5d, 16#7a,
                   16#ab, 16#85, 16#b5, 16#67, 16#b6, 16#cc, 16#d4, 16#1a,
                   16#d3, 16#12, 16#45, 16#1b, 16#94, 16#8a, 16#74, 16#13,
                   16#f0, 16#a1, 16#42, 16#fd, 16#40, 16#d4, 16#93, 16#47>>,
                 (eth_block:new(<<0:256>>, 1))#block.sha3_uncles).

%% The empty-ommers hash really is that value, rather than a constant that merely
%% looks right: it is keccak256 of the RLP of an empty list.
empty_ommers_hash_is_keccak_of_an_empty_list_test() ->
    ?assertEqual((eth_block:new(<<0:256>>, 1))#block.sha3_uncles,
                 eth_keccak:hash(eth_rlp:encode([]))).

%% The nonce is 8 bytes. It was 24, because it was written as <<0:192>> -- 192
%% bits. RLP prefixes a string with its length, so a 24-byte nonce makes the
%% header 16 bytes longer than the header the network hashed.
post_merge_nonce_is_eight_bytes_test() ->
    lists:foreach(
      fun({Fork, Fx}) ->
              {ok, B} = eth_block:from_payload(payload(Fx)),
              ?assertEqual({Fork, 8}, {Fork, byte_size(B#block.nonce)})
      end, eth_payload_fixture:all()).

%% And the difficulty is zero after the Merge, which is the other thing the
%% payload does not carry and the decoder has to supply correctly.
post_merge_difficulty_is_zero_test() ->
    lists:foreach(
      fun({Fork, Fx}) ->
              {ok, B} = eth_block:from_payload(payload(Fx)),
              ?assertEqual({Fork, 0}, {Fork, B#block.difficulty})
      end, eth_payload_fixture:all()).

%% EIP-4844's two quantities are numbers in the header, and they arrive as JSON
%% strings. The real Cancun fixture has both of them zero, so this needs its own
%% payload to be worth anything: with `"0x0"' in the fixture, a decoder that
%% forwarded the string undecoded would produce the same 32 bytes for both the
%% string and the number's encoding... not quite, but close enough that no other
%% value in the suite would have noticed. These are real blob gas values.
blob_quantities_reach_the_block_as_integers_test() ->
    Fx = eth_payload_fixture:blobs(),
    {ok, B} = eth_block:from_payload(maps:get(payload, Fx)),
    ?assertEqual(maps:get(blob_gas_used, Fx), B#block.blob_gas_used),
    ?assertEqual(maps:get(excess_blob_gas, Fx), B#block.excess_blob_gas),
    ?assert(is_integer(B#block.blob_gas_used)),
    ?assert(is_integer(B#block.excess_blob_gas)).

%% And they have to reach the *header*, not just the block: a payload whose blob
%% gas is zero and one whose is not must not hash the same, or the quantities are
%% being read and then ignored.
blob_quantities_reach_the_header_test() ->
    Zero = maps:get(payload, eth_payload_fixture:cancun()),
    NonZero = maps:get(payload, eth_payload_fixture:blobs()),
    ?assertNotEqual(eth_block:payload_block_hash(Zero),
                    eth_block:payload_block_hash(NonZero)).

%% ===========================================================================
%% What it refuses
%% ===========================================================================
%%
%% A payload is a complete object, so an absent field is not something to default.
%% Defaulting would mean this node inventing a field and then hashing it into a
%% block hash it has just certified as correct.

payload_missing_a_required_field_is_refused_test() ->
    Required = [<<"parentHash">>, <<"feeRecipient">>, <<"stateRoot">>,
                <<"receiptsRoot">>, <<"logsBloom">>, <<"prevRandao">>,
                <<"blockNumber">>, <<"gasLimit">>, <<"gasUsed">>,
                <<"timestamp">>, <<"extraData">>, <<"baseFeePerGas">>,
                <<"transactions">>],
    lists:foreach(
      fun(Key) ->
              Payload = maps:remove(Key, payload(eth_payload_fixture:paris())),
              ?assertMatch({error, {missing_field, Key}},
                           eth_block:from_payload(Payload))
      end, Required).

%% The specification requires every transaction to be at least one byte, in all
%% cases. A zero-length entry is a malformed payload, not a transaction.
payload_zero_length_transaction_is_refused_test() ->
    Payload = with_key(eth_payload_fixture:shanghai(), <<"transactions">>, [<<"0x">>]),
    ?assertMatch({error, {zero_length_transaction, 0}},
                 eth_block:from_payload(Payload)).

payload_malformed_transaction_is_refused_test() ->
    Payload = with_key(eth_payload_fixture:shanghai(), <<"transactions">>, [<<"0xdeadbeef">>]),
    ?assertMatch({error, {invalid_transaction, 0, _}},
                 eth_block:from_payload(Payload)).

%% A DATA field of the wrong width is not a hash. Accepting one would mean
%% padding or truncating it, and the block hash would then be computed over
%% something the client never sent.
payload_wrong_sized_data_is_refused_test() ->
    lists:foreach(
      fun(Key) ->
              Payload = with_key(eth_payload_fixture:paris(), Key, <<"0xabcd">>),
              ?assertMatch({error, {bad_field, Key, {wrong_size, _, _}}},
                           eth_block:from_payload(Payload))
      end, [<<"parentHash">>, <<"stateRoot">>, <<"receiptsRoot">>,
            <<"prevRandao">>, <<"feeRecipient">>, <<"logsBloom">>]).

payload_bad_quantity_is_refused_test() ->
    Payload = with_key(eth_payload_fixture:paris(), <<"blockNumber">>, <<"nonsense">>),
    ?assertMatch({error, {bad_field, <<"blockNumber">>, not_a_quantity}},
                 eth_block:from_payload(Payload)).

%% EIP-4844 appends both blob fields together. A payload carrying one without the
%% other is not a header this node can spell, and guessing which half is missing
%% would produce a hash that looks computable and is not.
payload_half_the_blob_fields_is_refused_test() ->
    %% The excess blob gas alone: `blobGasUsed' is still there, so the payload
    %% names one of EIP-4844's two appended fields and not the other.
    Payload = maps:filter(fun(_K, V) -> V =/= undefined end,
                          with_key(eth_payload_fixture:cancun(), <<"excessBlobGas">>, undefined)),
    ?assertMatch({error, {partial_blob_fields, _, undefined}},
                 eth_block:payload_block_hash(Payload)).

payload_not_an_object_is_refused_test() ->
    ?assertMatch({error, payload_not_an_object}, eth_block:from_payload(<<"x">>)),
    ?assertMatch({error, payload_not_an_object}, eth_block:from_payload([])).

%% ===========================================================================
%% The decoder is not the JSON-RPC decoder
%% ===========================================================================
%%
%% from_json/1 decodes a different object, and it defaults everything. A payload
%% fed through it would come out as a block with a height of 0, a fee recipient
%% of zero and no transactions at all -- and would look decoded.

%% The two decoders are not interchangeable, and the difference that matters is
%% the body. from_json/1 never reads the transaction list at all -- it exists for
%% the header-only sync path, where the upstream block's transactions are hashes
%% this node has no use for -- so a block decoded through it has an empty body
%% whatever the input carried. Feed a payload to it and it returns a block that
%% looks decoded and has nothing in it.
%%
%% (The reverse is not true and is not claimed: renaming a payload's fields to
%% the RPC names does give from_json/1 the height and the roots, because those
%% are the same values under different names. The body is the part that cannot
%% survive the translation, and that is the part a payload cannot be without.)
a_payload_is_not_a_json_rpc_block_test() ->
    lists:foreach(
      fun({Fork, Fx}) ->
              Payload = payload(Fx),
              Wire = maps:get(<<"transactions">>, Payload),
              {ok, FromPayload} = eth_block:from_payload(Payload),
              ?assertEqual({Fork, length(Wire)},
                           {Fork, length(FromPayload#block.transactions)}),
              %% The transactions were really there: raw wire bytes, not hashes.
              ?assert(lists:all(fun(Tx) -> is_binary(Tx) andalso byte_size(Tx) > 0 end,
                                Wire)),
              Json = eth_block:to_json(
                       eth_block:from_json(rename_to_rpc(Payload))),
              ?assertEqual({Fork, []},
                           {Fork, maps:get(<<"transactions">>, Json, [])})
      end, eth_payload_fixture:all()).

rename_to_rpc(P) ->
    maps:merge(P, #{<<"number">> => maps:get(<<"blockNumber">>, P),
                    <<"miner">> => maps:get(<<"feeRecipient">>, P),
                    <<"mixHash">> => maps:get(<<"prevRandao">>, P)}).

%% ===========================================================================
%% Helpers
%% ===========================================================================

hex_to_bytes(<<"0x", Rest/binary>>) -> binary:decode_hex(Rest);
hex_to_bytes(Bin) when byte_size(Bin) =:= 32 -> Bin.

payload(Fx) -> maps:get(payload, Fx).

%% Set a key to a value, and drop it entirely when the value is `undefined' --
%% the second case is what makes a payload look like an earlier fork's, which is
%% the only way a field can be genuinely absent rather than merely wrong.
with_key(Fx, Key, undefined) ->
    maps:filter(fun(_K, V) -> V =/= undefined end,
                maps:put(Key, undefined, payload(Fx)));
with_key(Fx, Key, Value) ->
    maps:put(Key, Value, payload(Fx)).

%% The encoder has to be the inverse of a decoder that is pinned against real
%% block hashes, or it is not an inverse at all. These use the real Sepolia
%% payloads, so a field name or width that disagrees with the network shows up as
%% a block hash that is not the block's own.
to_payload_round_trips_a_real_cancun_block_test() ->
    P = maps:get(payload, eth_payload_fixture:cancun()),
    {ok, Block} = eth_block:from_payload(P),
    {ok, Encoded} = eth_block:to_payload(Block),
    ?assertEqual(maps:get(<<"blockHash">>, P), maps:get(<<"blockHash">>, Encoded)),
    [?assertEqual(maps:get(K, P), maps:get(K, Encoded))
     || K <- [<<"parentHash">>, <<"feeRecipient">>, <<"stateRoot">>,
             <<"receiptsRoot">>, <<"logsBloom">>, <<"prevRandao">>,
             <<"blockNumber">>, <<"gasLimit">>, <<"gasUsed">>, <<"timestamp">>,
             <<"extraData">>, <<"baseFeePerGas">>, <<"blobGasUsed">>,
             <<"excessBlobGas">>, <<"parentBeaconBlockRoot">>]],
    ?assertEqual(maps:get(<<"transactions">>, P), maps:get(<<"transactions">>, Encoded)),
    ?assertEqual(maps:get(<<"withdrawals">>, P), maps:get(<<"withdrawals">>, Encoded)).

to_payload_round_trips_a_real_shanghai_block_test() ->
    P = maps:get(payload, eth_payload_fixture:shanghai()),
    {ok, Block} = eth_block:from_payload(P),
    {ok, Encoded} = eth_block:to_payload(Block),
    ?assertEqual(maps:get(<<"blockHash">>, P), maps:get(<<"blockHash">>, Encoded)),
    %% A Shanghai payload has no blob fields, and the encoder must not add any:
    %% the structure check in eth_engine compares the exact key set.
    ?assertNot(maps:is_key(<<"blobGasUsed">>, Encoded)),
    ?assertNot(maps:is_key(<<"parentBeaconBlockRoot">>, Encoded)),
    ?assert(maps:is_key(<<"withdrawals">>, Encoded)).

to_payload_round_trips_a_real_paris_block_test() ->
    P = maps:get(payload, eth_payload_fixture:paris()),
    {ok, Block} = eth_block:from_payload(P),
    {ok, Encoded} = eth_block:to_payload(Block),
    ?assertEqual(maps:get(<<"blockHash">>, P), maps:get(<<"blockHash">>, Encoded)),
    %% A Paris payload has no withdrawals field at all.
    ?assertNot(maps:is_key(<<"withdrawals">>, Encoded)),
    ?assertNot(maps:is_key(<<"blobGasUsed">>, Encoded)).
