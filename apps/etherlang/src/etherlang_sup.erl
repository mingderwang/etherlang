-module(etherlang_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},

    Chain = #{id => eth_chain,
              start => {eth_chain, start_link, [eth_config:data_dir()]},
              restart => permanent,
              shutdown => 5000,
              type => worker,
              modules => [eth_chain]},

    Rpc = #{id => eth_rpc_server,
            start => {eth_rpc_server, start_link, [#{port => eth_config:listen_port()}]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [eth_rpc_server]},

    Sync = #{id => eth_sync,
             start => {eth_sync, start_link, [#{concurrency => eth_config:concurrency(),
                                                body_window => eth_config:body_window(),
                                                poll_interval_ms => eth_config:poll_interval_ms(),
                                                sync_retry_ms => eth_config:sync_retry_ms(),
                                                max_reorg_depth => eth_config:max_reorg_depth(),
                                                sync_budget => eth_config:sync_budget(),
                                                start_block => eth_config:start_block()}]},
             restart => permanent,
             shutdown => 5000,
             type => worker,
             modules => [eth_sync]},

    {ok, {SupFlags, [Chain, Rpc, Sync]}}.