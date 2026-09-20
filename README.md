# etherlang

An Ethereum-compatible blockchain node written in Erlang, runnable in Docker.
It syncs and serves the canonical chain (headers and bodies) and ships a
local **Erlang EVM** (`eth_evm`) that executes `eth_call` — with state
overrides — against lazily-fetched upstream state. No devp2p, no tx pool, no
block production: the upstream node remains the source of truth for consensus
and inclusion.

## Summary

`etherlang` is a lightweight Ethereum **execution-layer-style** node written in
Erlang/OTP. It is *not* a full execution client (state verification is
partial — see honesty notes) and has *no* consensus-layer components (no
beacon, validators, or block production).

* **Chain store** — persistent DETS-backed canonical chain (block-by-number,
  hash index, head/metadata) with append, query, reorg rewind, and restart
  recovery.
* **Sync engine** — bounded-parallel gap sync from `genesis`/`<N>`/`latest`,
  header-only storage outside `BODY_WINDOW`, live polling follow, bounded
  ancestor-walk reorg handling, and a monotonic `finalized` floor that never
  accepts checkpoints ahead of the local head or off the canonical chain.
* **Local EVM** — pure-Erlang interpreter covering the full defined opcode set
  including Cancun (`PUSH0`/`TLOAD`/`TSTORE`/`MCOPY`) plus precompiles
  `0x02`–`0x05`; serves `eth_call` locally with standard state overrides,
  proxying upstream on unsupported paths. Known fidelity simplifications are
  listed under TODO.
* **JSON-RPC server** — cowboy listener on `:8545` that answers chain/block/tx
  queries and `eth_call` from local storage + local execution, transparently
  proxying everything else (`eth_getBalance`, `net_*`, …) to upstream.
* **State honesty** — `stateRoot`/`receiptsRoot` are trusted from upstream,
  not re-executed; blocks served locally carry the Sepolia TTD as
  `totalDifficulty` when upstream omits it (post-merge constant, serve-time
  only — see `with_td_compat`).
* **Ops** — Docker release image (non-root, volume-backed), compose stack with
  an EthStats dashboard (two host nodes reporting live), a dependency-free
  `eth_call` load benchmark, a live Sepolia smoke-test script, and an
  in-process mock-upstream eunit suite (**57 tests, green**).
* **Status** — v0.2.6; eunit green and verified live against Sepolia.

Built with `rebar3`, released via `relx` (cowboy + thoas + `inets/httpc`).

## Local EVM + `eth_call` (offline, no deployment / no mining)

Since v0.2.0 the node ships a small **Erlang EVM** (`eth_evm`) used to serve
`eth_call` locally with **state overrides** — the standard 3rd JSON-RPC
parameter (`{address: {code/balance/store}}`). Overridden calls are *executed*,
not proxied: inject bytecode at any address, call it, get `{ok, Out}` or an
honest `{revert, RevertData}`, all offline — no deploy, no tx fees, no block.
Since v0.2.3 the opcode set covers everything solc emits up to Cancun
(`PUSH0`/`TLOAD`/`TSTORE`/`MCOPY` included, plus correct EIP-145 shift operand
order), and no-override calls execute against lazily-fetched upstream state
with proxy fallback on any unsupported path.

Proven end-to-end in this checkout (foundry + hardhat harnesses drive the
live node as their RPC):

| tool | proves |
|------|--------|
| `tools/foundry-test/` (`forge test` + `cast call --override-code`) | `Simple.answer()` = 42 identically in foundry's EVM and through `:8545`/`:8546`; `stored()` reads seeded state; `eth_call` contract-creation runs init code locally |
| `tools/hardhat-test/` (`hardhat run scripts/run-node-tests.ts`) | richer contract through the node: calldata arrays + loops (`sumSquares` = 77), keccak double-hash matching ethers, storage read/write via `stateDiff`, honest `require`-reverts |
| `tools/eth_call_check.escript` | offline EVM sanity: hand-built `0x600360020160005260206000f3` arithmetic (3+2=5) runs — no network |
| `tools/eth_call_demo.escript` / `tools/eth_offline_run.escript` | offline: byte-identical pipeline `msg_from_tx` → `eth_state:new` (with overrides) → `eth_evm:run` |
| `tools/live_sepolia_smoke_test.sh` | live read-only smoke test: chain identity, local-vs-upstream block parity, parent-linkage window, persisted-block stability |
| `make bench` | concurrent live `eth_call` load benchmark through the running node |

> **Honest status on execution (verified offline and through the live
> nodes):** the full defined opcode set dispatches, including Cancun. What
> remains before v1.0 is *fidelity*, not coverage: value transfers kept on
> child revert, EIP-1153 transient scope (currently frame-local), `BLOBHASH`
> returning `0` instead of falling back, pre-EIP-6780 `SELFDESTRUCT`,
> simplified `SSTORE`/`CALL` gas (no warm/cold/refunds), `MODEXP` gas
> undercharge, and dropped child-frame logs — see the TODO list. Contracts
> exercising only the covered semantics (e.g. `--evm-version paris` output,
> arithmetic/storage/views) execute bit-correctly today.

## TODO before production (v1.0)

Each item below is drawn from what was actually verified against the running
code; none is guessing. Items marked DONE were closed with live verification.

### EVM fidelity (correctness first — these return wrong data, not clean errors)

1. **Value transfer kept on child revert** (`eth_evm.erl` `run_call`/`handle_child`):
   the `CALL` value transfer lands in `StateIn` *before* execution, and the
   revert branches restore `StateIn` — so a child that takes value then reverts
   still moves funds. Compounded by `transfer/3` doing no balance check
   (underfunded `CALL` wraps to a huge balance via `set_balance` masking).
   Fix: snapshot pre-transfer state, restore on revert, add the balance check.
2. **EIP-1153 transient storage is frame-local, spec says tx-global**
   (`run/5` rebuilds `#ctx{transient=#{}}` per frame; `run_call` never threads
   the parent map). Breaks reentrancy locks across `CALL`s. Handlers are fine
   in isolation; thread the map through child frames.
3. **`BLOBHASH (0x49)` fabricates `0`** (`eth_evm.erl:370-372`) instead of
   falling back like every other unsupported path. One-line fix class: return
   `unsupported` until a real lookup exists.
4. **Gas/state simplifications**: `SSTORE` without EIP-2200/2929 warm/cold/refunds,
   `CALL` without cold/warm/stipend subtleties, pre-EIP-6780 `SELFDESTRUCT`,
   `MODEXP` gas undercharge (ignores exponent bit-length), dropped child-frame
   logs. Each is a wrong-data-vs-upstream divergence, not a crash.
5. **Precompile gaps**: `0x01 ECRECOVER` recognized but unimplemented;
   `0x06`–`0x0A` (ECADD/ECMUL/ECPAIRING/BLAKE2/KZG) absent. All currently fall
   back to the upstream proxy (safe), but dense crypto contracts always proxy.

### Sync / chain store

6. **Non-atomic DETS writes** (`eth_chain` insert = 3 inserts + head;
   `rewind_to` = N×2 deletes + head rewrite; no `dets:sync`). Crash mid-batch
   leaves indexes/head divergent; `repair=force` may silently truncate. Needs
   write-ahead marker or sync points + a startup consistency check.
7. **Reorg bound mismatch**: chain allows rewind to `finalized`/genesis, but the
   sync ancestor walk caps at `MAX_REORG_DEPTH` (256) and parks on `error`,
   retrying the same window every tick. Needs bounded-retry with backoff plus
   operator-visible alerting instead of a silent hot loop.
8. **`stateRoot`/`receiptsRoot` honesty** — trusted from upstream (header-sync
   client); independent verification via local re-execution is the v1.0 gate.
9. **Window fetch is all-or-nothing** — first fetch error discards the whole
   window (`collect_window`), no partial append/retry; the 120s deadline blocks
   the tick. Partial progress + per-block retry before shipping an SLA.

### RPC surface / security

10. **Open proxy, no auth/rate-limit** — binds `0.0.0.0`, anonymously relays
    arbitrary methods (incl. `eth_send*`) upstream; unbounded batch fan-out
    amplifies against the free public endpoint. Bind localhost by default, add
    a batch cap + per-IP rate limiting before anything reachable.
11. **Batch spec gaps** — non-object items crash the handler (500s the whole
    batch); empty batch returns `[]`; notifications get responses. Per-item
    error objects + spec-compliant empty/notification handling.
12. **Upstream failures conflated into `-32000`** with `~p` formatting
    (transport errors, HTTP 4xx, bad-decode all look like execution errors).
    Distinct codes for transport vs execution; stop leaking internals.

### Ops / hygiene

13. **Two release trees + one hand-copied node**: Docker builds
    `_build/prod`, the host daemon runs `_build/default`, node B is a manual
    `_build/node2` copy with hand-edited `vm.args` + rsync'd beams. Commit a
    single launcher script (env, ports, data-dirs, names) so the second node
    is reproducible, not tribal knowledge.
14. **`bin/etherlang stop` silently no-ops** in this environment (exits 0, beam
    keeps running); stops currently go through `erl_call -a 'init stop []'`
    with the explicit epmd address. Fix or document.
15. **Docker image drift**: the image builds `_build/prod` while the live
    daemons run `_build/default`; any src fix needs both trees or they skew
    (already caused one stale-daemon and one stale-image incident). Rebuild +
    volume policy after each src change; OTP skew (host 29.x vs `erlang:27`
    images) wants pinning.

### Done (verified live, kept here so nobody re-opens them)

- [x] **Cancun opcode coverage** — `PUSH0`/`TLOAD`/`TSTORE`/`MCOPY` all dispatch;
  EIP-145 shift order fixed (v0.2.3; foundry `answer()` = 42 on both nodes).
- [x] **Finalized floor overshoot bricking sync** — checkpoints ahead of head
  or off-chain are now ignored with a warning; refusals back off 60s instead
  of hot-looping (v0.2.4; recovered a live 11k-block stall).
- [x] **ETS cache owner race killing RPC connections** — `eth_state`
  supervised; uncached fallbacks in both caches (v0.2.5; ended agent
  crash-looping).
- [x] **Dashboard frozen at agent-boot height** — post-merge Sepolia TTD served
  as `totalDifficulty` when upstream omits it (v0.2.6; rows track the tip).
- [x] **Test-suite contamination flakes** — `tmp_dir()` pid-scoped;
  `unique_integer` restarts from the same base per VM (v0.2.6; suite 57/57).
- [x] **EthStats registration** — `eth_getVersion` shim + dashboard `:3001` +
  second agent for node B (v0.2.1/v0.2.2; both rows live).
- [x] **`eth_chain_tests`/`eth_sync_tests` flakes** — root-caused to the
  `tmp_dir` reuse above, not network timing; deterministic suites were
  already 100%.
- [x] **No consensus-layer** — execution-layer-only by design; block
  production, beacon, validators are out of scope (documented), not TODO.

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
* **State honesty** — the local EVM executes calls but never re-executes full
  blocks, so `stateRoot`/`receiptsRoot` are *not* re-verified; they are trusted
  from upstream. This is documented and deliberate for v1.

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
| `SYNC_RETRY_MS` | `2000` | currently stored, backoff wiring pending (see TODO) |
| `VERIFY_HEADERS` | `true` | recompute + verify each header hash locally (`false` skips) |
| `EVM_ETH_CALL` | `true` | execute `eth_call` in the local EVM (`false` forces proxy) |

## Local JSON-RPC methods

Served locally: `eth_blockNumber`, `eth_syncing`, `eth_getBlockByNumber`,
`eth_getBlockByHash`, `eth_getBlockTransactionCountByNumber`,
`eth_getBlockTransactionCountByHash`,
`eth_getTransactionByBlockNumberAndIndex`, `eth_call` (local EVM when enabled,
proxy fallback), `web3_clientVersion`, `eth_getVersion` (EthStats-compat shim),
`eth_coinbase` (zero address), `eth_mining` (`false`), `eth_hashrate` (`0x0`).
Everything else is proxied to the upstream node transparently.

Notes: served blocks carry Sepolia TTD as `totalDifficulty` when upstream
omits it (post-merge constant, v0.2.6); `eth_getBlockByNumber` requires
`[hex, bool]` params or the request falls through to proxy; `latest`/`pending`
resolve against the local head while a proxied miss resolves against
upstream's — avoid mixing the two mid-sync.

## Tests

Tests run against an **in-process mock upstream node** (no network needed);
they cover gap sync, live follow, reorg handling + rewind, finalized-floor
guards (never ahead of head / off-chain), persistence across restart, the
JSON-RPC client, the JSON-RPC server (local + proxy + batch + `totalDifficulty`
compat), shift/dispatch EVM regressions, and the local `eth_call` override
path — **57 tests, all green**.

```bash
make docker-test        # builds a test image and runs `rebar3 eunit`
# or, if you have rebar3 locally:
rebar3 eunit
```

Flake note (closed): intermittent `missing_parent`/reorg failures were
root-caused to `tmp_dir()` reusing identical `/tmp` paths across runs
(`unique_integer` restarts from the same base per VM) — test dirs are now
pid-scoped. If a run ever goes red, `rm -rf /tmp/etherlang_test_*` isolates
stale-state contamination before blaming the code. Live behaviour is covered
separately by `tools/live_sepolia_smoke_test.sh` (read-only, needs a running
node) and the foundry/hardhat harnesses above.

## Benchmarking (`eth_call`)

`tools/eth_bench.escript` is a dependency-free concurrent JSON-RPC load
generator (pure OTP). It defaults to `eth_call` against a real Sepolia
contract, so the numbers include the full path through this node's **local
EVM execution** (with upstream state fetch) — use `--method` to target
pure-local reads instead.

```bash
make compose-up                        # start the node first
make bench                             # eth_call, 8 conns, 10s
make bench BENCH_ARGS="--concurrency 32 --duration 20 --requests 5000"
make bench BENCH_ARGS="--method eth_blockNumber"      # pure-local RPC
# or run it manually from anywhere with OTP:
escript tools/eth_bench.escript --url http://127.0.0.1:8545 --concurrency 16 --duration 15
```

Useful comparisons: `eth_blockNumber`/`eth_getBlockByNumber` are served
locally (proxy-free → node overhead only), while `eth_call` measures local
EVM execution plus lazy upstream state fetch (falls back to proxy on
unsupported paths).

## Layout

```
apps/etherlang/src/
  etherlang_app.erl      application boot
  etherlang_sup.erl      supervisor (state -> chain -> rpc server -> sync)
  eth_config.erl          env/config resolution
  eth_hex.erl             0x-hex encode/decode
  eth_word.erl            256-bit word arithmetic
  eth_rlp.erl             RLP encoding
  eth_keccak.erl          pure-Erlang Keccak-256
  eth_header.erl          header hash recomputation + verification
  eth_chain.erl           canonical chain store (DETS) + reorg/rewind
  eth_state.erl           call-state overlay (overrides) + upstream cache
  eth_evm.erl             local EVM interpreter (full defined opcode set)
  eth_evm_precompiles.erl precompiles 0x02-0x05 (0x01 recognized, 0x06+ proxied)
  eth_call.erl            eth_call execution incl. contract creation
  eth_rpc_client.erl      JSON-RPC client over HTTP(S) (httpc)
  eth_sync.erl            gap + follow sync engine + finality tracking
  eth_rpc_server.erl      cowboy listener
  eth_rpc_handler.erl     JSON-RPC dispatch + upstream proxy + TD compat
tools/
  eth_bench.escript       concurrent eth_call/JSON-RPC load benchmark
  eth_call_check.escript  offline EVM sanity checks
  eth_call_demo.escript   offline demo-contract runner
  eth_offline_run.escript byte-identical offline eth_call pipeline
  live_sepolia_smoke_test.sh  live read-only Sepolia smoke test
  demo-contract/          Demo Solidity (solc 0.8.35) + build artifact
  foundry-test/           forge project: Simple.sol + suite, cast-via-node checks
  hardhat-test/           hardhat: Ledger contract + run-node-tests.ts assertions
apps/etherlang/test/
  eth_mock_node.erl       mock upstream JSON-RPC node (in-process)
  eth_test_util.erl       deterministic block generator + helpers
```

## Roadmap (not in v1)

* `devp2p`/`RLPx` inbound and outbound peering and snap/header sync
* Local VM re-execution of full blocks to verify `stateRoot` (EVM exists;
  execution plumbing per-tx through `eth_call` is proven — block-scoped
  replay with receipts is the remaining work)
* tx pool, receipts store, `eth_getBalance` from local state
* snapshots for instant bootstrap (archive-style data-dir downloads)
* EVM fidelity items from the TODO list (revert/value semantics, transient
  scope, gas model, remaining precompiles)

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

> **Update (v0.2.3+, this note is history):** the Cancun set now dispatches
> (`PUSH0`/`TLOAD`/`TSTORE`/`MCOPY` all handled) and shift operand order is
> fixed — real compiled contracts execute. What remains is *fidelity*
> (TODO items 1–5 above), not coverage. `--evm-version paris` is no longer
> required, though still the most conservative choice.

### Offline tools (in `tools/`, no node needed)

| tool | what it does |
|------|--------------|
| `tools/eth_call_demo.escript` / `tools/eth_call_check.escript` | offline: run demo bytecode through the same `eth_evm` path as the live node — hand-built arithmetic `3+2=5` **and** honest reverts, no network |
| `tools/eth_offline_run.escript` | byte-identical offline pipeline: `msg_from_tx` -> `eth_state:new` (with overrides) -> `eth_evm:run`, printing `{ok, Out}` vs `{revert, ...}` |
| `tools/eth_bench.escript` | concurrent JSON-RPC `eth_call` load benchmark (pure OTP, no deps) |
| `tools/demo-contract/` | Demo Solidity (solc 0.8.35) + foundry build artifact used by the tools |
| `session-ses_f506.md` (repo root) | session transcript: the probe commands and live-verification log behind each proof |

> The session transcript (`session-ses_f506.md`, repo root) keeps the exact
> commands behind each proof reproducible.

## Release notes v0.2.1 → v0.2.6 (all verified live on Sepolia)

* **v0.2.1** — `eth_getVersion` shim (EthStats registration compat);
  `web3_clientVersion` → `etherlang/0.2.0`; dashboard remapped to `:3001`;
  EthStats agent watches the host node.
* **v0.2.2** — second host node (`:8546`, OTP `etherlang2`) + second agent;
  both rows live on the dashboard.
* **v0.2.3** — EIP-145 `SHL`/`SHR`/`SAR` operand-order fix (every real Solidity
  dispatcher was reverting); foundry harness proves `answer()` = 42 through
  both nodes.
* **v0.2.4** — finalized-floor guard (never ahead of head / off-chain) + 60s
  refusal backoff; recovered a live stall (finalized `11740998` vs head
  `11729363`, 594 identical errors). Lesson learned: Erlang monotonic time
  can be *negative* — never compare it against a literal.
* **v0.2.5** — `eth_state` supervised (stable ETS table owner) + uncached
  fallbacks; ended cowboy request crashes that crash-looped both agents.
* **v0.2.6** — Sepolia TTD served as `totalDifficulty` on post-merge blocks
  missing it (merge gate verified at block 1450409); dashboard height tracks
  the tip again. Test tmp dirs pid-scoped (full suite 57/57).

## License

MIT — see [LICENSE](LICENSE).