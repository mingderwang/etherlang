-module(eth_config).

%% Runtime configuration for the node. Values are read from OS environment
%% variables first, then from the application environment, then defaults.
%% Environment variables (all optional):
%%   UPSTREAM_RPC_URL   - upstream Ethereum JSON-RPC endpoint
%%   RPC_LISTEN_PORT    - local JSON-RPC HTTP port
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

-export([upstream_url/0, listen_port/0, data_dir/0, start_block/0, concurrency/0,
         body_window/0, chain_retention/0, poll_interval_ms/0, sync_retry_ms/0,
         max_reorg_depth/0, http_timeout_ms/0, sync_budget/0, verify_headers/0,
         evm_enabled/0]).

-define(DEF_URL, "https://ethereum-sepolia-rpc.publicnode.com").
-define(DEF_PORT, 8545).
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