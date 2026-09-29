-module(eth_config).

-compile(nowarn_unused_function).

%% Runtime configuration for the node. Values are read from **OS environment
%% variables**, and from nothing else.
%%
%% **The application environment was never a source and is not one now.** This header said
%% "from OS environment variables first, then from the application environment, then
%% defaults" for as long as the sentence existed, and `str_env/3' is
%% `str_env(Env, _Key, Default)' with the key argument underscored and unused -- so the
%% second source it described was a fiction, and a reader checking a value in
%% `sys.config` would have found nothing there.
%%
%% A variable set to something unusable is answered with its **default**, silently, and
%% one that parses to a nonsense value is answered as written -- a negative retention
%% included. That is what `eth_config_settings:validate/0' is for, and
%% `etherlang_app:start/2' calls it and refuses to start on a problem.
%%
%% Environment variables (all optional):
%%   UPSTREAM_RPC_URL   - upstream Ethereum JSON-RPC endpoint
%%   RPC_LISTEN_PORT    - local JSON-RPC HTTP port
%%   RPC_LISTEN_IP      - interface to bind (default 127.0.0.1; 0.0.0.0 = all)
%%   RPC_MAX_BATCH      - max JSON-RPC batch size accepted
%%   RPC_RATE_LIMIT     - per-client request rate in req/sec (0 disables)
%%   RPC_RATE_BURST     - max burst of requests a client may send at once
%%   RPC_API_KEY        - API key required for RPC access (empty = disabled)
%%   DATA_DIR           - directory for persisted chain data (blocks, index)
%%   ETH_START_BLOCK    - where to start syncing: "latest" or a block number
%%   SYNC_CONCURRENCY   - max parallel block fetches
%%   BODY_WINDOW        - how many most-recent blocks to store with full bodies
%%   CHAIN_RETENTION    - max recent blocks kept in the local chain store;
%%                        older blocks are pruned (served from upstream instead)
%%   POLL_INTERVAL_MS   - follow-mode poll interval
%%   SYNC_RETRY_MS      - base backoff between fetch retries
%%   MAX_REORG_DEPTH    - ancestor walk limit when handling a reorg
%%   HTTP_TIMEOUT_MS    - per-request upstream timeout
%%   SYNC_BUDGET        - max blocks fetched per sync tick (progress granularity)
%%   VERIFY_HEADERS     - recompute RLP+keccak header hashes on append (default true)
%%   EVM_ETH_CALL       - serve eth_call locally via the built-in EVM (default true)
%%   DISCV4_ENABLED     - run the experimental discv4 UDP discovery server (default false)
%%   DISCV4_PORT        - UDP port for discv4 (default 30303)
%%   DISCV4_BOOTNODES   - comma-separated enode:// URLs used as discovery seeds
%%   RLPX_ENABLED       - run the experimental RLPx TCP listener/peers (default false)
%%   RLPX_PORT          - TCP port for RLPx (default 30303)
%%   PEER_TARGET        - desired peer count for auto-dial (default 10)
%%   PEER_DIAL_INTERVAL - ms between auto-dial maintenance ticks (default 10000)
%%   TX_POOL_MAX        - max pooled transactions (default 1024)
%%   TX_POOL_PER_SENDER - max pooled transactions per sender (default 16)
%%   STATE_SYNC_ENABLED - run the snap state-heal worker (default false)

-export([upstream_url/0, listen_port/0, listen_ip/0, max_batch/0, rate_limit/0,
         rate_burst/0, api_key/0, engine_port/0, data_dir/0, start_block/0, concurrency/0,
         body_window/0, chain_retention/0, poll_interval_ms/0, sync_retry_ms/0,
         max_reorg_depth/0, http_timeout_ms/0, sync_budget/0, verify_headers/0,
         evm_enabled/0, discv4_enabled/0, discv4_port/0, discv4_bootnodes/0,
         rlpx_enabled/0, rlpx_port/0, peer_target/0, peer_dial_interval/0,
         tx_pool_max/0, tx_pool_per_sender/0, state_sync_enabled/0]).

-define(DEF_URL, "https://ethereum-sepolia-rpc.publicnode.com").
-define(DEF_PORT, 8545).
-define(DEF_LISTEN_IP, "127.0.0.1").
-define(DEF_MAX_BATCH, 30).
-define(DEF_RATE_LIMIT, 30).
-define(DEF_RATE_BURST, 100).
-define(DEF_API_KEY, "").
-define(DEF_DATA_DIR, "./data").
-define(DEF_CONCURRENCY, 8).
-define(DEF_BODY_WINDOW, 2048).
-define(DEF_CHAIN_RETENTION, 2048).
-define(DEF_POLL_MS, 5000).
-define(DEF_RETRY_MS, 2000).
-define(DEF_MAX_REORG, 256).
-define(DEF_HTTP_TIMEOUT, 20000).
-define(DEF_BUDGET, 2048).

upstream_url() -> str_env("UPSTREAM_RPC_URL", upstream_url, ?DEF_URL).

listen_port() -> int_env("RPC_LISTEN_PORT", listen_port, ?DEF_PORT).

%% Bind address as an inet ip tuple. Defaults to loopback so the endpoint is
%% never exposed to the network unless the operator opts in via RPC_LISTEN_IP.
%% The guard that used to be here checked `A' alone:
%%
%%     {A, B, C, D} when is_integer(A), A >= 0, A =< 255 -> {A, B, C, D};
%%
%% which is the wrong half of an address. `1.999.1.1' passed it, and the tuple it
%% returned was one `inet:parse_address/1' answers `einval' for, so the malformed bind
%% reached the listener and failed there -- in `cowboy`'s start-up, as a listener error,
%% which says nothing about a configuration value. And the *other* half of the failure
%% was silent: `999.1.1.1' did not pass, so `listen_ip/0' answered loopback. An operator
%% who asked to expose the JSON-RPC and mistyped the address got a node that is not
%% reachable, and nothing anywhere said so.
%%
%% There is no guard now, because `eth_config_settings:ip4/1' has already decided
%% whether this is an address and answered a valid tuple or `error'. A second
%% implementation of that decision here is how the two halves disagreed in the first
%% place. The refusal for a value that is not an address is `validate/0', called by
%% `etherlang_app:start/2'.
listen_ip() ->
    case eth_config_settings:ip4(str_env("RPC_LISTEN_IP", listen_ip, ?DEF_LISTEN_IP)) of
        {ok, {A, B, C, D}} -> {A, B, C, D};
        error -> {127, 0, 0, 1}
    end.

max_batch() -> int_env("RPC_MAX_BATCH", max_batch, ?DEF_MAX_BATCH).

rate_limit() -> int_env("RPC_RATE_LIMIT", rate_limit, ?DEF_RATE_LIMIT).

rate_burst() -> int_env("RPC_RATE_BURST", rate_burst, ?DEF_RATE_BURST).

api_key() -> str_env("RPC_API_KEY", api_key, ?DEF_API_KEY).

engine_port() -> int_env("ENGINE_PORT", engine_port, 8551).

data_dir() -> str_env("DATA_DIR", data_dir, ?DEF_DATA_DIR).

start_block() ->
    case str_env("ETH_START_BLOCK", start_block, "latest") of
        "latest" -> latest;
        "0x" ++ _ -> parse_hex(str_env("ETH_START_BLOCK", start_block, "latest"));
        V ->
            case string:to_integer(V) of
                {N, ""} when N >= 0 -> N;
                _ -> latest
            end
    end.

concurrency() -> int_env("SYNC_CONCURRENCY", concurrency, ?DEF_CONCURRENCY).

body_window() -> int_env("BODY_WINDOW", body_window, ?DEF_BODY_WINDOW).

chain_retention() -> int_env("CHAIN_RETENTION", chain_retention, ?DEF_CHAIN_RETENTION).

poll_interval_ms() -> int_env("POLL_INTERVAL_MS", poll_interval_ms, ?DEF_POLL_MS).

sync_retry_ms() -> int_env("SYNC_RETRY_MS", sync_retry_ms, ?DEF_RETRY_MS).

max_reorg_depth() -> int_env("MAX_REORG_DEPTH", max_reorg_depth, ?DEF_MAX_REORG).

http_timeout_ms() -> int_env("HTTP_TIMEOUT_MS", http_timeout_ms, ?DEF_HTTP_TIMEOUT).

sync_budget() -> int_env("SYNC_BUDGET", sync_budget, ?DEF_BUDGET).

verify_headers() ->
    case string:lowercase(str_env("VERIFY_HEADERS", verify_headers, "true")) of
        "false" -> false;
        "0" -> false;
        "no" -> false;
        _ -> true
    end.

evm_enabled() ->
    case string:lowercase(str_env("EVM_ETH_CALL", evm_enabled, "true")) of
        "false" -> false;
        "0" -> false;
        "no" -> false;
        _ -> true
    end.

discv4_enabled() ->
    case string:lowercase(str_env("DISCV4_ENABLED", discv4_enabled, "false")) of
        "true" -> true;
        "1" -> true;
        "yes" -> true;
        _ -> false
    end.

discv4_port() -> int_env("DISCV4_PORT", discv4_port, 30303).

discv4_bootnodes() ->
    case str_env("DISCV4_BOOTNODES", discv4_bootnodes, "") of
        "" -> [];
        S -> [T || T <- [string:trim(X) || X <- string:split(S, ",", all)],
                   T =/= ""]
    end.

rlpx_enabled() ->
    case string:lowercase(str_env("RLPX_ENABLED", rlpx_enabled, "false")) of
        "true" -> true;
        "1" -> true;
        "yes" -> true;
        _ -> false
    end.

rlpx_port() -> int_env("RLPX_PORT", rlpx_port, 30303).

peer_target() -> int_env("PEER_TARGET", peer_target, 10).

peer_dial_interval() -> int_env("PEER_DIAL_INTERVAL", peer_dial_interval, 10000).

tx_pool_max() -> int_env("TX_POOL_MAX", tx_pool_max, 1024).

tx_pool_per_sender() -> int_env("TX_POOL_PER_SENDER", tx_pool_per_sender, 16).

state_sync_enabled() ->
    case string:lowercase(str_env("STATE_SYNC_ENABLED", state_sync_enabled, "false")) of
        "true" -> true;
        "1" -> true;
        "yes" -> true;
        _ -> false
    end.

str_env(Env, _Key, Default) ->
    case os:getenv(Env) of
        false -> Default;
        "" -> Default;
        V -> V
    end.

int_env(Env, Key, Default) ->
    case str_env(Env, Key, Default) of
        D when is_integer(D) -> D;
        Str ->
            case string:to_integer(Str) of
                {N, ""} -> N;
                _ -> Default
            end
    end.

parse_hex(Hex) ->
    try eth_hex:decode(Hex) catch _:_ -> latest end.

