-module(etherlang_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(cowboy),
    eth_rpc_client:init(#{url => eth_config:upstream_url(),
                          timeout_ms => eth_config:http_timeout_ms(),
                          retries => 3,
                          backoff_ms => 1000}),
    etherlang_sup:start_link().

stop(_State) ->
    ok.