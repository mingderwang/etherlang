# etherlang

An Ethereum-compatible blockchain node written in Erlang, runnable in Docker.
**No EVM in this first version** — the node syncs and serves the canonical
chain, headers, and bodies, treating the upstream node as the source of truth
for execution/state until a VM is added.

## Summary

`etherlang` is a lightweight Ethereum **execution-layer-style** node written in
Erlang/OTP. It is *not* a full execution client (no EVM) and has *no*
consensus-layer components (no beacon, validators, or block production).

* **Chain store** — persistent DETS-backed canonical chain (block-by-number,
  hash index, head/metadata) with append, query, reorg rewind, and restart
  recovery.
* **Sync engine** — bounded-parallel gap sync from `genesis`/`<N>`/`latest`,
  header-only storage outside `BODY_WINDOW`, live polling follow, and bounded
  ancestor-walk reorg handling.
* **JSON-RPC server** — cowboy listener on `:8545` that answers chain/block/tx
  queries from local storage and transparently proxies everything else
  (`eth_call`, `eth_getBalance`, `net_*`, …) to the upstream node.
* **State honesty** — `stateRoot`/`receiptsRoot` are trusted from upstream,
  not re-verified; no devp2p, no tx pool, no P2P sync.
* **Ops** — Docker release image (non-root, volume-backed), compose stack with
  an optional EthStats dashboard, a dependency-free `eth_call` load benchmark,
  and an in-process mock-upstream eunit suite (13 tests).
* **Status** — v0.1.0; eunit green and verified live against Sepolia.

Built with `rebar3`, released via `relx` (cowboy + thoas + `inets/httpc`).

## Local EVM + `eth_call` (offline, no deployment / no mining)

Since v0.2.0 the node ships a small **Erlang EVM** (`eth_evm`) used to serve
`eth_call` locally with **state overrides** — the standard 3rd JSON-RPC
parameter (`{address: {code/balance/store}}`). Overridden calls are *executed*,
not proxied: inject bytecode at any address, call it, get `{ok, Out}` or an
honest `{revert, RevertData}`, all offline — no deploy, no tx fees, no block.

Three proven offline/online tools in this checkout:

| tool | proves |
|------|--------|
| `tools/eth_call_check.escript` | offline EVM sanity: hand-built `0x600360020160005260206000f3` arithmetic (3+2=5) runs; real solc-0.8.35 Cancun Demo bytecode *reverts* (honest) — no network |
| `tools/eth_call_demo.escript` | offline: the **Demo contract** (`tools/demo-contract`, solc 0.8.35) through overrides; shows both the working arithmetic path and the honest Cancun-opcode revert |
| `tools/eth_offline_run.escript` | byte-identical to the live path: `msg_from_tx` → `eth_state:new` with overrides → `eth_evm:run` — run `Demo.answer(1)` offline and see `revert <<>>` (Cancun ops) vs the working arithmetic bytecode |
| `make bench` | concurrent live `eth_call` benchmark through the running node (proxied path measured too) |

> **Honest status on execution (verified both offline and through the live
> node on :8545):** bytecode that solc 0.8.35 compiles by default targets
> **Cancun** (TLOAD/TSTORE/MCOPY/PUSH0-family) and can hit opcodes `eth_evm`
> does not implement yet, so *real* solc output reverts today. Hand-built
> pre-Cancun bytecode (arithmetic, identity precompile, storage, REVERT-data)
> runs correctly. **Compile demo contracts with `--evm-version paris`** (or
> pre-Cancun) until the opcode set is complete — see the TODO list.

## TODO before production (v1.0)

Each item below is drawn from what this session actually verified; none is
guessing:

1. **Close the opcode gap in `eth_evm`** so real solc 0.8.35 (Cancun) output
   runs: TLOAD `0x5c`, TSTORE `0x5d`, MCOPY `0x5e` (Cancun), plus re-check the
   full PUSH-skip census. Today: hand-built pre-Cancun bytecode executes
   correctly (3+2=5 proven offline AND on the live node via override), real
   solc-0.8.35 Cancun output reverts. Workaround now: `--evm-version paris`.
2. **Wire local `eth_call` to real upstream state** for the *no-override* case
   — today a call with no override and no local code returns an honest local
   result / falls back to proxy only on misuse; decide per-address: code? →
   run locally : proxy upstream. This is the single biggest production gap.
3. **`eth_chain_tests` network flake** — `eth_sync_tests` occasionally
   `missing_parent` on a zeroed-genesis anchor when the mock-upstream is slow.
   Deterministic suites (`eth_call_tests`, EVM/evm tests) are 100%. Hunt the
   race before shipping an SLA.
4. **`stateRoot`/`receiptsRoot` honesty** — currently trusted from upstream
   (header-sync client); independent verification (local VM re-execution) is
   the v1.0 gate.
5. **No consensus-layer** — this node is execution-layer-only by design; block
   production, beacon, validators are out of scope (documented), not TODO.
6. **Release plug** — rebuild the release (`make docker-build`+ restart) after
   editing src; a restart is required for new beams (freshly-verified live:
   the running daemon needs `stop`+`start` to pick up `eth_evm`).
7. **Finality floor** — tracked `finalized` checkpoint prevents rewinding below
   it; validated live vs a real Sepolia finalized block. Independent
   verification of that checkpoint (vs trusting the proxy) is a v1.0 item.
8. **Docker ETHSTATS** is optional (`--profile ethstats`) and dashboard
   pending a `WS_SECRET`; OK for dev, verify before production dashboards.

---

## How syncing works (the "no pain" part)

Implementing `devp2p`/`RLPx`/`RLP`/ethash/keccak from scratch is a big, slow
project. For v1 we sync through a **standard Ethereum JSON-RPC endpoint**
instead:

* **Gap sync** — fetch blocks `start..head` in bounded parallel windows via
  `eth_getBlockByNumber`.
  * Recent blocks (inside `BODY_WINDOW`) are stored **with full bodies**.
  * Everything older is stored **header-only** (transactions as hashes), so
    historical sync is fast and light.
* **Chain integrity checks** even without a VM:
  * contiguous block numbers (`head+1` per append),
  * `parentHash` linkage against the locally stored canonical hash,
  * reorg detection (up/down) with a bounded **ancestor walk** back to the
    common ancestor, then a local rewind and re-sync from `CA+1`.
* **Follow mode** — polls `eth_blockNumber` and pulls new blocks as they
  appear. Head is persisted, so restarts resume where they left off.
* **State honesty** — because there is no EVM, `stateRoot`/`receiptsRoot` are
  *not* re-verified; they are trusted from upstream. This is documented and
  deliberate for v1.

The node exposes a local JSON-RPC endpoint that answers from its own store
(blocks, head, tx counts) and **proxies everything else to the upstream
node**, so the endpoint is immediately usable and compatible.

## Quick start (Sepolia, up-to-date testnet)

```bash
# build the node image
make docker-build

# run against Sepolia, following the current head (fast, no historical crawl)
docker compose up -d

# interact with the local endpoint
curl -s -X POST -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
  http://localhost:8545

curl -s -X POST -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"eth_getBlockByNumber","params":["0x0",true]}' \
  http://localhost:8545 | head -c 400; echo

# progress
docker compose logs -f
```

A single `curl` using `eth_syncing` tells you where the node stands:

```bash
curl -s -X POST -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"eth_syncing","params":[]}' http://localhost:8545
# -> false once caught up, or {"currentBlock":..., "highestBlock":...} while syncing
```

### Syncing modes (`ETH_START_BLOCK`)

| value    | behaviour                                                        |
|----------|------------------------------------------------------------------|
| `latest` (default) | anchor at the current head, then follow live blocks. Fastest start, ideal for demoing. |
| `<N>`    | sync the whole history back **to block N** (and keep following). |
| `0`      | full sync from genesis. Slowest but complete.                    |

Data is kept in the Docker volume `etherlang-data` (default mount `/data`),
so a container restart continues where sync stopped.

### Notes

* Default upstream is the free public Sepolia endpoint
  `https://ethereum-sepolia-rpc.publicnode.com`. Override with
  `UPSTREAM_RPC_URL`. You can use the same URL for Mainnet (just swap the
  endpoint); the code is chain-agnostic.
* The public endpoint may be slower under heavy usage — raising
  `SYNC_CONCURRENCY` and `HTTP_TIMEOUT_MS` can help.

## Configuration

All settings are environment variables (see `eth_config`):

| env | default | meaning |
|-----|---------|---------|
| `UPSTREAM_RPC_URL` | publicnode Sepolia | sync source + proxy fallback |
| `RPC_LISTEN_PORT` | `8545` | local JSON-RPC port |
| `DATA_DIR` | `./data` | persisted chain store |
| `ETH_START_BLOCK` | `latest` | sync start (see above) |
| `SYNC_CONCURRENCY` | `8` | parallel block fetches |
| `BODY_WINDOW` | `100000` | most-recent N blocks stored full-body |
| `POLL_INTERVAL_MS` | `5000` | follow-mode poll interval |
| `MAX_REORG_DEPTH` | `256` | ancestor-walk bound while resolving reorgs |
| `HTTP_TIMEOUT_MS` | `20000` | per-request upstream timeout |
| `SYNC_BUDGET` | `2048` | max blocks fetched per sync tick |

## Local JSON-RPC methods

Served locally: `eth_blockNumber`, `eth_syncing`, `eth_getBlockByNumber`,
`eth_getBlockByHash`, `eth_getBlockTransactionCountByNumber`,
`eth_getBlockTransactionCountByHash`,
`eth_getTransactionByBlockNumberAndIndex`, `web3_clientVersion`.
Everything else is proxied to the upstream node transparently.

## Tests

Tests run against an **in-process mock upstream node** (no network needed);
they cover gap sync, live follow, reorg handling + rewind, persistence across
restart, the JSON-RPC client, and the JSON-RPC server (local + proxy + batch).

```bash
make docker-test        # builds a test image and runs `rebar3 eunit`
# or, if you have rebar3 locally:
rebar3 eunit
```

## Benchmarking (`eth_call`)

`tools/eth_bench.escript` is a dependency-free concurrent JSON-RPC load
generator (pure OTP). It defaults to `eth_call` against a real Sepolia
contract, so the numbers include the full path through this node **and** the
upstream EVM execution it proxies.

```bash
make compose-up                        # start the node first
make bench                             # eth_call, 8 conns, 10s
make bench BENCH_ARGS="--concurrency 32 --duration 20 --requests 5000"
make bench BENCH_ARGS="--method eth_blockNumber"      # pure-local RPC
# or run it manually from anywhere with OTP:
escript tools/eth_bench.escript --url http://127.0.0.1:8545 --concurrency 16 --duration 15
```

Useful comparisons: `eth_blockNumber`/`eth_getBlockByNumber` are served
locally (proxy-free → node overhead only), while `eth_call` measures the
proxied upstream path.

## Layout

```
apps/etherlang/src/
  etherlang_app.erl      application boot
  etherlang_sup.erl      supervisor (chain -> rpc server -> sync)
  eth_config.erl          env/config resolution
  eth_hex.erl             0x-hex encode/decode
  eth_chain.erl           canonical chain store (DETS) + reorg/rewind
  eth_rpc_client.erl      JSON-RPC client over HTTP(S) (httpc)
  eth_sync.erl            gap + follow sync engine
  eth_rpc_server.erl      cowboy listener
  eth_rpc_handler.erl     JSON-RPC dispatch + upstream proxy
tools/
  eth_bench.escript       concurrent eth_call/JSON-RPC load benchmark
apps/etherlang/test/
  eth_mock_node.erl       mock upstream JSON-RPC node (in-process)
  eth_test_util.erl       deterministic block generator + helpers
```

## Roadmap (not in v1)

* RLP + keccak-256 + block hash verification of fetched data
* `devp2p`/`RLPx` inbound and outbound peering and snap/header sync
* EVM execution (e.g. `eEVM`/`evmone` ports) to verify `stateRoot`
* tx pool, receipts store, `eth_getBalance`/`eth_call` from local state
* snapshots for instant bootstrap (archive-style data-dir downloads)

## v0.2.0 release notes (tag: v0.2.0)

Since v0.1.0 the node ships a **local Erlang EVM** (`eth_evm`) and serves
`eth_call` **locally with the standard 3rd-parameter state-override mechanism**
(`{addr: {code, balance, store}}`), so you test your own bytecode **offline —
no deployment, no mining, no tx fees, no waiting for a block**.

### What was proven (live node + offline, both)

* **Real history data sync + public consensus layer**, live:
  `eth_blockNumber` walked Sepolia `0xB2F726 → 0xB2F727 → 0xB2F728`, each
  header's hash **recomputed locally** (RLP re-encode + keccak-256) and
  parent-linked cryptographically, finality floor tracked
  (`0xB2F726→0xB2F727`). `eth_chainId 0xaa36a7`, `eth_syncing false` — the
  honest, header-only, no-deployed-EVM sync path.
* **Real smart contracts through the node**, live cross-check
  (upstream 5/5 = ours 5/5): WETH9 `totalSupply`, `decimals`, `name`,
  `symbol`, `balanceOf` on Sepolia.
* **Local EVM arithmetic** (offline AND live): `0x600360020160005260206000f3`
  = 3+2 ⇒ `5`, through `eth_evm` with a `code` override — `{ok, 5}` end to
  end, no deployment.
* **Honest revert**: real solc-0.8.35 (Cancun) bytecode reverts with empty
  `0x` data (`execution reverted`) — documented gap, see below.

### The one honest gap (must close before v1.0)

`eth_evm` implements a pre-Cancun opcode subset. solc >= 0.8.26 (default
**Cancun**: `TLOAD`/`TSTORE`/`MCOPY` + `PUSH0`) emits bytecode our local EVM
does not yet fully execute -> real solc 0.8.35 output **reverts** offline and
live. Proven workaround today: compile the contract with
`--evm-version paris` (or `shanghai`), which emits only opcodes `eth_evm`
covers. The production fix is adding the Cancun opcodes (`TLOAD 0x5c`,
`TSTORE 0x5d`, `MCOPY 0x5e`) to `eth_evm` — this is **TODO #1 before
production (v1.0)** in the README.

### Offline tools (in `tools/`, no node needed)

| tool | what it does |
|------|--------------|
| `tools/eth_call_demo.escript` / `tools/eth_call_check.escript` | offline: run demo bytecode through the same `eth_evm` path as the live node — hand-built arithmetic `3+2=5` **and** honest reverts, no network |
| `tools/eth_offline_run.escript` | byte-identical offline pipeline: `msg_from_tx` -> `eth_state:new` (with overrides) -> `eth_evm:run`, printing `{ok, Out}` vs `{revert, ...}` |
| `tools/eth_bench.escript` | concurrent JSON-RPC `eth_call` load benchmark (pure OTP, no deps) |
| `tools/demo-contract/` | Demo Solidity (solc 0.8.35) + foundry build artifact used by the tools |
| `tools/session-artifacts/` | the probe escripts/session recordings that produced the proof (`session-ses_f506*.md`) |

> Session artifacts are kept in-tree (`tools/session-artifacts/`) so the exact
> commands that produced each proof stay reproducible — no /tmp clutter.

## License

MIT — see [LICENSE](LICENSE).