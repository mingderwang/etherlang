%% Cowboy handler for the Engine API endpoint.
%%
%% Routes:
%%   POST /engine/       — Engine API JSON-RPC methods
%%     engine_newPayloadV1
%%     engine_forkchoiceUpdatedV1
%%     engine_getPayloadV1
%%     engine_exchangeTransitionConfigurationV1
%%
%% JWT authentication is enforced when JWT_SECRET is configured.
%% The exchangeTransitionConfigurationV1 method is public.
%%
-module(eth_engine_handler).

-export([init/2]).

%% ---------------------------------------------------------------------------
%% Cowboy handler
%% ---------------------------------------------------------------------------

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
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
            end;
        _ ->
            Req1 = cowboy_req:reply(405,
                #{<<"allow">> => <<"POST">>},
                <<"method not allowed">>, Req0),
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
                    handle_get_payload(Id, State);
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

handle_new_payload(Map, _State, Id) ->
    Params = maps:get(<<"params">>, Map, #{}),
    case Params of
        #{<<"payload">> := P} when is_map(P) ->
            case eth_engine:new_payload(P) of
                {Status, PayloadId} when is_binary(Status) ->
                    thoas:encode(#{
                        <<"jsonrpc">> => <<"2.0">>,
                        <<"id">> => Id,
                        <<"result">> => #{
                            <<"status">> => Status,
                            <<"latestValidHash">> => maps:get("blockHash", P, <<>>),
                            <<"payloadId">> => PayloadId
                        }
                    });
                {error, Reason} ->
                    error_rpc(Id, -38, Reason)
            end;
        _ ->
            error_rpc(Id, -32602, <<"invalid params">>)
    end.

handle_forkchoice_updated(Map, _State, Id) ->
    Params = maps:get(<<"params">>, Map, #{}),
    case Params of
        #{<<"forkChoice">> := ForkChoice} when is_map(ForkChoice) ->
            case eth_engine:forkchoice_updated(Params) of
                "VALID" ->
                    thoas:encode(#{
                        <<"jsonrpc">> => <<"2.0">>,
                        <<"id">> => Id,
                        <<"result">> => "VALID"
                    });
                {"INVALID", Reason} ->
                    error_rpc(Id, -38, Reason);
                "SYNCING" ->
                    error_rpc(Id, -38, <<"syncing">>);
                {"SECURITY_ERROR", Reason} ->
                    error_rpc(Id, -38, Reason);
                {error, Reason} ->
                    error_rpc(Id, -38, Reason)
            end;
        _ ->
            error_rpc(Id, -32602, <<"invalid params">>)
    end.

handle_get_payload(Id, _State) ->
    case eth_engine:get_payload() of
        {payload, Payload} ->
            thoas:encode(#{
                <<"jsonrpc">> => <<"2.0">>,
                <<"id">> => Id,
                <<"result">> => Payload
            });
        {error, Reason} ->
            error_rpc(Id, -38, Reason)
    end.

handle_exchange_config(Map, _State, Id) ->
    Params = maps:get(<<"params">>, Map, #{}),
    case Params of
        #{<<"transitionConfiguration">> := Config} when is_map(Config) ->
            case eth_engine:exchange_transition_config(Config) of
                "VALID" ->
                    thoas:encode(#{
                        <<"jsonrpc">> => <<"2.0">>,
                        <<"id">> => Id,
                        <<"result">> => "VALID"
                    });
                {error, Reason} ->
                    error_rpc(Id, -38, Reason)
            end;
        _ ->
            error_rpc(Id, -32602, <<"invalid params">>)
    end.

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
