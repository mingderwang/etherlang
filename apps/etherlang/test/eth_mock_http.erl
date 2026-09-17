-module(eth_mock_http).

%% cowboy handler serving the mock node's JSON-RPC surface.

-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0, #{length => 50_000_000,
                                                            period => 30000}),
            Name = maps:get(name, State, eth_mock_node),
            Resp = serve(Name, Body),
            Req2 = cowboy_req:reply(200,
                                    #{<<"content-type">> => <<"application/json">>},
                                    Resp, Req1),
            {ok, Req2, State};
        _ ->
            Req1 = cowboy_req:reply(405, #{<<"allow">> => <<"POST">>},
                                    <<"method not allowed">>, Req0),
            {ok, Req1, State}
    end.

serve(Name, Body) ->
    case thoas:decode(Body) of
        {ok, Map} when is_map(Map) ->
            Id = maps:get(<<"id">>, Map, null),
            Method = maps:get(<<"method">>, Map, undefined),
            Params = maps:get(<<"params">>, Map, []),
            thoas:encode(respond(Name, Id, Method, Params));
        _ ->
            thoas:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => null,
                           <<"error">> => #{<<"code">> => -32700,
                                            <<"message">> => <<"parse error">>}})
    end.

respond(_Name, Id, undefined, _Params) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"error">> => #{<<"code">> => -32600, <<"message">> => <<"missing method">>}};
respond(Name, Id, Method, Params) ->
    case eth_mock_node:handle_rpc(Name, Method, Params) of
        {ok, Result} ->
            #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"result">> => Result};
        {error, {rpc_error, Err}} ->
            #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"error">> => Err};
        {error, Reason} ->
            #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
              <<"error">> => #{<<"code">> => -32000, <<"message">> => to_bin(Reason)}}
    end.

to_bin(T) when is_binary(T) -> T;
to_bin(T) when is_atom(T) -> atom_to_binary(T, utf8);
to_bin(T) -> unicode:characters_to_binary(io_lib:format("~p", [T])).