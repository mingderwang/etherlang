-module(eth_rpc_client).

%% Minimal JSON-RPC 2.0 client over HTTPS using OTP's `httpc'.
%% Configuration is stored in a persistent_term entry, initialised once at
%% application start (or per test) via init/1. Transient failures (timeouts,
%% 5xx, 429) are retried with a small backoff.

-export([init/1, call/2]).

-record(cfg, {url = "", timeout_ms = 20000, retries = 3, backoff_ms = 1000}).

init(Cfg) ->
    persistent_term:put({?MODULE, cfg}, to_cfg(Cfg)),
    ok.

call(Method, Params) ->
    Cfg = cfg(),
    do_call(Method, Params, Cfg, Cfg#cfg.retries).

%% ---------------------------------------------------------------------------

cfg() ->
    persistent_term:get({?MODULE, cfg}, #cfg{}).

to_cfg(Cfg) ->
    #cfg{url = maps:get(url, Cfg, ""),
         timeout_ms = maps:get(timeout_ms, Cfg, 20000),
         retries = maps:get(retries, Cfg, 3),
         backoff_ms = maps:get(backoff_ms, Cfg, 1000)}.

do_call(Method, Params, Cfg, RetriesLeft) ->
    Body = thoas:encode(#{<<"jsonrpc">> => <<"2.0">>,
                          <<"id">> => erlang:unique_integer([positive]),
                          <<"method">> => Method,
                          <<"params">> => Params}),
    Headers = [{"content-type", "application/json"}],
    HttpOpts = [{timeout, Cfg#cfg.timeout_ms}, {connect_timeout, 5000}],
    R = case httpc:request(post,
                           {Cfg#cfg.url, Headers, "application/json", Body},
                           HttpOpts,
                           [{body_format, binary}]) of
            {ok, {{_, 200, _}, _, RespBin}} ->
                case thoas:decode(RespBin) of
                    {ok, #{<<"error">> := Err}} -> {error, {rpc_error, Err}};
                    {ok, #{<<"result">> := Result}} -> {ok, Result};
                    {error, DecErr} -> {error, {bad_decode, DecErr}};
                    _ -> {error, {bad_response, RespBin}}
                end;
            {ok, {{_, Code, _}, _, _}} when Code >= 500; Code =:= 429 ->
                {transient, {http, Code}};
            {ok, {{_, Code, _}, _, _}} ->
                {error, {http, Code}};
            {error, HTTPError} ->
                {transient, HTTPError}
        end,
    case R of
        {transient, _Why} when RetriesLeft > 0 ->
            timer:sleep(Cfg#cfg.backoff_ms * (Cfg#cfg.retries - RetriesLeft + 1)),
            do_call(Method, Params, Cfg, RetriesLeft - 1);
        {transient, Why} ->
            {error, Why};
        _ ->
            R
    end.