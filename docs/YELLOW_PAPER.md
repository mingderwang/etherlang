# etherlang — a yellow-paper style description

**Version**: v0.7.0 (Sepolia). This document describes what the node *is*,
its system model, trust assumptions, data structures, protocol, and the
properties that fall out of the design. It is not a re-derivation of the
Ethereum Yellow Paper; it is the design document for an approximately-30k-line
Erlang JSON-RPC node with an opportunistic embedded EVM.

Status: implementation described below is verified live on Sepolia; the EVM
fidelity caveats are listed in README's TODO and repeated here in §9.

---

## 1. Executive summary

etherlang is an Erlang/OTP application that speaks the Ethereum JSON-RPC
interface. It is **not** a full Ethereum execution client:

- it runs devp2p/RLPx opt-in (peer discovery, `eth/68` + snap sync,
  tx gossip), with upstream RPC as the dependable fallback,
- it does not run the beacon chain or vote in consensus,
- it has a transaction pool (gossip, validation, `eth_sendRawTransaction`)
  but does not mine or author blocks,
- it maintains a bounded snap state leaf store, not a full state trie,

Instead it syncs canonical blocks **from peers first** (verified headers,
bodies and receipts over RLPx), falling back to an **upstream Ethereum node
over JSON-RPC**, validates their structural integrity (contiguous numbering and
cryptographic parent linkage by recomputing header hashes, plus tx/receipt
trie roots on the peer path), stores a bounded
recent window of them in DETS tables, and serves that window locally while
transparently proxying everything it does not hold to the upstream node. A
separate, purely local EVM evaluates `eth_call` requests (reads) against
upstream-derived state, without ever mutating the chain.

The product is a low-footprint, dependency-light Ethereum-compatible endpoint
whose workload is proportional to *reads*, not to state.

## 2. System model and trust assumptions

The node is a **read-mostly relay with local cache and local verification**.

Trust boundary (all explicit, all configurable or documented):

1. **Canonicality** — the upstream node is the source of truth for what the
   canonical chain is. There is a single upstream URL (`UPSTREAM_RPC_URL`).
   The node never executes blocks, so it cannot detect a malicious upstream
   fork by replay; it can only detect *inconsistency within* a single chain
   (wrong hashes, broken linkage).
2. **Finality** — the `finalized` checkpoint (like `safe`) is *learned from
   the upstream node* rather than derived. It is only **accepted** when it
   satisfies a local guard: it must be at or below the local head **and** must
   match the locally recomputed canonical hash at that height (eth_sync
   `track_finalized/1`). A checkpoint that would otherwise brick the store —
   ahead of head or on a fork — is logged and ignored.
3. **Hash integrity** — except under `VERIFY_HEADERS=false`, every block's
   header is RLP-encoded and keccak-256 hashed locally (eth_header/eth_rlp/
   eth_keccak) before storage. The stored `hash` and the parentHash linkage are
   therefore recomputed, not copied from the wire (`eth_chain:verify_blocks/2`).
4. **State reads** — account state (balance/nonce/code/storage) is fetched
   lazily from upstream per read and cached; results are as trustworthy as the
   upstream node for that block tag.

Non-goals, stated so nobody re-opens them: block production, staking,
blob/KZG service, per-account fee payment, validators and proposer duties,
WebSocket transport.

## 3. OTP kernel

```
etherlang_app (application)
└─ etherlang_sup (one_for_one, 5 restarts / 10 s per child)
   ├─ eth_state       (gen_server)  — owns eth_state_cache ETS table
   ├─ eth_chain       (gen_server)  — canonical chain store (DETS)
   ├─ eth_rpc_server  (gen_server)  — cowboy HTTP listener + rate-limit table
   └─ eth_sync        (gen_server)  — chain synchroniser (poll loop)
```

Start-up order in `etherlang_app:start/2`: ensure `crypto`, `inets`, `ssl`,
`cowboy` are running, initialise the upstream JSON-RPC client
(`eth_rpc_client`, 3 retries / 1 s backoff / 20 s timeout), then start the
supervisor.

The supervisor deliberately owns `eth_state` as a named, permanent process:
the ETS cache table lives and dies with it. (This was a fix: when the table
was created lazily inside short-lived request handlers, the owning handler's
exit killed concurrent readers mid-request and crash-looped the EthStats
agents downstream — `etherlang_sup.erl:19-23`.)

## 4. Configuration (eth_config)

Every runtime knob is an environment variable first, application env second,
default last (see eth_config.erl for the full table). Representative defaults:

| Variable            | Default    | Meaning                                   |
|---------------------|-----------|-------------------------------------------|
| `UPSTREAM_RPC_URL`  | publicnode | upstream Sepolia JSON-RPC endpoint         |
| `RPC_LISTEN_IP`     | 127.0.0.1  | bind address (0.0.0.0 = expose)           |
| `RPC_LISTEN_PORT`   | 8545       | local HTTP port                           |
| `RPC_MAX_BATCH`     | 30         | max JSON-RPC batch size (else -32600)     |
| `RPC_RATE_LIMIT`    | 30         | per-source req/s (0 disables)             |
| `RPC_RATE_BURST`    | 100        | token-bucket burst (else HTTP 429)        |
| `CHAIN_RETENTION`   | 2048       | recent blocks kept locally                |
| `BODY_WINDOW`       | 2048       | most-recent blocks stored full-body       |
| `MAX_REORG_DEPTH`   | 256        | ancestor-walk cap                         |
| `SYNC_CONCURRENCY`  | 8          | parallel block fetches per tick           |
| `SYNC_BUDGET`       | 2048       | max blocks per sync tick                  |
| `POLL_INTERVAL_MS`  | 5000       | follow-mode poll interval                 |
| `VERIFY_HEADERS`    | true       | recompute + verify header hashes          |
| `EVM_ETH_CALL`      | true       | serve eth_call from the built-in EVM      |
| `DATA_DIR`          | ./data     | DETS persistence directory                |
| `ETH_START_BLOCK`   | latest     | head-offset sync, or a specific block     |

Two invariants are enforced structurally rather than by config: retention is
clamped `≥ max_reorg_depth` (`eth_chain:init/1`), so a rewind target can never
be pruned; the finalized checkpoint is never pruned and rewinds never go below
it.

## 5. The chain store (eth_chain)

Storage is three DETS "set" tables under `DATA_DIR`:

```
chain.num.dets   {{Num}}          -> {Hash, Block, Full}
chain.hash.dets  {{Hash}}         -> Num
chain.meta.dets  head | finalized | low
```

- `Block` is the JSON-RPC block map (header + consensus fields + some
  server-normalisation). `Full=true` means `transactions` holds full
  transaction objects; `Full=false` means it holds transaction *hashes* only
  (header-only sync).
- Only **canonical** blocks are kept. The canonical hash at Num is the locally
  recomputed one (`eth_header:verify/1` exchanges the claimed hash for the
  recomputed hex hash before `verify_blocks/2` folds it into the block).
- `head` is `{Num, Hash}`; on the empty store the first block becomes the
  anchor (genesis, or the `ETH_START_BLOCK` snapshot offset — anchors are
  trusted as configured, which is why header verification matters most in
  follow mode).
- `finalized` is the accepted checkpoint (monotonic; `set_finalized/2` never
  moves it backwards).
- `low` is the lowest block number still retained, a persisted watermark.

### 5.1 Append protocol

`append/1` takes an ascending batch. For each entry the head must be the
parent:

- `Num = HN + 1 ∧ parentHash = headHash` → insert, advance head.
- `parentHash` already stored at a height `< HN` → a reorg:
  `do_append/2` rewinds to the common ancestor (refusing to go below
  `finalized`), then continues the batch from `CA + 1`. Returns `{reorg, CA}`.
- parent unknown → `{missing_parent, Parent}`; the sync layer then walks
  ancestors to find the common ancestor (`ancestor_walk`, capped at
  `MAX_REORG_DEPTH`).

`rewind/1` discards blocks above N (deleting both hash and number entries),
re-derives the new head from the store, and refuses any rewind below
`finalized` (`{error, {below_finality, F}}`).

### 5.2 Bounded growth and pruning

DETS has a hard 2 GiB per-file ceiling; on Overflow-on-file the open crashes.
This drove the retention design. After each successful append:

```
below = max(head − retention + 1, 0)
delete_range(low, min(below, low + PRUNE_BATCH))     # PRUNE_BATCH = 4096
```

Each deleted Num also retires its hash-index row (`hash.dets`). `low` advances
incrementally so a store that pre-dates the watermark (or grew unbounded on old
code) is caught up a bounded number of deletions per append rather than in one
giant pass. The finalized block itself is skipped by `delete_range` (parameter
`Skip`) so `rewind` to the checkpoint always remains possible. `low = 0` is the
hard floor; blocks above `low` but below `fn + 1` cannot exist because
`retention ≥ max_reorg_depth` and pruning never crosses `finalized`.

Observed behaviour on Sepolia, Sept 2026: blob-heavy blocks ≈ 330 KB
full-bodied; at retention 2048 the live `num.dets` plateaus at ≈ 830 MB
(verified flat across minutes). Pre-fix (unbounded) growth hit the 2 GiB
ceiling in days.

### 5.3 Reads and the proxy fallback

`get_by_number/1` and `get_by_hash/1` return `{ok, Block, Full}` or
`not_found`. Pruned/unknown blocks are **not an error surface**: the RPC layer
falls back to the upstream proxy, so "garbage-collected historical data" is
invisible to callers (see §7). For a stored block requested **full** but only
kept header-only, the handler also proxies rather than fabricating bodies.

## 6. Synchronisation (eth_sync)

The synchroniser is a poll loop (`tick` → `run_once` → `send_after`). Each
tick tries **eth-ready peers first**, RPC second:

* **Peer sync** — backward walk (192-header reverse batches) from a peer's
  best hash to a local anchor, then forward fill: bodies fetched per header
  and `transactionsRoot`-verified, receipts fetched and `receiptsRoot`-
  verified, everything assembled and appended through the normal chain path
  (reorg logic reused). Empty stores advertise genesis `Status`.
* **RPC fallback** — `eth_blockNumber` from upstream → target `HeadU`,
  `finalized` tracked with the guarded accept (§2), then three branches on
  local head:
   - **empty store** → gap fill from `anchor` (`latest` → `max(HeadU, 0)`;
     a number → that block) up to `HeadU`.
   - **head below upstream** → `sync_range(head+1, HeadU)`.
   - **head above upstream** → upstream reorged or a stale fork tip was
     fetched; reconcile against the canonical hash of `HeadU` (rewind, or walk
     to the ancestor and rewind).

`sync_range` works in **windows**: `min(concurrency, span)` blocks are fetched
in parallel with a 120 s deadline and re-sorted into number order before
append. Per-tick progress is bounded by `SYNC_BUDGET`; `body_window` decides
which blocks in the run are fetched `Full=true` vs header-only. `mode` toggles
`gap`/`follow`; `synced=true` flips once `From > To`.

Error handling is deliberately graceful:

- window fetch failures and append `bad_block`/`below_finality` errors count
  `failed` and retry on the next tick;
- a rewind refused below the finalized floor triggers a 60 s backoff
  (`FLOOR_BACKOFF_MS`), re-armed on every refusal, stopping log spam and
  upstream churn while the node is pinned;
- a deep reorg (`ancestor_walk` exceeding `max_reorg` or reaching below
  finality) is given up with an error and backoff.

`eth_syncing` returns `false` once `synced ∧ head ≥ target`, else the
`{startingBlock, currentBlock, highestBlock}` object.

## 7. The RPC layer (eth_rpc_server / eth_rpc_handler)

Transport is HTTP/1.1 JSON-RPC 2.0 over cowboy (`POST /`). Security, all
default-on:

- binding confined to loopback by default (`RPC_LISTEN_IP` to open);
- per-source **token bucket** rate limit (`eth_rate_limit`, keyed on peer IP,
  `{ipv4, ...}`/`{ipv6, ...}`/`unknown`) → HTTP 429 + `-32005 too many
  requests`;
- batch cap `RPC_MAX_BATCH` → single `-32600 batch too large` error;
- parser errors → `-32700`; malformed requests → `-32600`; non-POST → 405.

Dispatch is two-tier:

1. **local ambitions** (served from the store or computed):
   - `eth_blockNumber` — local head,
   - `eth_syncing` — sync status,
   - `web3_clientVersion` / `eth_getVersion` — `etherlang/…`,
   - `eth_coinbase` (zero address), `eth_mining` (false), `eth_hashrate` (0),
   - `eth_getBlockByNumber` / `eth_getBlockByHash` (+ `Full` upgrade through
     the proxy when the local copy is header-only or absent),
   - block transaction counts (`…ByNumber`, `…ByHash`),
   - `eth_getTransactionByBlockNumberAndIndex` (full-body blocks only),
   - `eth_call` — §8.
   Tags are resolved for the local store: `latest`/`pending`→local head,
   `finalized`/`safe`→the tracked checkpoint, `earliest`→0; pruned or
   non-local targets are passed to the proxy verbatim.
2. **everything else** → verbatim upstream pass-through, including upstream
   error objects (codes and messages preserved).

A serving-time **compatibility shim** injects `totalDifficulty` into post-merge
Sepolia blocks (`eth_rpc_handler:with_td_compat/1`): since The Merge the value
is frozen at the terminal total difficulty (TTD = 17,000,000,000,000,000), so
re-adding it is state a protocol fact, not fabricated data. Gated to
`chain_id = 11155111 ∧ number ≥ 1450409`; storage is never touched and other
chains pass through.

### 7.1 Rate limiter (eth_rate_limit)

A per-source token bucket: `Rate` tokens refill per second up to a `Burst`
cap; `Rate ≤ 0` disables. The table is created in `eth_rpc_server:init/1`,
passed to every handler in `limits` (tests may pass none → unlimited), and
owned for the lifetime of the listener.

## 8. Local EVM execution (eth_call → eth_evm)

`eth_call` is the one reading/writing-experiment method implemented locally.
Design (eth_call.erl + eth_state.erl + eth_evm.erl ~900 lines + precompiles):

- **State model — lazy fetch + immutable overlay + snap state store.**
  The node maintains a bounded snap state leaf store (accounts/storage/codes
  fetched via snap sync) plus the `eth_state` cache. Reads go:
  overlay → ETS cache → local snap store → upstream JSON-RPC
  (`eth_getBalance`, `eth_getTransactionCount`, `eth_getCode`,
  `eth_getStorageAt`). Cache TTL: **3 s** for tags
  (`latest`/`pending`/`safe`/`finalized`), **unbounded** for concrete
  block numbers (immutable).
  Writes (SSTORE, value transfers, CREATE'd code) only ever land in the
  **overlay** map of the in-flight call and are discarded on revert — upstream
  state can never be mutated through `eth_call`.
- **State overrides** (the 3rd `eth_call` parameter) are parsed into the same
  overlay, with per-account `balance`, `nonce`, `code`, `state`, `stateDiff`.
  EIP-6780 `created`/`destroyed` markers cannot arrive via JSON overrides
  (only the fields above are parsed), so a client cannot forge them.
- **Environment** is built from the resolved block header (chain id cached in
  `persistent_term`, coinbase, base fee, gas limit, timestamp, block number);
  the gas limit defaults to 30,000,000 when the request omits `gas`.
- **Precompiles** at their canonical addresses are handled natively
  (`eth_evm_precompiles`, incl. the BN254 pairing via `eth_pairing_bn128`).
  `0x0A` (KZG point evaluation) is **not** implemented; those requests alone
  fall back to the upstream proxy.
- **Opportunistic semantics.** The EVM is honest about its own limits: on an
  unsupported opcode, an internal crash, or an unverifiable out-of-gas it
  returns `fallback` and `eth_rpc_handler` proxies the original request
  upstream. Correctness holes therefore degrade to *round-trip*, never to
  wrong answers. Known fidelity gaps (revert-value semantics, gas-accounting
  edge cases, dropped child-frame logs, missing warm/cold accesses) are
  tracked in README TODO items 1–5.

## 9. Known limitations (v0.7.0)

1. EVM fidelity gaps (see §8) — these can return *correct-looking-but-wrong*
   data on exotic code paths, hence the proxy fallback is the safety net.
2. No consensus participation, no block production.
3. devp2p is opt-in and young: discovery/RLPx/`eth`+snap sync, tx gossip,
   auto-dial and strict ForkID are implemented and loopback-tested, but
   live-peering breadth (against diverse real clients) is not yet
   demonstrated — upstream RPC remains the dependable fallback by design
   (all configurable).
4. Blobs are not stored/extended; KZG `0x0A` is proxied.
5. Header-only blocks proxy `Full=true` requests rather than serving bodies.
6. `eth_getLogs` serves ranges capped at 1024 blocks from the receipts store;
   wider ranges proxy upstream. Receipt/state serving needs the respective
   stores populated (peer/snap sync paths); pure-RPC syncs keep proxying.
7. Snap serving carries no proofs (leaf store only): strict requesters
   reject our ranges; full proof serving needs inner-node retention.
8. The state cache TTL for tags is a freshness/size trade-off; concurrent
   readers share it safely behind the `eth_state` owner.

## 10. Testing and the live harness

- 185 eunit tests in `apps/etherlang/test/`, exercised with
  `rebar3 eunit` (compiles to `_build/{default,node2}`).
- Two local nodes (node A `:8545`, node B `:8546`) + a Docker deployment
  (`Dockerfile`, `docker-compose` with ethstats agents) all run the same
  release; verified live against Sepolia: gas-level tx through the node,
  MetaMask send, `forge create` deploy, pruned-block proxying, retention
  plateau, rate-limit behaviour.
- `tools/etherlangctl` encodes the whole topology as one launcher.

## 11. Roadmap direction

Close remaining EVM fidelity gaps (precise gas accounting, better
revert value/error reporting), then address: RPC authentication,
block building from the pending pool, state-trie sync toward full
`eth_getBalance` independence, native blob transport, a second upstream
with automatic failover, and state prefetch warmers to cut cold
`eth_call` latency.