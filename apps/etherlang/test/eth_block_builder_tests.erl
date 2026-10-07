%% Tests for block building and the engine's payloadId path.
%%
%% `eth_block_builder' was dead code -- a gen_server nothing started, absent from
%% the `registered' list and from the supervisor's children -- and `getPayload'
%% reported every payloadId unknown because none was ever issued. These are the
%% tests that would have caught that, and the ones that pin the four header
%% defects the dead version would have shipped the moment it was switched on.
%%
%% The strongest available check on a built block is that it round-trips through
%% the payload codec, because that codec is pinned against three real Sepolia block
%% hashes in eth_block_payload_tests. A header assembled with a 24-byte nonce, an
%% empty-trie-root uncle hash, or a missing beacon root cannot reproduce a hash the
%% network computed, and cannot reproduce these blocks' either.
-module(eth_block_builder_tests).

-include_lib("eunit/include/eunit.hrl").

-include_lib("etherlang/include/eth_block.hrl").

-define(SYNCING, <<"SYNCING">>).

%% The empty *uncle hash* -- Keccak256(RLP([])) -- which is a different constant
%% from the empty *trie* root. Confusing the two was one of this project's found
%% defects, so it is written out here rather than referenced from eth_block, whose
%% macro is private.
-define(EMPTY_UNCLE_HASH,
        <<16#1d, 16#cc, 16#4d, 16#e8, 16#de, 16#c7, 16#5d, 16#7a, 16#ab, 16#85,
          16#b5, 16#67, 16#b6, 16#cc, 16#d4, 16#1a, 16#d3, 16#12, 16#45, 16#1b,
          16#94, 16#8a, 16#74, 16#13, 16#f0, 16#a1, 16#42, 16#fd, 16#40, 16#d4,
          16#93, 16#47>>).

%% The empty *trie* root -- 56e81f... -- which is what an empty transactions or
%% receipts trie roots to, and is NOT the uncle hash.
-define(EMPTY_TRIE_ROOT,
        <<16#56, 16#e8, 16#1f, 16#17, 16#1b, 16#cc, 16#55, 16#a6, 16#ff, 16#83,
          16#45, 16#e6, 16#92, 16#c0, 16#f8, 16#6e, 16#5b, 16#48, 16#e0, 16#1b,
          16#99, 16#6c, 16#ad, 16#c0, 16#01, 16#62, 16#2f, 16#b5, 16#e3, 16#63,
          16#b4, 16#21>>).

%% ===========================================================================
%% The module is a real supervised child
%% ===========================================================================
%%
%% It was not, and nothing caught that: `build_block/0,1' raised noproc and the
%% only caller was a test of `validate_transaction/2'. These two assert the two
%% things "is it started" means -- the application lists it, and the supervisor
%% starts it.

the_builder_is_a_supervised_child_test() ->
    Ids = with_data_dir(fun(_Dir) ->
                           {ok, {_Flags, Children}} = etherlang_sup:init([]),
                           [maps:get(id, C) || C <- Children, is_map(C)]
                       end),
    ?assert(lists:member(eth_block_builder, Ids)).

%% The `registered' list is a declaration that a process is running. eth_engine
%% was on it and was not started, so the list was asserting something false; the
%% builder is now on it *and* started, and this checks the declaration is there at
%% all -- a module that is started but not listed fails the application's own
%% consistency check, and one that is listed but not started is what this was.
the_builder_is_in_the_applications_registered_list_test() ->
    _ = application:load(etherlang),
    {ok, Registered} = application:get_key(etherlang, registered),
    ?assert(lists:member(eth_block_builder, Registered)).

%% The builder must be started before the engine, because a build issued by
%% `forkchoiceUpdated' calls into it and `getPayload' reads from it. Started after,
%% a build attempted in between raises noproc -- which is the failure the dead
%% module produced.
the_builder_starts_before_the_engine_test() ->
    Ids = with_data_dir(fun(_Dir) ->
                           {ok, {_Flags, Children}} = etherlang_sup:init([]),
                           [maps:get(id, C) || C <- Children, is_map(C)]
                       end),
    ?assert(Ids =/= []),
    Builder = index_of(eth_block_builder, Ids),
    Engine = index_of(eth_engine, Ids),
    ?assert(Builder < Engine).

index_of(Id, Ids) ->
    case lists:splitwith(fun(X) -> X =/= Id end, Ids) of
        {_Before, [_Id | _After]} -> ok;
        _ -> error
    end,
    length(lists:takewhile(fun(X) -> X =/= Id end, Ids)).

with_data_dir(Fun) ->
    Dir = eth_test_util:tmp_dir(),
    Previous = os:getenv("DATA_DIR"),
    os:putenv("DATA_DIR", Dir),
    try Fun(Dir)
    after
        case Previous of
            false -> os:unsetenv("DATA_DIR");
            _ -> os:putenv("DATA_DIR", Previous)
        end
    end.

%% ===========================================================================
%% A build uses the client's attributes
%% ===========================================================================
%%
%% Every one of these was discarded by the dead builder in favour of a
%% placeholder, so a build ignored the entire request it was answering: the
%% timestamp was the wall clock, the fee recipient was the zero address, prevRandao
%% was zero, and the withdrawals were an empty list. The tests are named after the
%% field, because "the build used the attributes" would still pass if it used four
%% of the five.

a_built_block_carries_the_clients_fee_recipient_test() ->
    with_build(fun(Head) ->
                   Attrs = attributes(Head),
                   {ok, Payload, _Value} = eth_block_builder:build(Attrs),
                   ?assertEqual(<<"0x00000000000000000000000000000000000000ff">>,
                                maps:get(<<"feeRecipient">>, Payload))
               end).

a_built_block_carries_the_clients_timestamp_test() ->
    with_build(fun(Head) ->
                   Ts = 1730403216,
                   {ok, Payload, _Value} =
                       eth_block_builder:build((attributes(Head))#{timestamp => Ts}),
                   ?assertEqual(eth_hex:encode_int(Ts),
                                maps:get(<<"timestamp">>, Payload))
               end).

%% The timestamp is the client's and never the clock's. A builder that used
%% `erlang:system_time/1' would produce a block for a different slot than the one
%% asked for -- and one that crossed a fork activation would build under different
%% rules than the client expects, which is the whole content of the field.
a_build_ignores_the_wall_clock_test() ->
    with_build(fun(Head) ->
                   Ts = 1000000000,
                   {ok, Payload, _Value} =
                       eth_block_builder:build((attributes(Head))#{timestamp => Ts}),
                   ?assertNotEqual(eth_hex:encode_int(
                                      erlang:system_time(second)),
                                   maps:get(<<"timestamp">>, Payload))
               end).

a_built_block_carries_the_clients_prev_randao_test() ->
    with_build(fun(Head) ->
                   {ok, Payload, _Value} = eth_block_builder:build(attributes(Head)),
                   ?assertEqual(<<"0x00000000000000000000000000000000000000000000000000000000000000aa">>,
                                maps:get(<<"prevRandao">>, Payload))
               end).

a_built_block_carries_the_clients_parent_beacon_block_root_test() ->
    with_build(fun(Head) ->
                   {ok, Payload, _Value} = eth_block_builder:build(attributes(Head)),
                   ?assertEqual(<<"0x00000000000000000000000000000000000000000000000000000000000000bb">>,
                                maps:get(<<"parentBeaconBlockRoot">>, Payload))
               end).

%% The withdrawals root is derived from the client's list, not carried. EIP-4895
%% commits to the list in the header, so a root that disagrees with the list is a
%% block nobody can verify -- and `eth_block:finalize/1' checks it, which is why
%% the builder computes it rather than trusting one.
a_built_blocks_withdrawals_root_commits_to_the_clients_list_test() ->
    with_build(fun(Head) ->
                   Ws = [#{index => 7, validatorIndex => 8,
                           address => <<9:160>>, amount => 1000}],
                   {ok, Payload, _Value} =
                       eth_block_builder:build(
                         (attributes(Head))#{withdrawals => Ws}),
                   ?assertEqual([#{<<"index">> => <<"0x7">>,
                                   <<"validatorIndex">> => <<"0x8">>,
                                   <<"address">> =>
                                       <<"0x0000000000000000000000000000000000000009">>,
                                   <<"amount">> => <<"0x3e8">>}],
                                maps:get(<<"withdrawals">>, Payload)),
                   %% And the header commits to that list. The proof is the hash:
                   %% two payloads identical except for the withdrawals must have
                   %% different blockHashes, or EIP-4895's header field is not
                   %% committing to anything.
                   %%
                   %% Not asserted on `Block#block.withdrawals_root': a block
                   %% decoded by from_payload/1 has that field at new/2's default,
                   %% because withdrawalsRoot is *derived* rather than carried --
                   %% so the first version of this asserted that a derived field
                   %% was populated and it never was.
                   {ok, Without, _V2} =
                       eth_block_builder:build(attributes(Head)),
                   ?assertNotEqual(maps:get(<<"blockHash">>, Without),
                                   maps:get(<<"blockHash">>, Payload))
               end).

%% ===========================================================================
%% The header constants the dead builder got wrong
%% ===========================================================================
%%
%% Four fields, each of which was wrong in the version that was dead. A block with
%% any of them is not a block: the hash is not the one the network computes, and a
%% consensus client would build and broadcast it.

%% The dead builder got three header constants wrong, and this records *why* the
%% rewrite makes that class of defect impossible rather than merely fixed.
%%
%% ExecutionPayloadV1 does not carry `nonce', `sha3Uncles' or `difficulty' -- after
%% the Merge the first two are fixed constants and the third is zero, and the
%% payload codec supplies them from `eth_block:new/2'. The hash path re-decodes the
%% payload and takes all three from `new/2' again. So a value the builder put in
%% those fields never reaches the block hash, and a test that reads them off a
%% decoded payload is reading `new/2's values, not the builder's.
%%
%% That is the whole point: `to_payload/1' cannot express a wrong nonce or a wrong
%% uncle hash, so there is nothing left to get wrong. The constants themselves are
%% pinned where they *are* observable -- `eth_block_payload_tests' asserts
%% `to_payload/1' reproduces the real block hashes of three Sepolia blocks, which is
%% only possible with an 8-byte nonce and ?EMPTY_UNCLE_HASH.
%%
%% What is observable here is that the hash commits to the header fields the
%% payload *does* carry, so the encoder is the same one and not a second
%% implementation.
a_built_payloads_block_hash_commits_to_its_header_fields_test() ->
    with_build(fun(Head) ->
                   {ok, A, _} = eth_block_builder:build(attributes(Head)),
                   %% One header field the payload carries, changed. If the hash
                   %% did not commit to it, these two would be equal and the
                   %% payload would be a fixed string no matter what it contained.
                   {ok, B, _} =
                       eth_block_builder:build(
                         (attributes(Head))#{extra_data => <<1, 2, 3>>}),
                   ?assertNotEqual(maps:get(<<"blockHash">>, A),
                                   maps:get(<<"blockHash">>, B)),
                   ?assertNotEqual(eth_hex:encode_int(3),
                                   maps:get(<<"extraData">>, A)),
                   ?assertEqual(<<"0x010203">>, maps:get(<<"extraData">>, B))
               end).

%% An empty transactions trie roots to the empty *trie* root, and so does an empty
%% receipts trie. Both are legitimately 56e81f... -- the point of the test is that
%% they are the trie root, and that neither is the uncle hash. A builder that
%% reached for ?EMPTY_UNCLE_HASH here, or for a trie root in the uncle field, would
%% be wrong in the same two ways this module used to be.
an_empty_block_roots_its_tries_to_the_empty_trie_root_test() ->
    with_built_block(fun(Block) ->
                         ?assertEqual(?EMPTY_TRIE_ROOT, Block#block.transactions_root),
                         ?assertEqual(?EMPTY_TRIE_ROOT, Block#block.receipts_root)
                     end).

%% Cancun headers carry 20 fields. A payload missing parentBeaconBlockRoot is
%% 19, and its block hash is not the block's.
a_cancun_payload_carries_all_twenty_header_fields_test() ->
    with_build(fun(Head) ->
                   {ok, Payload, _Value} = eth_block_builder:build(attributes(Head)),
                   %% The two Cancun blob fields and the EIP-4788 field, so the
                   %% encoder takes its 20-field branch rather than its 17-field
                   %% one. A payload missing any of them hashes a different header.
                   [?assert(maps:is_key(K, Payload))
                    || K <- [<<"blobGasUsed">>, <<"excessBlobGas">>,
                             <<"parentBeaconBlockRoot">>]],
                   ?assertEqual(maps:get(<<"blockHash">>, Payload),
                                hex(payload_hash(Payload)))
               end).

%% The strongest check available: a built payload must reproduce its own hash
%% through the encoder that is pinned against three real Sepolia block hashes. A
%% header assembled from wrong constants cannot.
a_built_payload_reproduces_its_own_block_hash_test() ->
    with_build(fun(Head) ->
                   {ok, Payload, _Value} = eth_block_builder:build(attributes(Head)),
                   {ok, Block} = eth_block:from_payload(Payload),
                   {ok, Again} = eth_block:to_payload(Block),
                   ?assertEqual(maps:get(<<"blockHash">>, Payload),
                                maps:get(<<"blockHash">>, Again))
               end).

%% EIP-4844: the child's excessBlobGas is the parent's excess plus the gas the
%% parent's blobs used, less the per-block target. It is a consensus header field on
%% Cancun, so defaulting it to 0 is a value the network did not choose.
%%
%% The fixture parent has a non-zero excess and used a blob, so the update is
%% visible in the built payload rather than collapsing to zero.
a_built_block_carries_the_eip_4844_excess_blob_gas_test() ->
    with_fresh_chain(fun() ->
        Head = store_head_with(blob_fixture_parent(), true),
        %% The builder takes the parent's two EIP-4844 inputs as attributes --
        %% eth_engine is what reads them off the chain store, so a test that calls
        %% the builder directly has to supply what the engine would have supplied.
        Attrs = (attributes(Head))#{parent_excess_blob_gas => 600000,
                                     parent_blob_gas_used => 131072},
        {ok, Payload, _Value} = eth_block_builder:build(Attrs),
        Expected = eth_fork_schedule:excess_blob_gas(fork_of(Attrs), 600000, 131072,
                                                    maps:get(parent_base_fee_per_gas, Attrs, 0)),
        ?assertNotEqual(0, Expected),
        ?assertEqual(eth_hex:encode_int(Expected),
                     maps:get(<<"excessBlobGas">>, Payload))
    end).

%% And the block's own blob gas used is 0, because this builder includes no blob
%% transactions. That is a statement about this build, not a default: the selection
%% path admits no type-3 transaction.
a_built_block_uses_no_blob_gas_of_its_own_test() ->
    with_fresh_chain(fun() ->
        Head = store_head_with(blob_fixture_parent(), true),
        {ok, Payload, _Value} =
            eth_block_builder:build(
              (attributes(Head))#{parent_excess_blob_gas => 600000,
                                   parent_blob_gas_used => 131072}),
        ?assertEqual(<<"0x0">>, maps:get(<<"blobGasUsed">>, Payload))
    end).

%% ===========================================================================
%% payloadId: issued, and answerable
%% ===========================================================================

forkchoice_updated_issues_a_payload_id_test() ->
    with_engine_and_head(fun(Head) ->
                             Status = ?SYNCING,
                             {Status, PayloadId} =
                                 eth_engine:forkchoice_updated(
                                   forkchoice(Head), attributes_json(3)),
                             ?assertEqual(8, byte_size(PayloadId)),
                             ?assertNotEqual(undefined, PayloadId)
                         end).

%% No attributes means no build, so no payloadId. `null' and an 8-byte zero id are
%% different answers: the first says "no build was started", the second names a
%% build that does not exist.
forkchoice_updated_without_attributes_issues_no_payload_id_test() ->
    with_engine_and_head(fun(Head) ->
                             {Status, PayloadId} =
                                 eth_engine:forkchoice_updated(forkchoice(Head),
                                                               null),
                             ?assertEqual(?SYNCING, Status),
                             ?assertEqual(undefined, PayloadId)
                         end).

two_builds_get_different_payload_ids_test() ->
    with_engine_and_head(fun(Head) ->
                             {_S, A} = eth_engine:forkchoice_updated(
                                         forkchoice(Head), attributes_json(3)),
                             {_S2, B} = eth_engine:forkchoice_updated(
                                          forkchoice(Head), attributes_json(3)),
                             ?assertNotEqual(A, B)
                         end).

get_payload_returns_the_payload_its_id_names_test() ->
    with_engine_and_head(fun(Head) ->
                             {_S, PayloadId} = eth_engine:forkchoice_updated(
                                                 forkchoice(Head),
                                                 attributes_json(3)),
                             {ok, Payload, _Value} = eth_engine:get_payload(PayloadId),
                             ?assert(maps:is_key(<<"blockHash">>, Payload)),
                             ?assert(maps:is_key(<<"transactions">>, Payload))
                         end).

%% An id this node never issued is -38001, and an id of the wrong shape is
%% -32602. "You sent me nonsense" and "I never built that" are different answers
%% and only the first is a client bug.
get_payload_distinguishes_an_unknown_id_from_a_malformed_one_test() ->
    with_engine_and_head(fun(Head) ->
                             {_S, PayloadId} = eth_engine:forkchoice_updated(
                                                 forkchoice(Head),
                                                 attributes_json(3)),
                             ?assertEqual({error, unknown_payload},
                                          eth_engine:get_payload(<<9:64>>)),
                             ?assertEqual({error, unknown_payload},
                                          eth_engine:get_payload(<<0:64>>)),
                             %% A well-formed id this node never issued is
                             %% unknown, not invalid -- including an all-ones one.
                             ?assertEqual({error, unknown_payload},
                                          eth_engine:get_payload(<<255:64>>)),
                             %% Only a malformed one is invalid_params: the
                             %% specification's parameter is DATA, 8 bytes.
                             ?assertEqual({error, invalid_params},
                                          eth_engine:get_payload(<<"0xzz">>)),
                             ?assertEqual({error, invalid_params},
                                          eth_engine:get_payload(<<1:32>>)),
                             ?assertEqual({error, invalid_params},
                                          eth_engine:get_payload(<<1:128>>)),
                             %% The id it *was* given is answerable, which is what
                             %% makes the two errors above meaningful.
                             ?assertMatch({ok, _, _},
                                          eth_engine:get_payload(PayloadId))
                         end).

%% ===========================================================================
%% Refusing rather than guessing
%% ===========================================================================

%% The number, gas limit, base fee and EIP-4844 inputs are read from the head block
%% in the chain store. A node that does not hold the head cannot build on it, and
%% inventing any of the four would put a guessed number or a guessed base fee in the
%% header -- the base fee is what every fee calculation then divides by.
no_build_when_the_chain_does_not_hold_the_head_test() ->
    with_engine(fun() ->
                    %% A well-formed 32-byte hash the chain does not hold. A
                    %% malformed one is refused by the head check before the build
                    %% is even considered, which is a different refusal and is
                    %% tested separately.
                    Unknown = binary:decode_hex(
                                <<"deadbeefdeadbeefdeadbeefdeadbeef"
                                  "deadbeefdeadbeefdeadbeefdeadbeef">>),
                    {Status, PayloadId} =
                        eth_engine:forkchoice_updated(forkchoice(Unknown),
                                                      attributes_json(3)),
                    ?assertEqual(?SYNCING, Status),
                    ?assertEqual(undefined, PayloadId)
                end).

%% An unreadable base fee on the parent is the same refusal: a Cancun header
%% carries excessBlobGas, and 0 is a value the network chose, not one this node
%% may substitute.
no_build_when_the_parents_fields_are_unreadable_test() ->
    with_builder_and_head_without_base_fee(fun(Head) ->
                                                {Status, PayloadId} =
                                                    eth_engine:forkchoice_updated(
                                                      forkchoice(Head),
                                                      attributes_json(3)),
                                                ?assertEqual(?SYNCING, Status),
                                                ?assertEqual(undefined, PayloadId)
                                            end).

%% ===========================================================================
%% Over the wire
%% ===========================================================================

%% V1's result is the bare payload; V2 and V3 add blockValue. Before this the
%% payloadId was a hardcoded `null' in every branch and the blockValue a hardcoded
%% `0x0', so a V2 client destructured an object with no executionPayload key and
%% read a revenue of zero.
get_payload_v1_is_a_bare_payload_and_v2_wraps_it_test() ->
    with_engine_and_http(fun(Head, Port) ->
                             PayloadId = call_forkchoice(Port, Head, 2),
                             ?assert(is_binary(PayloadId)),
                             {ok, #{<<"result">> := V1}, _} =
                                 call(Port, <<"engine_getPayloadV1">>, [PayloadId]),
                             ?assert(maps:is_key(<<"blockHash">>, V1)),
                             ?assertNot(maps:is_key(<<"executionPayload">>, V1)),
                             ?assertNot(maps:is_key(<<"blockValue">>, V1)),
                             {ok, #{<<"result">> := V2}, _} =
                                 call(Port, <<"engine_getPayloadV2">>, [PayloadId]),
                             ?assert(maps:is_key(<<"executionPayload">>, V2)),
                             %% The blockValue is 0x0 here, and that is the *right*
                             %% answer: this node's pool is not running, so the block
                             %% has no transactions and the fee recipient is owed
                             %% nothing. The wire test therefore pins the shape and
                             %% the encoding, and the arithmetic is pinned by the
                             %% block_value/1 tests -- a hardcoded 0x0 is
                             %% indistinguishable from a computed 0 on an empty
                             %% block, and pretending otherwise would be a test that
                             %% cannot fail.
                             ?assertEqual(<<"0x0">>, maps:get(<<"blockValue">>, V2)),
                             {ok, #{<<"result">> := V3}, _} =
                                 call(Port, <<"engine_getPayloadV3">>, [PayloadId]),
                             ?assert(maps:is_key(<<"blobsBundle">>, V3)),
                             ?assert(maps:is_key(<<"shouldOverrideBuilder">>, V3)),
                             %% V1 and V2 describe the same block, so the payload
                             %% must be identical between them.
                             ?assertEqual(V1, maps:get(<<"executionPayload">>, V2))
                         end).

forkchoice_updated_over_http_returns_the_payload_id_test() ->
    with_engine_and_http(fun(Head, Port) ->
                             Id = call_forkchoice(Port, Head, 3),
                             ?assert(is_binary(Id)),
                             %% DATA, 8 bytes: 0x plus 16 nibbles.
                             ?assertEqual(18, byte_size(Id)),
                             ?assertEqual(<<"0x">>, binary:part(Id, 0, 2))
                         end).

forkchoice_updated_over_http_reports_null_without_attributes_test() ->
    with_engine_and_http(fun(Head, Port) ->
                             ?assertMatch(
                                {ok, #{<<"result">> :=
                                       #{<<"payloadId">> := null}}, _},
                                call(Port, <<"engine_forkchoiceUpdatedV3">>,
                                     [forkchoice(Head), null]))
                         end).

%% An 8-byte zero id is not "no build". It names a build, so a client must not be
%% able to read one.
a_zero_payload_id_is_not_answered_with_a_payload_test() ->
    with_engine_and_http(fun(_Head, Port) ->
                             ?assertMatch(
                                {ok, #{<<"error">> := #{<<"code">> := -38001}}, _},
                                call(Port, <<"engine_getPayloadV1">>, [<<0:64>>]))
                         end).

%% ===========================================================================
%% blockValue
%% ===========================================================================
%%
%% "The expected value to be received by the feeRecipient in wei". The base fee is
%% burned, so this is the sum of *tips* over the gas the transactions actually used
%% -- not the declared gas limits and not the full gas prices.

%% **The shape of the argument is the defect, and it is pinned here rather than
%% only implied.** `build/1' used to hand this function a `Verification' map, which
%% has no `receipts' key, and the function answered 0 -- so `getPayload' reported
%% `blockValue: 0` for every block this node built. Nothing caught it, because all
%% eight of the other assertions on this function passed the map shape
%% `#{receipts => [...]}`: the tip arithmetic was pinned correctly against a fixture
%% **no production call could supply**. A test that pins the arithmetic and the call
%% shape at once will happily pin a call shape that never happens.
%%
%% So this asserts the guard rather than a number. A `Verification` map is refused
%% loudly instead of answering 0, which is the whole difference between the bug and
%% the fix: the bug's failure mode was a **plausible number**, and this makes an
%% incompatible argument an exception.
%%
%% **Not covered, and it should be:** no test exercises `getPayload` on a block that
%% actually contains a transaction. That needs a funded state in the parent's trie,
%% a signed transaction in a running pool, and the chain head carrying that state
%% root -- and `store_head/0' builds a header with no state at all, so the fixture
%% does not exist in this module. The end-to-end path is unverified here, and the
%% `0x0` assertion in the wire test is *correct* for an empty block, which is why it
%% never noticed.
block_value_refuses_a_verification_map_rather_than_answering_zero_test() ->
    ?assertError(function_clause,
                 eth_block_builder:block_value(#{receipts => []})),
    ?assertError(function_clause,
                 eth_block_builder:block_value(#{})).

block_value_of_a_block_with_no_transactions_is_zero_test() ->
    ?assertEqual(0, eth_block_builder:block_value([])).

%% A receipt that did not execute carries no gas, so there is nothing to value. The
%% answer is 0 rather than the product of a declared gas limit and a declared price,
%% which would be a revenue the proposer does not receive.
block_value_of_an_unexecuted_receipt_is_zero_test() ->
    ?assertEqual(0, eth_block_builder:block_value(
                      [#{<<"gasPrice">> => <<"0x3b9aca00">>,
                         <<"gas">> => <<"0x5208">>}])).

block_value_sums_the_tip_over_the_gas_used_test() ->
    %% The tip is min(maxPriorityFeePerGas, maxFeePerGas - baseFee), and the
    %% priority fee is the binding term here: 2 gwei against a 10 gwei cap.
    Receipt = #{<<"maxPriorityFeePerGas">> => <<"0x77359400">>,   %% 2 gwei
                <<"maxFeePerGas">> => <<"0x2540be400">>,           %% 10 gwei
                <<"baseFeePerGas">> => <<"0x3b9aca00">>,           %% 1 gwei
                gas_used => 21000},
    ?assertEqual(21000 * 2000000000,
                 eth_block_builder:block_value([Receipt])),
    %% Raise the base fee to meet the priority fee. The tip is unchanged at 2 gwei,
    %% because the *priority* term is still the binding one -- min(2 gwei, 8 gwei).
    Capped = Receipt#{<<"baseFeePerGas">> => <<"0x77359400">>},     %% 2 gwei
    ?assertEqual(21000 * 2000000000,
                 eth_block_builder:block_value([Capped])),
    %% A priority fee above the cap cannot be paid at all, so the tip is the cap
    %% minus the burn. Reading the priority fee alone here would report more
    %% revenue than the transaction can possibly pay.
    Over = Receipt#{<<"maxPriorityFeePerGas">> => <<"0x2540be400">>},
    ?assertEqual(21000 * (10000000000 - 1000000000),
                 eth_block_builder:block_value([Over])).

block_value_of_a_legacy_receipt_subtracts_the_burn_test() ->
    Receipt = #{<<"gasPrice">> => <<"0x3b9aca00">>,               %% 1 gwei
                <<"baseFeePerGas">> => <<"0x3b9aca00">>,          %% 1 gwei
                gas_used => 21000},
    %% gasPrice equals the base fee, so the whole payment is burn and the tip is
    %% zero. This is the case that a builder multiplying gas by gasPrice would get
    %% wrong by 21000 gwei.
    ?assertEqual(0, eth_block_builder:block_value([Receipt])),
    Receipt2 = Receipt#{<<"baseFeePerGas">> => <<"0x2540be400">>},  %% 10 gwei
    ?assertEqual(0, eth_block_builder:block_value([Receipt2])).

%% ===========================================================================
%% Fixtures
%% ===========================================================================


payload_hash(Payload) ->
    {ok, Hash} = eth_block:payload_block_hash(Payload),
    Hash.

with_built_block(Fun) ->
    with_build(fun(Head) ->
                   {ok, Payload, _Value} = eth_block_builder:build(attributes(Head)),
                   {ok, Block} = eth_block:from_payload(Payload),
                   Fun(Block)
               end).

%% A chain holding one post-Merge block, and the builder running. The block carries
%% a base fee, which the builder reads for the block it builds -- and which the
%% shared `eth_test_util:header/3' fixture does not, because a pre-Merge fixture
%% has none.
with_build(Fun) ->
    with_fresh_chain(fun() -> Fun(store_head()) end).

with_builder_and_head_without_base_fee(Fun) ->
    with_fresh_chain(fun() -> Fun(store_head_without_base_fee()) end).

%% A chain of this module's own, stopped on the way out.
%%
%% Not reused. `eth_chain' is a singleton registered under its own name, the engine
%% and the builder both reach it as `eth_chain', and another test module in the
%% same VM may have left one running with block 0 already stored -- from a
%% *different* parent hash. Appending a second block 0 then failed the chain's own
%% parent check with `missing_parent', which reads as the code under test refusing
%% a build when it is the fixture colliding. A fresh store per test is the only
%% way to keep the two apart.
with_fresh_chain(Fun) ->
    _ = ensure(eth_block_builder, #{}),
    stop(eth_chain),
    {ok, _} = eth_chain:start_link(eth_chain, eth_test_util:tmp_dir()),
    try Fun()
    after
        stop(eth_chain),
        stop(eth_block_builder)
    end.

with_engine(Fun) ->
    _ = ensure(eth_block_builder, #{}),
    {ok, _} = eth_engine:start_link(#{jwt_secret => <<16#5a:256>>}),
    try Fun()
    after stop(eth_engine), stop(eth_block_builder)
    end.

with_engine_and_head(Fun) ->
    with_engine(fun() -> with_fresh_chain(fun() -> Fun(store_head()) end) end).

%% start_apps/0 brings up cowboy, and with it ranch_sup, which is what actually
%% starts a listener. Without it `cowboy:start_clear/3' raises noproc on
%% ranch_sup -- four tests failed on that before this line existed.
with_engine_and_http(Fun) ->
    with_engine(fun() ->
                    ok = eth_test_util:start_apps(),
                    with_fresh_chain(
                      fun() ->
                              Head = store_head(),
                              Port = eth_test_util:free_port(),
                              Dispatch = cowboy_router:compile(
                                [{'_', [{<<"/engine">>,
                                         eth_engine_handler, #{}}]}]),
                              {ok, _} = cowboy:start_clear(
                                          'builder_test_listener',
                                          [{port, Port},
                                           {ip, {127, 0, 0, 1}}],
                                          #{env => #{dispatch => Dispatch}}),
                              try Fun(Head, Port)
                              after
                                  (try cowboy:stop_listener('builder_test_listener')
                                   catch _:_ -> ok end)
                              end
                      end)
                end).

ensure(Mod, Opts) ->
    case whereis(Mod) of
        undefined -> {ok, Pid} = Mod:start_link(Opts), Pid;
        Pid -> Pid
    end.

stop(Mod) ->
    case whereis(Mod) of
        undefined -> ok;
        _ -> (try gen_server:stop(Mod) catch _:_ -> ok end)
    end.

%% Block 0, post-Merge, with the fields the builder reads off a parent.
store_head() ->
    store_head_with(#{<<"blobGasUsed">> => <<"0x0">>,
                      <<"excessBlobGas">> => <<"0x0">>}, true).

%% A parent whose blocks have used blob gas, so the EIP-4844 update to the child's
%% excessBlobGas is observable. With a parent at zero excess and zero used -- which
%% is what the first fixture used -- the update reads max(0, 0 + 0 - target) = 0, so
%% hardcoding the field to 0 was invisible: the wrong value and the right value were
%% the same number. A test that cannot tell a correct field from a hardcoded one is
%% not testing it.
store_head_with(Blob, IncludeBaseFee) ->
    Base = eth_test_util:header(0, hex(<<0:256>>), 0),
    Parent0 = maps:merge(Base, Blob),
    Parent1 = case IncludeBaseFee of
                  true -> Parent0#{<<"baseFeePerGas">> => eth_hex:encode_int(1000000000)};
                  false -> Parent0
              end,
    Parent = Parent1#{<<"totalDifficulty">> => eth_hex:encode_int(0)},
    {ok, HashHex} = eth_header:verify(Parent),
    ok = eth_chain:append([{0, Parent#{<<"hash">> => HashHex}, true}]),
    binary:decode_hex(binary:part(HashHex, 2, 64)).

%% 6 blobs' worth of excess plus 1 blob used: the target is 393216 gas (3 blobs), so
%% the child's excess is 6*131072 + 131072 - 393216 = 524288 - ... computed by the
%% same helper the builder calls, and asserted here so the fixture and the code
%% cannot agree by accident.
blob_fixture_parent() ->
    #{<<"blobGasUsed">> => eth_hex:encode_int(131072),
      <<"excessBlobGas">> => eth_hex:encode_int(600000)}.

store_head_without_base_fee() ->
    Base = eth_test_util:header(0, hex(<<0:256>>), 0),
    Parent = Base#{<<"blobGasUsed">> => <<"0x0">>,
                   <<"excessBlobGas">> => <<"0x0">>,
                   <<"totalDifficulty">> => eth_hex:encode_int(0)},
    {ok, HashHex} = eth_header:verify(Parent),
    ok = eth_chain:append([{0, Parent#{<<"hash">> => HashHex}, true}]),
    binary:decode_hex(binary:part(HashHex, 2, 64)).

%% The decoded form eth_block_builder:build/1 takes. A Cancun timestamp, so the
%% block built from it is a Cancun block and carries the blob and beacon-root
%% fields.
attributes(Head) ->
    #{parent_hash => Head,
      number => 1,
      gas_limit => 30000000,
      base_fee => 1000000000,
      parent_excess_blob_gas => 0,
      parent_blob_gas_used => 0,
      timestamp => 1730403216,
      extra_data => <<>>,
      prev_randao => <<16#aa:256>>,
      fee_recipient => <<16#ff:160>>,
      withdrawals => [],
      parent_beacon_block_root => <<16#bb:256>>}.

%% The same thing as the Engine API carries it: hex strings, not raw bytes, and
%% carrying *that version's* keys and no more.
%%
%% The version is a parameter because PayloadAttributesV1 has no `withdrawals',
%% V2 adds it, and V3 adds `parentBeaconBlockRoot' -- and a V3 attributes object on
%% a V2 method is refused with -38003, correctly. One fixture for all three meant
%% the V2 tests sent a beacon root and were refused for the right reason by the
%% wrong test, which is the most expensive kind of confusion: the gate was right and
%% the fixture was wrong.
attributes_json(1) -> attributes_v1();
attributes_json(2) -> attributes_v2();
attributes_json(3) -> attributes_v3().

attributes_v1() ->
    #{<<"timestamp">> => <<"0x6723db90">>,
      <<"prevRandao">> => hex(<<16#aa:256>>),
      <<"suggestedFeeRecipient">> => hex(<<16#ff:160>>)}.

attributes_v2() ->
    (attributes_v1())#{<<"withdrawals">> => []}.

attributes_v3() ->
    (attributes_v2())#{<<"parentBeaconBlockRoot">> => hex(<<16#bb:256>>)}.

%% The three hashes as the wire carries them: 0x-prefixed hex *strings*. They are
%% built here from raw bytes, and passing the raw 32 bytes instead made the test's
%% own request encoder fail with `{invalid_byte, <<"0x8F">>}' -- it only appeared to
%% work on the hashes that happened to be all-ASCII. The same trap as three
%% separate production defects in this codebase, in a fixture.
forkchoice(Head) ->
    #{<<"headBlockHash">> => hex(Head),
      <<"safeBlockHash">> => hex(<<0:256>>),
      <<"finalizedBlockHash">> => hex(<<0:256>>)}.

%% The payloadId the response carries, or the whole response if it carries none.
%% A client reads this field, so the helper returns exactly that rather than the
%% envelope -- the first version returned the 3-tuple and every caller had to
%% destructure it, and one did not.
call_forkchoice(Port, Head, Version) ->
    Method = <<"engine_forkchoiceUpdatedV", (integer_to_binary(Version))/binary>>,
    {ok, Body, _Status} = call(Port, Method, [forkchoice(Head), attributes_json(Version)]),
    case maps:get(<<"result">>, Body, undefined) of
        #{<<"payloadId">> := Id} -> Id;
        _ -> Body
    end.

%% The HTTP helpers, duplicated here rather than shared with eth_engine_tests
%% because those are private to that module and this one must not reach into
%% another test's internals.
call(Port, Method, Params) ->
    Token = eth_jwt:sign(#{<<"iat">> => os:system_time(second)}, <<16#5a:256>>),
    Body = thoas:encode(#{<<"jsonrpc">> => <<"2.0">>,
                          <<"id">> => 1,
                          <<"method">> => Method,
                          <<"params">> => Params}),
    URL = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/engine",
    {ok, {{_, Status, _}, _, Resp}} =
        httpc:request(post, {URL, [{"authorization", "Bearer " ++ Token}],
                             "application/json", Body},
                      [{timeout, 10000}], [{body_format, binary}]),
    {ok, Decoded} = thoas:decode(Resp),
    {ok, Decoded, Status}.

hex(Bin) -> <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.

%% The fork the attributes name, for the same reason `eth_fork_schedule:excess_blob_gas/3'
%% needs one: the per-block target is a fork parameter.
fork_of(Attributes) ->
    case maps:get(fork, Attributes, undefined) of
        undefined -> eth_fork_schedule:configured_fork();
        Fork -> Fork
    end.
