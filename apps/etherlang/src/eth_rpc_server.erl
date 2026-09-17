-module(eth_rpc_server).
-behaviour(gen_server).

%% Local JSON-RPC (HTTP) endpoint. Serves what the node actually holds
%% (head, blocks) and transparently proxies everything else to the upstream
%% node, so the endpoint is immediately usable and backwards compatible.

-export([start_link/1, start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(st, {listener}).

start_link(Opts) -> start_link(eth_rpc_server, Opts).
start_link(Name, Opts) when is_atom(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, Opts}, []).

init({Name, Opts}) ->
    Port = maps:get(port, Opts, 8545),
    HandlerOpts = #{chain => maps:get(chain, Opts, eth_chain),
                    sync => maps:get(sync, Opts, eth_sync)},
    Dispatch = cowboy_router:compile([{'_', [{"/", eth_rpc_handler, HandlerOpts}]}]),
    {ok, _} = cowboy:start_clear(Name,
                                 [{port, Port}, {ip, {0, 0, 0, 0}}],
                                 #{env => #{dispatch => Dispatch}}),
    logger:notice("etherlang: JSON-RPC listening on ~p", [Port]),
    {ok, #st{listener = Name}}.

handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.
handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, #st{listener = L}) ->
    catch cowboy:stop_listener(L),
    ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.