-module(eth_rpc_server).
-behaviour(gen_server).

%% Local JSON-RPC (HTTP) endpoint. Serves what the node actually holds
%% (head, blocks) and transparently proxies everything else to the upstream
%% node, so the endpoint is immediately usable and backwards compatible.
%%
%% Security posture (all configurable via env, see eth_config):
%%   - binds to 127.0.0.1 by default (RPC_LISTEN_IP to override),
%%   - caps the JSON-RPC batch size (RPC_MAX_BATCH),
%%   - token-bucket rate limit per source IP (RPC_RATE_LIMIT/RPC_RATE_BURST).

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
    Dispatch = cowboy_router:compile([{'_',
                                       [{"/", eth_rpc_handler,
                                         #{chain => maps:get(chain, Opts, eth_chain),
                                           sync => maps:get(sync, Opts, eth_sync),
                                           pool => maps:get(pool, Opts, eth_txpool),
                                           max_batch => MaxBatch,
                                           limits => #{tab => Tab, rate => Rate,
                                                       burst => Burst}}}]}]),
    case cowboy:start_clear(Name, [{port, Port}, {ip, IP}],
                            #{env => #{dispatch => Dispatch}}) of
        {ok, _} ->
            logger:notice("etherlang: JSON-RPC listening on ~s:~p (batch<=~p, rate ~p/s burst ~p)",
                          [inet:ntoa(IP), Port, MaxBatch, Rate, Burst]),
            {ok, #st{listener = Name, tab = Tab}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.
handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, #st{listener = L, tab = Tab}) ->
    _ = try cowboy:stop_listener(L) catch _:_ -> ok end,
    _ = try eth_rate_limit:stop(Tab) catch _:_ -> ok end,
    ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.