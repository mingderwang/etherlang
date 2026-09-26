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

-define(NO_TTD, 16#ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff).

%% ===========================================================================
%% newPayload: no status this node cannot support
%% ===========================================================================

%% A payload with no parent hash cannot be placed on any chain, so no status
%% derived from execution could describe it.
new_payload_without_a_parent_hash_is_invalid_test() ->
    with_engine(fun() ->
        ?assertEqual({<<"INVALID">>, missing_parent_hash},
                     eth_engine:new_payload(#{
                         <<"blockNumber">> => <<"0x1">>,
                         <<"stateRoot">> => hex(<<16#cd, 0:248>>)
                     }))
    end).

%% The specification's ACCEPTED is a claim with preconditions -- non-empty
%% transactions, a blockHash equal to Keccak256(RLP(header)), a non-canonical
%% payload, known and well-formed ancestors. None is checked here, and nothing is
%% executed, so ACCEPTED and VALID are both unsupported.
new_payload_never_reports_a_block_it_did_not_execute_test() ->
    with_engine(fun() ->
        Status = eth_engine:new_payload(payload()),
        ?assertEqual(<<"SYNCING">>, Status)
    end).

%% The web browser attack the authentication document names is a malicious page
%% posting JSON, so the key form a request arrives in is the one that matters.
%% Every lookup in the module used to be `maps:get("someKey", ...)`, so a
%% binary-keyed payload -- which is what a decoded JSON object always is -- was
%% read as empty and answered INVALID for a parent hash it was carrying.
new_payload_reads_the_keys_a_json_request_carries_test() ->
    with_engine(fun() ->
        ?assertEqual(<<"SYNCING">>, eth_engine:new_payload(payload()))
    end).

new_payload_rejects_a_malformed_parent_hash_test() ->
    with_engine(fun() ->
        ?assertMatch({<<"INVALID">>, {malformed_parent_hash, {wrong_length, 32}}},
                     eth_engine:new_payload(#{
                         <<"parentHash">> => <<"0xabcd">>,
                         <<"blockNumber">> => <<"0x1">>
                     })),
        ?assertMatch({<<"INVALID">>, {malformed_parent_hash, not_data}},
                     eth_engine:new_payload(#{<<"parentHash">> => 42}))
    end).

%% An in-process caller holds raw bytes, a JSON caller holds a hex string, and
%% the record stores raw bytes so both sides of every comparison agree.
new_payload_accepts_a_parent_hash_as_raw_bytes_test() ->
    with_engine(fun() ->
        Parent = <<16#ab, 0:248>>,
        ?assertEqual(<<"SYNCING">>,
                     eth_engine:new_payload(#{
                         <<"parentHash">> => Parent,
                         <<"blockNumber">> => <<"0x1">>
                     }))
    end).

new_payload_needs_a_map_test() ->
    with_engine(fun() ->
        ?assertEqual({<<"INVALID">>, payload_not_an_object},
                     eth_engine:new_payload(<<"not a map">>))
    end).

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
%% layers must use 2^256-1, so a client and a node that have not decided can
%% still compare equal.
exchange_transition_configuration_reports_the_absent_total_difficulty_test() ->
    with_engine(fun() ->
        {ok, Cfg} = eth_engine:exchange_transition_config(
            #{<<"terminalBlockHash">> => hex(<<0:2048>>)}),
        ?assertEqual(?NO_TTD, maps:get(terminal_total_difficulty, Cfg)),
        %% An all-zero terminal block hash is the "not decided" marker, not a
        %% block hash, so it is reported as absent.
        ?assertEqual(undefined, maps:get(terminal_block_hash, Cfg))
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

payload() ->
    #{<<"parentHash">> => hex(<<16#ab, 0:248>>),
      <<"feeRecipient">> => <<"0x0000000000000000000000000000000000000000">>,
      <<"stateRoot">> => hex(<<16#cd, 0:248>>),
      <<"receiptsRoot">> => hex(<<16#ef, 0:248>>),
      <<"logsBloom">> => hex(<<0:2048>>),
      <<"prevRandao">> => hex(<<16#11, 0:248>>),
      <<"blockNumber">> => <<"0x64">>,
      <<"gasLimit">> => <<"0x1c9c380">>,
      <<"gasUsed">> => <<"0x5208">>,
      <<"timestamp">> => <<"0x64">>,
      <<"extraData">> => <<"0x">>,
      <<"baseFeePerGas">> => <<"0x7">>,
      <<"blockHash">> => hex(<<16#77, 0:248>>),
      <<"transactions">> => [<<"0xf8">>]}.

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

hex(Bin) -> <<"0x", (binary:encode_hex(Bin))/binary>>.

triton_td() -> eth_hex:decode(<<"0xc70d815d562d3cfa955">>).

recorded_head() ->
    %% #st{} is a tuple: the record tag, then the fields in declaration order, so
    %% `head' is the fifth field. This is the only white-box assertion in the
    %% file, and it is here because the discarded-write defect it guards was
    %% invisible from the public API once the statuses became honest.
    element(6, gen_server:call(eth_engine, get_state, infinity)).
