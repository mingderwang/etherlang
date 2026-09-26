# etherlang v1.0 — Execution Client Task List

**81 tasks across 9 phases** — Phase 1-5 partially complete (44/81 done, 37 remaining).

## Phase 1: Engine API — Consensus Layer Interface (7 tasks)
- [x] **Engine API server** — `engine_newPayloadV1`, `engine_forkchoiceUpdatedV1`, `engine_getPayloadV1`, `engine_exchangeTransitionConfigurationV1` (`eth_engine`)
  - `engine_newPayloadV1`: receive and validate execution payload from CL
  - `engine_forkchoiceUpdatedV1`: handle safe/finalized forkchoice updates
  - `engine_getPayloadV1`: return the payload for the CL to broadcast
  - `engine_exchangeTransitionConfigurationV1`: negotiate engine version
  - Return correct status codes (`VALID`, `INVALID`, `SYNCING`, `ACCEPTED`, `SECURITY_ERROR`)
- [x] **Payload validation** — validate each payload before accepting:
  - Parent hash matches current head ✅
  - Block number is expected ✅
  - Fee recipient (coinbase) set ✅
  - State root matches after execution (deferred to Phase 4)
  - Receipts root matches after execution (deferred to Phase 4)
- [x] **Transition configuration** — handle `TERMINAL_TOTAL_DIFFICULTY` and `TERMINAL_BLOCK_HASH` correctly for PoW→PoS transition
- [ ] **Safe/finalized forkchoice** — handle CL's safe and finalized forkchoice updates, update `eth_sync:track_finalized/1` to respect CL finality
- [x] **Engine API authentication** — JWT secret via `JWT_SECRET` env var, HMAC-SHA256 verification
- [x] **Execution engine status** — engine status tracked in `eth_engine` gen_server
- [x] **Engine API test vectors** — eunit tests for all 4 engine methods

## Phase 2: Full State Trie — Replace Bounded Snap Store (8 tasks)
- [x] **MPT node type** — implement Extension, Leaf, Branch nodes (`eth_trie`)
- [x] **MPT insertion** — insert key-value pairs into the trie, update hashes (`eth_trie:insert/3`, `eth_mpt`)
- [x] **MPT verification** — verify state proofs (account proof, storage proof) (`eth_trie:verify_proof/3`, `eth_mpt:prove_account/1`)
- [x] **MPT encoding** — RLP encode/decode trie nodes (`eth_trie:encode/1`, `decode_compact/1`)
- [x] **Account trie** — map account addresses to account nodes (balance, nonce, codeHash, storageRoot) (`eth_mpt:put_account/4`)
- [x] **Storage trie** — per-account storage tries (slot → value) (`eth_mpt:put_storage/3`)
- [x] **Code storage** — store contract code by keccak hash (`eth_mpt:put_code/2`)
- [x] **State root computation** — compute `stateRoot` from the MPT root hash (`eth_mpt:state_root/0`)
- [x] **Trie iterators** — iterate over all accounts/storage for state sync (`eth_mpt:iter_accounts/0`, `iter_storage/1`)
- [x] **Replace `eth_statestore`** — rewired to use `eth_mpt` internally (replaces bounded DETS snap store)
- [x] **`eth_getProof`** — `eth_mpt:prove_account/1`, `prove_storage/2`, `verify_proof/3`
- [x] **`eth_getStorageAt`** — `eth_mpt:get_storage/2` with proof verification

## Phase 3: Block Production (7 tasks)
- [ ] **Block builder** — construct execution payloads from the transaction pool:
  - Select transactions from pending pool (by gas price / priority fee)
  - Respect block gas limit
  - Handle blob transactions (EIP-4844)
  - Compute gas used, receipts, logs, bloom filter
- [ ] **Block header** — construct full block header:
  - Parent hash, uncle hash, fee recipient, state root, receipts root
  - Logs bloom, difficulty (0 in PoS), number, gas limit, gas used
  - Timestamp, extra data, base fee, blob gas used, excess blob gas
  - Withdrawal root (EIP-4895), Requests hash (EIP-7685)
- [x] **Block execution** — execute transactions in order within the block ✅
  - Each transaction is applied against the state the previous one produced; the EVM reads its message and environment through atom keys, and the caller is always the recovered signer rather than any `from` the payload declares
  - Receipts carry their own `transactionIndex` and a bloom filter over their own logs; the block's bloom is the OR of the receipts'
  - EIP-4788 runs before the transactions and EIP-4895 withdrawals after, both into the same overlay
  - An EVM crash is an exceptional halt that consumes the whole gas limit and discards the frame, which is recorded as an error and not as a revert
  - The state root is recomputed from the committed trie afterwards
  - **Not** a full state transition: the gas schedule is approximate rather than per-fork exact, so the roots this produces do not match the network's
- [x] **Withdrawals** — process beacon block withdrawals (EIP-4895) ✅
  - Applied through the state overlay so the credits are inside the block's state root; `withdrawalsRoot` is the MPT root keyed by `rlp(position)`
  - Verified against two real Sepolia blocks (2 and 16 withdrawals)
- [ ] **Beacon requests** — handle `engine_notifyHeaders` and beacon root requests
  - The execution side of EIP-4788 is done (see Phase 5): the parent beacon block root is carried on the block, read from the payload, and applied at finalization. What is missing is the engine-API plumbing — `engine_notifyHeaders` is not handled, and a new payload's `parentBeaconBlockRoot` is not populated from the consensus client's notification. As it stands, a locally built block has no beacon root, so the system call is correctly skipped and its ring buffer goes unadvanced.
- [ ] **Execution payload building** — integrate with consensus client's `engine_getPayload` flow
- [ ] **Proposer selection** — receive proposer duties from consensus client, produce blocks when selected

## Phase 4: State Management (8 tasks)
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
  - `eth_mpt:snapshot/0` serializes the account, storage and code tables plus the root, and startup restores from it
  - This is a dump of the in-memory maps, not a persistent trie: it grows with the whole state and is written on demand, not per block. A node that relies on it is not faster to restart than one that replays.
- [x] **State root verification** — recompute the state root after executing a block and report `{verified, Root}` or `{unverified, Reason}`. A locally built block has no root to check against and is reported unverified rather than stamped. This is not an EIP; it is a property of the node, and it was previously labelled EIP-4788, which is the beacon-roots system call.

## Phase 5: Protocol Compliance (12 tasks)
- [ ] **Per-fork exact gas schedule** — replace approximate gas with exact per-fork schedule
  - Fork *selection* is done and driven by real network activation points (`current_fork/3`; Paris is the modelled floor, the Merge being a TTD activation rather than a block number). What is not done is the per-fork *gas table*: `eth_evm` still carries one approximate schedule, so opcode costs are wrong on every fork and are not bit-exact against any of them.
  - Istanbul, Berlin, London, Arrow Glacier, Gray Glacier, Merge, Bellatrix, Paris, Shanghai, Cancun, Deneb
  - Each fork's exact gas costs for all opcodes
  - Dynamic base fee calculation (EIP-1559), Blob gas accounting (EIP-4844)
- [x] **EIP-1559** — base fee calculation and burning ✅
  - Per-block base fee from the parent's, using the gas-target and adjustment rules; the burned portion is not credited to the fee recipient
  - Priority fee handling: the effective price a transaction pays is `min(maxFeePerGas, baseFee + maxPriorityFeePerGas)`, so a transaction never bids below the base fee by overpaying the recipient
  - The EIP-1559 chain id is part of every signing preimage, and it is read from configuration rather than from `eth_chainId` over RPC — an id that moved with the upstream endpoint's mood would change which transactions are valid
- [ ] **EIP-4844 (blobs)** — blob transactions support (partial)
  - Done: blob transaction type (0x03), blob gas accounting and `blobGasPrice`, excess blob gas carried across blocks
  - **Not** done: KZG commitment verification. Transactions are accepted and priced without their commitments being checked against the blob, so a block carrying an invalid commitment is not rejected. Blob data propagation is also absent. The item stays open until the commitment check exists.
- [x] **EIP-4788 (beacon roots)** — store beacon block roots in state ✅
  - Runs the deployed contract's code as `0xff..fe` on every post-Cancun block, rather than writing the two slots directly. The EIP permits the shortcut, but only where the code at the address is the code the EIP specifies; hardcoding the slots would silently commit to a state nobody else computed on a network that deployed something else.
  - The ring buffer is two regions 8191 apart, `ts mod 8191` for the timestamp and `+ 8191` for the root. A single buffer keyed by the full timestamp is a plausible encoding and is unreachable — the contract only ever touches these two ranges.
  - Skips the all-zero root (the Cancun genesis placeholder), and fails silently on no code, on revert, or on an exception, as the EIP requires.
  - Not charged against the block gas limit; leftover gas is discarded.
  - Verified against Sepolia: the runtime bytecode fetched from `eth_getCode` reproduces the slots a real block's state actually contains.
  - `BLOCKHASH` returning the beacon root is a separate opcode concern and is not part of this item.
- [x] **EIP-4895 (withdrawals)** — process withdrawals from beacon block ✅
  - Applied through the state overlay, so the credits land inside the block's state root rather than beside it
  - `withdrawalsRoot` is the MPT root keyed by `rlp(position)`, holding `rlp([index, validatorIndex, address, amount])` — not an SSZ hash
  - Capped at 16 per payload, extra entries truncated
  - Verified against two real Sepolia blocks (2 and 16 withdrawals)
- [ ] **EIP-3675 (PoS merge)** — full PoS execution engine (partial)
  - Post-merge blocks are modelled: difficulty is 0 and the header is built in the PoS shape.
  - **Not** done: `TERMINAL_TOTAL_DIFFICULTY` is threaded through the engine config and the block builder but is never *evaluated* against a block's total difficulty, and `TERMINAL_BLOCK_HASH` is not handled at all. Nothing here decides that a chain has crossed the merge; fork selection treats Paris as the floor unconditionally. A pre-merge block would be executed under post-merge rules.
- [ ] **Geth-compatible devp2p** — full protocol compliance
  - `eth/68` with all sub-protocols, `eth/69` (history) if needed
  - Snap protocol (`snap/1`) full compliance
  - `discv5` discovery (UDP v5) instead of `discv4`
  - Full `Status` message with fork compatibility
- [x] **State root verification** — verify the state root after block execution ✅
  - `eth_block:finalize/1` returns `{ok, Block, Verification}` where `Verification.state_root` is `{verified, Root}` or `{unverified, Reason}`. A block the node built itself has no root to check against and is reported unverified; it is never stamped with a root the node cannot justify.
  - The state root is recomputed from the committed trie rather than carried over from the parent.
  - **Not** done: this verifies the node's own execution, not agreement with the network. Blocks arriving from a peer are executed and their declared root compared, but nothing re-executes historical blocks to confirm the local trie still reproduces the roots it once accepted. A locally built block stays unverified indefinitely.
- [ ] **Receipt verification** — verify transaction receipts on the peer path
  - Receipts are *built* during execution (per-transaction index, cumulative gas, own bloom, logs) and the block's receipts root is derived from them, but a receipt arriving from a peer is never recomputed and compared. A peer can declare any receipts root and the node will not notice.
- [ ] **Full transaction validation** — validate every transaction in every block
  - A transaction's sender is recovered from its signature rather than read from the payload, and a sender that cannot be recovered makes finalization fail rather than falling back to a declared address
  - **Not** done: nonce, balance, chain ID and gas limit are not checked against the pre-state, and an invalid signature does not cause the transaction to be rejected — a block whose transaction does not check out is executed anyway
- [ ] **EVM opcode fidelity** — bit-exact EVM for all opcodes
  - The gas schedule is approximate and shared across all forks, so opcode costs are wrong everywhere
  - Run Foundry/vmtests to verify opcode correctness
  - Run generalStateTests to verify state transitions
  - Fix any divergences found

## Phase 6: JSON-RPC API Completion (6 tasks)
- [ ] **Debug API** — `debug_traceTransaction`, `debug_traceBlockByNumber`, `debug_traceBlockByHash`, `debug_traceRawTransaction`
  - Trace mode: `callTrace`, `structLog`, `builtInTracer`
  - Parity-style trace API compatibility
- [ ] **Trace API** — `trace_replayTransaction`, `trace_replayBlock`, `trace_filter`, `trace_transaction`
- [ ] **Miner API** — `miner_start`, `miner_stop`, `miner_setExtra`, `miner_setGasPrice`, `miner_setEtherbase`
  - No-op in PoS but must respond to avoid client incompatibility
- [ ] **Admin API** — `admin_nodeInfo`, `admin_peers`, `admin_datadir`, `admin_startRPC`, `admin_stopRPC`
- [ ] **Personal API** — `personal_importRawKey`, `personal_listAccounts`, `personal_newAccount`, `personal_sign`, `personal_ecRecover`, `personal_sendTransaction`, `personal_unlockAccount`
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
- [ ] **EIP compliance** — EIP-1898 (`eth_chainId`), EIP-1474 (`eth_feeHistory`), EIP-2930 (access lists), EIP-712 (typed data signing), EIP-2718 (typed transactions)

## Phase 7: Consensus Integration (7 tasks)
- [ ] **Lighthouse integration** — test with Lighthouse (Rust, Sigma Prime): Engine API, `eth/68`, ForkID, Payload validation
- [ ] **Prysm integration** — test with Prysm (Go, Prysmatic Labs)
- [ ] **Nimbus integration** — test with Nimbus (Nim, Status)
- [ ] **Teku integration** — test with Teku (Java, Consensys)
- [ ] **Lodestar integration** — test with Lodestar (TypeScript, Chainsafe)
- [ ] **Local test setup** — docker-compose with Lighthouse + etherlang on Sepolia
- [ ] **Mainnet readiness** — test on mainnet with a real consensus client

## Phase 8: Testing & Verification (7 tasks)
- [ ] **Foundry tests** — `forge test` with `--rpc-url` pointing to etherlang; contract deployment, execution, opcode regression tests
- [ ] **Geth test vectors** — run geth's test suite: block execution, state transition, transaction, VM tests
- [ ] **Property-based tests** — property-based testing of EVM execution
- [ ] **Fuzz testing** — fuzz the EVM interpreter for edge cases
- [ ] **Differential testing** — run same block through etherlang and geth, compare outputs
- [ ] **Performance benchmarks** — block processing speed, state access latency
- [ ] **Conformance tests** — run Ethereum Foundation conformance tests

## Phase 9: Infrastructure & Operations (10 tasks)
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
