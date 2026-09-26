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
                    handle_new_payload(Map, State, Id);
                <<"engine_forkchoiceUpdatedV1">> ->
                    handle_forkchoice_updated(Map, State, Id);
                <<"engine_getPayloadV1">> ->
                    handle_get_payload(Map, Id);
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

%% The response shapes below follow the engine API specification
%% (execution-apis, src/engine/paris.md):
%%
%%   engine_newPayloadV1                      result: PayloadStatusV1
%%   engine_forkchoiceUpdatedV1               result: {payloadStatus, payloadId}
%%   engine_getPayloadV1                      result: ExecutionPayloadV1
%%   engine_exchangeTransitionConfigurationV1 result: TransitionConfigurationV1
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
handle_new_payload(Map, _State, Id) ->
    case param(Map, 0) of
        P when is_map(P) ->
            case eth_engine:new_payload(P) of
                Status when is_binary(Status) ->
                    ok(Id, payload_status(Status, null, null));
                {Status, Reason} when is_binary(Status) ->
                    %% validationError is populated only for the INVALID statuses;
                    %% the specification has it null otherwise.
                    ok(Id, payload_status(Status, null, message(Reason)))
            end;
        _ ->
            invalid_params(Id)
    end.

handle_forkchoice_updated(Map, _State, Id) ->
    case param(Map, 0) of
        ForkChoice when is_map(ForkChoice) -> forkchoice_reply(ForkChoice, Id);
        _ -> invalid_params(Id)
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

handle_get_payload(Map, Id) ->
    %% The specification passes the 8-byte build-process id as params[0]. This
    %% handler took no params at all and returned whatever the client had last
    %% sent to newPayload.
    case param(Map, 0) of
        PayloadId when is_binary(PayloadId) ->
            case eth_engine:get_payload(PayloadId) of
                {payload, Payload} -> ok(Id, Payload);
                {error, Reason} ->
                    %% -38001 is the specification's code for an unknown payload.
                    error_rpc(Id, -38001, message(Reason))
            end;
        _ ->
            invalid_params(Id)
    end.

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

%% PayloadStatusV1: status, latestValidHash (DATA|null), validationError
%% (String|null). The specification defines validationError as a message
%% accompanying INVALID or INVALID_BLOCK_HASH, and null for every other status.
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
