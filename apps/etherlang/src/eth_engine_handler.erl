%% Cowboy handler for the Engine API endpoint.
%%
%% Routes:
%%   POST /engine/       — Engine API JSON-RPC methods
%%     engine_newPayloadV1
%%     engine_forkchoiceUpdatedV1
%%     engine_getPayloadV1
%%     engine_exchangeTransitionConfigurationV1
%%
%% Every request is authenticated with a JWT in the Authorization header, per
%% execution-apis src/engine/authentication.md. This was not implemented: the
%% comment above claimed it was, TASKS.md ticked it as done, and the handler read
%% no secret and verified no token. The port was open to anything that could
%% reach it, and the methods it exposed are the ones a consensus client trusts.
%%
%% The status codes, from the engine API specification. They are duplicated here
%% rather than exported from eth_engine because they are part of this module's own
%% contract with the wire: it decides which statuses may carry a validationError,
%% and it must be able to say so without reaching into the engine's internals.
-define(INVALID, <<"INVALID">>).
-define(INVALID_BLOCK_HASH, <<"INVALID_BLOCK_HASH">>).

-module(eth_engine_handler).

-export([init/2]).

%% ---------------------------------------------------------------------------
%% Cowboy handler
%% ---------------------------------------------------------------------------

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            case authenticate(Req0) of
                {error, Code, Message} ->
                    unauthorized(Req0, Code, Message);
                ok ->
                    dispatch(Req0, State)
            end;
        _ ->
            Req1 = cowboy_req:reply(405,
                #{<<"allow">> => <<"POST">>},
                <<"method not allowed">>, Req0),
            {ok, Req1, State}
    end.

authenticate(Req0) ->
    case eth_engine:jwt_secret() of
        {ok, Secret} when Secret =/= <<>> ->
            case cowboy_req:header(<<"authorization">>, Req0) of
                <<"Bearer ", Token/binary>> ->
                    case eth_jwt:verify(Token, Secret) of
                        ok -> ok;
                        {error, Reason} ->
                            {error, 401, message(Reason)}
                    end;
                undefined ->
                    {error, 401, <<"missing Authorization header">>};
                _ ->
                    {error, 401, <<"Authorization header is not a Bearer token">>}
            end;
        {error, Reason} ->
            %% Not authentication, availability: the node has no secret, so it
            %% cannot authenticate anything. Serving the port anyway is the
            %% failure this scheme exists to prevent.
            {error, 503, message({engine_api_unavailable, Reason})}
    end.

unauthorized(Req0, Code, Message) ->
    Req1 = cowboy_req:reply(Code,
        #{<<"content-type">> => <<"application/json">>},
        thoas:encode(#{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => null,
            <<"error">> => #{
                <<"code">> => Code,
                <<"message">> => Message
            }
        }), Req0),
    {ok, Req1, undefined}.

dispatch(Req0, State) ->
    case allowed(State, Req0) of
        true ->
                    {ok, Body, Req1} = cowboy_req:read_body(Req0,
                                                            #{length => 50_000_000,
                                                              period => 30000}),
                    Resp = handle_body(Body, State),
                    Req2 = cowboy_req:reply(200,
                                            #{<<"content-type">> => <<"application/json">>},
                                            Resp, Req1),
                {ok, Req2, State};
        false ->
            Req1 = cowboy_req:reply(429,
                #{<<"content-type">> => <<"application/json">>},
                thoas:encode(#{
                    <<"jsonrpc">> => <<"2.0">>,
                    <<"error">> => #{
                        <<"code">> => -32005,
                        <<"message">> => <<"too many requests">>
                    }
                }), Req0),
            {ok, Req1, State}
    end.

%% ---------------------------------------------------------------------------
%% Body handling
%% ---------------------------------------------------------------------------

handle_body(Body, State) ->
    case thoas:decode(Body) of
        {ok, Map} when is_map(Map) ->
            Id = maps:get(<<"id">>, Map, null),
            case maps:get(<<"method">>, Map, undefined) of
                undefined ->
                    error_rpc(Id, -32600, <<"missing method">>);
                <<"engine_newPayloadV1">> ->
                    handle_new_payload(Map, State, Id, 1);
                <<"engine_newPayloadV2">> ->
                    handle_new_payload(Map, State, Id, 2);
                <<"engine_newPayloadV3">> ->
                    handle_new_payload_v3(Map, State, Id);
                <<"engine_forkchoiceUpdatedV1">> ->
                    handle_forkchoice_updated(Map, State, Id, 1);
                <<"engine_forkchoiceUpdatedV2">> ->
                    handle_forkchoice_updated(Map, State, Id, 2);
                <<"engine_forkchoiceUpdatedV3">> ->
                    handle_forkchoice_updated(Map, State, Id, 3);
                <<"engine_getPayloadV1">> ->
                    handle_get_payload(Map, Id, 1);
                <<"engine_getPayloadV2">> ->
                    handle_get_payload(Map, Id, 2);
                <<"engine_getPayloadV3">> ->
                    handle_get_payload(Map, Id, 3);
                <<"engine_exchangeTransitionConfigurationV1">> ->
                    handle_exchange_config(Map, State, Id);
                _ ->
                    error_rpc(Id, -32601, <<"method not found">>)
            end;
        _ ->
            thoas:encode(#{
                <<"jsonrpc">> => <<"2.0">>,
                <<"error">> => #{
                    <<"code">> => -32700,
                    <<"message">> => <<"parse error">>
                }
            })
    end.

%% ---------------------------------------------------------------------------
%% Engine method handlers
%% ---------------------------------------------------------------------------

%% The response shapes below follow the engine API specification:
%%
%%   method                              result
%%   ----------------------------------  --------------------------------------
%%   engine_newPayloadV1                 PayloadStatusV1
%%   engine_newPayloadV2                 PayloadStatusV1, no INVALID_BLOCK_HASH
%%   engine_newPayloadV3                 PayloadStatusV1, blob hashes checked
%%   engine_forkchoiceUpdatedV1          {payloadStatus, payloadId}
%%   engine_forkchoiceUpdatedV2          {payloadStatus, payloadId}, V2 attributes
%%   engine_forkchoiceUpdatedV3          {payloadStatus, payloadId}, V3 attributes
%%   engine_getPayloadV1                 ExecutionPayloadV1
%%   engine_getPayloadV2                 {executionPayload, blockValue}
%%   engine_getPayloadV3                 + blobsBundle, shouldOverrideBuilder
%%   engine_exchangeTransitionConfigurationV1  TransitionConfigurationV1
%%
%% Only the V1 row of each pair existed. A post-Merge consensus client calls the V3
%% methods, so every call it made was answered `-32601 method not found'. The
%% version is threaded through as an integer because the differences between
%% versions are not one response shape: each version changes the parameter check,
%% the structure the payload must carry, the statuses the response may carry, and
%% the shape of the result. Handling them as one method with a version tag is what
%% keeps those four axes from drifting apart.
%%
%% Every one of these handlers used to match the *string* "VALID" (and the
%% strings "SYNCING", "INVALID", "SECURITY_ERROR") against return values that are
%% binaries, and to return a bare status string where the specification has an
%% object. So forkchoiceUpdated and exchangeTransitionConfiguration matched none
%% of their clauses and raised a case_clause, and newPayload answered with a
%% `payloadId' the specification does not put in that response at all. A handler
%% whose clauses cannot match its callee returns a crash, not an answer, and
%% nothing called it.
%% All four methods take their arguments positionally: the specification lists
%% newPayload's ExecutionPayloadV1, forkchoiceUpdated's forkchoiceState and
%% payloadAttributes, getPayload's payloadId, and the transition configuration,
%% each as params[n]. Three of these handlers read them as objects with named
%% keys instead -- `#{<<"payload">> := P}' -- so every well-formed request was
%% answered `invalid params'. That is why the engine needed no payload decoder to
%% be visibly broken: it never got as far as needing one.
%% The version/fork gates, in the order the specification lists them: the
%% structure check, then the fork frame. Both answer with a JSON-RPC error, not a
%% payload status, and eth_engine owns the decision so it can be tested without an
%% HTTP server in the way.
admit_payload(Payload, Version, Id) ->
    case eth_engine:payload_admission(Payload, Version) of
        ok -> proceed;
        {error, Code, Message} -> {admission_error, Code, Message, Id}
    end.

admit_attributes(Attributes, Version, Id) ->
    case eth_engine:attributes_admission(Attributes, Version) of
        ok -> proceed;
        {error, Code, Message} -> {admission_error, Code, Message, Id}
    end.

handle_new_payload(Map, _State, Id, Version) ->
    case param(Map, 0) of
        P when is_map(P) ->
            case admit_payload(P, Version, Id) of
                {admission_error, Code, Message, Id2} ->
                    error_rpc(Id2, Code, Message);
                proceed ->
                    new_payload_reply(P, Id, Version)
            end;
        _ ->
            invalid_params(Id)
    end.

%% newPayloadV3 takes three parameters, and only the first is the payload
%% (execution-apis src/engine/cancun.md, engine_newPayloadV3, Request):
%%
%%   2. `expectedBlobVersionedHashes': Array of DATA, 32 Bytes
%%   3. `parentBeaconBlockRoot': DATA, 32 Bytes
%%
%% The second is checked before the payload is executed, and "in all cases even
%% during active sync process" -- see eth_engine:blob_hashes_admission/2 for why
%% that ordering is the whole point. The third is validated as DATA and otherwise
%% only carried: this node does not commit a beacon root it has not checked, and
%% the header field belongs to the block-processing path, not to admission.
handle_new_payload_v3(Map, _State, Id) ->
    case param(Map, 0) of
        P when is_map(P) ->
            case parent_beacon_root_admission(param(Map, 2)) of
                {error, Code, Message} ->
                    error_rpc(Id, Code, Message);
                ok ->
                    case admit_payload(P, 3, Id) of
                        {admission_error, Code2, Message2, Id2} ->
                            error_rpc(Id2, Code2, Message2);
                        proceed ->
                            blob_hashes_reply(P, param(Map, 1), Id)
                    end
            end;
        _ ->
            invalid_params(Id)
    end.

%% "Any field having `null' value MUST be considered as not provided" -- so a null
%% parentBeaconBlockRoot is a missing parameter, which is -32602 and not -38005.
%%
%% DATA is accepted in both the wire form (0x-prefixed hex) and as the 32 raw bytes
%% it denotes, via eth_engine:data32/1 -- the module's one DATA reader. Writing a
%% second decoder here is what made the first version of this check reject every
%% well-formed value: eth_hex:decode/1 returns an integer, so that decoder could
%% never produce the 32 bytes it was testing for, and a well-formed
%% <<0:256>> parentBeaconBlockRoot drew -32602.
parent_beacon_root_admission(null) -> {error, -32602, <<"invalid params">>};
parent_beacon_root_admission(undefined) -> {error, -32602, <<"invalid params">>};
parent_beacon_root_admission(Root) when is_binary(Root) ->
    case eth_engine:data32(Root) of
        {ok, Bytes} when byte_size(Bytes) =:= 32 -> ok;
        {ok, _Other} -> {error, -32602, <<"invalid params">>};
        {error, _} -> {error, -32602, <<"invalid params">>}
    end;
parent_beacon_root_admission(_Root) -> {error, -32602, <<"invalid params">>}.

%% The blob hash check's own answer, before the state-dependent path. A mismatch is
%% INVALID and is reported as such. An *undeterminable* actual array is not
%% INVALID: it means this node could not read the payload's transactions, which is a
%% statement about the node and not a verdict on the payload, so it is logged and
%% the payload proceeds to the ordinary path. Reporting it INVALID would be
%% indistinguishable from a real mismatch to the client, and reporting it VALID
%% would be a commitment this node has not earned.
blob_hashes_reply(Payload, Expected, Id) ->
    case eth_engine:blob_hashes_admission(Payload, Expected) of
        ok ->
            new_payload_reply(Payload, Id, 3);
        {invalid, ExpectedHashes, ActualHashes} ->
            ok(Id, payload_status(?INVALID, null,
                                  blob_hashes_mismatch(ExpectedHashes,
                                                       ActualHashes)));
        {unchecked, Reason} ->
            logger:info("etherlang: engine newPayloadV3 blob hashes unchecked: ~p",
                        [Reason]),
            new_payload_reply(Payload, Id, 3)
    end.

new_payload_reply(Payload, Id, Version) ->
    case eth_engine:new_payload(Payload) of
        Status when is_binary(Status) ->
            ok(Id, payload_status(
                   eth_engine:status_for_version(Status, Version), null, null));
        {Status, Reason} when is_binary(Status) ->
            Mapped = eth_engine:status_for_version(Status, Version),
            ok(Id, payload_status(Mapped, null, validation_error(Mapped, Reason)))
    end.

handle_forkchoice_updated(Map, _State, Id, Version) ->
    case param(Map, 0) of
        ForkChoice when is_map(ForkChoice) ->
            %% payloadAttributes is params[1] and is `Object|null'. The
            %% specification's checks run over it whether or not it is null, and
            %% for V2 and V3 they are what distinguish those methods from V1.
            case admit_attributes(param(Map, 1), Version, Id) of
                {admission_error, Code, Message, Id2} ->
                    error_rpc(Id2, Code, Message);
                proceed ->
                    forkchoice_reply(ForkChoice, Id)
            end;
        _ ->
            invalid_params(Id)
    end.

forkchoice_reply(ForkChoice, Id) ->
    case eth_engine:forkchoice_updated(ForkChoice) of
        Status when is_binary(Status) ->
            ok(Id, #{
                <<"payloadStatus">> => payload_status(Status, null, null),
                <<"payloadId">> => null
            });
        {error, Reason} ->
            %% -38002 is the specification's code for a forkchoiceState that is
            %% invalid or inconsistent.
            error_rpc(Id, -38002, message(Reason))
    end.

%% The result of getPayload changes shape with the version:
%%
%%   V1  ExecutionPayloadV1
%%   V2  {executionPayload, blockValue}
%%   V3  {executionPayload, blockValue, blobsBundle, shouldOverrideBuilder}
%%
%% from execution-apis src/engine/shanghai.md engine_getPayloadV2 and
%% src/engine/cancun.md engine_getPayloadV3. Returning V1's bare payload from a V2
%% method is not a shape the client can read: it destructures an object and finds
%% no executionPayload, which it cannot distinguish from a node that answered
%% wrongly.
handle_get_payload(Map, Id, Version) ->
    %% The specification passes the 8-byte build-process id as params[0]. This
    %% handler took no params at all and returned whatever the client had last
    %% sent to newPayload.
    case param(Map, 0) of
        PayloadId when is_binary(PayloadId) ->
            case eth_engine:get_payload(PayloadId) of
                {payload, Payload} -> ok(Id, get_payload_result(Payload, Version));
                {error, Reason} ->
                    %% -38001 is the specification's code for an unknown payload.
                    error_rpc(Id, -38001, message(Reason))
            end;
        _ ->
            invalid_params(Id)
    end.

get_payload_result(Payload, 1) -> Payload;
get_payload_result(Payload, 2) ->
    #{<<"executionPayload">> => Payload,
      %% `blockValue' is "The expected value to be received by the feeRecipient in
      %% wei". This node issues no payloadIds (eth_block_builder is not started),
      %% so this branch is unreachable from a client and the value here is never a
      %% commitment to anything. It is written as 0 rather than omitted so the
      %% response has the shape the method's version requires, should the builder
      %% ever be started.
      <<"blockValue">> => <<"0x0">>};
get_payload_result(Payload, 3) ->
    (get_payload_result(Payload, 2))#{
      %% "The call MUST return blobsBundle with empty blobs, commitments and proofs
      %% if the payload doesn't contain any blob transactions." (cancun.md,
      %% engine_getPayloadV3 item 2.) An empty bundle is a true statement about a
      %% payload with no blob transactions, unlike a fabricated one carrying a
      %% commitment this node cannot compute -- see eth_kzg.
      <<"blobsBundle">> => #{
        <<"commitments">> => [],
        <<"proofs">> => [],
        <<"blobs">> => []
      },
      <<"shouldOverrideBuilder">> => false}.

handle_exchange_config(Map, _State, Id) ->
    case param(Map, 0) of
        Config when is_map(Config) ->
            case eth_engine:exchange_transition_config(Config) of
                {ok, Cfg} -> ok(Id, transition_configuration(Cfg));
                {error, Reason} -> error_rpc(Id, -32603, message(Reason))
            end;
        _ ->
            invalid_params(Id)
    end.

%% ---------------------------------------------------------------------------
%% Encoders
%% ---------------------------------------------------------------------------

%% The specification defines `validationError' as a message accompanying INVALID
%% or INVALID_BLOCK_HASH, and null for every other status. So a reason reported
%% alongside SYNCING is a local condition, not a verdict on the payload, and the
%% specification has no field to put it in -- it goes to the log instead, because
%% a client shown an error for a block it did nothing wrong is worse than one
%% shown nothing.
validation_error(?INVALID, Reason) -> message(Reason);
validation_error(?INVALID_BLOCK_HASH, Reason) -> message(Reason);
validation_error(_Status, Reason) ->
    logger:info("etherlang: engine new_payload ~s: ~p", [_Status, Reason]),
    null.

%% PayloadStatusV1: status, latestValidHash (DATA|null), validationError
%% (String|null).
payload_status(Status, LatestValidHash, ValidationError) ->
    #{<<"status">> => Status,
      <<"latestValidHash">> => LatestValidHash,
      <<"validationError">> => ValidationError}.

%% TransitionConfigurationV1: two QUANTITYs and a DATA. Quantities are encoded
%% as minimal lowercase hex with no leading zeros, and DATA is fixed-width.
transition_configuration(#{terminal_total_difficulty := TTD,
                            terminal_block_hash := TBH,
                            terminal_block_number := TBN}) ->
    #{<<"terminalTotalDifficulty">> => eth_hex:encode_int(TTD),
      <<"terminalBlockHash">> => data_or_null(TBH),
      <<"terminalBlockNumber">> => eth_hex:encode_int(TBN)}.

data_or_null(undefined) -> null;
data_or_null(Bytes) when is_binary(Bytes), byte_size(Bytes) =:= 32 ->
    <<"0x", (binary:encode_hex(Bytes))/binary>>;
data_or_null(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).

%% The module reports reasons as atoms and tuples. A JSON-RPC error message is a
%% string, and thoas is not obliged to render an atom as one.
message(Reason) when is_binary(Reason) -> Reason;
message(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).

%% A blob-hash mismatch reported to a client, which is the one reason here that
%% is not an atom or a small tuple and so would come out of message/1 as a ~p dump
%% of two lists of 32-byte binaries: several hundred characters of decimal, with
%% the offending pair impossible to pick out. It names the count, the first
%% position that disagrees, and the first bytes of each side there, which is
%% enough for a client to identify which blob it got wrong.
%%
%% The hex is lowercase for the same reason eth_hex:encode_int/1 is: the rest of
%% the response is lowercase, and a client comparing hashes as text would not match
%% an uppercase rendering.
blob_hashes_mismatch(Expected, Actual) ->
    {Index, E, A} = first_disagreement(Expected, Actual, 1),
    iolist_to_binary(
      io_lib:format("blob versioned hashes do not match: expected ~b, got ~b; "
                    "first disagreement at index ~b: expected 0x~s, got 0x~s",
                    [length(Expected), length(Actual), Index,
                     short_hash(E), short_hash(A)])).

%% {Index, ExpectedSide, ActualSide}, where a side is `extra' or `missing' when one
%% array ran out before the other. All four length cases are spelled out because the
%% first version covered only the equal-head and prefix cases: a real Cancun
%% fixture with no blob transactions gives Expected of length 1 and Actual of
%% length 0, which matched no clause and raised function_clause inside the
%% request process -- so a client asking a legitimate question about a payload
%% with no blobs got a cowboy crash report instead of an answer.
first_disagreement([E | Es], [A | As], Index) when E =:= A ->
    first_disagreement(Es, As, Index + 1);
first_disagreement([E | _Es], [A | _As], Index) when E =/= A ->
    {Index, E, A};
first_disagreement([_E | _Es], [], Index) ->
    {Index, extra, missing};
first_disagreement([], [_A | _As], Index) ->
    {Index, missing, extra};
first_disagreement([], [], _Index) ->
    {0, none, none}.

%% The first eight hex nibbles, which is half a versioned hash: enough to tell two
%% mismatching entries apart in a log without printing all of them.
short_hash(missing) -> <<"(absent)">>;
short_hash(extra) -> <<"(unexpected)">>;
short_hash(none) -> <<"(none)">>;
short_hash(Bytes) when is_binary(Bytes), byte_size(Bytes) >= 4 ->
    <<(binary:encode_hex(binary:part(Bytes, 0, 4)))/binary, "...">>;
short_hash(Bytes) when is_binary(Bytes) -> binary:encode_hex(Bytes);
short_hash(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

%% params[n], or undefined.
param(Map, N) ->
    case maps:get(<<"params">>, Map, []) of
        Params when is_list(Params) ->
            case length(Params) > N of
                true -> lists:nth(N + 1, Params);
                false -> undefined
            end;
        _ ->
            undefined
    end.

ok(Id, Result) ->
    thoas:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"result">> => Result
    }).

invalid_params(Id) ->
    error_rpc(Id, -32602, <<"invalid params">>).

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

allowed(State, Req0) ->
    case maps:get(limits, State, undefined) of
        undefined -> true;
        #{tab := Tab, rate := Rate, burst := Burst} ->
            {IP, _} = cowboy_req:peer(Req0),
            eth_rate_limit:take(Tab, IP, Rate, Burst)
    end.

error_rpc(Id, Code, Msg) ->
    thoas:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"error">> => #{
            <<"code">> => Code,
            <<"message">> => Msg
        }
    }).
