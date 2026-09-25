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
  - Withdrawal root (EIP-4895), Request hash (EIP-4788)
- [ ] **Block execution** — execute transactions in order within the block
  - Apply each transaction (value transfer, contract creation, contract call)
  - Update state trie after each transaction
  - Collect receipts and logs, Track gas used and refunds
- [ ] **Withdrawals** — process beacon block withdrawals (EIP-4895)
- [ ] **Beacon requests** — handle `engine_notifyHeaders` and beacon root requests (EIP-4788)
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
- [x] **State root verification** — verify state root after every block execution (EIP-4788) ✅

## Phase 5: Protocol Compliance (12 tasks)
- [ ] **Per-fork exact gas schedule** — replace approximate gas with exact per-fork schedule
  - Istanbul, Berlin, London, Arrow Glacier, Gray Glacier, Merge, Bellatrix, Paris, Shanghai, Cancun, Deneb
  - Each fork's exact gas costs for all opcodes
  - Dynamic base fee calculation (EIP-1559), Blob gas accounting (EIP-4844)
- [ ] **EIP-1559** — base fee calculation and burning
  - Compute base fee per block, Burn base fee (update state trie), Priority fee handling
- [ ] **EIP-4844 (blobs)** — blob transactions support
  - Blob transaction type (0x03), Blob gas pricing, KZG commitment verification, Blob data propagation
- [ ] **EIP-4788 (beacon roots)** — store beacon block roots in state
  - `BLOCKHASH` opcode returns beacon block root
  - Beacon root contract (0x0000000000000000000000000000000000000000000000000000000000000000)
  - Beacon root storage in state trie
- [ ] **EIP-4895 (withdrawals)** — process withdrawals from beacon block
  - Withdrawal schedule, Withdrawal root in block header, Process withdrawals in execution payload
- [ ] **EIP-3675 (PoS merge)** — full PoS execution engine
  - `TERMINAL_TOTAL_DIFFICULTY` handling, `TERMINAL_BLOCK_HASH` handling, PoW difficulty = 0 after merge
- [ ] **Geth-compatible devp2p** — full protocol compliance
  - `eth/68` with all sub-protocols, `eth/69` (history) if needed
  - Snap protocol (`snap/1`) full compliance
  - `discv5` discovery (UDP v5) instead of `discv4`
  - Full `Status` message with fork compatibility
- [ ] **stateRoot honest verification** — re-execute every block locally and verify the state root matches
- [ ] **Receipt verification** — verify transaction receipts on the peer path
- [ ] **Full transaction validation** — validate every transaction in every block
  - Signature verification (secp256k1), Nonce checking, Balance checking
  - Chain ID checking, Gas limit checking
- [ ] **EVM opcode fidelity** — bit-exact EVM for all opcodes
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
