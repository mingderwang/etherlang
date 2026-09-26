# etherlang

An Ethereum-compatible blockchain node written in Erlang, runnable in Docker.
It syncs and serves the canonical chain (headers, bodies, **receipts**) over
**devp2p/RLPx** with peer-first sync (RPC fallback), heals **contract state**
via snap sync, runs a pending **transaction pool** with gossip, and ships a
local **Erlang EVM** (`eth_evm`) that executes `eth_call` — with state
overrides — against lazily-fetched upstream state. No block production: the
network remains the source of truth for consensus and inclusion.

## Support

If etherlang is useful to you, you can support its development:

[![GitHub Sponsors](https://img.shields.io/github/sponsors/mingderwang?style=flat-square)](https://github.com/sponsors/mingderwang)

## Summary

`etherlang` is a lightweight Ethereum **execution-layer-style** node written in
Erlang/OTP. It is *not* a full execution client (state verification is
partial — see honesty notes) and has *no* consensus-layer components (no
beacon, validators, or block production).

* **Chain store** — persistent DETS-backed canonical chain (block-by-number,
  hash index, head/metadata, **receipts**, **tx→block index**) with append,
  query, reorg rewind, and restart recovery. Growth is bounded by
  `CHAIN_RETENTION` (default 2048 blocks; the
  recent-window blocks carry full bodies, so this caps the store around
  several hundred MiB) so the 2 GiB DETS ceiling can never be reached; older
  blocks prune away and are served from the upstream proxy instead.
* **Sync engine** — **peer-first**: verified headers/bodies/receipts from
  eth-ready peers (backward walk to a local anchor, forward fill, tx-root and
  receipts-root verified before append), with the bounded-parallel RPC gap
  sync as fallback; header-only storage outside `BODY_WINDOW`, live polling
  follow, bounded ancestor-walk reorg handling, and a monotonic `finalized`
  floor that never accepts checkpoints ahead of the local head or off the
  canonical chain.
* **devp2p stack** (opt-in, off by default) — discv4 UDP discovery
  (`DISCV4_ENABLED`, k-buckets, bonding), RLPx EIP-8 handshake + framing
  (`RLPX_ENABLED`), `eth/68` Status (strict EIP-2124 ForkID)/headers/bodies/
  receipts/pooled-txs, snap/1 account/storage/code ranges, auto-dial to
  `PEER_TARGET` with backoff, persisted node key. Pure Erlang throughout
  (secp256k1, ECIES, MPT, snappy).
* **Transaction pool** (always on) — signature recovery, Sepolia chain-ID,
  gas/nonce/balance validation against head state, pending/queued nonce
  tiers, price eviction, gossip receive + broadcast, local
  `eth_sendRawTransaction`; pool revalidates on every sync append.
* **State heal** (opt-in `STATE_SYNC_ENABLED`) — snap account/storage/code
  ranges with boundary-proof verification into a persistent leaf store;
  `eth_getBalance`/`Nonce`/`Code`/`StorageAt` served locally first.
* **Local EVM** — pure-Erlang interpreter covering the full defined opcode set
  including Cancun (`PUSH0`/`TLOAD`/`TSTORE`/`MCOPY`) plus precompiles
  `0x01`–`0x09` (`0x0A` KZG still proxies); serves `eth_call` locally with
  standard state overrides, proxying upstream on unsupported paths. Known
  fidelity simplifications are listed under TODO.
* **JSON-RPC server** — cowboy listener on `:8545` that answers chain/block/tx/
  **receipt/log-filter** queries and `eth_call` from local storage + local
  execution, transparently proxying everything else (`eth_getBalance`,
  `net_*`, …) to upstream.
* **State honesty** — `stateRoot` is trusted from upstream, not re-executed;
  `transactionsRoot`/`receiptsRoot` **are** verified against the block's own
  body at finalization and reported as explicit verdicts; blocks served locally
  carry the Sepolia TTD as `totalDifficulty` when upstream omits it (post-merge
  constant, serve-time only — see `with_td_compat`).
* **Ops** — Docker release image (non-root, volume-backed), compose stack with
  an EthStats dashboard (two host nodes reporting live), a dependency-free
  `eth_call` load benchmark, a live Sepolia smoke-test script, and an
  in-process mock-upstream eunit suite (**185 tests, green**).
* **Status** — v0.7.0; eunit green (185 tests) and verified live against Sepolia.

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

All items below have been verified against the running code and
implemented. Items marked [x] are closed with live verification.

### EVM fidelity (all resolved)

- [x] **1. Value transfer on child revert** - revert branches restore
   the pre-call state; `check_call_value` guards the balance check
   (`eth_evm`) (v0.7.0).
- [x] **2. EIP-1153 transient storage** - tx-global by design; child
   inherits, success merges back, revert discards (`eth_evm`) (v0.7.0).
- [x] **3. `BLOBHASH (0x49)`** - returns `unsupported` (proxy fallback)
   instead of fabricating `0` (`eth_evm`) (v0.7.0).
- [x] **4. Gas/state simplifications** - SSTORE EIP-2200 refunds applied
   to final gas (capped at half gas used); MODEXP per EIP-2565; CALL
   2300 stipend (`eth_evm`) (v0.7.3).
- [x] **5. Precompile gaps** - all precompiles `0x01`-`0x09` execute
   locally; `0x0A` KZG deferred (needs BLS12-381 backend) (`eth_evm`) (v0.7.0).

### Sync / chain store (all resolved)

- [x] **6. Non-atomic DETS writes** - `dets:sync` after all writes;
   startup `check_consistency` validating head/hash linkage (`eth_chain`) (v0.7.2).
- [x] **7. Reorg bound mismatch** - exponential backoff (60s-300s max);
   resets on sync progress (`eth_sync`) (v0.7.2).
- [x] **8. `stateRoot` honesty** - trusted from upstream; independent
   verification remains the v1.0 gate (`eth_sync`) (v0.7.2).
- [x] **9. RPC window fetch** - `collect_window` returns partial results
   on error/timeout instead of discarding the whole window (`eth_sync`) (v0.7.2).

### RPC surface / security (all resolved)

- [x] **10. API key authentication** - `RPC_API_KEY` env var; every request
   must include matching key in params; disabled when empty (`eth_rpc_handler`) (v0.7.4).
- [x] **11. Batch spec gaps** - `safe_handle_one` wraps each batch item
   in try/catch; non-object items produce per-item `-32700` or `-32603`
   (`eth_rpc_handler`) (v0.7.3).
- [x] **12. Upstream error codes** - proxy maps decode/transport errors to
   distinct codes (`-32700`, `-32602`, `-32603`) (`eth_rpc_handler`) (v0.7.3).

### Ops / hygiene (all resolved)

- [x] **Batch spec compliance** - non-object items produce per-item error
   responses (`eth_rpc_handler`) (v0.7.3).
- [x] **Upstream error codes** - distinct codes instead of `-32000`
   (`eth_rpc_handler`) (v0.7.3).
- [x] **API key + per-method rate limiting** - `eth_rate_limit:take/5`
   supports per-method buckets; `eth_rpc_server` passes `api_key` to handler
   (`eth_rate_limit`, `eth_rpc_server`) (v0.7.4).
- [x] **SSTORE refunds applied to gas** - EIP-2200 refunds capped at half
   gas used, added to final gas (`eth_evm:run_t`) (v0.7.3).
- [x] **Release trees, bin/etherlang stop, Docker image drift** -
   documented operational procedures; tracked as process items.

---

## v1.0: Complete execution client (work in progress)

This is the full plan to make etherlang a **production-grade, consensus-layer-compatible** Ethereum execution client. It replaces the current "read-mostly relay" architecture with a full execution layer that can work with Lighthouse, Prysm, Nimbus, Teku, or Lodestar.

### Phase 1: Engine API — Consensus Layer Interface ✅ COMPLETE

The Engine API (EIP-3675 / Cancun) is what lets a consensus client (Lighthouse, Prysm, etc.) delegate block execution to etherlang. Implemented and passing all tests.

- [x] **Engine API server** — `engine_newPayloadV1`, `engine_forkchoiceUpdatedV1`, `engine_getPayloadV1`, `engine_exchangeTransitionConfigurationV1` (`eth_engine`)
  - `engine_newPayloadV1`: receive and validate execution payload from CL (parent hash, block number)
  - `engine_forkchoiceUpdatedV1`: handle safe/finalized forkchoice updates
  - `engine_getPayloadV1`: return the payload for the CL to broadcast
  - `engine_exchangeTransitionConfigurationV1`: negotiate engine version
  - Return correct status codes (`VALID`, `INVALID`, `SYNCING`, `ACCEPTED`, `SECURITY_ERROR`)
- [x] **Engine API HTTP endpoint** — `eth_engine_handler.erl` serves `POST /engine` on port 8551 with JWT auth support
- [x] **Payload validation** — parent hash and block number checks
  - The declared state root is compared against the root recomputed after execution (Phase 4), and the receipts and transactions roots against the ones derived from the block's own body (Phase 5)
  - All three are reported as `{verified, Root} | {unverified, Reason}` verdicts in the `Verification` map. None of them is reported as a bare root: a recomputed value under a key named after a header field is indistinguishable from a confirmed one, and that is how a wrong receipts root passed unchecked until Phase 5
  - A block whose parent's state this node does not hold locally still gets its transactions root checked, since that root covers only the block's own transaction list. Its receipts root is reported `{unverified, not_executed}`
- [x] **Transition configuration** — echoes `TERMINAL_TOTAL_DIFFICULTY` and `TERMINAL_BLOCK_HASH` back to the consensus client. The values are passed through, not interpreted: nothing in execution evaluates a total difficulty against the TTD to decide that the merge has happened (see EIP-3675 in Phase 5).
- [x] **Engine API authentication** — JWT secret via `JWT_SECRET` env var, HMAC-SHA256 verification
- [x] **Engine API server startup** — `eth_rpc_server` starts separate cowboy listener on port 8551

### Phase 2: Full State Trie — Replace Bounded Snap Store ✅ COMPLETE

The current `eth_state` uses a bounded DETS-backed snap leaf store. A complete execution client needs a full Merkle-Patricia Trie to verify state proofs and support full state queries. Implemented and passing all tests.

- [x] **MPT node type** — `Extension`, `Leaf`, `Branch` nodes via `eth_trie` (extended)
- [x] **MPT insertion** — `eth_trie:insert/3` and `eth_mpt` wrapper for state management
- [x] **MPT verification** — `eth_trie:verify_proof/3`, account/storage proof generation
- [x] **MPT encoding** — RLP encode/decode trie nodes via `eth_trie`
- [x] **Account trie** — `eth_mpt:put_account/4`, `get_account/1`, `delete_account/1`
- [x] **Storage trie** — `eth_mpt:put_storage/3`, `get_storage/2`, `delete_storage/2`
- [x] **Code storage** — `eth_mpt:put_code/2`, `get_code/1`
- [x] **State root computation** — `eth_mpt:state_root/0` from MPT root hash
- [x] **Trie iterators** — `eth_mpt:iter_accounts/0`, `iter_storage/1`
- [x] **Replace `eth_statestore`** — rewired to use `eth_mpt` internally (replaces bounded DETS snap store)
- [x] **`eth_getProof`** — `eth_mpt:prove_account/1`, `prove_storage/2`, `verify_proof/3`
- [x] **`eth_getStorageAt`** — `eth_mpt:get_storage/2` with proof verification
- [x] **Snapshot/restore** — `eth_mpt:snapshot/0`, `restore/1` for fast restart
  - Serializes the whole in-memory account, storage and code tables. It grows with total state and is written on demand, not per block
- [x] **Persistence** — DETS-backed via `eth_mpt:init/1` with snapshot files

### Phase 3: Block Production (partial)

Blocks are built and executed, but the node does not author them: it never receives proposer duties, so a locally built block is a construct for testing rather than something the network would accept. Execution is real — receipts, logs, bloom, state root — but the gas schedule is approximate, so the state roots it produces do not match the network's.

- [x] **Block builder** — construct execution payloads from the transaction pool
  - Select transactions from pending pool (by gas price / priority fee) ✅
  - Respect block gas limit ✅
  - Handle blob transactions (EIP-4844) (partial — no KZG commitment verification)
  - Compute gas used, receipts, logs, bloom filter ✅
- [ ] **Block header** — construct full block header:
  - Parent hash, uncle hash, fee recipient, state root, receipts root
  - Logs bloom, difficulty (0 in PoS), number, gas limit, gas used
  - Timestamp, extra data, base fee, blob gas used, excess blob gas
  - Withdrawal root (EIP-4895) ✅
  - Requests hash (EIP-7685) — not implemented
- [x] **Block execution** — execute transactions in order within the block ✅
  - Apply each transaction (value transfer, contract creation, contract call) ✅
  - Update state trie after each transaction ✅
  - Collect receipts and logs ✅
  - Track gas used and refunds ✅
  - Transaction-level effects applied in the protocol order: buy gas at the ceiling, bump the nonce, transfer value, run the EVM, refund the sender at the effective price, pay the recipient the tip
  - EIP-161 (a touched-but-empty account must not enter the trie) and EIP-170 (24576-byte code limit) enforced
  - A transaction is validated before it is executed; a block containing an invalid one is refused and nothing is committed
  - Gas costs are approximate, not per-fork exact
- [x] **Withdrawals** — process beacon block withdrawals (EIP-4895) ✅
- [ ] **Beacon requests** — handle `engine_notifyHeaders` and beacon root requests
  - The execution side is done and verified against Sepolia; the engine-API plumbing is not
- [x] **Execution payload building** — integrate with consensus client's `engine_getPayload` flow ✅
- [ ] **Proposer selection** — receive proposer duties from consensus client, produce blocks when selected

### Phase 4: State Management (partial)

State is stored in a trie, persisted, prunable, and its root recomputed and checked after every block. What is absent is snap sync and proof-verified boundary reconstruction, so the trie can only be built by executing blocks the node already has.

- [x] **State pruning** — implement archive, recent, and pruning modes
  - Archive mode: keep all historical states ✅
  - Pruned mode: keep only recent states, prune old ones ✅
  - Full mode: keep all states, prune old state tries but keep history ✅
- [x] **State expiration** — expire state older than `STATE_HISTORY` blocks (EIP-4444 client-side enforcement) ✅
- [x] **History indices** — maintain history index for block hashes and receipts ✅
- [ ] **Full state sync** — download full state from peers using snap sync protocol
  - Snap code (EIP-1189) — download account/storage ranges
  - Boundary proof verification
  - Parallel range downloads
  - State trie reconstruction from snap data
- [x] **Block hash oracle** — maintain block hash list for `eth_getBlockByHash` and consensus ✅
- [x] **State trie persistence** — persist MPT to disk (DETS or ETS + snapshot files) ✅
- [x] **Snapshot creation** — create state snapshots for fast restart ✅
  - A dump of the in-memory maps written on demand, not a persistent trie; a node relying on it is no faster to restart than one that replays
- [x] **State root verification** — recompute the state root after block execution and report `{verified, Root}` or `{unverified, Reason}` ✅
  - A block the node built itself is reported unverified rather than stamped with a root it cannot justify
  - Historical blocks are not re-executed, so local agreement with previously accepted roots is not re-established

### Phase 5: Protocol Compliance (partial)

EIP-1559, EIP-4788, EIP-4895 and EIP-2935 are implemented, and the two system-contract EIPs are verified against the real bytecode Sepolia has deployed and against real block state. The per-fork gas schedule is not, so the state roots this node computes are not expected to match the network's. It has not been established that the gas schedule is the *only* remaining divergence — that cannot be checked end-to-end without real prestate.

- [ ] **Per-fork exact gas schedule** — replace approximate gas with exact per-fork schedule
  - Fork *selection* is driven by real activation points (`current_fork/3`); the per-fork *gas table* is what's missing
  - **A fork-parameterized table exists and is dead code.** `eth_fork_schedule:gas_cost/3,4` takes a fork atom, is exported and has its own unit tests — and nothing in the execution path calls it. The EVM charges `eth_evm:base_cost/1`, which takes no fork. So the tests on the fork-aware table prove nothing about execution, and the two tables have been free to disagree because nothing ever compared them. Wiring the table up is the start of this task, not the end of it
  - Istanbul, Berlin, London, Arrow Glacier, Gray Glacier, Merge, Bellatrix, Paris, Shanghai, Cancun, Deneb
  - Each fork's exact gas costs for all opcodes
  - The catch-all `base_cost(_) -> 3` is still a fallback for an unassigned opcode. It silently priced `RETURN`/`REVERT`/`INVALID`/`SELFDESTRUCT` at 3 gas each until they were given 0 — an unassigned opcode is still a guess rather than an error
  - Fixed: `BASEFEE`/`BLOBHASH`/`BLOBBASEFEE` at 2/3/2 instead of 20/20/20. A contract reading the base fee in a loop was charged a tenth of the real price
  - Missing: EIP-3860's init-code word cost inside `CREATE`/`CREATE2`; it is counted in the transaction's intrinsic gas but not by the opcode
  - Dynamic base fee calculation (EIP-1559)
  - Blob gas accounting (EIP-4844)
- [x] **EIP-1559** — base fee calculation and burning ✅
  - Compute base fee per block ✅
  - Burn base fee ✅ — the sender pays `gasLimit * maxFeePerGas` and is refunded `gasLeft * effectivePrice`, so the base fee on unused gas is burned as well as on used gas; the fee recipient gets `gasUsed * (effectivePrice - baseFee)` and nothing else
  - Priority fee handling ✅
  - Verified by asserting on the *sum* of balances, not on one account: what the sender loses and what the recipient gains must account for the rest
- [ ] **EIP-4844 (blobs)** — blob transactions support (partial)
  - Blob transaction type (0x03) ✅
  - Blob gas pricing ✅
  - KZG commitment verification — **not implemented**; an invalid commitment is not rejected
  - Blob data propagation — not implemented
- [x] **EIP-4788 (beacon roots)** — store beacon block roots in state ✅
  - Executes the deployed contract's code as `0xff..fe` each post-Cancun block, rather than writing the two slots directly
  - Two ring regions 8191 apart: `ts mod 8191` for the timestamp, `+ 8191` for the root
  - Skips the all-zero genesis placeholder; fails silently on no code, revert, or exception; not charged to the block gas limit
  - Verified against Sepolia by running the bytecode from `eth_getCode` and requiring the slots a real block's state contains
  - `BLOCKHASH` returning the beacon root is a separate opcode concern, not implemented
- [x] **EIP-2935 (block hash history)** — store the last 8191 parent hashes in state ✅
  - Executes the deployed contract's code at `0x0000F90827F1C53a10cb7A02335B175320002935` as `0xff..fe` each Prague-or-later block, passing the block's own parent hash
  - The ring is keyed by **block number** (`(number - 1) mod 8191`), not by timestamp as EIP-4788's is. The two rings are separate accounts with separate keying, and conflating them writes a slot no other client reads
  - The public getter answers for the 8191 block numbers in `[number - 8191, number - 1]` and reverts outside it; `read_parent_hash/3` mirrors that window so a caller using the shortcut gets the same answers the on-chain getter would
  - Verified against Sepolia by running the bytecode from `eth_getCode` with a real block's number and parent hash, requiring the slot that block's state really contains, and exercising the getter's window boundaries
- [x] **EIP-4895 (withdrawals)** — process withdrawals from beacon block ✅
  - Withdrawal schedule ✅
  - Withdrawal root in block header ✅ (an MPT root keyed by `rlp(position)`, not an SSZ hash)
  - Process withdrawals in execution payload ✅ (through the state overlay, so the credits are inside the state root)
- [ ] **EIP-3675 (PoS merge)** — full PoS execution engine (partial)
  - PoW difficulty = 0 after merge ✅
  - `TERMINAL_TOTAL_DIFFICULTY` handling — carried through config but never evaluated against a total difficulty
  - `TERMINAL_BLOCK_HASH` handling — not implemented
  - Nothing decides that a chain has crossed the merge; Paris is the floor unconditionally, so a pre-merge block would run under post-merge rules
- [ ] **Geth-compatible devp2p** — full protocol compliance
  - `eth/68` with all sub-protocols (status, new block, tx announcements)
  - `eth/69` (history) if needed
  - Snap protocol (`snap/1`) full compliance
  - `discv5` discovery (UDP v5) instead of `discv4`
  - Full `Status` message with fork compatibility
- [x] **stateRoot honest verification** — verify the state root after block execution ✅
  - Reports `{verified, Root}` or `{unverified, Reason}`; a locally built block is never stamped
  - Historical blocks are not re-executed, so agreement with previously accepted roots is not re-established
- [ ] **Receipt verification** — verify transaction receipts on the peer path
  - Receipts are built during execution, but one arriving from a peer is never recomputed and compared
- [x] **Full transaction validation** — every transaction in every block ✅
  - `eth_tx:validate/1,2` is the single implementation; the pool, the block
    builder and block finalization all delegate to it
  - `eth_block:finalize/1` validates before executing and returns
    `{error, {invalid_transaction, Index, Reason}}` without committing — an
    invalid transaction in a block changes nothing
  - Covers field shapes and ranges, `to`/data/access list, per-type fee
    consistency, the fee ceiling, EIP-4844 blob rules, the intrinsic gas
    floor, signature recoverability and malleability, chain id, the block gas
    limit, and nonce/balance against the executing pre-state
  - No `from` fallback: the sender is always recovered from the signature
  - An absent context key means the rule is unchecked, not passed

### Phase 6: JSON-RPC API Completion

Complete the full Ethereum JSON-RPC API set that geth exposes.

- [ ] **Debug API** — `debug_traceTransaction`, `debug_traceBlockByNumber`, `debug_traceBlockByHash`, `debug_traceRawTransaction`
  - Trace mode: `callTrace`, `structLog`, `builtInTracer`
  - Parity-style trace API compatibility
- [ ] **Trace API** — `trace_replayTransaction`, `trace_replayBlock`, `trace_filter`, `trace_transaction`
- [ ] **Miner API** — `miner_start`, `miner_stop`, `miner_setExtra`, `miner_setGasPrice`, `miner_setEtherbase`
  - No-op in PoS but must respond to avoid client incompatibility
- [ ] **Admin API** — `admin_nodeInfo`, `admin_peers`, `admin_datadir`, `admin_startRPC`, `admin_stopRPC`
- [ ] **Personal API** — `personal_importRawKey`, `personal_listAccounts`, `personal_newAccount`, `personal_sign`, `personal_ecRecover`, `personal_sendTransaction`, `personal_unlockAccount`
- [ ] **Web3 API** — `web3_clientVersion`, `web3_sha3`, `web3_clientVersion`
- [ ] **Net API** — `net_listening`, `net_peerCount`, `net_version`
- [ ] **Eth API completeness** — ensure all `eth_*` methods match geth's response format:
  - `eth_getBlockByNumber`, `eth_getBlockByHash` (with/unlimited transactions)
  - `eth_getTransactionByHash`, `eth_getTransactionByBlockHashAndIndex`
  - `eth_getTransactionReceipt`, `eth_getTransactionCount`
  - `eth_getBalance`, `eth_getStorageAt`, `eth_getCode`
  - `eth_call`, `eth_estimateGas`, `eth_feeHistory`
  - `eth_sendRawTransaction`, `eth_sign`, `eth_signTransaction`, `eth_signTypedData`
  - `eth_newFilter`, `eth_newBlockFilter`, `eth_newPendingTransactionFilter`
  - `eth_getFilterChanges`, `eth_getFilterLogs`, `eth_uninstallFilter`
  - `eth_getLogs`, `eth_submitHashrate`, `eth_submitWork`
  - `eth_protocolVersion`, `eth_syncing`, `eth_coinbase`, `eth_mining`
  - `eth_hashrate`, `eth_gasPrice`, `eth_chainId`, `eth_feeHistory`
  - `eth_getUncleByBlockHashAndIndex`, `eth_getUncleByBlockNumberAndIndex`
  - `eth_getUncleCountByBlockHash`, `eth_getUncleCountByBlockNumber`
  - `eth_getBaseFee`, `eth_getBlobBaseFee`, `eth_getChainId`
- [ ] **EIP-1898** — `eth_chainId` returns correct chain ID
- [ ] **EIP-1474** — `eth_feeHistory` returns correct fee history
- [ ] **EIP-2930** — `eth_createAccessList` (access list transactions)
- [ ] **EIP-712** — `eth_signTypedData_v1`, `eth_signTypedData_v3`, `eth_signTypedData_v4`
- [ ] **EIP-2718** — typed transaction support (legacy, EIP-2930, EIP-1559, EIP-4844)

### Phase 7: Consensus Integration

Full integration with consensus clients.

- [ ] **Lighthouse integration** — test with Lighthouse (Rust, maintained by Sigma Prime)
  - Engine API compatibility
  - `eth/68` Status message compatibility
  - ForkID compatibility
  - Payload validation compatibility
- [ ] **Prysm integration** — test with Prysm (Go, maintained by Prysmatic Labs)
- [ ] **Nimbus integration** — test with Nimbus (Nim, maintained by Status)
- [ ] **Teku integration** — test with Teku (Java, maintained by Consensys)
- [ ] **Lodestar integration** — test with Lodestar (TypeScript, maintained by Chainsafe)
- [ ] **Local test setup** — docker-compose with Lighthouse + etherlang on Sepolia
- [ ] **Mainnet readiness** — test on mainnet with a real consensus client

### Phase 8: Testing & Verification

- [ ] **Foundry tests** — run foundry test suite against etherlang's JSON-RPC
  - `forge test` with `--rpc-url` pointing to etherlang
  - Contract deployment and execution tests
  - EVM opcode regression tests
- [ ] **Geth test vectors** — run geth's test suite against etherlang
  - `go test ./tests/...` with geth test data
  - Block execution tests
  - State transition tests
  - Transaction tests
  - VM tests
- [ ] **Property-based tests** — property-based testing of EVM execution
- [ ] **Fuzz testing** — fuzz the EVM interpreter for edge cases
- [ ] **Differential testing** — run same block through etherlang and geth, compare outputs
- [ ] **Performance benchmarks** — block processing speed, state access latency
- [ ] **Memory benchmarks** — state trie memory usage under load
- [ ] **Conformance tests** — run Ethereum Foundation conformance tests

### Phase 9: Infrastructure & Operations

- [ ] **Docker image** — multi-stage build, optimized production image
- [ ] **Release process** — automated versioning, changelog generation
- [ ] **Monitoring** — Prometheus metrics, Grafana dashboards
- [ ] **Logging** — structured JSON logging, log rotation
- [ ] **Health check** — `/health` endpoint for orchestration
- [ ] **Graceful shutdown** — clean state dump, peer disconnection
- [ ] **Configuration validation** — validate config at startup
- [ ] **Upgrade path** — zero-downtime upgrade support
- [ ] **Documentation** — complete deployment guide, architecture guide
- [ ] **Security audit** — third-party security review of execution engine

---

### Current Status

**v0.7.4** was a read-mostly relay. It is NOT a complete execution client and is NOT compatible with Lighthouse or any consensus client.

Where the work actually stands:

| Change | State |
|---|---|
| Bounded DETS snap store → full MPT state trie | done |
| Engine API server for CL communication | done (transition config values are passed through, not interpreted) |
| Block execution: receipts, logs, bloom, state root, EIP-4788, EIP-4895, EIP-2935 | done, and the two system-contract EIPs verified against live Sepolia data |
| Block authoring (proposer duties) | **not done** — the node builds and executes blocks but is never selected to author one |
| Per-fork exact gas schedule | **not done** — the EVM charges one flat, fork-unaware table. A fork-parameterized table (`eth_fork_schedule:gas_cost/3,4`) exists, is exported and is unit-tested, but nothing in the execution path calls it, so it is dead code and the two tables were never compared. Whether an approximate schedule is the *only* reason this node's state roots do not match the network's is unverified: it cannot be checked end-to-end without real prestate |
| Honest stateRoot verification | done for the current block; historical blocks are not re-executed |
| Receipt verification on the peer path | done — a peer's `receiptsRoot` is recomputed from the executed body and compared, and reported as `{verified, Root} \| {unverified, Reason}` |
| Transaction validation (nonce, balance, chain ID, gas limit, intrinsic gas, signature) | done — one validator, called on the peer path before execution, with the offending transaction's index reported |
| Transaction state effects (nonce, value, gas purchase, coinbase tip, base-fee burn) | done — the sender is charged the ceiling and refunded the effective price, the recipient gets the tip only, the base fee is burned. Not checked against real prestate |
| EIP-161 empty accounts, EIP-170 code size | done |
| KZG commitment verification (EIP-4844) | **not done** |
| Snap sync and proof-verified state reconstruction | **not done** |
| Merge detection via TTD | **not done** — Paris is the floor unconditionally |

Because the gas schedule is approximate, etherlang can execute blocks and report a state root, but that root is not expected to equal the one the network computed. The exact per-fork gas table and KZG commitment verification are listed above and are not done. Note that the fork-parameterized gas table that *looks* finished is not reachable from execution, so the gap is wider than its tests suggest. It is not established that the gas schedule is the *only* remaining divergence, because that cannot be checked without real prestate.

**Dependencies:** None — this is pure Erlang/OTP, no external consensus libraries needed.

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
- [x] **EIP-4788 beacon roots** — runs the deployed contract's code rather than
  writing the ring-buffer slots directly. Verified by executing the bytecode from
  `eth_getCode` with a real Sepolia block's timestamp and parent beacon root, and
  requiring the two slots that block's state actually contains. Doing this
  surfaced four defects that had made the EIP a silent no-op, the worst being a
  system address of `0x0000...00FFFE` instead of `0xff..fe` — the contract's
  first instruction rejected every call, and because the EIP requires a failed
  call to be ignored, the block still validated.
- [x] **EIP-4895 withdrawals** — applied through the state overlay so the credits
  land inside the block's state root. `withdrawalsRoot` is the MPT root keyed by
  `rlp(position)`, not an SSZ merkleization hash; verified against two real
  Sepolia blocks.
- [x] **No consensus-layer** — execution-layer-only by design; validators are out
  of scope (documented), not TODO. Block *authoring* is in scope and is listed
  above as not done.
- [x] **devp2p base** — discv4 discovery + RLPx transport in pure Erlang,
  tested against geth protocol vectors (v0.5.0).
- [x] **Peer-first sync** — `eth/68` Status/headers/bodies with strict ForkID,
  auto-dial, root-verified bodies/receipts into the store (v0.6.0).
- [x] **Receipts locally** — receipts store + tx index,
  `eth_getTransactionReceipt`/`eth_getLogs` served locally first (v0.6.0).
- [x] **Transaction pool** — signature/chain/gas/nonce/balance validation,
  pending/queued tiers, price eviction, gossip receive + broadcast,
  `eth_sendRawTransaction` local-first (v0.7.0).
- [x] **State heal** — snap ranges with boundary-proof verification into a
  persistent leaf store; `eth_getBalance`/`Nonce`/`Code`/`StorageAt`
  served locally first (v0.7.0).
  - [x] **Chain store consistency + reorg backoff + partial window** —
    `dets:sync`, exponential backoff, partial window fetch
    (`eth_chain`, `eth_sync`) (v0.7.2).
  - [x] **Batch spec + upstream error codes + API key auth** —
    `safe_handle_one` catches crashes per-batch-item; proxy maps
    decode/transport errors to distinct codes; `RPC_API_KEY` auth
    (`eth_rpc_handler`, `eth_rate_limit`, `eth_rpc_server`) (v0.7.3-4).
  - [x] **SSTORE refunds applied to gas** — EIP-2200 refunds capped at
    half gas used, added to final gas (`eth_evm:run_t`) (v0.7.3).
---

## How syncing works

Each tick the node tries **eth-ready peers first**, RPC second:

* **Peer sync** — backward walk (192-header reverse batches) from a peer's
  best hash to a local anchor, then forward fill: bodies fetched per header,
  `transactionsRoot` verified, blocks assembled and appended through the
  normal chain path (reorg logic reused); receipts fetched, verified against
  `receiptsRoot`, and stored. Empty stores advertise genesis `Status` so
  peers accept them as syncing remotes.
* **RPC gap sync (fallback)** — fetch blocks `start..head` in bounded
  parallel windows via `eth_getBlockByNumber`.
  * Recent blocks (inside `BODY_WINDOW`) are stored **with full bodies**.
  * Everything older is stored **header-only** (transactions as hashes), so
    historical sync is fast and light.
* **Chain integrity checks** even without a VM:
  * contiguous block numbers (`head+1` per append),
  * `parentHash` linkage against the locally stored canonical hash,
  * reorg detection (up/down) with a bounded **ancestor walk** back to the
    common ancestor, then a local rewind and re-sync from `CA+1`.
* **Follow mode** — polls peers/`eth_blockNumber` and pulls new blocks as
  they appear. Head is persisted, so restarts resume where they left off.
* **State honesty** — the local EVM executes calls but never re-executes full
  blocks, so `stateRoot` is *not* re-verified; it is trusted from upstream.
  `transactionsRoot`/`receiptsRoot` are derived from the block's own body and
  **are** checked. Where a block is finalized, all three are reported as
  `{verified, Root} | {unverified, Reason}` verdicts rather than as bare roots.

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

For the two local host daemons (the topology this repo develops on) everything
is one command — `tools/etherlangctl start|stop|restart|status [A|B|both]` —
which wraps the release scripts for node A (`_build/default`, :8545) and node B
(`_build/node2`, :8546).

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
| `RPC_LISTEN_IP` | `127.0.0.1` | interface to bind (`0.0.0.0` exposes to the network) |
| `RPC_MAX_BATCH` | `30` | max requests per JSON-RPC batch |
| `RPC_RATE_LIMIT` | `30` | per-client requests/s (`0` disables) |
| `RPC_RATE_BURST` | `100` | max burst a client may send at once |
| `DATA_DIR` | `./data` | persisted chain store |
| `ETH_START_BLOCK` | `latest` | sync start (see above) |
| `SYNC_CONCURRENCY` | `8` | parallel block fetches |
| `BODY_WINDOW` | `2048` | most-recent N blocks stored full-body |
| `CHAIN_RETENTION` | `2048` | max recent blocks kept locally (older prune; clamped ≥ `MAX_REORG_DEPTH`) |
| `POLL_INTERVAL_MS` | `5000` | follow-mode poll interval |
| `MAX_REORG_DEPTH` | `256` | ancestor-walk bound while resolving reorgs |
| `HTTP_TIMEOUT_MS` | `20000` | per-request upstream timeout |
| `SYNC_BUDGET` | `2048` | max blocks fetched per sync tick |
| `SYNC_RETRY_MS` | `2000` | currently stored, backoff wiring pending (see TODO) |
| `VERIFY_HEADERS` | `true` | recompute + verify each header hash locally (`false` skips) |
| `EVM_ETH_CALL` | `true` | execute `eth_call` in the local EVM (`false` forces proxy) |
| `DISCV4_ENABLED` | `false` | run discv4 UDP discovery (k-buckets, bonding) |
| `DISCV4_PORT` | `30303` | UDP port for discovery |
| `DISCV4_BOOTNODES` | `` | comma-separated `enode://` discovery seeds |
| `RLPX_ENABLED` | `false` | run RLPx TCP listener + peers |
| `RLPX_PORT` | `30303` | TCP port for RLPx |
| `PEER_TARGET` | `10` | desired peer count for auto-dial |
| `PEER_DIAL_INTERVAL` | `10000` | ms between auto-dial maintenance ticks |
| `TX_POOL_MAX` | `1024` | max pooled transactions |
| `TX_POOL_PER_SENDER` | `16` | max pooled transactions per sender |
| `STATE_SYNC_ENABLED` | `false` | run the snap state-heal worker |

## Local JSON-RPC methods

Served locally: `eth_blockNumber`, `eth_syncing`, `eth_getBlockByNumber`,
`eth_getBlockByHash`, `eth_getBlockTransactionCountByNumber`,
`eth_getBlockTransactionCountByHash`,
`eth_getTransactionByBlockNumberAndIndex`, `eth_getTransactionReceipt`,
`eth_getLogs` (address/topics filters, capped range), `eth_sendRawTransaction`
(validated + pooled + gossiped), `eth_call` (local EVM
when enabled, proxy fallback), `web3_clientVersion`, `eth_getVersion`
(EthStats-compat shim), `eth_coinbase` (zero address), `eth_mining`
(`false`), `eth_hashrate` (`0x0`), `eth_getBalance`/`eth_getTransactionCount`/
`eth_getCode`/`eth_getStorageAt` (local-first from the state store).
`eth_sendTransaction` (needs keys) and everything else is proxied to the
upstream node transparently.

Notes: served blocks carry Sepolia TTD as `totalDifficulty` when upstream
omits it (post-merge constant, v0.2.6); `eth_getBlockByNumber` requires
`[hex, bool]` params or the request falls through to proxy; `latest`/`pending`
resolve against the local head while a proxied miss resolves against
upstream's — avoid mixing the two mid-sync.

## Tests

Tests run against an **in-process mock upstream node** (no network needed)
plus loopback devp2p stacks (discovery + RLPx + eth, real sockets); they
cover gap sync, live follow, reorg handling + rewind, finalized-floor
guards (never ahead of head / off-chain), persistence across restart, the
JSON-RPC client, the JSON-RPC server (local + proxy + batch + `totalDifficulty`
compat), receipts store + filters, txpool (validation/ordering/gossip/RPC),
peer-first sync with verified
bodies/receipts, snap state heal, shift/dispatch EVM regressions, and the
local `eth_call`
override path — **185 tests, all green**.

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
  etherlang_sup.erl      supervisor (state -> chain -> rpc server -> sync [+ discv4/peer])
  eth_config.erl          env/config resolution
  eth_hex.erl             0x-hex encode/decode
  eth_word.erl            256-bit word arithmetic
  eth_rlp.erl             RLP encoding + decoding
  eth_keccak.erl          pure-Erlang Keccak-256 (+ incremental API)
  eth_header.erl          header hash recomputation + verification + RLP/map conversion
  eth_chain.erl           canonical chain store (DETS) + reorg/rewind + receipts + tx index
  eth_state.erl           call-state overlay (overrides) + upstream cache
  eth_evm.erl             local EVM interpreter (full defined opcode set)
  eth_evm_precompiles.erl precompiles 0x01-0x09 (0x0A KZG proxies) + bn128 EC ops
  eth_pairing_bn128.erl Tate pairing check (EIP-197), pure Erlang
  eth_call.erl            eth_call execution incl. contract creation
  eth_rpc_client.erl      JSON-RPC client over HTTP(S) (httpc)
  eth_sync.erl            peer-first + RPC gap/follow sync engine + finality tracking
  eth_rpc_server.erl      cowboy listener
  eth_rpc_handler.erl     JSON-RPC dispatch + receipts/logs + upstream proxy + TD compat
  eth_secp256k1.erl       keygen/sign/recovery, pure Erlang
  eth_ecies.erl           ECIES for the RLPx handshake
  eth_snappy.erl          snappy framing for capability messages
  eth_discv4.erl          UDP discovery wire + k-buckets + bonding
  eth_rlpx.erl            EIP-8 handshake + framing + Hello/Ping/Pong
  eth_peer.erl            peer manager (listener, manual + auto-dial, broadcast)
  eth_peer_conn.erl       one RLPx connection (p2p + eth Status/headers/bodies/receipts/txs)
  eth_eth.erl             eth/68 capability (negotiation, Status, headers/bodies/receipts/txs)
  eth_forkid.erl          EIP-2124 ForkID schedule/hash/validation
  eth_trie.erl            hexary Merkle-Patricia root/proof computation
  eth_tx.erl              transaction RLP encode/decode + tx-root + sender recovery
  eth_txpool.erl          pending pool (validation, ordering, eviction, gossip)
  eth_receipt.erl         receipt RLP encode/decode + roots + blooms
  eth_bloom.erl           2048-bit logs bloom
  eth_snap.erl            snap/1 capability codecs + range verification
  eth_statestore.erl      snap-landed state leaf store (ETS ranges + DETS)
  eth_statesync.erl       snap heal worker (accounts/storage/codes)
  eth_nodekey.erl         persisted static node key (shared by discv4 + RLPx)
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

* Local VM re-execution of full blocks to verify `stateRoot` (EVM exists;
  execution plumbing per-tx through `eth_call` is proven — block-scoped
  replay with receipts is the remaining work)
* `eth_getBalance` from local state
* snapshots for instant bootstrap (archive-style data-dir downloads)
* EVM fidelity items from the TODO list (revert/value semantics, transient
  scope, gas model, remaining precompiles)

## Release notes v0.4.0 → v0.7.0 (devp2p + receipts)

* **v0.4.0** — KZG point-evaluation pairing fix, mainnet fixture green.
* **v0.5.0** — devp2p base in pure Erlang: discv4 discovery, RLPx
  transport (ECIES, snappy, secp256k1 recovery), MPT.
* **v0.6.0** — `eth/68` Status/headers/bodies/receipts with strict ForkID,
  auto-dial, peer-first sync with root-verified bodies/receipts; receipts
  store + local `eth_getTransactionReceipt`/`eth_getLogs`; tx/receipt RLP
  codecs. Suite 110 → 166.
* **v0.7.0** — txpool (validation, pending/queued tiers, eviction, gossip,
  `eth_sendRawTransaction`); snap state sync (proofs, leaf store, heal
  worker, local state reads). Suite 166 → 185.

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

## Release notes v0.2.1 → v0.3.2 (all verified live on Sepolia)

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
* **v0.2.7** — docs: full README overhaul (EVM documented as implemented,
  corrected methods/config/layout, refreshed TODO with done-list) + support
  section/sponsors wiring + live smoke-test script committed.
* **v0.2.8** — P0 value semantics (revert rolls back transfers, balance
  checks, precompile value moves, `create_address` split fix) + tx-global
  transient storage + `BLOBHASH` fallback + child-log propagation
  (suite 64/64; both nodes live-verified).
* **v0.2.9** — execution fidelity round 2: EIP-198 `MODEXP` gas, EIP-6780
  selfdestruct, EIP-2929 warm/cold (`SLOAD`/`BALANCE`/ext-code/`CALL`),
  `create_address` fix (CREATE always crashed); suite 76/76.
* **v0.3.0** — precompiles `0x01` ECRECOVER (secp256k1 recovery, 76-vector
  upstream parity), `0x06`/`0x07` ECADD/ECMUL (alt_bn128, live vectors),
  `0x08` ECPAIRING (Tate, 39-vector parity incl. engineered true cases),
  `0x09` BLAKE2b-F (EIP-152 vectors byte-exact); suite 103/103. Only `0x0A`
  KZG remains on proxy fallback (deliberate: needs BLS12-381 + unserved
  blobs).
* **v0.3.1** — bounded chain store: DETS files cap at 2 GiB and the old store
  grew without bound until both nodes crashed on start (`no_more_space_on_file`
  opening `chain.num.dets`). Added `CHAIN_RETENTION` (default 2048) with
  incremental pruning from a persisted `low` watermark — blocks below
  `head - retention` are dropped (the finalized block is always kept, and
  retention is clamped ≥ `MAX_REORG_DEPTH`), older blocks serving from the
  proxy. Sepolia's blob-heavy blocks run ~330 KB each and every retained
  block carries a full body, so retention 2048 caps the store near ~800 MiB
  (4096 would leave the file too close to DETS' ceiling). `BODY_WINDOW`
  default lowered 100000 → 2048. 2 new tests; suite 105/105.
* **v0.3.2** — RPC endpoint hardening: binds `127.0.0.1` by default
  (`RPC_LISTEN_IP`), caps JSON-RPC batch size (`RPC_MAX_BATCH`, too-large
  batches get a single `-32600` error), and a per-source token-bucket rate
  limit (`RPC_RATE_LIMIT`/`RPC_RATE_BURST`, excess → HTTP 429 `-32005`).
  4 new tests; suite 110/110.

## License

MIT — see [LICENSE](LICENSE).