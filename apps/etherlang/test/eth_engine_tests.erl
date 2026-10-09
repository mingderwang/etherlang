%% Tests for the Engine API.
%%
%% There were none. `grep -rl eth_engine apps/etherlang/test/' returned nothing,
%% so every claim this project made about the engine was unchecked, and the module
%% had a defect that no amount of reading would have surfaced: it crashed on
%% every call. `#st.payloads' had no default and `init/1' never set it, so
%% `maps:put/3' raised badmap inside a try whose catch turned it into
%% `{INVALID, {error, {badmap, undefined}}}'. engine_newPayloadV1 refused
%% everything and looked, from the outside, like a node validating payloads.
%%
%% The tests are grouped by what they pin:
%%
%%   - newPayload cannot report anything but "not checked", because this node
%%     executes nothing
%%   - the JSON the engine actually receives is decoded (binary keys, hex DATA)
%%   - forkchoiceUpdated cannot say VALID about a block it has not validated
%%   - the state the engine is handed is actually kept
%%   - getPayload will not hand back a payload this node never built
%%   - exchangeTransitionConfiguration returns the configuration, not a status
%%   - the HTTP surface answers, is authenticated, and shapes its responses as
%%     the specification does
-module(eth_engine_tests).

-include_lib("eunit/include/eunit.hrl").

%% The sentinel for an undecided TERMINAL_TOTAL_DIFFICULTY, written as the
%% decimal the specification prints so this fixture is a transcription of the
%% clause rather than a copy of the source's expression. It equals 2^256-2^10.
%% It was 16#ffff...ff, i.e. 2^256-1, which is 1023 too high.
-define(NO_TTD, 115792089237316195423570985008687907853269984665640564039457584007913129638912).

%% ===========================================================================
%% newPayload: no status this node cannot support
%% ===========================================================================

%% A payload with no parent hash cannot be placed on any chain, so no status
%% derived from execution could describe it.
new_payload_without_a_parent_hash_is_invalid_test() ->
    with_engine(fun() ->
        ?assertEqual({<<"INVALID">>, {missing_field, <<"parentHash">>}},
                     eth_engine:new_payload(maps:remove(
                         <<"parentHash">>, real_payload())))
    end).

%% The specification's ACCEPTED is a claim with preconditions -- non-empty
%% transactions, a blockHash equal to Keccak256(RLP(header)), a non-canonical
%% payload, known and well-formed ancestors. None is checked here, and nothing is
%% executed, so ACCEPTED and VALID are both unsupported.
%% A real, well-formed Cancun block. This node holds no state for its parent and
%% no chain to resolve it against, so it cannot execute it, and SYNCING is the
%% specification's status for exactly that. What it must not do is answer VALID,
%% or ACCEPTED, or INVALID: the block is not bad, and this node has not checked it.
new_payload_never_reports_a_block_it_did_not_execute_test() ->
    with_engine(fun() ->
        ?assertEqual(<<"SYNCING">>, eth_engine:new_payload(payload()))
    end).

%% The three that are still refusals of *this* payload, not of the engine's
%% ability to validate it: a payload that does not decode, and a payload whose
%% block hash is not the hash of its own header.
new_payload_rejects_a_payload_that_does_not_decode_test() ->
    with_engine(fun() ->
        ?assertEqual({<<"INVALID">>, {missing_field, <<"stateRoot">>}},
                     eth_engine:new_payload(
                         maps:remove(<<"stateRoot">>, real_payload())))
    end).

new_payload_rejects_a_block_hash_that_is_not_its_own_test() ->
    with_engine(fun() ->
        %% A different block's hash, 32 bytes and the right length.
        Forged = hex(<<16#99, 0:248>>),
        ?assertMatch({<<"INVALID_BLOCK_HASH">>, {block_hash_mismatch, _, _}},
                     eth_engine:new_payload(
                         maps:put(<<"blockHash">>, Forged, real_payload())))
    end).

new_payload_rejects_a_block_hash_of_the_wrong_width_test() ->
    with_engine(fun() ->
        ?assertEqual({<<"INVALID_BLOCK_HASH">>,
                      missing_or_malformed_block_hash},
                     eth_engine:new_payload(
                         maps:put(<<"blockHash">>, <<"0xabcd">>, real_payload())))
    end).

%% The web browser attack the authentication document names is a malicious page
%% posting JSON, so the key form a request arrives in is the one that matters.
%% Every lookup in the module used to be `maps:get("someKey", ...)`, so a
%% binary-keyed payload -- which is what a decoded JSON object always is -- was
%% read as empty and answered INVALID for a parent hash it was carrying.
%% A decoded JSON object has binary keys, and every lookup in the engine used to
%% be `maps:get("someKey", ...)' with a string, so nothing was ever read over HTTP.
%% The real fixture is binary-keyed, so this fails if that comes back.
new_payload_reads_the_keys_a_json_request_carries_test() ->
    with_engine(fun() ->
        P = payload(),
        ?assertEqual([], [K || K <- maps:keys(P), is_list(K)]),
        ?assertEqual(<<"SYNCING">>, eth_engine:new_payload(P))
    end).

new_payload_rejects_a_malformed_parent_hash_test() ->
    with_engine(fun() ->
        %% Too short to be a 32-byte hash.
        ?assertMatch({<<"INVALID">>, {bad_field, <<"parentHash">>, _}},
                     eth_engine:new_payload(
                         maps:put(<<"parentHash">>, <<"0xabcd">>, real_payload()))),
        %% Right length, but not hex.
        ?assertMatch({<<"INVALID">>, {bad_field, <<"parentHash">>, _}},
                     eth_engine:new_payload(
                         maps:put(<<"parentHash">>,
                                  non_hex_data(), real_payload())))
    end).

%% A decoded JSON object carries a DATA field as a 0x-prefixed *string*; the
%% record stores it as raw bytes, and an in-process caller naturally holds the
%% bytes. Accepting only one of the two forms means refusing either every real
%% payload or every caller in the same VM -- and the raw form is the one the
%% record stores, so a decoder that rejected it would be rejecting its own output.
new_payload_accepts_a_parent_hash_as_raw_bytes_test() ->
    with_engine(fun() ->
        P = real_payload(),
        Raw = maps:put(<<"parentHash">>, unhex(maps:get(<<"parentHash">>, P)), P),
        ?assertEqual(32, byte_size(maps:get(<<"parentHash">>, Raw))),
        ?assertEqual(<<"SYNCING">>, eth_engine:new_payload(Raw))
    end).

new_payload_rejects_a_parent_hash_that_is_not_data_test() ->
    with_engine(fun() ->
        ?assertMatch({<<"INVALID">>, {bad_field, <<"parentHash">>, _}},
                     eth_engine:new_payload(
                         maps:put(<<"parentHash">>, 42, real_payload())))
    end).

new_payload_needs_a_map_test() ->
    with_engine(fun() ->
        ?assertEqual({<<"INVALID">>, payload_not_an_object},
                     eth_engine:new_payload(<<"not a map">>))
    end).

%% The engine's own fixture is a payload whose parent this node cannot resolve,
%% so every status below is reached through the real decode-then-verify path
%% rather than through a shortcut. These are the three that matter:
%% - a payload whose declared roots disagree with what execution produced is
%%   INVALID, and a payload whose parent is unknown is SYNCING. Reporting both as
%%   one status would leave a client unable to tell a bad block from an
%%   unfinished check.

%% ===========================================================================
%% The verdict mapping
%% ===========================================================================
%%
%% A payload whose parent this node cannot resolve never gets as far as a verdict,
%% so every test above lands on SYNCING and the mapping below it is untested by
%% them. These cover it directly.
%%
%% The Verification maps are the shapes eth_finalize_tests produces from blocks
%% that actually execute, so the two halves of the path -- finalize/1 producing
%% these verdicts, and the engine mapping them onto statuses -- are each pinned
%% where they can be, rather than one test pretending to have executed a block.

all_three_roots_verified_is_valid_test() ->
    R = eth_trie:root([]),
    ?assertEqual(<<"VALID">>,
                 eth_engine:status_for_verification(
                   #{state_root => {verified, R},
                     transactions_root => {verified, R},
                     receipts_root => {verified, R}})).

%% A commitment that was checked and does not match is INVALID. Reporting it as
%% SYNCING instead would leave a client unable to tell a block this node has
%% found bad from one it has not finished looking at -- and the block is never
%% going to become valid, so there is nothing to wait for.
%%
%% Every term below is the one eth_block:finalize/1 actually produced, taken from
%% the Verification map of a block that really executed. They are not written out
%% by hand, and that is the whole point of this test: the mismatch reasons are
%% not one shape. check_state_root/2 reports a 3-tuple
%% `{mismatch, Declared, Computed}' and check_commitment/3 a 4-tuple
%% `{mismatch, Which, Declared, Computed}', and the earlier version of this test
%% hand-wrote the 4-tuple for all three roots. So it passed against an engine
%% that matched only the 4-tuple -- which is to say it passed against an engine
%% that answered SYNCING for a payload declaring a wrong state root, the
%% commitment this node is most entitled to have an opinion about. A test that
%% builds its fixture in the shape the code under test expects cannot catch the
%% code disagreeing with eth_block about what shape that is.
a_mismatched_state_root_is_invalid_test() ->
    eth_test_util:finalize_ctx(fun() ->
        ParentRoot = eth_test_util:seed_account(),
        Parent = eth_test_util:store_parent(ParentRoot),
        Lying = eth_block:declare_state_root(eth_block:new(Parent, 1),
                                             <<16#99:256>>),
        {ok, _, V} = eth_block:finalize(Lying),
        ?assertMatch({unverified, {mismatch, <<16#99:256>>, _}},
                     maps:get(state_root, V)),
        ?assertMatch({<<"INVALID">>, {unverified, {mismatch, _, _}}},
                     eth_engine:status_for_verification(V))
    end).

a_mismatched_receipts_root_is_invalid_test() ->
    eth_test_util:finalize_ctx(fun() ->
        Parent = eth_test_util:store_parent(eth_test_util:seed_account()),
        Lying = eth_test_util:inbound_block(
                  hex(Parent), #{<<"receiptsRoot">> => hex(<<16#77:256>>)}),
        {ok, _, V} = eth_block:finalize(Lying),
        ?assertMatch({unverified, {mismatch, receipts_root, <<16#77:256>>, _}},
                     maps:get(receipts_root, V)),
        ?assertMatch({<<"INVALID">>, {unverified, {mismatch, receipts_root, _, _}}},
                     eth_engine:status_for_verification(V))
    end).

a_mismatched_transactions_root_is_invalid_test() ->
    eth_test_util:finalize_ctx(fun() ->
        Parent = eth_test_util:store_parent(eth_test_util:seed_account()),
        Lying = eth_test_util:inbound_block(
                  hex(Parent), #{<<"transactionsRoot">> => hex(<<16#66:256>>)}),
        {ok, _, V} = eth_block:finalize(Lying),
        ?assertMatch({unverified, {mismatch, transactions_root, <<16#66:256>>, _}},
                     maps:get(transactions_root, V)),
        ?assertMatch({<<"INVALID">>, {unverified, {mismatch, transactions_root, _, _}}},
                     eth_engine:status_for_verification(V))
    end).

%% A commitment this node could not check is not the same thing, and must not be
%% reported the same way: nothing is known against the block.
an_unchecked_root_is_syncing_test() ->
    R = eth_trie:root([]),
    ?assertEqual(<<"SYNCING">>,
                 eth_engine:status_for_verification(
                   #{state_root => {unverified, state_not_local},
                     transactions_root => {verified, R},
                     receipts_root => {unverified, not_executed}})).

%% A mismatch outranks an unchecked root: if anything is known to be wrong, that
%% is the answer, whatever else could not be checked. Built from a real finalize
%% result, so the state root here is the 3-tuple eth_block produces and the
%% receipts root is the {unverified, not_executed} of a block whose body was
%% never executed.
a_mismatch_outranks_an_unchecked_root_test() ->
    eth_test_util:finalize_ctx(fun() ->
        ParentRoot = eth_test_util:seed_account(),
        Parent = eth_test_util:store_parent(ParentRoot),
        %% No transactions, so the declared content roots are the empty-trie
        %% roots and both check out. The state root is made to lie.
        Lying = eth_block:declare_state_root(
                  eth_test_util:inbound_block(
                    hex(Parent),
                    #{<<"receiptsRoot">> => hex(eth_trie:root([])),
                      <<"transactionsRoot">> => hex(eth_trie:root([]))}),
                  <<16#99:256>>),
        {ok, _, V} = eth_block:finalize(Lying),
        ?assertEqual({verified, eth_trie:root([])}, maps:get(receipts_root, V)),
        ?assertEqual({verified, eth_trie:root([])},
                     maps:get(transactions_root, V)),
        ?assertMatch({<<"INVALID">>, {unverified, {mismatch, _, _}}},
                     eth_engine:status_for_verification(V))
    end).

%% A declared root this node could not even interpret is a mismatch, not an
%% absence: the payload is claiming something, and the claim is unreadable.
an_uninterpretable_declared_root_is_invalid_test() ->
    ?assertMatch({<<"INVALID">>, {unverified, {invalid_declared, _}}},
                 eth_engine:status_for_verification(
                   #{state_root => {verified, eth_trie:root([])},
                     transactions_root => {unverified, {invalid_declared,
                                                       transactions_root}},
                     receipts_root => {verified, eth_trie:root([])}})).

%% The same mapping, applied to what finalizing returns rather than to the
%% verdicts alone.

an_unknown_parent_is_syncing_test() ->
    ?assertEqual(<<"SYNCING">>,
                 eth_engine:status_for_finalize(
                     {error, {unknown_parent, <<16#ab, 0:248>>}})).

%% A block containing an invalid transaction is not a block, and no amount of
%% waiting changes that -- so INVALID, not SYNCING.
an_invalid_transaction_is_invalid_test() ->
    ?assertEqual({<<"INVALID">>, {invalid_transaction, 0, bad_nonce}},
                 eth_engine:status_for_finalize(
                     {error, {invalid_transaction, 0, bad_nonce}})).

an_unrecognised_finalize_error_is_invalid_test() ->
    ?assertEqual({<<"INVALID">>, some_other_failure},
                 eth_engine:status_for_finalize({error, some_other_failure})).

%% ===========================================================================
%% forkchoiceUpdated: not "VALID" about an unvalidated head
%% ===========================================================================

%% VALID in this method means the named payload passed payload validation. No
%% payload validation runs in this node, so the head cannot be VALID however
%% confident the client is. SYNCING is the specification's status for a payload
%% that cannot be validated because the requisite data is missing.
forkchoice_naming_an_unvalidated_head_is_syncing_test() ->
    with_engine(fun() ->
        ?assertEqual(<<"SYNCING">>, eth_engine:forkchoice_updated(forkchoice(head()))),
        ?assertEqual(<<"SYNCING">>,
                     eth_engine:forkchoice_updated(forkchoice(head(), payload_id())))
    end).

%% There is one case with nothing to judge: no head claimed and no payload to
%% build on.
forkchoice_claiming_nothing_is_valid_test() ->
    with_engine(fun() ->
        ?assertEqual(<<"VALID">>, eth_engine:forkchoice_updated(forkchoice(undefined))),
        %% The specification allows an all-zero hash as the "not claimed"
        %% marker, so it must not be read as a head the node has a record of.
        ?assertEqual(<<"VALID">>, eth_engine:forkchoice_updated(forkchoice(<<0:256>>)))
    end).

forkchoice_with_an_inconsistent_state_is_rejected_test() ->
    with_engine(fun() ->
        %% An empty map is a state with nothing claimed, not a malformed one.
        ?assertEqual(<<"VALID">>, eth_engine:forkchoice_updated(#{})),
        ?assertEqual({error, invalid_forkchoice_state},
                     eth_engine:forkchoice_updated(not_a_map)),
        %% A head that cannot be 32 bytes of DATA names no block.
        ?assertEqual({error, invalid_forkchoice_state},
                     eth_engine:forkchoice_updated(
                       #{<<"headBlockHash">> => <<"0xabcd">>})),
        ?assertEqual({error, invalid_forkchoice_state},
                     eth_engine:forkchoice_updated(#{<<"headBlockHash">> => 7})),
        %% The all-zero hash is the specification's "not claimed" marker and is
        %% the one malformed-looking value that is accepted.
        ?assertEqual(<<"VALID">>,
                     eth_engine:forkchoice_updated(
                       #{<<"headBlockHash">> => hex(<<0:256>>)}))
    end).

%% The engine used to hand its new state to a `save_state' handler that returned
%% the *old* state, so the head, the safe block and the finalized checkpoint the
%% client declared went nowhere -- and the call still answered VALID. The status
%% fix alone would have hidden that: a node that cannot validate has no business
%% keeping a head, but if it does keep one it must keep the client's.
forkchoice_records_the_clients_head_test() ->
    with_engine(fun() ->
        Head = head(),
        ?assertEqual(undefined, recorded_head()),
        ?assertEqual(<<"SYNCING">>, eth_engine:forkchoice_updated(forkchoice(Head))),
        ?assertEqual(Head, recorded_head())
    end).

forkchoice_keeps_the_head_across_calls_test() ->
    with_engine(fun() ->
        Head = head(),
        ?assertEqual(<<"SYNCING">>, eth_engine:forkchoice_updated(forkchoice(Head))),
        ?assertEqual(<<"VALID">>, eth_engine:forkchoice_updated(forkchoice(undefined))),
        ?assertEqual(Head, recorded_head())
    end).

%% ===========================================================================
%% getPayload: no payload this node never built
%% ===========================================================================

%% This used to take no argument and return the last payload the client had
%% itself submitted to newPayload -- not a block this node built, and not
%% necessarily a block this node believes is valid. A consensus client that
%% broadcast that would be relaying a block the execution layer never produced.
get_payload_refuses_a_payload_id_this_node_never_issued_test() ->
    with_engine(fun() ->
        ?assertEqual({error, unknown_payload}, eth_engine:get_payload(<<0:64>>)),
        ?assertEqual({error, unknown_payload}, eth_engine:get_payload(payload_id()))
    end).

get_payload_requires_an_eight_byte_id_test() ->
    with_engine(fun() ->
        ?assertEqual({error, invalid_params}, eth_engine:get_payload(<<1, 2, 3>>)),
        ?assertEqual({error, invalid_params}, eth_engine:get_payload(hex(<<9, 9>>)))
    end).

%% ===========================================================================
%% exchangeTransitionConfiguration: the configuration, not a status
%% ===========================================================================

%% The specification's result here is a TransitionConfigurationV1 object. This
%% returned a bare VALID, so the one method whose entire purpose is to hand the
%% consensus client these values handed it nothing.
exchange_transition_configuration_returns_the_configuration_test() ->
    with_engine(fun() ->
        {ok, Cfg} = eth_engine:exchange_transition_config(#{
            <<"terminalTotalDifficulty">> => <<"0xc70d815d562d3cfa955">>,
            <<"terminalBlockHash">> => hex(<<16#de, 0:248>>),
            <<"terminalBlockNumber">> => <<"0x77359400">>
        }),
        ?assertEqual(triton_td(), maps:get(terminal_total_difficulty, Cfg)),
        ?assertEqual(<<16#de, 0:248>>, maps:get(terminal_block_hash, Cfg)),
        ?assertEqual(16#77359400, maps:get(terminal_block_number, Cfg))
    end).

%% A QUANTITY is hex, and this was decoded with binary_to_integer/1 -- base 10 --
%% so every real total difficulty raised badarg and the catch turned it into
%% SECURITY_ERROR. No network with a non-trivial terminal total difficulty could
%% exchange its configuration at all.
exchange_transition_configuration_decodes_hex_quantities_test() ->
    with_engine(fun() ->
        {ok, Cfg} = eth_engine:exchange_transition_config(
            #{<<"terminalTotalDifficulty">> => <<"0xff">>}),
        ?assertEqual(255, maps:get(terminal_total_difficulty, Cfg)),
        %% A bare integer is accepted too, so a same-VM caller is not forced to
        %% render a quantity as JSON.
        {ok, Cfg2} = eth_engine:exchange_transition_config(
            #{<<"terminalTotalDifficulty">> => 16}),
        ?assertEqual(16, maps:get(terminal_total_difficulty, Cfg2))
    end).

%% The specification: in the absence of a TERMINAL_TOTAL_DIFFICULTY value both
%% layers must use 2^256-2^10, so a client and a node that have not decided can
%% still compare equal. This was 2^256-1, 1023 higher than the specification
%% says; see eth_engine for the clause and what a wrong value here costs.
exchange_transition_configuration_reports_the_absent_total_difficulty_test() ->
    with_engine(fun() ->
        {ok, Cfg} = eth_engine:exchange_transition_config(
            #{<<"terminalBlockHash">> => hex(<<0:2048>>)}),
        ?assertEqual(?NO_TTD, maps:get(terminal_total_difficulty, Cfg)),
        %% An all-zero terminal block hash is the "not decided" marker, not a
        %% block hash, so it is reported as absent.
        ?assertEqual(undefined, maps:get(terminal_block_hash, Cfg))
    end).

%% A test that asserts against the source's own expression cannot catch the
%% source being wrong, so this one pins the decimal string from the
%% specification's text and separately checks the arithmetic. Both have to hold
%% for the node to report the specified sentinel:
%%
%%   115792089237316195423570985008687907853269984665640564039457584007913129638912
%%   = 2^256 - 2^10
%%
%% The first is what the consensus client compares; the second is why. Note this
%% is *not* 2^256-1, which is the value the code used to report.
exchange_transition_configuration_pins_the_undecided_ttd_sentinel_test() ->
    with_engine(fun() ->
        Spec = "115792089237316195423570985008687907853269984665640564039457584007913129638912",
        {ok, Cfg} = eth_engine:exchange_transition_config(
            #{<<"terminalBlockHash">> => hex(<<0:2048>>)}),
        TD = maps:get(terminal_total_difficulty, Cfg),
        ?assertEqual(list_to_integer(Spec), TD),
        ?assertEqual(1 bsl 256 - 1024, TD),
        %% And it is the encoding the wire carries, not just the decoded value.
        %% Lowercase, which is what eth_hex:encode_int/1 emits; binary:encode_hex
        %% emits uppercase, so the expected side is lowercased rather than
        %% trusting the two to agree.
        ?assertEqual(<<"0x",
                       (string:lowercase(
                          binary:encode_hex(<<TD:256>>)))/binary>>,
                     eth_hex:encode_int(TD))
    end).

%% The configuration map used to be built from the *previous* state's values, so
%% what the node recorded was one exchange out of date -- and the specification
%% has the client receive these values back, so the staleness was visible from
%% outside.
exchange_transition_configuration_returns_the_value_it_was_given_test() ->
    with_engine(fun() ->
        {ok, _} = eth_engine:exchange_transition_config(
            #{<<"terminalTotalDifficulty">> => <<"0x1">>}),
        {ok, Cfg} = eth_engine:exchange_transition_config(
            #{<<"terminalTotalDifficulty">> => <<"0x2">>}),
        ?assertEqual(2, maps:get(terminal_total_difficulty, Cfg))
    end).

%% ===========================================================================
%% Supervision
%% ===========================================================================
%%
%% `eth_engine' was listed in etherlang.app.src's `registered' list, which
%% asserts a process is running, and was not a child of the supervisor, so nothing
%% started it. eth_rpc_server mounts the /engine listener regardless, and every
%% method in a real node answered from a gen_server that did not exist. The
%% {registered, [...]} list is a claim, not a check: a module named there that no
%% supervisor starts looks identical to one that is running.

the_engine_is_a_supervised_child_test() ->
    Ids = with_data_dir(fun(Dir) ->
        ok = filelib:ensure_dir(filename:join(Dir, "x")),
        {ok, {_Flags, Children}} = etherlang_sup:init([]),
        [maps:get(id, C) || C <- Children, is_map(C)]
    end),
    ?assert(lists:member(eth_engine, Ids)),
    ?assert(lists:member(eth_rpc_server, Ids)).

%% The secret must exist before the port that authenticates against it is
%% listening, so the engine starts first.
the_engine_starts_before_the_listener_test() ->
    Ids = with_data_dir(fun(_Dir) ->
        {ok, {_Flags, Children}} = etherlang_sup:init([]),
        [maps:get(id, C) || C <- Children, is_map(C)]
    end),
    EngineAt = index_of(eth_engine, Ids),
    RpcAt = index_of(eth_rpc_server, Ids),
    ?assert(EngineAt =/= undefined),
    ?assert(RpcAt =/= undefined),
    ?assert(EngineAt < RpcAt).

index_of(Id, Ids) -> index_of(Id, Ids, 1).
index_of(_Id, [], _N) -> undefined;
index_of(Id, [Id | _Rest], N) -> N;
index_of(Id, [_Other | Rest], N) -> index_of(Id, Rest, N + 1).

%% etherlang_sup:init/1 reads the data directory from the environment, and
%% eth_nodekey writes into it, so point DATA_DIR at a temporary directory for the
%% duration and put the old value back.
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
%% The HTTP surface
%% ===========================================================================
%%
%% Two of the four handlers matched the *string* "VALID" against return values
%% that are binaries, and to a shape ("INVALID", Reason) the module never
%% produced, so forkchoiceUpdated and exchangeTransitionConfiguration matched none
%% of their clauses and raised a case_clause. The two that did match returned
%% shapes the specification does not define: newPayload included a payloadId the
%% specification does not put in that response, and all four returned a bare
%% status string where the specification has an object. Nothing exercised them.

new_payload_over_http_answers_a_payload_status_test() ->
    with_http(fun(Port) ->
        {ok, #{<<"result">> := Result}, _} = call(Port, <<"engine_newPayloadV1">>,
                                              [payload()]),
        ?assertEqual(<<"SYNCING">>, maps:get(<<"status">>, Result)),
        ?assertEqual(null, maps:get(<<"latestValidHash">>, Result)),
        ?assertEqual(null, maps:get(<<"validationError">>, Result)),
        %% The specification puts no payloadId in this response.
        ?assertNot(maps:is_key(<<"payloadId">>, Result))
    end).

new_payload_over_http_reports_an_invalid_payload_with_a_reason_test() ->
    with_http(fun(Port) ->
        {ok, #{<<"result">> := Result}, _} = call(Port, <<"engine_newPayloadV1">>,
                                              [#{<<"blockNumber">> => <<"0x1">>}]),
        ?assertEqual(<<"INVALID">>, maps:get(<<"status">>, Result)),
        ?assert(maps:get(<<"validationError">>, Result) =/= null)
    end).

forkchoice_over_http_answers_a_payload_status_and_payload_id_test() ->
    with_http(fun(Port) ->
        {ok, #{<<"result">> := Result}, _} = call(Port, <<"engine_forkchoiceUpdatedV1">>,
                                              forkchoice_payload(head())),
        ?assertEqual(<<"SYNCING">>,
                     maps:get(<<"status">>, maps:get(<<"payloadStatus">>, Result))),
        ?assertEqual(null, maps:get(<<"payloadId">>, Result))
    end).

forkchoice_over_http_rejects_a_malformed_forkchoice_test() ->
    with_http(fun(Port) ->
        %% -38002 is the specification's code for a forkchoiceState that is
        %% invalid or inconsistent. A head that is not 32 bytes of DATA names no
        %% block, so the state is inconsistent.
        {ok, #{<<"error">> := #{<<"code">> := Code}}, _} =
            call(Port, <<"engine_forkchoiceUpdatedV1">>,
                 [#{<<"headBlockHash">> => <<"0xabcd">>}, null]),
        ?assertEqual(-38002, Code),

        %% A param that is not an object at all is a malformed request rather
        %% than an invalid forkchoice state.
        {ok, #{<<"error">> := #{<<"code">> := ParamCode}}, _} =
            call(Port, <<"engine_forkchoiceUpdatedV1">>, [<<"nope">>, null]),
        ?assertEqual(-32602, ParamCode)
    end).

exchange_config_over_http_returns_the_configuration_object_test() ->
    with_http(fun(Port) ->
        {ok, #{<<"result">> := Result}, _} =
            call(Port, <<"engine_exchangeTransitionConfigurationV1">>,
                 [#{<<"terminalTotalDifficulty">> => <<"0xc70d815d562d3cfa955">>,
                    <<"terminalBlockHash">> => hex(<<16#de, 0:248>>),
                    <<"terminalBlockNumber">> => <<"0x77359400">>}]),
        ?assertEqual(<<"0xc70d815d562d3cfa955">>,
                     maps:get(<<"terminalTotalDifficulty">>, Result)),
        ?assertEqual(hex(<<16#de, 0:248>>),
                     maps:get(<<"terminalBlockHash">>, Result)),
        ?assertEqual(<<"0x77359400">>,
                     maps:get(<<"terminalBlockNumber">>, Result))
    end).

%% The specification requires a hex total difficulty to come back as a QUANTITY:
%% minimal, lowercase, no leading zeros.
exchange_config_over_http_encodes_quantities_minimally_test() ->
    with_http(fun(Port) ->
        {ok, #{<<"result">> := Result}, _} =
            call(Port, <<"engine_exchangeTransitionConfigurationV1">>,
                 [#{<<"terminalTotalDifficulty">> => <<"0x00ff">>}]),
        ?assertEqual(<<"0xff">>, maps:get(<<"terminalTotalDifficulty">>, Result))
    end).

get_payload_over_http_reports_an_unknown_payload_test() ->
    with_http(fun(Port) ->
        {ok, #{<<"error">> := #{<<"code">> := Code, <<"message">> := Msg}}, _} =
            call(Port, <<"engine_getPayloadV1">>, [payload_id()]),
        ?assertEqual(-38001, Code),
        ?assert(is_binary(Msg))
    end).

get_payload_over_http_requires_the_payload_id_parameter_test() ->
    with_http(fun(Port) ->
        {ok, #{<<"error">> := #{<<"code">> := Code}}, _} =
            call(Port, <<"engine_getPayloadV1">>, []),
        ?assertEqual(-32602, Code)
    end).

%% ===========================================================================
%% Authentication
%% ===========================================================================

%% The authentication document says the engine port must be authenticated, and
%% this node did not authenticate it at all: the handler read no secret and
%% verified no token, while its own comment and TASKS.md both said otherwise.
authenticated_engine_accepts_a_signed_token_test() ->
    with_http(fun(Port) ->
        {ok, #{<<"result">> := Result}, _} = call(Port, <<"engine_newPayloadV1">>,
                                              [payload()]),
        ?assertEqual(<<"SYNCING">>, maps:get(<<"status">>, Result))
    end).

unauthenticated_engine_request_is_refused_test() ->
    with_http(fun(Port) ->
        {ok, #{<<"error">> := #{<<"code">> := Code}}, _} =
            call(Port, <<"engine_newPayloadV1">>, [payload()], no_auth),
        ?assertEqual(401, Code)
    end).

a_token_signed_with_another_key_is_refused_test() ->
    with_http(fun(Port) ->
        {ok, #{<<"error">> := #{<<"code">> := Code}}, _} =
            call(Port, <<"engine_newPayloadV1">>, [payload()],
                 {bearer, eth_jwt:sign(claims(), <<0:256>>)}),
        ?assertEqual(401, Code)
    end).

%% The specification requires `alg: none' to be rejected. An unsecured token is
%% the attack the scheme exists to stop, so it must not be accepted even when it
%% carries a correct iat.
an_unsigned_token_is_refused_test() ->
    with_http(fun(Port) ->
        Header = eth_jwt:b64url_encode(thoas:encode(#{<<"alg">> => <<"none">>,
                                                 <<"typ">> => <<"JWT">>})),
        B64Payload = eth_jwt:b64url_encode(thoas:encode(claims())),
        {ok, #{<<"error">> := #{<<"code">> := Code}}, _} =
            call(Port, <<"engine_newPayloadV1">>, [payload()],
                 {bearer, <<Header/binary, $., B64Payload/binary, $., "">>}),
        ?assertEqual(401, Code)
    end).

%% A stale iat is a replay, which the document lists as out of scope for the
%% scheme to prevent -- but it asks implementations to bound the window anyway.
an_expired_token_is_refused_test() ->
    with_http(fun(Port) ->
        Stale = claims(#{<<"iat">> => os:system_time(second) - 3600}),
        {ok, #{<<"error">> := #{<<"code">> := Code}}, _} =
            call(Port, <<"engine_newPayloadV1">>, [payload()],
                 {bearer, eth_jwt:sign(Stale, test_secret())}),
        ?assertEqual(401, Code)
    end).

a_token_within_the_window_is_accepted_test() ->
    with_http(fun(Port) ->
        Fresh = claims(#{<<"iat">> => os:system_time(second) - 30}),
        {ok, #{<<"result">> := Result}, _} =
            call(Port, <<"engine_newPayloadV1">>, [payload()],
                 {bearer, eth_jwt:sign(Fresh, test_secret())}),
        ?assertEqual(<<"SYNCING">>, maps:get(<<"status">>, Result))
    end).

%% Without a secret the node cannot authenticate anything, so the port must not
%% be served. Falling through to an open port is the failure this scheme exists
%% to prevent, and it is what a `jwt_secret = <<>>' default meant.
an_engine_without_a_secret_does_not_serve_the_port_test() ->
    with_http_no_secret(fun(Port) ->
        {ok, #{<<"error">> := #{<<"code">> := Code}}, _} =
            call(Port, <<"engine_newPayloadV1">>, [payload()], no_auth),
        ?assertEqual(503, Code)
    end).

%% A secret on disk is reused, not replaced: regenerating would silently
%% invalidate every consensus client already provisioned with the old key.
a_secret_is_generated_once_and_reused_test() ->
    Dir = eth_test_util:tmp_dir(),
    {ok, First} = eth_jwt:load_or_create_secret(Dir),
    ?assertEqual(32, byte_size(First)),
    {ok, Second} = eth_jwt:load_or_create_secret(Dir),
    ?assertEqual(First, Second),
    ?assertEqual(32, byte_size(First)),
    {ok, Stored} = file:read_file(filename:join(Dir, "jwt.hex")),
    ?assertEqual(binary:encode_hex(First), string:trim(Stored)).

a_corrupt_secret_file_is_an_error_test() ->
    Dir = eth_test_util:tmp_dir(),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    ok = file:write_file(filename:join(Dir, "jwt.hex"), <<"not hex at all">>),
    ?assertMatch({error, {secret_not_hex, _}}, eth_jwt:load_or_create_secret(Dir)),
    ok = file:write_file(filename:join(Dir, "jwt.hex"), <<"aabb">>),
    ?assertMatch({error, {secret_wrong_length, _, 2}},
                 eth_jwt:load_or_create_secret(Dir)).

%% base64url is the URL-safe alphabet with no padding, which `base64/1' is not.
%% Getting it wrong breaks every token, and does so silently, because a base64
%% decoder that accepts the wrong alphabet still decodes *something*.
base64url_round_trips_test() ->
    Samples = [<<>>, <<0>>, <<1, 2, 3>>, <<16#fb, 16#ff, 16#be>>, <<0:256>>],
    lists:foreach(
      fun(Bin) ->
          Encoded = eth_jwt:b64url_encode(Bin),
          %% No padding, and none of the standard alphabet's two specials.
          %% binary:match/2 answers {0,0} on an empty subject, so the empty
          %% sample is checked for the round trip only.
          case Encoded of
              <<>> -> ok;
              _ -> ?assertEqual(nomatch,
                                binary:match(Encoded, [<<"=">>, <<"+">>, <<"/">>]))
          end,
          {ok, Back} = eth_jwt:b64url_decode(Encoded),
          ?assertEqual(Bin, Back)
      end, Samples).

base64url_decodes_the_url_safe_alphabet_test() ->
    %% 0xfbffbe encodes to "+/++=" in the standard alphabet, "-_--" url-safe.
    {ok, Bin} = eth_jwt:b64url_decode(<<"-_--">>),
    ?assertEqual(<<16#fb, 16#ff, 16#be>>, Bin),
    ?assertEqual({error, not_base64url}, eth_jwt:b64url_decode(<<"!!!!">>)).

%% ===========================================================================
%% Versioned methods: the structure and fork gates
%% ===========================================================================
%%
%% These are the checks that decide whether a payload is *processed* at all, and
%% they were absent: the node implemented only V1, so every call a post-Merge
%% consensus client makes was answered -32601. The rules below are transcribed from
%% execution-apis src/engine/{paris,shanghai,cancun}.md, and each test names the
%% clause it comes from, because the differences between versions are the whole
%% content of these functions and a test that did not distinguish them would pass
%% against an implementation that ignored the version entirely.

%% V1 has no parameter gate. paris.md's engine_newPayloadV1 lists six
%% specification items and none is a structure check, and the string -32602 does
%% not occur in paris.md at all -- the clause arrives with V2 and V3. So a payload
%% carrying Cancun fields is admitted by newPayloadV1, and a test that "fixed"
%% this by tightening V1 would be encoding a rule the specification does not state.
v1_admits_a_payload_with_later_fork_fields_test() ->
    Cancun = payload(),
    ?assert(maps:is_key(<<"blobGasUsed">>, Cancun)),
    ?assertEqual(ok, eth_engine:payload_admission(Cancun, 1)).

%% shanghai.md, engine_newPayloadV2: "ExecutionPayloadV1 MUST be used if the
%% `timestamp' value is lower than the Shanghai timestamp, ExecutionPayloadV2 MUST
%% be used if the `timestamp' value is greater or equal to the Shanghai
%% timestamp, Client software MUST return -32602: Invalid params error if the
%% wrong version of the structure is used in the method call."
%%
%% So the structure V2 demands is a function of the timestamp, in both directions.
v2_structure_follows_the_timestamp_test() ->
    Pre = v1_payload(shanghai_at(sepolia) - 1),
    Post = v2_payload(shanghai_at(sepolia)),
    ?assertEqual(paris, eth_engine:structure_for_version(2, shanghai_at(sepolia) - 1)),
    ?assertEqual(shanghai, eth_engine:structure_for_version(2, shanghai_at(sepolia))),
    %% Below Shanghai, V2 wants the V1 structure, so a payload carrying
    %% `withdrawals' is the wrong version of the structure.
    ?assertMatch({error, -32602, _},
                 eth_engine:payload_admission(Pre#{<<"withdrawals">> => []}, 2)),
    %% And a V2 payload at a pre-Shanghai timestamp is the same failure.
    ?assertMatch({error, -32602, _},
                 eth_engine:payload_admission(v2_payload(shanghai_at(sepolia) - 1), 2)),
    %% At or after Shanghai it wants the V2 structure, so a payload without
    %% `withdrawals' is the wrong version.
    ?assertMatch({error, -32602, _},
                 eth_engine:payload_admission(maps:remove(<<"withdrawals">>, Post), 2)),
    ?assertEqual(ok, eth_engine:payload_admission(Pre, 2)),
    ?assertEqual(ok, eth_engine:payload_admission(Post, 2)).

%% "strictly matches the expected one" (cancun.md item 1) taken literally: the
%% appended keys must *equal* the required set, not merely contain it. ExecutionPayloadV3
%% is a superset of V2, so a presence-only check would admit a Prague payload on a
%% V2 method -- a node that cannot execute Prague rules agreeing to process one.
v2_refuses_a_superset_structure_test() ->
    Prague = (v2_payload(far_future()))#{<<"blobGasUsed">> => <<"0x0">>,
                                        <<"excessBlobGas">> => <<"0x0">>},
    ?assert(maps:is_key(<<"blobGasUsed">>, Prague)),
    ?assertMatch({error, -32602, _}, eth_engine:payload_admission(Prague, 2)).

%% cancun.md, engine_newPayloadV3: V3 is Cancun, so it demands all three appended
%% keys and refuses the payload if any is missing.
v3_requires_every_appended_key_test() ->
    P = payload(),
    [?assert(maps:is_key(Key, P))
     || Key <- [<<"withdrawals">>, <<"blobGasUsed">>, <<"excessBlobGas">>]],
    ?assertEqual(ok, eth_engine:payload_admission(P, 3)),
    [?assertMatch({error, -32602, _},
                  eth_engine:payload_admission(maps:remove(Key, P), 3))
     || Key <- [<<"withdrawals">>, <<"blobGasUsed">>, <<"excessBlobGas">>]].

%% cancun.md item 1: "Any field having `null' value MUST be considered as not
%% provided." A payload that carries a key set to null is therefore short a field,
%% and a decoder that read null as a value would admit it.
null_counts_as_not_provided_test() ->
    P = payload(),
    ?assertMatch({error, -32602, _},
                 eth_engine:payload_admission(P#{<<"blobGasUsed">> => null}, 3)),
    ?assertMatch({error, -32602, _},
                 eth_engine:payload_admission(P#{<<"excessBlobGas">> => undefined}, 3)).

%% cancun.md item 2 for all three V3 entry points: "MUST return -38005: Unsupported
%% fork error if the `timestamp' of the payload does not fall within the time frame
%% of the Cancun fork." The frame is half open, [cancun, prague), so a payload on
%% the Prague activation instant is out of it.
v3_rejects_timestamps_outside_the_cancun_frame_test() ->
    Cancun = cancun_at(sepolia),
    Prague = after_cancun_at(sepolia),
    P0 = payload(),
    At = fun(T) -> P0#{<<"timestamp">> => hexq(T)} end,
    ?assertEqual({error, -38005, <<"unsupported fork">>},
                 eth_engine:payload_admission(At(Cancun - 1), 3)),
    ?assertEqual(ok, eth_engine:payload_admission(At(Cancun), 3)),
    ?assertEqual(ok, eth_engine:payload_admission(At(Prague - 1), 3)),
    ?assertEqual({error, -38005, <<"unsupported fork">>},
                 eth_engine:payload_admission(At(Prague), 3)),
    ?assertEqual({error, -38005, <<"unsupported fork">>},
                 eth_engine:payload_admission(At(Cancun - 1), 3)),
    ?assertEqual({error, -38005, <<"unsupported fork">>},
                 eth_engine:payload_admission(At(Prague + 1000), 3)).

%% The fork frame is read from the *network's* schedule, so the same payload
%% timestamp is in frame on one network and not on another. If the gate ignored the
%% network it would be checking a constant, and a node configured for the wrong
%% chain would admit payloads it cannot execute.
v3_frame_is_per_network_test() ->
    SepCancun = cancun_at(sepolia),
    MainCancun = cancun_at(mainnet),
    P = payload(),
    At = fun(T) -> P#{<<"timestamp">> => hexq(T)} end,
    with_network("sepolia",
                 fun() ->
                     ?assertEqual(ok, eth_engine:payload_admission(At(SepCancun), 3))
                 end),
    with_network("mainnet",
                 fun() ->
                     %% Same timestamp, and mainnet's Cancun had not started yet.
                     ?assertEqual({error, -38005, <<"unsupported fork">>},
                                  eth_engine:payload_admission(At(SepCancun), 3)),
                     ?assertEqual(ok,
                                  eth_engine:payload_admission(At(MainCancun), 3))
                 end).

%% Only V3 carries the -38005 clause. paris.md has no versioned-fork rule and
%% shanghai.md puts no upper bound on V2, so a post-Cancun timestamp on V2 is
%% admitted -- imposing the Cancun window there would refuse payloads the
%% specification says to accept.
only_v3_has_the_fork_frame_test() ->
    %% A V2-structure payload, so the only thing under test is the timestamp.
    P = v2_payload(shanghai_at(sepolia)),
    Far = v2_payload(far_future()),
    ?assertEqual(ok, eth_engine:payload_admission(P, 1)),
    ?assertEqual(ok, eth_engine:payload_admission(Far, 2)),
    %% A Cancun-structure payload at a post-Cancun timestamp is the -38005 case.
    ?assertEqual({error, -38005, <<"unsupported fork">>},
                 eth_engine:payload_admission(
                   (payload())#{<<"timestamp">> => hexq(far_future())}, 3)),
    %% The structure check comes first, so a V2-structure payload on V3 is refused
    %% for its keys before its frame is considered -- the order the specification
    %% lists them in, and the order that decides which code a client reads.
    %% A plain match, not ?assertMatch: the assertion macro matches inside a
    %% match spec, so a variable written in its pattern is not bound outside.
    {error, -32602, Message} = eth_engine:payload_admission(Far, 3),
    %% The message has to name the keys that are missing -- that is what tells a
    %% client what to send instead -- and it has to name the ones this payload
    %% actually lacks, which is not the same as naming all three.
    [?assert(binary:match(Message, Key) =/= nomatch)
     || Key <- [<<"blobGasUsed">>, <<"excessBlobGas">>]].

%% An unreadable timestamp is a shape failure, not a fork failure: "does not fall
%% within the time frame" cannot be evaluated, and V2's structure choice depends on
%% the timestamp, so a default of 0 would silently pick the wrong structure.
an_unreadable_timestamp_is_invalid_params_not_unsupported_fork_test() ->
    P = payload(),
    ?assertEqual({error, -32602, <<"invalid params">>},
                 eth_engine:payload_admission(maps:remove(<<"timestamp">>, P), 3)),
    ?assertEqual({error, -32602, <<"invalid params">>},
                 eth_engine:payload_admission(P#{<<"timestamp">> => <<"not hex">>}, 3)),
    ?assertEqual({error, -32602, <<"invalid params">>},
                 eth_engine:payload_admission(P#{<<"timestamp">> => null}, 3)),
    ?assertEqual({error, -32602, <<"invalid params">>},
                 eth_engine:payload_admission(P#{<<"timestamp">> => <<"-1">>}, 3)).

%% A payload that is not an object cannot match any structure.
a_payload_that_is_not_an_object_is_invalid_params_test() ->
    [?assertEqual({error, -32602, <<"invalid params">>},
                  eth_engine:payload_admission(Bad, V))
     || Bad <- [not_a_map, <<"a string">>, 42, [1, 2, 3]], V <- [2, 3]].

%% ===========================================================================
%% payloadAttributes admission
%% ===========================================================================

%% cancun.md, engine_forkchoiceUpdatedV3 item 2, which extends point (8) of the V1
%% specification. PayloadAttributesV3 is V2 plus parentBeaconBlockRoot, so V3
%% demands all three appended keys and -38003 -- not -32602 -- on a mismatch: the
%% attributes are a second parameter, and -38003 is the code the specification
%% names for them.
attributes_v3_requires_both_appended_keys_test() ->
    A = attributes(cancun),
    ?assertEqual(ok, eth_engine:attributes_admission(A, 3)),
    ?assertMatch({error, -38003, _},
                 eth_engine:attributes_admission(maps:remove(<<"withdrawals">>, A), 3)),
    ?assertMatch({error, -38003, _},
                 eth_engine:attributes_admission(maps:remove(<<"parentBeaconBlockRoot">>,
                                                            A), 3)),
    %% V2 demands withdrawals and must refuse parentBeaconBlockRoot, or a V2 build
    %% would be started with a beacon root the method does not define.
    A2 = attributes(shanghai),
    ?assertEqual(ok, eth_engine:attributes_admission(A2, 2)),
    ?assertMatch({error, -38003, _},
                 eth_engine:attributes_admission(A, 2)).

%% cancun.md item 2.2: the *attributes'* timestamp is the one that must be in
%% frame, because it is the timestamp the new block would carry. A head timestamp
%% is not what is being checked, and using the wrong one would build for the fork
%% the head is in rather than the fork being built.
attributes_timestamp_is_the_one_checked_against_the_frame_test() ->
    Cancun = cancun_at(sepolia),
    Prague = after_cancun_at(sepolia),
    A = attributes(cancun),
    At = fun(T) -> A#{<<"timestamp">> => hexq(T)} end,
    ?assertEqual(ok, eth_engine:attributes_admission(At(Cancun), 3)),
    ?assertEqual({error, -38005, <<"unsupported fork">>},
                 eth_engine:attributes_admission(At(Prague), 3)),
    ?assertEqual({error, -38005, <<"unsupported fork">>},
                 eth_engine:attributes_admission(At(Cancun - 1), 3)).

%% `payloadAttributes' is `Object|null', so null is the normal case for a
%% forkchoice update that starts no build. It must not be an error, on any
%% version, or a CL that only wants to move the head could never call the method.
null_attributes_are_accepted_on_every_version_test() ->
    [?assertEqual(ok, eth_engine:attributes_admission(null, V)) || V <- [1, 2, 3]],
    [?assertEqual(ok, eth_engine:attributes_admission(undefined, V)) || V <- [1, 2, 3]].

%% Attributes that are not an object cannot match any structure, and the code is
%% -38003 because the specification names it for payloadAttributes specifically.
malformed_attributes_are_38003_test() ->
    [?assertEqual({error, -38003, <<"invalid payload attributes">>},
                  eth_engine:attributes_admission(Bad, 3))
     || Bad <- [<<"a string">>, 42, [1, 2, 3]]].

%% ===========================================================================
%% INVALID_BLOCK_HASH is supplanted from V2
%% ===========================================================================

%% shanghai.md, engine_newPayloadV2, Response: "values of the `status' field are
%% restricted in the following way: INVALID_BLOCK_HASH status value is supplanted
%% by INVALID." V1 keeps it; V2 and V3 must not emit it, because a client reading
%% INVALID_BLOCK_HASH on a V2 method is reading a value the specification withdrew
%% from that method -- and it is the value that distinguishes a corrupt payload
%% from a valid block the node chose to reject.
invalid_block_hash_is_supplanted_from_v2_test() ->
    S = fun eth_engine:status_for_version/2,
    ?assertEqual(<<"INVALID_BLOCK_HASH">>, S(<<"INVALID_BLOCK_HASH">>, 1)),
    [?assertEqual(<<"INVALID">>, S(<<"INVALID_BLOCK_HASH">>, V)) || V <- [2, 3]],
    %% Every other status is unchanged by the version.
    [?assertEqual(St, S(St, V))
     || St <- [<<"VALID">>, <<"INVALID">>, <<"SYNCING">>, <<"ACCEPTED">>],
        V <- [1, 2, 3]].

%% ===========================================================================
%% Blob versioned hashes (newPayloadV3 item 3)
%% ===========================================================================

%% "If the payload has no blob transactions the expected array MUST be []." So an
%% empty expected array against a payload with no blob transactions is the passing
%% case, and any hash at all is a mismatch.
blob_hashes_of_a_payload_with_no_blob_transactions_test() ->
    P = payload(),
    ?assertEqual(ok, eth_engine:blob_hashes_admission(
                       P#{<<"transactions">> => []}, [])),
    %% Either form of DATA: the 0x-hex the wire carries, or the 32 raw bytes an
    %% in-process caller holds. eth_block:payload_data/2 accepts both.
    %% The reported tuple is {invalid, Expected, Actual}, in that order.
    ?assertMatch({invalid, [_], []},
                 eth_engine:blob_hashes_admission(
                   P#{<<"transactions">> => []}, [versioned_hash(1)])),
    ?assertMatch({invalid, [_], []},
                 eth_engine:blob_hashes_admission(
                   P#{<<"transactions">> => []}, [hex(versioned_hash(1))])).

%% A mismatch is INVALID and is reported as INVALID. It is a *status* and not an
%% error code, unlike the structure and fork gates above: the payload is well
%% formed and aimed at the right fork, and it is the contents that are wrong.
blob_hashes_that_disagree_are_a_mismatch_test() ->
    P = payload(),
    Empty = P#{<<"transactions">> => []},
    ?assertMatch({invalid, [_], []},
                 eth_engine:blob_hashes_admission(Empty, [versioned_hash(7)])).

%% The actual array is the concatenation, in order of inclusion, of each blob
%% transaction's own hashes. This is checked against a real transaction encoded by
%% this repo's codec, so it pins the ordering and the normalisation rather than a
%% hand-written list -- a hand-written list would agree with the implementation by
%% construction.
blob_hashes_concatenate_in_order_of_inclusion_test() ->
    Txs = [blob_tx(#{1 => versioned_hash(11), 2 => versioned_hash(12)}),
           blob_tx(#{1 => versioned_hash(21)})],
    P = payload_with_transactions(Txs),
    [A, B] = Txs,
    %% eth_block:hex_data/1, not eth_hex:decode/1: the latter returns an integer,
    %% and from_rlp/1 on an integer is a function_clause. The same mistake the
    %% production code made twice.
    %% Uppercase: a lowercase-initial name in call position is parsed as a
    %% *function* call, not a call of the fun variable bound above it.
    HashesOf = fun(Wire) ->
        {ok, Bytes} = eth_block:hex_data(Wire),
        {ok, Tx} = eth_tx:from_rlp(Bytes),
        eth_tx:blob_versioned_hashes(Tx)
    end,
    Expected = HashesOf(A) ++ HashesOf(B),
    ?assertEqual(3, length(Expected)),
    ?assertEqual(ok, eth_engine:blob_hashes_admission(P, Expected)),
    %% The same set in the wrong order is a mismatch, which is what "respecting the
    %% order of inclusion" is for.
    ?assertMatch({invalid, _, _},
                 eth_engine:blob_hashes_admission(P, lists:reverse(Expected))).

%% "This validation MUST be instantly run in all cases even during active sync
%% process" -- so it must not be reachable only from the path that executes. An
%% actual array this node cannot compute is `unchecked', and in particular is NOT
%% treated as `[]': "the payload has no blob transactions" and "this node could not
%% read the transactions" are different claims, and conflating them would report
%% INVALID against a payload whose blobs are fine.
blob_hashes_that_cannot_be_computed_are_unchecked_not_invalid_test() ->
    P = payload_with_transactions([<<"0xdeadbeef">>]),
    %% The invariant is that it is `unchecked' and *not* a mismatch: an
    %% undeterminable actual array must never be reported as a disagreement,
    %% because a client cannot act on "this node could not read it".
    ?assertMatch({unchecked, _}, eth_engine:blob_hashes_admission(P, [])),
    ?assertMatch({unchecked, _},
                 eth_engine:blob_hashes_admission(
                   P, [hex(versioned_hash(1))])),
    P2 = payload(),
    ?assertMatch({unchecked, transactions_not_an_array},
                 eth_engine:blob_hashes_admission(P2#{<<"transactions">> => null}, [])),
    ?assertMatch({unchecked, expected_hashes_not_an_array},
                 eth_engine:blob_hashes_admission(
                   P2#{<<"transactions">> => []}, not_a_list)).

%% A versioned hash is 0x01 followed by 31 bytes (EIP-4844: the first byte of the
%% SHA-256 of the commitment, with the version in the top bit). An expected value
%% whose first byte is not 0x01 is not a versioned hash, and admitting it would let
%% a caller assert anything and be told the payload is fine.
expected_hashes_must_be_versioned_hashes_test() ->
    P = payload(),
    Empty = P#{<<"transactions">> => []},
    %% A well-formed hash passes the *shape* check, and then disagrees with the
    %% payload -- which is the shape failure being absent, not a pass.
    ?assertMatch({invalid, [<<1, _/binary>>], []},
                 eth_engine:blob_hashes_admission(Empty, [versioned_hash(1)])),
    ?assertMatch({invalid, [<<1, _/binary>>], []},
                 eth_engine:blob_hashes_admission(Empty, [hex(versioned_hash(1))])),
    %% Version 0x00, not 0x01.
    ?assertMatch({unchecked, expected_hashes_not_an_array},
                 eth_engine:blob_hashes_admission(
                   Empty, [hex(<<0:248, 1>>)])),
    %% Right length, wrong width.
    ?assertMatch({unchecked, expected_hashes_not_an_array},
                 eth_engine:blob_hashes_admission(Empty, [<<1, 2, 3>>])).

%% ===========================================================================
%% Over the wire
%% ===========================================================================

%% The whole reason this work exists: a post-Merge consensus client calls V3, and
%% before this change every one of those calls was answered -32601 method not
%% found, which is indistinguishable from a node that does not implement the Engine
%% API at all.
v3_methods_are_routed_rather_than_refused_test() ->
    with_http(fun(Port) ->
        Head = #{<<"headBlockHash">> => <<1:256>>,
                 <<"safeBlockHash">> => <<0:256>>,
                 <<"finalizedBlockHash">> => <<0:256>>},
        %% forkchoiceUpdatedV3 with null attributes: a status, not an error.
        ?assertMatch({ok, #{<<"result">> := #{<<"payloadStatus">> :=
                                        #{<<"status">> := _}}}, _},
                     call(Port, <<"engine_forkchoiceUpdatedV3">>, [Head, null])),
        %% getPayloadV3 for an id this node never issued: -38001, the code the
        %% specification names, and not -32601.
        ?assertMatch({ok, #{<<"error">> := #{<<"code">> := -38001}}, _},
                     call(Port, <<"engine_getPayloadV3">>, [<<0:64>>])),
        ?assertMatch({ok, #{<<"error">> := #{<<"code">> := -38001}}, _},
                     call(Port, <<"engine_getPayloadV2">>, [<<0:64>>]))
    end).

%% newPayloadV2 and V3 with a payload whose structure is wrong for the method
%% answer -32602 over HTTP, not a payload status. A status here would be read by a
%% client as a verdict on the block.
new_payload_v2_answers_invalid_params_for_the_wrong_structure_test() ->
    with_http(fun(Port) ->
        V1 = v1_payload(shanghai_at(sepolia) - 1),
        %% Post-Shanghai timestamp, so V2 wants the V2 structure.
        Post = v2_payload(shanghai_at(sepolia)),
        ?assertMatch({ok, #{<<"error">> := #{<<"code">> := -32602}}, _},
                     call(Port, <<"engine_newPayloadV2">>,
                          [Post#{<<"withdrawals">> => null}])),
        %% Pre-Shanghai timestamp, so V2 wants the V1 structure, and this payload
        %% carries `withdrawals'.
        ?assertMatch({ok, #{<<"error">> := #{<<"code">> := -32602}}, _},
                     call(Port, <<"engine_newPayloadV2">>,
                          [V1#{<<"withdrawals">> => []}]))
    end).

%% newPayloadV3's third parameter is parentBeaconBlockRoot, DATA, 32 bytes. A null
%% is "not provided" (cancun.md item 1) and so is -32602, not -38005: the frame
%% check is about the payload's timestamp and says nothing about this parameter.
%% ===========================================================================
%% The Prague and Amsterdam method set, all four dispatch clauses
%% ===========================================================================
%% **"Recognised" is the assertion, not "works".** `-32601` and a plausible-looking status
%% are both things a handler without the clause can answer, and a status from a catch-all
%% proxy would read as success to anything checking only for an error's absence.

new_payload_v4_is_recognised_test() ->
    with_http(fun(Port) ->
        {ok, Body, _} = call(Port, <<"engine_newPayloadV4">>,
                             [payload(), [], <<0:256>>, []]),
        ?assertNot(is_error(Body, -32601))
    end).

forkchoice_updated_v4_is_recognised_test() ->
    with_http(fun(Port) ->
        %% An all-zero head is the specification's "not claimed" marker, so this reaches
        %% `eth_engine` and answers VALID rather than being refused by the state check --
        %% which is what makes it a test of the *dispatch* rather than of the head.
        {ok, Body, _} = call(Port, <<"engine_forkchoiceUpdatedV4">>,
                             [forkchoice(undefined), <<0:256>>, []]),
        ?assertNot(is_error(Body, -32601))
    end).

%% **`getPayloadV4` and `getPayloadV6` answer `-38001` for an unknown payload id**, which is
%% the specification's code and proves the method ran rather than being proxied. A `-32601`
%% here would mean the dispatch clause is missing; a `-32602` would mean the parameter
%% shape is wrong.
get_payload_v4_and_v6_answer_unknown_payload_id_test() ->
    with_http(fun(Port) ->
        [begin
             {ok, Body, _} = call(Port, Method, [<<"0x0102030405060708">>]),
             ?assertEqual({Method, -38001}, {Method, error_code(Body)})
         end || Method <- [<<"engine_getPayloadV4">>, <<"engine_getPayloadV6">>]]
    end).

%% **`PayloadAttributesV4` demands `slotNumber` and `targetGasLimit`, and
%% `targetGasLimit` is in neither EIP this fork is built from.** It appears in
%% execution-apis and nowhere else: not in EIP-7843's header field, not in EIP-7928. So the
%% structure check requires a field the node has no rule for -- which is recorded rather
%% than papered over, and asserted here so the requirement is visible in a test.
payload_attributes_v4_requires_slot_number_and_target_gas_limit_test() ->
    with_http(fun(Port) ->
        %% Without both, the attributes object is not V4's and the answer is -38003.
        {ok, Body, _} = call(Port, <<"engine_getPayloadV6">>,
                             [<<"0x0102030405060708">>]),
        ?assertEqual(-38001, error_code(Body)),
        %% And the structure check itself, asked directly of the admission function so the
        %% requirement does not have to be inferred from an end-to-end refusal. **A
        %% comprehension over `[x || true]` is not a way to name a term** -- my first
        %% version had one here and it did not parse, which is the cheapest possible report
        %% of a construct that was never going to mean anything.
        %% **An attributes object, not a payload.** My first version passed the *payload*
        %% fixture to `attributes_admission/2', which checks a different structure --
        %% `required_attributes/1` against `appended_attribute_keys/0` -- so the assertion was
        %% about the wrong object entirely and would have passed for the wrong reason on a
        %% node that checked nothing.
        A = amsterdam_attributes(),
        ?assertMatch({error, -38003, _},
                     eth_engine:attributes_admission(maps:remove(<<"slotNumber">>, A), 6)),
        ?assertMatch({error, -38003, _},
                     eth_engine:attributes_admission(
                       maps:remove(<<"targetGasLimit">>, A), 6)),
        %% **Both present: the structure passes and the frame gate is reached.** The
        %% timestamp is post-Amsterdam, so this is `ok` rather than `-38005` -- which is the
        %% assertion that the fork gate is a *separate* check and not a side effect of the
        %% structure one.
        ?assertEqual(ok, eth_engine:attributes_admission(A, 6)),
        %% And Prague's method wants V3's attributes, so the same object is refused there.
        ?assertMatch({error, -38003, _},
                     eth_engine:attributes_admission(A, 4))
    end).

%% `PayloadAttributesV4`, with the timestamp after Sepolia's Amsterdam activation.
amsterdam_attributes() ->
    #{<<"timestamp">> => <<"0x6ac7a2e0">>,
      <<"prevRandao">> => <<0:256>>,
      <<"suggestedFeeRecipient">> => <<0:160>>,
      <<"withdrawals">> => [],
      <<"parentBeaconBlockRoot">> => <<0:256>>,
      <<"slotNumber">> => <<"0xac6000">>,
      <<"targetGasLimit">> => <<"0x1c9c380">>}.

error_code(#{<<"error">> := #{<<"code">> := Code}}) -> Code;
error_code(#{<<"result">> := #{<<"code">> := Code}}) -> Code;
error_code(_Body) -> none.

%% ===========================================================================
%% engine_newPayloadV5: the method that carries `executionRequests`
%% ===========================================================================
%% **`requestsHash` has exactly one source on this path and it is this method's fourth
%% parameter.** `ExecutionPayloadV4` does not carry it (execution-apis
%% src/engine/amsterdam.md), so a node without V5 cannot hash a Prague or Amsterdam payload
%% at all -- which is what `missing_requests_hash` was reporting before it became derivable.

%% **The method exists, and "recognised" is asserted rather than assumed.** `-32601` and a
%% status are both plausible answers from a handler that never had the clause.
new_payload_v5_is_recognised_test() ->
    with_http(fun(Port) ->
        {ok, Body, _} = call(Port, <<"engine_newPayloadV5">>,
                             [payload(), [], <<0:256>>, []]),
        %% **A map pattern is not an expression** -- only a match context accepts one -- so
        %% this asks the question through a function rather than inline.
        ?assertNot(is_error(Body, -32601))
    end).

%% **A null fourth parameter is an empty request list, not a missing parameter.**
%%
%% The specification says a null field "MUST be considered as not provided", which would
%% make this -32602 -- and a CL that sends `null` for a block with no requests would be
%% refused for a payload that is perfectly valid. The empty list's hash is the chain's
%% `0xe3b0c442...`, so there is a value to commit to and refusing wastes it.
new_payload_v5_treats_null_execution_requests_as_an_empty_list_test() ->
    with_http(fun(Port) ->
        %% **A payload in V5's own structure.** My first version sent the Cancun fixture to
        %% V5 and asserted "not -32602" -- and got -32602, correctly: `structure_admission/2`
        %% compares the appended keys against `required_structure(amsterdam)' and the
        %% Cancun fixture carries neither `blockAccessList' nor `slotNumber'. **A test that
        %% asks a method about the wrong structure is testing the structure check**, and the
        %% parameter it meant to ask about never ran.
        P = amsterdam_payload(),
        [begin
             {ok, Body, _} = call(Port, <<"engine_newPayloadV5">>, [P, [], <<0:256>>, R]),
             ?assertNot(is_error(Body, -32602))
         end || R <- [null, []]]
    end).

%% A payload carrying the two fields `ExecutionPayloadV4` appends. `executionRequests` is
%% the method's fourth parameter and is deliberately not here -- it is attached by the
%% handler, and a structure check that demanded it would refuse every other method's payload.
amsterdam_payload() ->
    maps:merge(payload(),
               #{<<"blockAccessList">> => <<"0xc0">>, <<"slotNumber">> => <<"0xac6000">>}).

%% **The beacon-root gate is unchanged and still comes first.** V5 has one more parameter
%% than V3 and a test that only checked the new one would not notice if that gate had been
%% dropped along the way -- and it is the gate that keeps a payload for the wrong fork out.
new_payload_v5_still_requires_a_parent_beacon_block_root_test() ->
    with_http(fun(Port) ->
        [?assertMatch({ok, #{<<"error">> := #{<<"code">> := -32602}}, _},
                      call(Port, <<"engine_newPayloadV5">>, [payload(), [], Root, []]))
         || Root <- [null, undefined, <<"0x00">>, 42]]
    end).

%% **An Amsterdam-shaped payload reaches the 23-field header check.**
%%
%% Asserted as `INVALID_BLOCK_HASH` rather than `INVALID`: the fixture's own hash does not
%% match a header carrying `slotNumber`, so the *hash* rule is the one that fires, and a
%% V5 handler that dropped the payload's new fields on the floor would answer something
%% else. `requestsHash` is supplied, so the refusal is not the one from the previous commit.
new_payload_v5_reaches_the_amsterdam_header_check_test() ->
    with_http(fun(Port) ->
        %% **The timestamp has to be at or after Prague**, or the answer is `-38005
        %% Unsupported fork' -- which is what this test got first, and it is the right
        %% answer: the method serves Prague-or-later and the Cancun fixture is older. A test
        %% that reaches the header check has to get past the frame gate first, and the gate
        %% is the reason a wrong-fork payload is refused before anything is hashed.
        %% 1,791,600,000 is after Sepolia's Prague activation (1,741,159,776) and after
        %% Amsterdam (1,791,294,816).
        P = maps:merge(payload(),
                       #{<<"timestamp">> => <<"0x6ac7a2e0">>,
                         <<"slotNumber">> => <<"0xac6000">>,
                         <<"blockAccessList">> => <<"0xc0">>}),
        %% **`INVALID` with `{block_hash_mismatch, _}`, which is the answer that matters.**
        %% I first asserted `INVALID_BLOCK_HASH` and the test told me otherwise: this node
        %% reports the hash disagreement through `finalize/1`'s verdict, so the status is
        %% `INVALID` and the reason carries the figure. **The point of the assertion is that
        %% a hash was computed at all** -- on this path, before the fix, the payload could
        %% not be encoded at all and the answer was `-32602`/`missing_requests_hash`.
        {ok, #{<<"result">> := #{<<"status">> := <<"INVALID">>,
                                  <<"validationError">> := Reason}}, _} =
            call(Port, <<"engine_newPayloadV5">>, [P, [], <<0:256>>, []]),
        ?assertNotEqual(nomatch, binary:match(Reason, <<"block_hash_mismatch">>)),
        %% And specifically **not** the refusal this path used to give, which is the whole
        %% point: before `executionRequests` became a source, the answer here was
        %% `missing_requests_hash`.
        ?assertEqual(nomatch, binary:match(Reason, <<"requests_hash">>))
    end).

new_payload_v3_requires_a_parent_beacon_block_root_test() ->
    with_http(fun(Port) ->
        P = payload(),
        [?assertMatch({ok, #{<<"error">> := #{<<"code">> := -32602}}, _},
                      call(Port, <<"engine_newPayloadV3">>, [P, [], Root]))
         || Root <- [null, <<"0x00">>, <<"0xzz">>, 42]],
        %% Present and well formed, and the blob hashes disagree, so the answer is
        %% the INVALID *status* -- which is the check the other two gates do not do.
        %% This is the real Cancun fixture, with its real transactions, so the
        %% actual array is whatever those transactions commit to; a check that could
        %% not read them would answer SYNCING here, and that is what the first
        %% version of this did.
        Hash = hex(versioned_hash(9)),
        %% call/3 is {ok, Body, HttpStatus}; the status is not under test here.
        {ok, #{<<"result">> := #{<<"status">> := <<"INVALID">>,
                                 <<"latestValidHash">> := null,
                                 <<"validationError">> := Reason}}, _} =
            call(Port, <<"engine_newPayloadV3">>, [P, [Hash], <<0:256>>]),
        %% The reason has to be readable, not a ~p dump of two lists of 32-byte
        %% binaries: it names the disagreement, not the whole arrays.
        ?assertNotEqual(nomatch, binary:match(Reason, <<"blob versioned hashes">>)),
        ?assertNotEqual(nomatch, binary:match(Reason, <<"first disagreement at index">>)),
        %% Nothing of the dump survives, so this would fail if message/1 were used.
        ?assertEqual(nomatch, binary:match(Reason, <<"blob_hashes_mismatch">>))
    end).

%% newPayloadV3 with matching blob hashes falls through to the ordinary path, and
%% the ordinary path's verdict is unchanged by the blob check having run. That is
%% the invariant, and comparing against the same payload on V1 is what makes it
%% checkable: asserting a hard-coded status would only pin whatever the ordinary
%% path happens to return today, and would still pass with the blob check removed
%% from the code -- which is the failure this test exists to catch, since the
%% mismatch case above is its only other guard.
%%
%% The payload is the real fixture, with its real transaction list, and the
%% expected array is therefore whatever its blob transactions commit to. It has no
%% blob transactions, so `[]' is the correct expectation and not a convenient one.
new_payload_v3_with_matching_hashes_reaches_the_ordinary_path_test() ->
    with_http(fun(Port) ->
        P = payload(),
        ?assertEqual(ok, eth_engine:blob_hashes_admission(P, [])),
        {ok, #{<<"result">> := V3}, _} =
            call(Port, <<"engine_newPayloadV3">>, [P, [], <<0:256>>]),
        {ok, #{<<"result">> := V1}, _} = call(Port, <<"engine_newPayloadV1">>, [P]),
        ?assertEqual(maps:get(<<"status">>, V1), maps:get(<<"status">>, V3))
    end).

%% forkchoiceUpdatedV2 and V3 run the attributes checks; -38003 for a shape
%% failure. The code is -38003 and not -32602 because the specification names
%% -38003 for payloadAttributes specifically.
forkchoice_updated_checks_payload_attributes_test() ->
    with_http(fun(Port) ->
        Head = #{<<"headBlockHash">> => <<1:256>>,
                 <<"safeBlockHash">> => <<0:256>>,
                 <<"finalizedBlockHash">> => <<0:256>>},
        V2 = attributes(shanghai),
        %% V3 demands parentBeaconBlockRoot as well.
        ?assertMatch({ok, #{<<"error">> := #{<<"code">> := -38003}}, _},
                     call(Port, <<"engine_forkchoiceUpdatedV3">>, [Head, V2])),
        %% V2 refuses it for carrying the key at all.
        ?assertMatch({ok, #{<<"error">> := #{<<"code">> := -38003}}, _},
                     call(Port, <<"engine_forkchoiceUpdatedV2">>,
                          [Head, attributes(cancun)])),
        %% Well formed for V2, so this is a status and not an error.
        ?assertMatch({ok, #{<<"result">> := #{<<"payloadStatus">> := _}}, _},
                     call(Port, <<"engine_forkchoiceUpdatedV2">>, [Head, V2])),
        %% A timestamp outside the Cancun frame is -38005, a different code from
        %% the shape failure above.
        Prague = after_cancun_at(sepolia),
        ?assertMatch({ok, #{<<"error">> := #{<<"code">> := -38005}}, _},
                     call(Port, <<"engine_forkchoiceUpdatedV3">>,
                          [Head, (attributes(cancun))#{<<"timestamp">> => hexq(Prague)}]))
    end).

%% ===========================================================================
%% Helpers
%% ===========================================================================

%% ETH_NETWORK is process-wide, so it is restored. The gate reads
%% eth_fork_schedule:configured_network/0, and a test that left this set would
%% silently redirect every later test's frame check.
with_network(Network, Fun) ->
    Previous = os:getenv("ETH_NETWORK"),
    true = os:putenv("ETH_NETWORK", Network),
    try Fun()
    after
        case Previous of
            false -> os:unsetenv("ETH_NETWORK");
            _ -> os:putenv("ETH_NETWORK", Previous)
        end
    end.

%% The activation instants, read from the schedule rather than written here. The
%% *values* are pinned by eth_fork_schedule_tests, which is the module that owns
%% them; this module only states the behaviour at whatever they are, so a change to
%% the schedule cannot make a test here quietly test the wrong boundary.
shanghai_at(Network) ->
    {ok, T, _To} = eth_fork_schedule:timestamp_frame(Network, shanghai), T.

cancun_at(Network) ->
    {ok, T, _To} = eth_fork_schedule:timestamp_frame(Network, cancun), T.

%% The instant Cancun's frame closes, which is the next timestamped fork's
%% activation. This is the boundary the half-open rule is about.
after_cancun_at(Network) ->
    {ok, _From, To} = eth_fork_schedule:timestamp_frame(Network, cancun), To.

far_future() -> 1900000000.

payload_with_timestamp(Timestamp) ->
    (payload())#{<<"timestamp">> => Timestamp}.

%% Genuine structures, not a Cancun payload with its timestamp moved. The gates
%% compare the *set* of appended keys, so a test that only changed the timestamp
%% would be testing "a Cancun payload at a Shanghai timestamp", which is refused
%% for carrying the wrong keys rather than for being in the wrong frame.
v1_payload(Timestamp) ->
    lists:foldl(fun(K, Acc) -> maps:remove(K, Acc) end,
                payload_with_timestamp(hexq(Timestamp)),
                [<<"withdrawals">>, <<"blobGasUsed">>, <<"excessBlobGas">>]).

v2_payload(Timestamp) ->
    lists:foldl(fun(K, Acc) -> maps:remove(K, Acc) end,
                payload_with_timestamp(hexq(Timestamp)),
                [<<"blobGasUsed">>, <<"excessBlobGas">>]).

payload_with_transactions(Txs) ->
    (payload())#{<<"transactions">> => Txs}.

%% A type-3 (blob) transaction carrying the given versioned hashes, keyed by
%% position, encoded to the wire form a payload carries.
blob_tx(HashesByIndex) ->
    Hashes = [maps:get(I, HashesByIndex) || I <- lists:sort(maps:keys(HashesByIndex))],
    {ok, Bin} = eth_tx:to_rlp(#{
        <<"type">> => <<"0x3">>,
        <<"chainId">> => <<"0x1">>,
        <<"nonce">> => <<"0x0">>,
        <<"maxPriorityFeePerGas">> => <<"0x1">>,
        <<"maxFeePerGas">> => <<"0x2">>,
        <<"gas">> => <<"0x5208">>,
        <<"to">> => <<"0x0102030405060708090a0b0c0d0e0f1011121314">>,
        <<"value">> => <<"0x0">>,
        <<"input">> => <<"0x">>,
        <<"accessList">> => [],
        <<"maxFeePerBlobGas">> => <<"0x3b9aca00">>,
        <<"blobVersionedHashes">> => [hex(H) || H <- Hashes],
        <<"v">> => <<"0x0">>, <<"r">> => <<"0x1">>, <<"s">> => <<"0x1">>
    }),
    hex(Bin).

%% EIP-4844 versioned hash: 0x01 in the first byte, then 31 arbitrary bytes.
versioned_hash(N) -> <<1, N:248>>.

attributes(shanghai) ->
    #{<<"timestamp">> => hexq(shanghai_at(sepolia) + 12),
      <<"prevRandao">> => <<0:256>>,
      <<"suggestedFeeRecipient">> => <<0:160>>,
      <<"withdrawals">> => []};
%% The V3 attributes' timestamp has to be inside the Cancun frame, or the -38005
%% check fires before the structure is reached. V2's does not matter for the same
%% reason: V2 has no frame check.
attributes(cancun) ->
    (attributes(shanghai))#{<<"timestamp">> => hexq(cancun_at(sepolia) + 12),
                            <<"parentBeaconBlockRoot">> => <<0:256>>}.

hexq(Int) -> <<"0x", (binary:encode_hex(<<Int:64>>))/binary>>.


%% ===========================================================================
%% Fixtures
%% ===========================================================================

with_engine(Fun) ->
    {ok, _} = eth_engine:start_link(#{jwt_secret => test_secret()}),
    try Fun()
    after stop_engine()
    end.

with_http(Fun) ->
    with_http_common(Fun, test_secret()).

with_http_no_secret(Fun) ->
    with_http_common(Fun, <<>>).

with_http_common(Fun, Secret) ->
    ok = eth_test_util:start_apps(),
    {ok, _} = eth_engine:start_link(#{jwt_secret => Secret}),
    Port = eth_test_util:free_port(),
    Dispatch = cowboy_router:compile(
                 [{'_', [{<<"/engine">>, eth_engine_handler, #{}}]}]),
    {ok, _} = cowboy:start_clear('engine_api_test_listener',
                                  [{port, Port}, {ip, {127, 0, 0, 1}}],
                                  #{env => #{dispatch => Dispatch}}),
    try Fun(Port)
    after
        (try cowboy:stop_listener('engine_api_test_listener')
         catch _:_ -> ok end),
        stop_engine()
    end.

stop_engine() ->
    case whereis(eth_engine) of
        undefined -> ok;
        _ -> (try gen_server:stop(eth_engine) catch _:_ -> ok end)
    end.

test_secret() -> <<16#5a:256>>.

claims() -> claims(#{}).

claims(Extra) ->
    maps:merge(#{<<"iat">> => os:system_time(second),
                 <<"id">> => <<"engine-tests">>,
                 <<"clv">> => <<"etherlang-tests/1">>}, Extra).

%% **Does this answer carry exactly this JSON-RPC error code?** A pattern is not an
%% expression in Erlang, so the negative assertions above cannot be written inline.
is_error(#{<<"error">> := #{<<"code">> := Code}}, Code) -> true;
is_error(_Body, _Code) -> false.

call(Port, Method, Params) -> call(Port, Method, Params, default).

call(Port, Method, Params, no_auth) ->
    post(Port, Method, Params, []);

%% httpc's header list is [{"Name", "Value"}] as strings; a binary header
%% name is rejected with {headers_error, invalid_field}, which looks like a
%% server refusal rather than a malformed request.
call(Port, Method, Params, {bearer, Token}) ->
    post(Port, Method, Params, [{"authorization", "Bearer " ++ binary_to_list(Token)}]);

call(Port, Method, Params, default) ->
    post(Port, Method, Params, default_auth()).

default_auth() ->
    [{"authorization", "Bearer " ++ binary_to_list(eth_jwt:sign(claims(), test_secret()))}].

post(Port, Method, Params, Headers) ->
    Body = thoas:encode(#{<<"jsonrpc">> => <<"2.0">>,
                          <<"id">> => 1,
                          <<"method">> => Method,
                          <<"params">> => Params}),
    URL = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/engine",
    %% Any status: the authentication failures answer 401/503, and a test that
    %% only accepted 200 could not tell a refusal from a crash.
    {ok, {{_, Status, _}, _, Resp}} =
        httpc:request(post, {URL, Headers, "application/json", Body},
                      [{timeout, 10000}], [{body_format, binary}]),
    {ok, Decoded} = thoas:decode(Resp),
    {ok, Decoded, Status}.

%% A real Cancun payload from Sepolia, so the engine is exercised on data the
%% network produced: a decodable body, a block hash that really is the hash of the
%% header, and withdrawals. The hand-rolled payload this replaced had a
%% transaction that was not a transaction, so every test using it was really only
%% testing that the decoder complains.
payload() -> real_payload().

real_payload() -> maps:get(payload, eth_payload_fixture:cancun()).

forkchoice(Head) -> forkchoice(Head, undefined).

forkchoice(Head, PayloadId) -> forkchoice_map(Head, PayloadId).

%% The specification allows the safe and finalized hashes to be all-zero when
%% there is nothing to say, so they are sent that way.
forkchoice_map(Head, PayloadId) ->
    Zero = hex(<<0:256>>),
    Pairs = [{<<"headBlockHash">>, hash_value(Head)},
             {<<"safeBlockHash">>, Zero},
             {<<"finalizedBlockHash">>, Zero}]
        ++ [{<<"payloadId">>, PayloadId} || PayloadId =/= undefined],
    maps:from_list(Pairs).

%% The engine API sends the forkchoiceState as params[0] and the
%% payloadAttributes, which may be null, as params[1].
forkchoice_payload(Head) ->
    [forkchoice(Head), null].

head() -> <<16#11, 0:248>>.

payload_id() -> hex(<<16#a1, 0:56>>).

hash_value(undefined) -> undefined;
hash_value(Hash) -> hex(Hash).

%% The two forms a 32-byte hash arrives in: a 0x-prefixed string, which is what a
%% decoded JSON object carries, and the raw bytes themselves.
hex(Bin) -> <<"0x", (binary:encode_hex(Bin))/binary>>.

unhex(<<"0x", Rest/binary>>) -> binary:decode_hex(Rest);
unhex(Bin) -> Bin.

%% The right *length* for a 32-byte hash and not hex, which is a different failure
%% from being the wrong length and worth testing separately: a decoder that only
%% counted bytes would take this for a hash.
non_hex_data() -> iolist_to_binary(["0xZZ", binary:copy(<<"0">>, 62)]).

triton_td() -> eth_hex:decode(<<"0xc70d815d562d3cfa955">>).

recorded_head() ->
    %% #st{} is a tuple: the record tag, then the fields in declaration order, so
    %% `head' is the fifth field. This is the only white-box assertion in the
    %% file, and it is here because the discarded-write defect it guards was
    %% invisible from the public API once the statuses became honest.
    element(6, gen_server:call(eth_engine, get_state, infinity)).

