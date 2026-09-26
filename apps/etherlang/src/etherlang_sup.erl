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

    %% Owns the eth_state_cache ETS table. Without this child the table was
    %% created on first use by a short-lived request handler that owned it;
    %% when that request finished, concurrent requests crashed on insert to
    %% the dead table, killing their HTTP connections (and crash-looping the
    %% EthStats agents downstream).
    State = #{id => eth_state,
              start => {eth_state, start_link, []},
              restart => permanent,
              shutdown => 5000,
              type => worker,
              modules => [eth_state]},

    %% eth_engine was listed in the .app.src `registered' list -- a declaration
    %% that a process is running -- but was not a child here, so nothing ever
    %% started it. The /engine listener that eth_rpc_server mounts answered every
    %% method from a gen_server that did not exist: `whereis(eth_engine)' was
    %% undefined, so newPayload and forkchoiceUpdated returned SYNCING and
    %% getPayload and exchangeTransitionConfiguration returned an error. The
    %% methods were reachable over HTTP and none of them had a backend.
    %%
    %% Started before eth_rpc_server so the secret exists before the port that
    %% authenticates against it is listening.
    Engine = #{id => eth_engine,
               start => {eth_engine, start_link,
                         [#{data_dir => eth_config:data_dir()}]},
               restart => permanent,
               shutdown => 5000,
               type => worker,
               modules => [eth_engine]},

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

    %% Experimental devp2p stack. Disabled by default; when enabled both
    %% children share one persisted static node key (DATA_DIR/nodekey) so
    %% the enode URL stays stable across restarts. Discovery only fills a
    %% routing table for now and RLPx only speaks p2p Hello/Ping/Pong
    %% (no eth capability / peer fetch yet); RPC sync is unchanged.
    NodeKey = eth_nodekey:load_or_generate(eth_config:data_dir()),
    Disc = case eth_config:discv4_enabled() of
               true ->
                   [#{id => eth_discv4,
                      start => {eth_discv4, start_link,
                                [#{port => eth_config:discv4_port(),
                                   bootnodes => eth_config:discv4_bootnodes(),
                                   privkey => NodeKey}]},
                      restart => permanent,
                      shutdown => 5000,
                      type => worker,
                      modules => [eth_discv4]}];
               false ->
                   []
           end,
    Peer = case eth_config:rlpx_enabled() of
               true ->
                   DiscName = case eth_config:discv4_enabled() of
                                  true -> eth_discv4;
                                  false -> undefined
                              end,
                   [#{id => eth_peer,
                      start => {eth_peer, start_link,
                                [#{port => eth_config:rlpx_port(),
                                   privkey => NodeKey,
                                   disc => DiscName,
                                   target => eth_config:peer_target(),
                                   interval => eth_config:peer_dial_interval()}]},
                      restart => permanent,
                      shutdown => 5000,
                      type => worker,
                      modules => [eth_peer]}];
               false ->
                   []
           end,

    Pool = #{id => eth_txpool,
             start => {eth_txpool, start_link, [#{max => eth_config:tx_pool_max(),
                                                  per_sender => eth_config:tx_pool_per_sender()}]},
             restart => permanent,
             shutdown => 5000,
             type => worker,
             modules => [eth_txpool]},

    Store = #{id => eth_statestore,
              start => {eth_statestore, start_link, [#{dir => eth_config:data_dir()}]},
              restart => permanent,
              shutdown => 5000,
              type => worker,
              modules => [eth_statestore]},

    StateSync = case eth_config:state_sync_enabled() of
                    true ->
                        [#{id => eth_statesync,
                           start => {eth_statesync, start_link, [#{}]},
                           restart => permanent,
                           shutdown => 5000,
                           type => worker,
                           modules => [eth_statesync]}];
                    false ->
                        []
                end,

    {ok, {SupFlags, [State, Chain, Engine, Rpc, Sync, Pool, Store] ++ Disc ++ Peer ++ StateSync}}.