# etherlang v1.0 — Execution Client Task List

**81 tasks across 9 phases** — Phase 1-5 partially complete (44/81 done, 37 remaining).

## Phase 1: Engine API — Consensus Layer Interface (7 tasks)
- [ ] **Engine API server** — `engine_newPayloadV1`, `engine_forkchoiceUpdatedV1`, `engine_getPayloadV1`, `engine_exchangeTransitionConfigurationV1` (`eth_engine`). All four are served, over real HTTP, with the response shapes the specification defines and with a JWT check on every request. What they cannot do is validate anything, and until a payload decoder exists they do not pretend to. This item was marked complete; it is not. What each method actually does:
  - `engine_newPayloadV1` checks only that `parentHash` is present and is 32 bytes of DATA, then answers **`SYNCING`** — the specification's status for a payload whose "requisite data for the payload's acceptance or validation is missing", which is this node exactly. It does not decode the header, execute the transactions, or check the state root, the transactions root, the receipts root, `gasUsed` or the blob-gas fields
  - It does not answer `ACCEPTED` either, and that is a deliberate change. `ACCEPTED` is in the status enum, so returning it looks right, but the specification makes it a claim with preconditions — every transaction non-empty, `blockHash` equal to `Keccak256(RLP(header))`, the payload not extending the canonical chain, not fully validated, and its ancestors known and well-formed. None is checked here, so `ACCEPTED` is as unsupported as `VALID`
  - `engine_forkchoiceUpdatedV1` records the client's `headBlockHash`, `safeBlockHash` and `finalizedBlockHash` as this node's head, safe block and finalized checkpoint, and answers **`SYNCING`** for any head it has not itself validated. Per the specification that method's `VALID` *is* the verdict on executing the block, so the previous unconditional `VALID` was the claim the node actually made: a block reported valid without executing it, decoding it, or checking a single one of its three roots. `VALID` is still returned for the one case with nothing to judge — no head claimed and no payload to build on
  - It does **not** check that the head exists, that it descends from the finalized block, or that the finalized block is a checkpoint, and it cannot: the head is now recorded as a *hash*, which is what the specification's field is, where it used to be resolved to a block *number* through `eth_chain`
  - `engine_getPayloadV1` takes the specification's `payloadId` and answers `-38001 Unknown payload` for all of them. The builder that would issue a `payloadId`, `eth_block_builder`, is not started (see Phase 3), so no id this node could be asked about is one it issued. It used to take no argument at all and return the last payload the client had itself submitted to `newPayload` — not a block this node built, and not necessarily one it believes is valid, which is a block a consensus client would have broadcast
  - `engine_exchangeTransitionConfigurationV1` returns the `TransitionConfigurationV1` object — `terminalTotalDifficulty`, `terminalBlockHash`, `terminalBlockNumber` — which is the whole purpose of the method. It used to return a bare `VALID`, so the client received no configuration at all from the one call that exists to hand it over
  - `eth_engine` never calls `eth_block`, `eth_mpt` or `eth_tx`, and never compares a root. That was checked by grep rather than assumed
- [ ] **Payload validation** — validate each payload before accepting:
  - Parent hash is present and well-formed ✅ — the only check performed. It is deliberately **not** compared against the recorded head: a payload whose parent is not the head is not invalid, it is a side branch or an unimported block, and the specification answers `SYNCING` to both, so the comparison could not decide anything
  - Block number is expected — **not** done. This line was marked complete and is not
  - Fee recipient (coinbase) set — **not** done
  - `blockHash` equals `Keccak256(RLP(header))` — **not** done, and required by the specification even during an active sync
  - State root matches after execution — **not** done here. `eth_block:finalize/1` computes it and reports `{verified, Root} | {unverified, Reason}` (Phase 4/5), but `eth_engine` never calls `finalize/1`, so the verification exists and is tested and is unreachable from the engine's only entry point
  - Receipts and transactions roots match after execution — **not** done here, same reason
  - The missing piece is a decoder: no payload-to-`#block{}` function exists anywhere, so there is no path from the engine's JSON-RPC payload to the code that could verify it
- [x] **Transition configuration** — the configuration is now parsed and returned, and parsed as what the specification says it is: a `QUANTITY`, i.e. hex. It was decoded with `binary_to_integer/1`, which is base 10, so every real terminal total difficulty — `"0xc70d815d562d3cfa955"` for mainnet, and the `2^256-1` the specification mandates for an undecided value — raised `badarg` and the surrounding catch turned it into `SECURITY_ERROR`. No network with a non-trivial total difficulty could exchange its configuration at all. An absent value is now reported as `2^256-1`, and the map handed to the client is built from the values just parsed rather than the ones being replaced. `TERMINAL_TOTAL_DIFFICULTY` is also the Merge's activation input, and fork selection evaluates a block's total difficulty against it (see EIP-3675 in Phase 5). `TERMINAL_BLOCK_HASH` is carried and echoed, but nothing checks a post-Merge block's difficulty against it or validates that the last PoW block is the one it names — that part is **not** done and is listed under EIP-3675 below
- [ ] **Safe/finalized forkchoice** — the hashes are recorded, as the block hashes the specification defines them to be; they were resolved to block *numbers*, which cannot tell two blocks at the same height apart, and which made an ordinary forkchoice update depend on `eth_chain` being up — a call to it raised `noproc`, which the catch turned into an error for the whole request. What is still missing is resolving them against the local chain: ancestry from head to finalized, checkpoint checks, and `eth_sync:track_finalized/1` respecting CL finality
- [x] **Engine API authentication** — implemented in `eth_jwt` against `src/engine/authentication.md`: HS256, `alg: none` rejected, the `iat` claim required and bounded to ±60 seconds, unrecognized claims ignored, a hex-encoded 256-bit secret read from `DATA_DIR/jwt.hex` and generated on first start. This was ticked before it existed. The handler read no secret and verified no token, so the port was open to anything that could reach it while TASKS.md and the handler's own header comment described it as authenticated. A node with no secret now refuses the port rather than serving it open
- [x] **Execution engine status** — engine state is held in `eth_engine` and the CL's head/safe/finalized are kept in it. `eth_engine` is now a supervised child, started before the listener that serves it; it was declared in `etherlang.app.src`'s `registered` list — a claim that a process is running — but nothing started it, so every engine method in a real node was answering from a gen_server that did not exist
- [x] **Engine API test vectors** — `eth_engine_tests.erl`, 38 tests: the status each method may honestly return, the JSON key and hex forms a real request carries, the state actually being kept, the response shapes, the authentication rules, and the HTTP surface end to end through a real listener. There were **none** before: `grep -rl eth_engine apps/etherlang/test/` returned nothing, so every claim this project made about the engine was unchecked
- [ ] **Engine API version coverage** — only the V1 methods are served. Cancun requires `newPayloadV2`/`V3`, `forkchoiceUpdatedV2`/`V3` and `getPayloadV2`/`V3`; Prague requires V3. A Lighthouse client on either fork calls a method this node does not implement
- [ ] **`engine_getPayloadBodiesByHashV1` / `engine_getPayloadBodiesByRangeV1`** — absent entirely. Lighthouse requires both, so "Lighthouse-compatible" is not currently true of the engine surface
- [ ] **`engine_notifyHeaders`** — absent (see the Beacon requests item under Phase 3)
- [ ] **Block authoring** — no `payloadAttributes` handling, so `forkchoiceUpdated` can never return a `payloadId` and the node cannot build a block for the CL. This is the remaining reason the engine cannot be used in production: it can neither validate what the CL proposes nor produce what the CL should propose

### What the engine could not do before this pass

Recorded because the documentation claimed otherwise, and because each of these was found by running the code rather than reading it:

- **`engine_newPayloadV1` crashed on every payload.** `#st.payloads` was declared with no default and `init/1` never set it, so it was `undefined`, and the `maps:put/3` that stored the payload raised `badmap` — inside a `try` whose catch turned it into `{INVALID, {error, {badmap, undefined}}}`. The method refused everything, well-formed payloads included, and returned a plausible status. `getPayloadV1` then had nothing to return. Every field of the record now has a default
- **No field lookup could ever match.** Every lookup was `maps:get("someKey", Map, Default)` with a *string* key. A decoded JSON object has *binary* keys, so over HTTP nothing was ever read: `newPayload` saw no `parentHash` and answered `INVALID, missing_parent_hash`, `forkchoiceUpdated` saw no head and answered `VALID`, and the transition configuration kept the values it already had. All three returned well-formed statuses while reading nothing
- **Every write to the engine's state was discarded.** `handle_call({save_state, _NewState}, _From, S)` returned the *old* state, so the head, safe block and finalized checkpoint went nowhere — and the call still answered `VALID`
- **The `head` was stored in the wrong position of the wrong shape.** It was typed `{integer(), binary()}` and stored as `{HeadHash, undefined}` while being read out of the *second* position, so the value compared against a payload's `parentHash` was always `undefined` — which the code reads as "no opinion". The parent-hash check could not reject anything
- **The handler could not match its own module.** `handle_forkchoice_updated` and `handle_exchange_config` matched the *strings* `"VALID"`, `"SYNCING"`, `{"INVALID", Reason}` against return values that are *binaries*, so neither matched any clause and both raised `case_clause`
- **Every method read the wrong parameter shape.** All four take their arguments positionally — `newPayloadV1` an `ExecutionPayloadV1`, `forkchoiceUpdatedV1` a `forkchoiceState` and a `payloadAttributes`, `getPayloadV1` a `payloadId`, the configuration exchange a `TransitionConfigurationV1`, each as `params[n]`. Three of the four handlers read them as objects with named keys (`#{<<"payload">> := P}`), so every well-formed request was answered `invalid params`. That is why the engine could be visibly broken without needing a payload decoder to be visibly broken: it never got as far as needing one
- **Responses were not the shapes the specification defines.** `newPayload` returned a bare status string where the specification has a `PayloadStatusV1` object, and included a `payloadId` that response has no field for; `forkchoiceUpdated` returned a bare string where the specification has `{payloadStatus, payloadId}`; the configuration exchange returned a status where the specification has the configuration
- **The port was unauthenticated** — see the authentication item above

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
  - The sub-tasks are listed as work to do, but the code for most of them is
    already written in `eth_block_builder` and is unreachable. The module is a
    `gen_server` that nothing starts — it is in neither `etherlang.app.src`'s
    `registered` list nor the supervisor's children — and nothing calls it, so
    `build_block/0,1` would raise `noproc`. Its only surviving use is
    `validate_transaction/2`, from one test file. It is also incomplete on its
    own terms: `build_block/1` reads `parent_hash` and `number` from its options
    and discards both, `do_build/1` re-derives the parent from `eth_chain:head/1`
    instead, and the built payload is never appended
  - Select transactions from pending pool (by gas price / priority fee) — written, unreachable, untested
  - Respect block gas limit — written, unreachable, untested
  - Handle blob transactions (EIP-4844) — the wrapper's fee and commitment-hash checks are real; blob sidecar data is not propagated
  - Compute gas used, receipts, logs, bloom filter — done in `eth_block` during execution and finalization, not here
- [ ] **Block header** — construct full block header:
  - Parent hash, uncle hash, fee recipient, state root, receipts root
  - Logs bloom, difficulty (0 in PoS), number, gas limit, gas used
  - Timestamp, extra data, base fee, blob gas used, excess blob gas
  - Withdrawal root (EIP-4895), Requests hash (EIP-7685)
- [x] **Block execution** — execute transactions in order within the block ✅
  - Each transaction is applied against the state the previous one produced; the EVM reads its message and environment through atom keys, and the caller is always the recovered signer rather than any `from` the payload declares
  - Receipts carry their own `transactionIndex` and a bloom filter over their own logs; the block's bloom is the OR of the receipts'
  - EIP-2935 and EIP-4788 run before the transactions and EIP-4895 withdrawals after, all into the same overlay
  - Which of those apply is decided by the block's own scheduled fork, read from the fork schedule rather than hardcoded
  - An EVM crash is an exceptional halt that consumes the whole gas limit and discards the frame, which is recorded as an error and not as a revert
  - The state root is recomputed from the committed trie afterwards
  - Transaction-level effects are applied, not just the EVM: the nonce bump, the value transfer, gas purchase and settlement, and contract creation. EIP-161's empty-account rule and EIP-170's code-size limit are enforced. See "Transaction state effects" under Phase 5
  - A transaction is validated before it is executed; a block containing an invalid one is refused and nothing is committed
  - **Not** a full state transition: the gas schedule has no per-fork branching, so it prices every fork with Cancun-era rules and the roots this produces do not match the network's
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
- [ ] **Per-fork exact gas schedule** — give the gas schedule the per-fork branching it lacks
  - Fork *selection* is done and driven by real network activation points, including the Merge's total-difficulty activation (`current_fork/4`; see EIP-3675 below). What is not done is the per-fork *gas table*: `eth_evm` still carries one fork-unaware schedule. Within Cancun-era rules that schedule is now bit-exact — and the process of checking it turned up a live 3-gas overcharge on three of the four `CALL` opcodes — but it is applied unchanged to forks where EIP-150, EIP-2929 and EIP-3860 did not yet exist.
  - **There is a fork-parameterized table, it is dead code, and it was also wrong.** `eth_fork_schedule:gas_cost/3,4` (over `base_gas_cost/3` and `dynamic_gas_cost/4`) takes a fork atom, is exported, and has its own unit tests — and nothing in the execution path calls it. The EVM charges `eth_evm:base_cost/1`, which takes no fork, so the fork table passing its tests proved nothing about execution.
  - Checking what that dead table actually said, rather than assuming it was a better version of the live one, found it wrong for **19 of the 256 opcodes** (measured by evaluating both tables across the whole range, cold and warm) while its tests stayed green. With a non-zero length argument it is 21, the two extra being `CREATE` and `CREATE2`, which had no init-code term at all. `SELFBALANCE` was 32000 (it shared a clause with `CREATE`/`CREATE2`, the other two opcodes that read the caller's account); `RETURNDATASIZE` was 2600 (routed through `access_cost/3`); `TLOAD`, `TSTORE`, `MCOPY` and `PUSH0` were **0** (no clause at all, so they fell to a catch-all that prices an unassigned opcode at 0); `SLOAD` was 2; `JUMP`/`JUMPI` were 2; `MLOAD`/`MSTORE`/`MSTORE8` were 2; `SSTORE` was 2 rather than 0; `CALLDATASIZE`/`CODESIZE`/`GASPRICE` were 3; `JUMPDEST` was 2; `INVALID` was 5000. The per-word terms were transposed: `RETURNDATASIZE` carried the 3-per-word copy cost and `RETURNDATACOPY` carried none, so reading the size of a return buffer was billed per byte of it and copying it was free. `CREATE`/`CREATE2` also had no EIP-3860 init-code term, and `CREATE2` no hashing term, so deploying a large contract cost nothing for the code about to run.
  - The tests missed all of it because they sampled nine opcodes the table already had right (`ADD`, `MUL`, `SUB`, `DIV`, `MOD`, `ADDM`, `EXP`, `KECCAK256`, `CREATE`) and none it had wrong. So the earlier claim that wiring the table up "is the start of this task, not the end" was too generous: wiring it up as it stood would have made execution worse. The table is now corrected and pinned by a **whole-table** assertion — the priced set exactly, plus every value — so a missing clause shows up as a missing entry rather than as a silent zero. That test is what would have caught all nineteen.
  - Comparing the two tables also found a **live** bug the fork table did not have. `eth_evm:base_cost/1` has no clause for `CALL`, `CALLCODE` or `STATICCALL`, so all three fell to its `base_cost(_) -> 3` catch-all and were charged 3 gas more than EIP-2929 specifies; `DELEGATECALL`, the one member that *was* listed, was correct. Three gas changes no execution outcome, so no test failed and no contract behaved differently — but `gasUsed` is a receipt field, the receipts root is in the block header, and the header is hashed. Fixed, with the whole family pinned at 2600 cold and 100 warm.
  - **Wiring it up is not a substitution, and the two tables are not interchangeable.** They agree on the *total* for every opcode but not on how it is composed. `eth_evm:base_cost/1` prices a warm access at 100 and its handler adds the cold surcharge separately (2500 for an account, 2000 for a storage slot); `eth_fork_schedule:access_cost/3` returns the **total**, 2600 or 2100, in one figure. Substituting the fork table for the EVM's base would charge a cold `BALANCE` 5100 instead of 2600 (2x), a cold `SLOAD` 4100 instead of 2100, and a cold `CALL` 5200 instead of 2600, because the handlers would add their surcharges on top of a figure that already includes them. So the wiring has to pick one owner of the composition and change the other side to match -- it is a refactor of the charging path, not a one-line change, and it cannot be done by swapping a function name.
  - What is still missing is the part neither table covers: `eth_evm` has no EIP-150 pre-Berlin access costs, and no per-fork branching at all, so its prices are a Cancun-era schedule applied to every fork. `eth_fork_schedule` also has no EIP-3529 refund logic and its `SSTORE` is a bare 0, so the table is not yet a complete per-fork schedule either.
  - Istanbul, Berlin, London, Arrow Glacier, Gray Glacier, Merge, Bellatrix, Paris, Shanghai, Cancun, Deneb
  - Each fork's exact gas costs for all opcodes
  - Dynamic base fee calculation (EIP-1559), Blob gas accounting (EIP-4844)
- [x] **EIP-1559** — base fee calculation and burning ✅
  - Per-block base fee from the parent's, using the gas-target and adjustment rules; the burned portion is not credited to the fee recipient
  - Priority fee handling: the effective price a transaction pays is `min(maxFeePerGas, baseFee + maxPriorityFeePerGas)`, so a transaction never bids below the base fee by overpaying the recipient
  - The EIP-1559 chain id is part of every signing preimage, and it is read from configuration rather than from `eth_chainId` over RPC — an id that moved with the upstream endpoint's mood would change which transactions are valid
  - The per-transaction side is implemented too: the sender is charged the ceiling for the whole gas limit and refunded the effective price for the unused part, the recipient gets `gasUsed * (effectivePrice - baseFee)`, and everything else is burned. Unused gas is therefore also charged its base fee, and a sender whose cap exceeds `baseFee + maxPriorityFeePerGas` forfeits the difference outright. Confirmed by test against the sum of balances, not by inspecting one of them.
- [ ] **EIP-4844 (blobs)** — blob transactions support (partial)
  - Done: blob transaction type (0x03), blob gas accounting and `blobGasPrice`, excess blob gas carried across blocks
  - Done: the point-evaluation precompile `0x0A` is wired into execution. `eth_kzg` implements it and is verified against mainnet exec-specs fixtures, but for a long time `is_precompile(10)` was `false`, so the module was reachable only from its own tests. It is now dispatched, and a real mainnet point evaluation is driven through the EVM by `eth_evm_tests` rather than only through the precompile boundary
  - A precompile that **ran and failed** now has a return of its own, `{error, Reason}`, distinct from `unsupported`. The distinction is load-bearing: `unsupported` means "this node cannot run this, ask someone else", and `eth_call` answers it with an upstream fallback. A point evaluation that fails is not that -- the input is invalid, the answer is a hard failure that consumes the frame's gas, and falling back would substitute another node's verdict for this one's. A failed `0x0A` now halts with `{error, {kzg, point_evaluation_failed}}` and refunds its caller nothing
  - **Not** done: KZG *commitment* verification. `eth_kzg` has `g1_mul/2`, the pairing check and `versioned_hash/1`, but no `blob_to_kzg_commitment/1` -- the G1 MSM over 4096 field elements, the bit-reversal permutation, and the compressed 48-byte encoding. So a transaction's commitment is still accepted without being checked against its blob, and a block carrying an invalid commitment is not rejected. Blob data propagation is also absent
  - **Not** done, and deliberately: `commit_to_blob/1` is *not* implemented, because it cannot be verified here. Its `g1_lin` derivation has to come from the specification, and the published test vector could not be fetched (no network access) and is not present in the repository. Shipping a KZG commitment function that no test can check would be a second table that passes its own tests while being wrong, which is the failure mode this project has already had to unpick twice. It needs the spec text and one authoritative vector before it can be written honestly
- [x] **EIP-4788 (beacon roots)** — store beacon block roots in state ✅
  - Runs the deployed contract's code as `0xff..fe` on every post-Cancun block, rather than writing the two slots directly. The EIP permits the shortcut, but only where the code at the address is the code the EIP specifies; hardcoding the slots would silently commit to a state nobody else computed on a network that deployed something else.
  - The ring buffer is two regions 8191 apart, `ts mod 8191` for the timestamp and `+ 8191` for the root. A single buffer keyed by the full timestamp is a plausible encoding and is unreachable — the contract only ever touches these two ranges.
  - Skips the all-zero root (the Cancun genesis placeholder), and fails silently on no code, on revert, or on an exception, as the EIP requires.
  - Not charged against the block gas limit; leftover gas is discarded.
- [x] **EIP-2935 (block hash history)** — store the last 8191 parent hashes in state ✅
  - Runs the deployed contract's code at `0x0000F90827F1C53a10cb7A02335B175320002935` as `0xff..fe` on every Prague-or-later block, handing it the block's own parent hash. The same reasoning as 4788 for running the code rather than writing the slot directly.
  - The ring is keyed by **block number** (`(number - 1) mod 8191`). EIP-4788's ring next to it is keyed by timestamp, and the two are different accounts with different keying; reusing the beacon-roots helper here would write a slot the contract never reads, and — like the earlier 4788 single-ring defect — fail silently.
  - The public getter answers only for block numbers in `[number - 8191, number - 1]` and reverts outside it. `read_parent_hash/3` enforces the same window, so the shortcut cannot hand back answers the on-chain getter would refuse.
  - Verified against Sepolia by running the bytecode from `eth_getCode`: a real block's parent hash lands in the slot that block's state really contains (re-checked at three separate ring slots), and the getter's window boundaries were confirmed by reverting queries one step past each end.
  - Verified against Sepolia: the runtime bytecode fetched from `eth_getCode` reproduces the slots a real block's state actually contains.
  - `BLOCKHASH` returning the beacon root is a separate opcode concern and is not part of this item.
- [x] **EIP-4895 (withdrawals)** — process withdrawals from beacon block ✅
  - Applied through the state overlay, so the credits land inside the block's state root rather than beside it
  - `withdrawalsRoot` is the MPT root keyed by `rlp(position)`, holding `rlp([index, validatorIndex, address, amount])` — not an SSZ hash
  - Capped at 16 per payload, extra entries truncated
  - Verified against two real Sepolia blocks (2 and 16 withdrawals)
- [ ] **EIP-3675 (PoS merge)** — full PoS execution engine (partial)
  - Post-merge blocks are modelled: difficulty is 0 and the header is built in the PoS shape.
  - The merge is now **detected**, by total difficulty. `{ttd, N, Fork}` is a third activation kind alongside `{block, N, Fork}` and `{time, T, Fork}`, and `current_fork/4` takes a block's total difficulty. Mainnet's `TERMINAL_TOTAL_DIFFICULTY` (58750000000000000000000) and Sepolia's (0) are written down in the schedule as data, which is what the network uses and not a guess about a block number.
  - `#block{}` carries `total_difficulty` and `from_json/1` reads it. `undefined` is distinct from `0`, because Sepolia's TTD *is* 0: conflating them would report a post-Merge chain as pre-Merge forever.
  - This was a silent mis-execution, not a missing feature. Paris was absent from both schedules and `highest_ranked([]) -> paris` could never fire once any listed fork was reached, so every mainnet block from the Merge (15537394) to the Shanghai timestamp — 823461 blocks — was executed as `gray_glacier`: with a difficulty bomb that had already been halted, at a difficulty that should have been zero.
  - An **unknown** total difficulty reports the *pre*-Merge fork, not Paris. The selector fails toward "not merged" on purpose: a caller that guessed "merged" would apply PoS rules to a block it has not established is post-Merge, and would not know it had. `current_fork/3` therefore does not answer the merge question at all, and `eth_block:fork/1` only answers it when the block actually carries the field.
  - **Still not done**: `TERMINAL_BLOCK_HASH` is not handled at all — nothing checks a post-Merge block's difficulty against it, and nothing validates that the last PoW block is the one named. The timestamp-activated forks (Shanghai, Cancun, Prague) are not gated on the merge either, which is right for mainnet and Sepolia because both merged before Shanghai, and would be a bug on a network whose fork order differed. That is pinned by a test rather than left implicit.
- [ ] **Geth-compatible devp2p** — full protocol compliance
  - `eth/68` with all sub-protocols, `eth/69` (history) if needed
  - Snap protocol (`snap/1`) full compliance
  - `discv5` discovery (UDP v5) instead of `discv4`
  - Full `Status` message with fork compatibility
- [x] **State root verification** — verify the state root after block execution ✅
  - `eth_block:finalize/1` returns `{ok, Block, Verification}` where `Verification.state_root` is `{verified, Root}` or `{unverified, Reason}`. A block the node built itself has no root to check against and is reported unverified; it is never stamped with a root the node cannot justify.
  - The state root is recomputed from the committed trie rather than carried over from the parent.
  - **Not** done: this verifies the node's own execution, not agreement with the network. Blocks arriving from a peer are executed and their declared root compared, but nothing re-executes historical blocks to confirm the local trie still reproduces the roots it once accepted. A locally built block stays unverified indefinitely.
- [x] **Receipt verification** — verify transaction receipts on the peer path ✅
  - Receipts are *built* during execution (per-transaction index, cumulative gas, own bloom, logs), and the block's declared `receiptsRoot` is recomputed from them and compared. The transactions root is checked the same way.
  - Both are reported as `{verified, Root} | {unverified, Reason}`, not as a bare root. Reporting only the recomputed value — which is what this did — is not verification: a peer could declare any receipts root and the report would show a self-consistent number under a key that read as though it had been confirmed.
  - The transactions root depends on nothing but the block's own transaction list, so it is checked even when the parent's state is not held locally and the body cannot be executed. The receipts root genuinely needs execution, and is reported `{unverified, not_executed}` on that path rather than guessed.
- [x] **Full transaction validation** — validate every transaction in every block ✅
  - `eth_tx:validate/1,2` is the single implementation. `eth_block:finalize/1` calls it per transaction before executing, and a block containing an invalid one returns `{error, {invalid_transaction, Index, Reason}}` without committing state — executing it anyway would produce a wrong state root and accept an invalid block
  - The transaction pool delegates to it too, which it did not until recently and which documentation here claimed it did. Admission ran three checks of its own and stopped, so the EIP-4844 rules went unchecked on the `eth_sendRawTransaction` path: a blob transaction with no versioned hashes or no `maxFeePerBlobGas` was given a hash and broadcast, and refused only when a block tried to execute it. Those rules had tests — through `eth_block_builder:validate_transaction/2`, which nothing in the application calls. The pool's two weaker duplicates were removed rather than kept in step, since the authoritative chain-id rule is both stronger (it derives a legacy id from `v`, catching a `chainId` field that contradicts the signature) and more correct (a valid EIP-155 transaction carrying only `v` was being rejected for lacking the field)
  - `base_fee` and `blob_base_fee` are deliberately not passed to admission. Both depend on the block being built, so neither is knowable at submission, and a guess would refuse transactions a later block would have accepted. An absent context key means the rule is unchecked rather than passed, so the two floors stay with block execution
  - The sender is recovered from the signature; there is no `from` fallback, and `validate/2` deliberately ignores the payload's `from` because that field is a JSON-RPC annotation, not part of the signed payload
  - Checked, in rule order: type supported → field shapes and ranges → `to`/data/access list → fee fields consistent with the type → fee ceiling against the base fee → EIP-4844 blob rules → the intrinsic gas floor → signature (recoverable, `r` in range, `s` not malleable) → chain id → block gas limit → nonce and balance against the *executing* pre-state
  - **Not** done: the checks read configuration and pre-state the node holds. A transaction is not replayed against a historical root, and no signature is verified against a cached authority set
  - An absent context key means the rule is **unchecked**, not passed. `finalize/1` supplies base fee, gas limit, gas used, chain id, and the balance/nonce lookups, so a caller that omits one is reading a weaker check than it asked for
  - EIP-1559 chain id is read from `eth_fork_schedule:chain_id/0` in the pool and the block executor alike; it used to be hardcoded to Sepolia's `11155111` in the pool, which would reject every transaction on any other chain
- [x] **Transaction state effects** — nonce, value, gas purchase, coinbase tip, base-fee burn ✅
  - Applied in the geth/yellow-paper order: buy gas at the ceiling → bump the nonce → transfer value → run the EVM with `gasLimit - intrinsicGas` → refund the sender at the effective price → pay the coinbase `gasUsed * (effectivePrice - baseFee)`, the base-fee portion being burned
  - Effective price is `min(maxFeePerGas, baseFee + maxPriorityFeePerGas)`; the sender is charged the ceiling for the whole gas limit and refunded the effective price for the unused part, so the base fee on unused gas is burned too
  - EIP-161 is implemented via `eth_state:drop_if_empty/2`: an account touched but left empty must not enter the trie, which is what stops a zero-value transfer to a non-existent address from being committed
  - Contract creation at the transaction level: address `keccak256(rlp([sender, nonce]))[12:]`, init code taken from the calldata, code installed only on success, new account nonce 1, EIP-170's 24576-byte limit
  - **Not** done: none of this is checked against real prestate, so the state root it contributes to is not known to match the network's (see the gas schedule gap below)
- [ ] **EVM opcode fidelity** — bit-exact EVM for all opcodes
  - The gas schedule is shared across all forks, so opcode costs are right for Cancun-era rules and wrong for every earlier fork. **Unverified** as the sole cause of root divergence: the per-fork exact schedule has not been ruled out as the only remaining difference, because that cannot be checked end-to-end without real prestate
  - Fixed within the Cancun-era schedule: `CALL`/`CALLCODE`/`STATICCALL` were each charged 3 gas over the EIP-2929 figure, because they were the only members of their family absent from `eth_evm:base_cost/1` and fell to the catch-all. `DELEGATECALL`, which was listed, was correct — so the family was internally inconsistent and the inconsistency cost 3 gas on every call in every block
  - The catch-all `base_cost(_) -> 3` remains a fallback for any opcode with no assigned cost, and it is a trap that has now fired twice: it once mispriced the four halting opcodes `RETURN`/`REVERT`/`INVALID`/`SELFDESTRUCT` at 3 gas each, and once charged 3 gas on top of EIP-2929 for `CALL`, `CALLCODE` and `STATICCALL`, the only three opcodes the table never listed. An unassigned opcode is still a guess rather than an error, and nothing in the code distinguishes "deliberately free" from "nobody has costed this yet"
  - Fixed: `BASEFEE`, `BLOBHASH` and `BLOBBASEFEE` cost 2, 3 and 2. They cost 20 each, and 2 is the price of the `ADDRESS` family that a range clause had swept them into. A contract reading the base fee in a loop was charged a tenth of the real price, so it ran about ten times deeper than intended and the block's `gasUsed` came out low by that factor
  - Checked and already correct, not guesses: `LOG0`–`LOG4` (a flat 375 base plus `375 * topics` plus `8 * len`, which is right), EIP-2929 warm/cold access (100 base plus 2500/2000 charged from the transient set), and exceptional-halt gas (a frame that throws reports no remainder, and `handle_child/7` adds nothing back, so a failed sub-call cannot refund gas it never spent)
  - Fixed: EIP-3860's 2-gas-per-word init-code cost is now charged inside `do_create/3`. `CREATE` pays 2 a word and `CREATE2` pays 8 — the 2 for the init code plus the 6 for hashing it. Before this, `do_create/3` billed `CREATE2` its hashing term and `CREATE` nothing at all, so deploying a large contract cost nothing for the code that was about to run, and `CREATE2` was short two thirds of what it owes. `gasUsed` is a receipt field, so this was a receipts-root difference on every create in a block
  - The two terms do not double-charge, and that is structural rather than lucky: `eth_tx:initcode_gas/2` prices the *transaction's* `data`, and a contract-creation transaction runs that `data` straight through `eth_evm:run/5` in `eth_block:execute_transactions/5` without ever entering `do_create/3`. The opcode's word cost therefore only ever applies to a nested create
  - Charged unconditionally, because `eth_evm` has no fork and applies one schedule to every block. The Shanghai condition belongs with the per-fork branching that is still missing
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
