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


%% ---------------------------------------------------------------------------
%% A payload may not carry more withdrawals than the bound
%% ---------------------------------------------------------------------------
%%
%% `eth_fork_schedule:withdrawals_root/1' truncates at
%% `?MAX_WITHDRAWALS_PER_PAYLOAD', and its own comment said the caller must reject
%% the payload rather than accept the truncated commitment. **No caller did**, so a
%% 17-withdrawal payload was given a root computed over 16 of its withdrawals --
%% a root that is not the root of the payload's own list, so the header stopped
%% committing to what the payload carried and nothing said so.
%%
%% Built from a **real** network payload rather than a hand-written one, so the
%% other seventeen header fields are the ones the network actually published.
%% `withdrawals` is the only thing changed, which is what makes the refusal
%% attributable to the length and not to a malformed fixture.

%% The committed Shanghai payload carries **exactly sixteen** withdrawals -- the cap
%% itself. So the accepted arm needs no fixture change at all, and the refused arm
%% is that payload plus one duplicated entry: the header's seventeen other fields
%% are the ones the network published, so the refusal is attributable to the length
%% and nothing else. A first version picked "a fixture with withdrawals" and matched
%% two, because both Shanghai and Cancun carry sixteen; naming the fork is both
%% simpler and deterministic.
at_cap_withdrawals_are_accepted_test() ->
    {shanghai, Fx} = pick_shanghai(),
    Payload = maps:get(payload, Fx),
    ?assertEqual(16, length(maps:get(<<"withdrawals">>, Payload))),
    ?assertMatch({ok, _}, eth_block:from_payload(Payload)).

over_cap_withdrawals_are_refused_test() ->
    {Fork, Fx} = pick_shanghai(),
    Payload0 = maps:get(payload, Fx),
    Ws = maps:get(<<"withdrawals">>, Payload0),
    Payload = Payload0#{<<"withdrawals">> => Ws ++ [lists:last(Ws)]},
    ?assertEqual({Fork, {error, {too_many_withdrawals, 17, 16}}},
                 {Fork, eth_block:from_payload(Payload)}).

%% Shanghai, because that is the fork that introduced the field, and because the
%% Committed fixture's payload is one that really carries withdrawals -- a Paris one
%% has no such key and the check would be unreachable there.
pick_shanghai() ->
    [FX] = [FX || FX = {F, _} <- eth_payload_fixture:all(), F =:= shanghai],
    FX.

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

%% ---------------------------------------------------------------------------
%% There is exactly one header encoder, and its field list is the fork's
%% ---------------------------------------------------------------------------
%% `eth_block:to_rlp/1' and `eth_block:hash/1' used to be a second encoder. It emitted
%% nineteen header fields unconditionally -- the fifteen of Frontier, then
%% `baseFeePerGas`, then `withdrawalsRoot`, then EIP-4844's two blob fields -- so it
%% was wrong at every fork, and at Cancun it was short and long at once because
%% EIP-4788's `parentBeaconBlockRoot` had no term in it. They are deleted, and these
%% tests are what the deletion is worth: they pin the surviving encoder's field list
%% per fork against the real blocks, so a second one cannot be reintroduced by someone
%% who believes the first was missing something.

the_header_encoder_is_not_reachable_except_through_a_payload_test() ->
    %% There is no `eth_block:to_rlp/1' and no `eth_block:hash/1' to reach for. A
    %% second encoder that computes a header hash is the one thing that must not come
    %% back, because a block hash that is merely *computable* is indistinguishable
    %% from a correct one.
    ?assertEqual(false, erlang:function_exported(eth_block, to_rlp, 1)),
    ?assertEqual(false, erlang:function_exported(eth_block, hash, 1)).

a_paris_header_carries_no_withdrawal_or_blob_field_test() ->
    %% Paris is 16 fields: the fifteen of Frontier plus EIP-1559's `baseFeePerGas`.
    %% EIP-4895's `withdrawalsRoot` is Shanghai's, so including it here produced a
    %% header sixteen bytes too long -- and a header RLP prefixes by length, so one
    %% extra field shifts every byte after it.
    Payload = maps:get(payload, eth_payload_fixture:paris()),
    ?assertEqual(undefined, maps:get(<<"blobGasUsed">>, Payload, undefined)),
    ?assertEqual(undefined, maps:get(<<"withdrawals">>, Payload, undefined)),
    ?assertNotEqual(undefined, maps:get(<<"baseFeePerGas">>, Payload)),
    assert_hash(eth_payload_fixture:paris()).

a_shanghai_header_adds_withdrawals_and_no_blob_field_test() ->
    %% 17 fields.
    %%
    %% The payload carries the withdrawals *list* and not `withdrawalsRoot', and that
    %% is worth asserting rather than working around: the header commits to the root
    %% of a trie the payload does not hand over, so the root has to be computed from
    %% the list. I wrote an assertion that the payload contains `withdrawalsRoot' and
    %% the test caught it -- a payload that contained the root would be circular,
    %% because the whole point is that this node derives it and checks it against the
    %% network rather than reading its own answer back.
    Payload = maps:get(payload, eth_payload_fixture:shanghai()),
    ?assertNotEqual(undefined, maps:get(<<"withdrawals">>, Payload)),
    ?assertEqual(undefined, maps:get(<<"withdrawalsRoot">>, Payload, undefined)),
    ?assertNotEqual(undefined, maps:get(withdrawals_root, eth_payload_fixture:shanghai())),
    ?assertEqual(undefined, maps:get(<<"blobGasUsed">>, Payload, undefined)),
    assert_hash(eth_payload_fixture:shanghai()).

a_cancun_header_carries_both_blob_fields_and_the_beacon_root_test() ->
    %% 20 fields: EIP-4844's two blob fields and EIP-4788's `parentBeaconBlockRoot`,
    %% which is in the *header* as well as being the value handed to the system call.
    %% The deleted encoder had 19 and no term for the beacon root.
    Payload = maps:get(payload, eth_payload_fixture:cancun()),
    ?assertNotEqual(undefined, maps:get(<<"blobGasUsed">>, Payload)),
    ?assertNotEqual(undefined, maps:get(<<"excessBlobGas">>, Payload)),
    ?assertNotEqual(undefined, maps:get(<<"parentBeaconBlockRoot">>, Payload)),
    assert_hash(eth_payload_fixture:cancun()).

%% A header field the fork does not have must be *absent*, not zero. `engine_getPayload'
%% returns whatever `to_payload/1' builds, and `0x0' there is a number a consensus
%% client would read as an answer about the chain rather than as an absence.
an_absent_base_fee_is_absent_and_not_zero_test() ->
    Block = (eth_block:new(<<0:256>>, 1))#block{base_fee_per_gas = undefined},
    ?assertEqual(undefined, maps:get(<<"baseFeePerGas">>, eth_block:header(Block))),
    ?assertNotEqual(<<"0x0">>, maps:get(<<"baseFeePerGas">>, eth_block:header(Block))).


%% ===========================================================================
%% EIP-7843: the slot number reaches the interpreter, and an absent one does not
%% ===========================================================================
%% The opcode is only half of it. `SLOTNUM' reads `slot_number' out of the Env with
%% `maps:find/2' and refuses when the key is absent, so **the whole feature depends on
%% this decoder leaving the key out** for a payload that carries no `slotNumber' -- and
%% on not seeding it with 0, which is the genesis slot.
%%
%% The value is the one real Sepolia block 11,856,337 carries.

slot_number_is_absent_unless_the_payload_carries_it_test() ->
    %% The three fixtures are Paris, Shanghai and Cancun and all three predate the fork,
    %% so this is the case that must be *absent* rather than *present and wrong*.
    lists:foreach(fun({Fork, Fx}) ->
        {ok, B} = eth_block:from_payload(maps:get(payload, Fx)),
        ?assertEqual({Fork, undefined}, {Fork, B#block.slot_number})
    end, eth_payload_fixture:all()),
    {ok, Paris} = eth_block:from_payload(payload(eth_payload_fixture:paris())),
    ?assertEqual(undefined, Paris#block.slot_number).

a_payload_carrying_a_slot_number_decodes_it_test() ->
    P = maps:put(<<"slotNumber">>, <<"0xac6000">>,
                 payload(eth_payload_fixture:cancun())),
    {ok, B} = eth_block:from_payload(P),
    ?assertEqual(11296768, B#block.slot_number).

the_env_carries_the_slot_number_from_the_payload_test() ->
    %% End to end through the two hops, because the two can each be right while the pair
    %% is wrong: a decoder that fills the record and an Env that seeds a different key
    %% would both pass their own test.
    P = maps:put(<<"slotNumber">>, <<"0xac6000">>,
                 payload(eth_payload_fixture:cancun())),
    {ok, B} = eth_block:from_payload(P),
    Env = eth_block:block_env(B, eth_state:new(0, #{})),
    ?assertEqual(11296768, maps:get(slot_number, Env)).

the_env_omits_the_slot_number_for_a_block_that_has_none_test() ->
    {ok, B} = eth_block:from_payload(payload(eth_payload_fixture:cancun())),
    Env = eth_block:block_env(B, eth_state:new(0, #{})),
    ?assertNot(maps:is_key(slot_number, Env)).

the_env_carries_slot_zero_rather_than_omitting_it_test() ->
    %% **The control for the test above.** The two differ by one instruction -- seeding
    %% unconditionally with `Env#{slot_number => Slot}' and reading `Slot' -- and they
    %% agree on every block except this one, where slot 0 is a real value. A handler that
    %% treated 0 as "absent" would pass everything above and answer `SLOTNUM' on the
    %% genesis slot with a refusal instead of a number.
    {ok, B0} = eth_block:from_payload(payload(eth_payload_fixture:cancun())),
    B = B0#block{slot_number = 0},
    Env = eth_block:block_env(B, eth_state:new(0, #{})),
    ?assertEqual(0, maps:get(slot_number, Env)).


%% ===========================================================================
%% Prague and Amsterdam: the encoder had three shapes and needed five
%% ===========================================================================
%% `payload_header_rlp/4' spelled Paris, Shanghai and Cancun. **A Prague payload was
%% encoded as a 20-field Cancun header** -- EIP-7685's `requestsHash' missing -- and an
%% Amsterdam one as the same 20 fields, missing `requestsHash', `blockAccessListHash' and
%% `slotNumber'. `payload_block_hash/1' therefore answered a hash that is not the block's,
%% which `newPayload' reports to the client as `INVALID_BLOCK_HASH` on a valid payload.
%% `eth_block_payload_tests' pinned Paris, Shanghai and Cancun and had no Prague case,
%% which is the whole reason this survived.

%% **The header for a Prague payload is 21 fields and the 21st is `requestsHash`.**
%%
%% Asserted as a *difference* from the 20-field encoding rather than as an absolute, because
%% the pre-fix code produced a hash too -- just not the block's. My first version of this
%% test asserted `{error, missing_requests_hash}' for a payload that *does* carry
%% `requestsHash', and it was the fixture that was wrong: the Prague branch is only
%% reachable when the field is present, since its absence is what makes the payload look
%% like Cancun.
prague_payload_hashes_to_a_header_with_twenty_one_fields_test() ->
    Cancun = payload(eth_payload_fixture:cancun()),
    {ok, TwentyFields} = eth_block:payload_block_hash(Cancun),
    {ok, TwentyOneFields} = eth_block:payload_block_hash(
        maps:put(<<"requestsHash">>,
                 <<"0xec88bf0d3fe6b86b583cf638c5635cb64bc842fee1e220f0e8be964a4d368c15">>,
                 Cancun)),
    ?assertNotEqual(TwentyFields, TwentyOneFields),
    %% **And the 21-field hash is the one a real Prague header commits to**, which is checked
    %% against the chain in `eth_header_tests` (`requests_hash_is_the_last_header_field_and
    %% _says_so_against_a_real_block_test'). This test's job is that the payload path
    %% reaches 21 fields at all.
    ?assertEqual(32, byte_size(TwentyOneFields)).

%% **Amsterdam needs all three new terms, and each absence is named.**
amsterdam_payload_names_the_field_it_is_missing_test() ->
    Base = amsterdam_shaped(),
    ?assertEqual({error, missing_requests_hash},
                 eth_block:payload_block_hash(Base)),
    WithRequests = maps:put(<<"requestsHash">>, <<"0xec88bf0d3fe6b86b583cf638c5635cb64bc842f"
                                              "ee1e220f0e8be964a4d368c15">>, Base),
    ?assertEqual({error, missing_block_access_list},
                 eth_block:payload_block_hash(WithRequests)),
    WithBal = maps:put(<<"blockAccessList">>, <<"0xc0">>, WithRequests),
    %% And with all three present it produces a hash rather than an error, which is the
    %% whole point: a refusal that never lifts is not a fix.
    ?assertMatch({ok, _}, eth_block:payload_block_hash(WithBal)),
    %% **A malformed list is refused, and does not take the node down.** `eth_hex:decode/1`
    %% raises on `"0xzz"' rather than answering an error, so the first version of
    %% `header_block_access_list_hash/1' crashed on it -- a payload from the network
    %% stopping the node rather than being turned away.
    ?assertEqual({error, {bad_block_access_list, <<"0xzz">>}},
                 eth_block:payload_block_hash(
                   maps:put(<<"blockAccessList">>, <<"0xzz">>, WithRequests))).

%% **The two new terms participate.** Without this the first two tests would also be
%% satisfied by an encoder that recognises the shape and then ignores the fields -- which
%% is the pre-fix behaviour with a different error message.
an_amsterdam_payloads_hash_depends_on_its_two_new_terms_test() ->
    Base = maps:put(<<"requestsHash">>,
                    <<"0xec88bf0d3fe6b86b583cf638c5635cb64bc842fee1e220f0e8be964a4d368c15">>,
                    amsterdam_shaped()),
    WithBal = maps:put(<<"blockAccessList">>, <<"0xc0">>, Base),
    WithOtherSlot = maps:put(<<"slotNumber">>, <<"0xac6001">>, WithBal),
    {ok, H1} = eth_block:payload_block_hash(WithBal),
    {ok, H2} = eth_block:payload_block_hash(WithOtherSlot),
    ?assertNotEqual(H1, H2),
    %% The empty list and a single-entry list are different commitments:
    ?assertNotEqual(H1, eth_block:payload_block_hash(
        maps:put(<<"blockAccessList">>, <<"0xc0c0">>, WithBal))).


%% **EIP-7928's empty case, pinned against the chain and against this repository.**
%%
%% "For an empty block access list, this is `keccak256(rlp.encode([])) =
%% 0x1dcc4de8...`". That value is also `eth_block:empty_uncle_hash()` -- `Keccak256(RLP([]))`,
%% the ommers hash -- so the EIP's figure, this node's constant and the computation agree,
%% and the test is that they do rather than a restatement of any one of them.
the_empty_block_access_list_hashes_to_the_empty_ommers_hash_test() ->
    ?assertEqual(<<16#c0>>, eth_rlp:encode([])),
    ?assertEqual(eth_block:empty_uncle_hash(), eth_keccak:hash(eth_rlp:encode([]))),
    %% **Written as hex and decoded, not as 32 bytes typed by hand.** The first version
    %% was a `<<16#.., ..>>' literal and one byte of it was wrong, which produced a failure
    %% whose expected and actual values look identical in EUnit's truncated output -- the
    %% one shape of wrong answer that reads as a compiler bug rather than a typo.
    ?assertEqual(eth_hex:must_decode_bytes(
                   <<"0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347">>),
                 eth_block:empty_uncle_hash()).

%% **The Cancun path must not have started demanding the new fields.** `slotNumber' is
%% what distinguishes the two shapes, so a Cancun payload with no `slotNumber' still takes
%% the 20-field branch -- and a test that only covers the new shapes would not notice if
%% that had changed.
a_cancun_payload_is_still_encoded_as_twenty_fields_test() ->
    P = payload(eth_payload_fixture:cancun()),
    {ok, Cancun} = eth_block:payload_block_hash(P),
    {ok, WithRequests} = eth_block:payload_block_hash(
        maps:put(<<"requestsHash">>,
                 <<"0xec88bf0d3fe6b86b583cf638c5635cb64bc842fee1e220f0e8be964a4d368c15">>,
                 P)),
    ?assertNotEqual(Cancun, WithRequests),
    %% **A `requestsHash` that is not 32 bytes is refused rather than padded.** `<<"0x00">>'
    %% is one byte, and a header committing to a one-byte word would be a different header
    %% again -- so this is the third distinct answer for three distinct defects, which is
    %% why the reason carries the field it is about.
    ?assertEqual({error, {bad_data_word, requests_hash, <<"0x00">>}},
                 eth_block:payload_block_hash(maps:put(<<"requestsHash">>,
                                                        <<"0x00">>, P))).

%% An Amsterdam-shaped payload: `slotNumber` present, `blockAccessList` deliberately
%% absent so each missing term can be named in turn.
amsterdam_shaped() ->
    maps:remove(<<"requestsHash">>,
                maps:put(<<"slotNumber">>, <<"0xac6000">>,
                         payload(eth_payload_fixture:cancun()))).
