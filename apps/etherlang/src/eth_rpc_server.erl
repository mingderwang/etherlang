-module(eth_rpc_server).
-behaviour(gen_server).

%% Local JSON-RPC (HTTP) endpoint. Serves what the node actually holds
%% (head, blocks) and transparently proxies everything else to the upstream
%% node, so the endpoint is immediately usable and backwards compatible.
%%
%% Security posture (all configurable via env, see eth_config):
%%   - binds to 127.0.0.1 by default (RPC_LISTEN_IP to override),
%%   - caps the JSON-RPC batch size (RPC_MAX_BATCH),
%%   - token-bucket rate limit per source IP (RPC_RATE_LIMIT/RPC_RATE_BURST),
%%   - optional API key authentication (RPC_API_KEY).

-export([start_link/1, start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(st, {listener, tab}).

start_link(Opts) -> start_link(eth_rpc_server, Opts).
start_link(Name, Opts) when is_atom(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, Opts}, []).

init({Name, Opts}) ->
    Port = maps:get(port, Opts, 8545),
    IP = maps:get(listen_ip, Opts, eth_config:listen_ip()),
    Rate = maps:get(rate_limit, Opts, eth_config:rate_limit()),
    Burst = maps:get(rate_burst, Opts, eth_config:rate_burst()),
    MaxBatch = maps:get(max_batch, Opts, eth_config:max_batch()),
    Tab = eth_rate_limit:start(Rate, Burst),
    HandlerOpts = #{chain => maps:get(chain, Opts, eth_chain),
                    sync => maps:get(sync, Opts, eth_sync),
                    pool => maps:get(pool, Opts, eth_txpool),
                    store => maps:get(store, Opts, eth_statestore),
                    %% Carried for `/health' only, and named rather than hardcoded there
                    %% so that the trie probe has the same seam as the other three.
                    mpt => maps:get(mpt, Opts, eth_mpt),
                    max_batch => MaxBatch,
                    limits => #{tab => Tab, rate => Rate, burst => Burst},
                    api_key => eth_config:api_key()},
    %% `/health' and `/'. The **order does not matter**, and that was measured rather than
    %% assumed: reversing these two entries leaves `eth_health_tests' HTTP case green.
    %% The first draft of this comment claimed the opposite -- that `"/"' is a prefix
    %% catch-all which would shadow a `/health' route listed after it -- on the strength of
    %% what cowboy's routing is generally supposed to do. It is not, here: routes match
    %% exact paths, and any other path 404s, which the same test pins.
    %%
    %% So the risk is not reordering. It is changing `"/health'" into something that is
    %% *not* an exact path -- a prefix or a wildcard -- at which point it would begin
    %% answering requests meant for the JSON-RPC handler, and the endpoint would keep
    %% returning 200 while the RPC stopped working. `eth_health_tests` asks for a
    %% health-shaped body and a JSON-RPC envelope from the same port, which is the pair
    %% that catches that.
    Dispatch = cowboy_router:compile([{'_',
                                        [{"/health", eth_health_handler, HandlerOpts},
                                         {"/", eth_rpc_handler, HandlerOpts}]}]),
    case cowboy:start_clear(Name, [{port, Port}, {ip, IP}],
                            #{env => #{dispatch => Dispatch}}) of
        {ok, _} ->
            logger:notice("etherlang: JSON-RPC listening on ~s:~p (batch<=~p, rate ~p/s burst ~p, api_key=~s)",
                          [inet:ntoa(IP), Port, MaxBatch, Rate, Burst,
                           case eth_config:api_key() of
                               "" -> "disabled";
                               _ -> "set"
                           end]),
            %% Start Engine API on separate port
            EnginePort = case eth_config:engine_port() of
                             0 -> 8551;
                             P -> P
                         end,
            %% Propagated, and the failure is fatal. This used to log the error and
            %% return `ok', and `init/1' ignored the answer anyway, so a node whose
            %% Engine API port was already taken came up **reporting success** with the
            %% Engine API silently absent. Everything else in this `case' treats a
            %% listener failure as `{stop, Reason}', and a consensus client that cannot
            %% reach the Engine API does not degrade — it fails the node, a slot later,
            %% with a connection refusal the operator has to correlate back to one log
            %% line among the startup noise.
            %%
            %% Note what this does *not* change: a node with no JWT secret still
            %% starts, because that is a 503 from the handler, not a listener failure.
            %% Refusing to serve is the point of that scheme; refusing to boot would be
            %% a different and much worse answer to it.
            case start_engine_api(EnginePort, HandlerOpts) of
                ok ->
                    {ok, #st{listener = Name, tab = Tab}};
                {error, EngineReason} ->
                    _ = try cowboy:stop_listener(Name) catch _:_ -> ok end,
                    {stop, {engine_api, EngineReason}}
            end;
        {error, Reason} ->
            {stop, Reason}
    end.

%% ---------------------------------------------------------------------------
%% Engine API listener
%% ---------------------------------------------------------------------------

start_engine_api(Port, HandlerOpts) ->
    EngineDispatch = cowboy_router:compile([{'_',
        [{<<"/engine">>, eth_engine_handler, HandlerOpts}]}]),
    case cowboy:start_clear(engine_listener,
                            [{port, Port}, {ip, eth_config:listen_ip()}],
                            #{env => #{dispatch => EngineDispatch}}) of
        {ok, _} ->
            logger:notice("etherlang: Engine API listening on ~s:~p",
                          [inet:ntoa(eth_config:listen_ip()), Port]),
            ok;
        {error, Reason} ->
            logger:error("etherlang: Engine API failed to start: ~p", [Reason]),
            {error, Reason}
    end.

handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.
handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, #st{listener = L, tab = Tab}) ->
    _ = try cowboy:stop_listener(L) catch _:_ -> ok end,
    _ = try eth_rate_limit:stop(Tab) catch _:_ -> ok end,
    _ = try cowboy:stop_listener(engine_listener) catch _:_ -> ok end,
    ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.
