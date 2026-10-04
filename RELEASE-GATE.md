# Release gate

**This file says what a release must show before it can be cut. Every cell below is
`GREEN`, `RED` or `ABSENT`, and `ABSENT` is not `GREEN`.**

A gate that reports `PASS` for something nobody runs is worse than no gate: it stops
the checking. That is the failure this repository has already paid for in prose
(AGENTS.md §10 — "a handle that cannot be trusted is worse than none"), and the reason
the tri-state exists.

**Current state: this node would not pass its own gate.** Tier 1 is six of six `ABSENT`, Tier 2's full-corpus floor is unmeasured, and 8 deviations are open. The sections below record that rather than rounding it up.
five of six `ABSENT`, and 8 deviations are open. The sections below record that
rather than rounding it up.

---

## Version semantics

```
v0.MINOR.PATCH
    ^     ^
    |     +-- a defect fix that changes no published conformance figure
    +-------- a MINOR may only raise a floor, never lower one
```

## Three rules that make the rest of this file mean anything

**1. A release claims only the fork it models.** Not "supports" — models: present in
`eth_fork_schedule`, with its opcodes, its gas schedule and its activation points.
The highest fork in `src/` today is **`amsterdam`** (rank 21, mainnet time
1791294816). **`fusaka` appears zero times in `src/`**, so no release may claim it.
`osaka` and `amsterdam` are currently ranked separately with `bpo1`–`bpo5` beside
them, which is the shape those names had *before* they were bundled; reconciling that
with the current fork schedule is a prerequisite for claiming either.

**2. Three states, never two.** `GREEN` — the command runs and the criterion holds.
`RED` — it runs and fails. `ABSENT` — there is nothing to run. An `ABSENT` cell must
name what building it would take, because "we don't check that" is not the same claim
as "it passes" and the difference is the whole point.

**3. Every number carries its corpus.** AGENTS.md §10a: *"a property measured on 266
entries and stated without its scope is a claim about the node that the node does not
support."* `state tests: 255/266 on the committed 25-file subset` — never
`state tests PASS`.

---

## Tier 0 — not waivable

The node must not be able to lie about itself. No release tag without all five.

| # | Gate | Criterion | Command | Status |
|---|---|---|---|---|
| 0.1 | Builds warning-free | zero warnings; `warnings_as_errors` is set | `rebar3 compile` | **GREEN** |
| 0.2 | Whole suite green | `Failed: 0` | `rebar3 eunit` | **GREEN** — 969 passed |
| 0.3 | No commitment returned as a bare value | every entry of a `Verification` map is `{verified,_} \| {unverified,_}`; no exception | review of `eth_block:finalize/1` | **GREEN** |
| 0.4 | Every published figure has a corpus and a date | no number in README/TASKS/AGENTS without both | `eth_published_figures_tests` | **GREEN** — enforced by a test, 2026-10-04 |
| 0.5 | Known deviations exist, dated, each with a measurement | no entry without all four fields | review of §"Known deviations" | **GREEN** — 18 entries |

**0.4 was red for as long as the cell existed, and turned green by being enforced rather
than by being corrected.** The condition is now a test: `eth_published_figures_tests` reads the
pin out of `eest_conformance_tests.erl`'s `?EXPECTED` -- so it tracks the pin rather than a copy
of it -- and requires every markdown item that publishes a conformance figure to either
publish the pin or name the pass it belongs to with a version tag. **A bare ISO date is not
an attribution**: a date says when, a version tag says which measurement.

**It was not a formality. It found three live figures disagreeing with the pin**, all in prose
that reads as current: `250 of 266` in README's EVM-execution row, `254 of 266` in TASKS.md's
block-authoring item, and `250 of 266 now` in TASKS.md's conformance item. Plus seven figures
with a corpus and no date, and one sentence in README that a slice edit had left
ungrammatical. This is the same failure the header of this file records having happened
before -- *"four mutually unequal conformance figures"* -- and it had happened again.

**Seven injections, all shown to bite**: the three stale figures put back, a historical
figure stripped of its version tag, the pin moved under the documentation, the item splitter
turned off, and `re:run/3' losing `global'. The first version of the test passed four of the
seven, including all three stale figures, and that is recorded below rather than fixed quietly.

## Tier 1 — blocking

A release is blocked until these are `GREEN`. **Five of six are `ABSENT`: there is
currently no mechanical evidence that this node produces a block any other client
would accept.**

| # | Gate | Criterion | Status |
|---|---|---|---|
| 1.1 | Block-level conformance | `blockchain_tests` all match | **ABSENT** — the runner says so itself: `eest_state_tests.erl:83-85`, "this node cannot currently execute a whole block against EEST". Needs the validator to execute a whole block and compare state root, receipts root, bloom and header. Also blocked by D-1 and D-2, which would make the comparison mean something. |
| 1.2 | Transaction-level conformance | `transaction_tests` all match | **ABSENT** — a 22-file validity set was measured by hand (3,842/3,884) but is not vendored and not runnable in CI |
| 1.3 | Ecosystem, Engine API | Hive `engine-api` green | **ABSENT** — no Hive configuration anywhere in the tree |
| 1.4 | Peer interoperability | handshakes and syncs a fork with geth, reth and besu | **ABSENT** — no client is installed here and no harness exists, so there is **no evidence either way**. This cell was previously recorded as *known broken*, on a snappy diagnosis that three checks refuted (D-9, now withdrawn). Treat it as unmeasured, not as failing |
| 1.5 | Differential execution | the same payload yields the same state root on ≥2 external clients | **ABSENT** — no harness. This is the check that would catch 1.1's absence most cheaply |
| 1.6 | Fuzzing | ≥N executions, 0 crashes, 0 unexplained mismatches | **ABSENT** — `eth_prop.erl` is a fixed-seed property tester, not a fuzzer, and it generates the inputs it tests |

**The order these unblock in is not the order they are listed.** D-9 first (a few
lines, and 1.4 is unreachable without it), then D-1/D-2/D-3 (consensus correctness,
and 1.1 is meaningless without them), then 1.1, then the rest.

---

## Tier 2 — floors, ratchet only

A release may raise a floor. Lowering one is a release-blocker in its own right.

| # | Gate | Floor | Measured today |
|---|---|---|---|
| 2.1 | committed-subset match rate | ≥ previous release | **255 of 266 (95.9%)** — `match` 255, `state_mismatch` 8, `fork_unreachable` 3, every other outcome 0 |
| 2.2 | full-corpus state match rate | ≥ previous release | **not run since `v1.55`.** Last recorded: 6,786 of 15,660 on the 229 non-`static` files (43.3%), pre-dating the blob-fee, refund-cap, authorization-refund and delegation work. The 25-file subset and the full corpus disagree by ~52 points, so a release that quotes only the subset is quoting the easy 2% |
| 2.3 | both figures recorded, with their directories | mandatory | **GREEN** — TASKS.md header and `apps/etherlang/doc/MEASUREMENTS.md` |
| 2.4 | test count | ≥ previous release | **997** (`make counts`: 49 src modules / 14,334 lines, 64 test modules / 14,224 lines) |
| 2.5 | every consensus constant | derived-and-pinned, or documented-as-a-gap | review — **8 open, all in §"Known deviations"** |
| 2.6 | every new test shown to bite | defect injected, test watched fail, restored, `touch` | review |

### What the 255 hides

Per-fork, on the committed subset — a single headline number is the wrong unit here:

```
Berlin 22/22   Byzantium 15/15   ConstantinopleFix 17/17   Homestead 3/3
Istanbul 18/18   London 22/22   Paris 22/22
Cancun 39/42    Prague 52/56    Shanghai 35/36
Frontier 0/2    (unreachable by block number in this node's schedule, not wrongly executed)
```

Worst suite by divergence: **`eip6780_selfdestruct`, 0 of 5** — every entry, and D-11
is the reason. Three suites are present on disk and execute **zero** entries —
`eip7702_set_code_tx`, `eip7516_blobgasfee`, `eip4844_blobs` — so a green line for each
of them says nothing.

---

## Tier 3 — published, not blocking

Recorded at the release, not gated on.

| # | Item | Measured today |
|---|---|---|
| 3.1 | opcode set | full defined set, Cancun included, reached through a **required** `fork` key in the Env — no default |
| 3.2 | precompiles | `0x01`–`0x0A`, each either local or answering `unsupported`. Note the three-way answer: `{ok,…}` / `{failed,…}` (a call that fails) / `unsupported` (this node cannot run it, and the block is refused) |
| 3.3 | JSON-RPC methods | **33** dispatched: 19 local, 14 local-then-proxy, everything else refused with `-32601`. `eth_createAccessList` is the one genuinely absent method. Derivation: `grep -oE '<<"(eth\|web3\|net)_[a-zA-Z0-9_]+">>' apps/etherlang/src/eth_rpc_handler.erl \| sort -u \| wc -l` |
| 3.4 | Engine API methods | **10**: `newPayload` V1/V2/V3, `forkchoiceUpdated` V1/V2/V3, `getPayload` V1/V2/V3, `exchangeTransitionConfigurationV1`. Absent with reasons: `getPayloadBodiesBy*V1` (raw tx wire bytes are not retained), `notifyHeaders` (no clause found), V4/V5, `getBlobsV1` |
| 3.5 | configuration | every variable `eth_config` reads is in `settings/0`, enforced by a test that scans the source |
| 3.6 | dead code | declared, not merely unwired. Two modules currently fail this: `eth_state_management` and `eth_block_hash_oracle` have no starter, are in `app.src`'s `registered` list, and are absent from AGENTS.md §11 — D-12 |

---

## Known deviations

The mechanism, not an appendix. A deviation without a measurement is an opinion.

```
DEVIATION <id> — <rule> — <scope>
  Measured:  <corpus>  <N/M>  <date>
  Why:       quote the clause, or the measurement. Never "simplified" or "approximate".
  Revisit:   the condition under which this must be re-examined
```

Three of the rules that govern this list: **`not implemented` and `not wired in` are
gaps; `simplified` and `approximate` are not** (AGENTS.md §4.2). Every entry needs a
measurement. Every entry needs a revisit condition, or it rots in the list. And **the
count is itself a gate**: two consecutive releases without reducing it blocks Tier 1.

| id | Deviation | Scope | Measured |
|---|---|---|---|
| **D-1** | ~~**Block-level header validity is not checked at all** — no timestamp, number, gas-limit band, base fee, difficulty or nonce check.~~ **CLOSED 2026-10-04** — and closing it found that the check that now runs was reading the wrong parent. | every block | **Thirteen rules** in `eth_block_validator`, transcribed from `execution-specs`' `validate_header/2` and `check_gas_limit/2`, consulted by `eth_chain` on the append path. Two are unreachable and say so in the module: `gas_limit_below_minimum` cannot fire for a parent at or above 5000 because the lower bound fires first, and `gas_used_above_gas_limit` needs usage above a limit that was itself legal. **The defect that was not on this list:** `verify_blocks` seeded the parent chain with the *head*, so a reorg was validated against the block it was replacing rather than its own parent -- `eth_chain_tests:reorg_test` appended blocks 3..11 against a head of 8 and block 3 was compared with block 8. A contiguous batch cannot show that, because there the head *is* the parent. **Also:** `VERIFY_HEADERS` now gates *validity* and not only hash recomputation, so the operator-facing name understates what it does — see the note in `eth_chain`. |
| **D-2** | ~~**`withdrawalsRoot` is decoded, stored and hashed but never compared against a computed value.**~~ **WITHDRAWN 2026-10-03 — the premise is false.** There is no declared value to compare against, and there are two checks the entry did not know about. | not a defect | **There is no declared `withdrawalsRoot` at this boundary.** `ExecutionPayloadV3` in `execution-apis` lists `parentHash`, `feeRecipient`, `stateRoot`, `receiptsRoot`, `logsBloom`, `prevRandao`, `blockNumber`, `gasLimit`, `gasUsed`, `timestamp`, `extraData`, `baseFeePerGas`, `blockHash`, `transactions`, `withdrawals`, `blobGasUsed`, `excessBlobGas` -- and **no `withdrawalsRoot`**. EIP-4895 does have a section titled "Execution payload validity" whose entire content is `assert execution_payload_header.withdrawals_root == compute_trie_root_from_indexed_data(execution_payload.withdrawals)`, and the assertion is correct -- it is simply **not expressible where a payload is decoded**, because the value it names is not there. The node's own comment said so ("Both are recomputed here from those lists rather than read from anywhere") and was correct to. | **Two checks exist that the entry did not credit.** (i) *Structural:* the computed root enters the header, the header is hashed, and that hash is compared with the payload's own `blockHash`, which the consensus layer derived from the network's real header, real `withdrawalsRoot` included. A payload whose withdrawals did not produce the network's root fails on the block hash. (ii) *Against real data:* `payload_withdrawals_root_matches_the_network_test` compares the node's computed root against the `withdrawalsRoot` published in real Shanghai and Cancun Sepolia payloads, and it agrees. So the rule is enforced twice, once of it against the network's own number. What is absent is a **named verdict** in the `Verification` map, and adding one would mean stamping `{verified, _}` for a value derived from the same list it would be compared against -- the circular `verified` AGENTS.md §4.1 exists to forbid. |
| **D-3** | ~~**A payload with more than 16 withdrawals is neither rejected nor refused.**~~ **CLOSED 2026-10-03** — refused at both decode entry points. | payload validation | `eth_fork_schedule:withdrawals_root/1' truncated at `?MAX_WITHDRAWALS_PER_PAYLOAD' and its own comment said a caller must reject the payload rather than accept the truncated commitment; **no caller did**, so a 17-withdrawal payload got a root computed over 16 of its withdrawals -- a root that is not the root of the payload's own list, so the header stopped committing to what the payload carried and nothing said so. | **Both entry points now refuse it**, in one predicate (`withdrawals_within_bound/1`). The first version put the check only in `payload_roots/2`, and `from_payload/1` still accepted the payload while `payload_block_hash/1` refused it -- two answers to one question, which is the worst shape for a validation rule, and the test caught it because it was written against `from_payload/1`. | **The bound is recorded, not derived.** EIP-4895 does not name a limit; it says the bound is "enforced by the consensus layer", and `execution-apis` states no number either. The macro's comment used to claim "EIP-4895 allows at most 16" -- an attribution no reachable document supports -- and now says so, and the figure is read through `eth_fork_schedule:max_withdrawals_per_payload/0` rather than duplicated as a macro in `eth_block` (§3: one owner per constant). | **Both tests use the committed Shanghai payload, which carries exactly sixteen** -- the cap itself -- so the accepted arm changes nothing and the refused arm is that payload plus one duplicated entry. |
| **D-4** | EIP-7691's blob schedule is not modelled — target 3 blobs and max 6 are EIP-4844's Cancun figures; Prague raises them to 6 and 9 | Prague onward | `eth_fork_schedule.erl:798,804`; the same table carries Prague activations. Legal 7–9-blob blocks are refused and `excess_blob_gas` diverges, changing the state root |
| **D-5** | Any block containing an EIP-7702 transaction gets the empty receipts root | type-4 transactions | `eth_receipt.erl:91-100` maps `0x4` to `unsupported`; `to_wire/1` cannot match and the failure is caught; `eth_block:receipts_root/1` falls back to `eth_trie:root([])`. On the build path the empty root is **stamped and reported verified** |
| **D-6** | ~~**`blockValue` is always 0.**~~ **CLOSED 2026-10-03** — the builder now sums the receipts it actually produced. | block building | `eth_block_builder:block_value/1` read `maps:get(receipts, Verification, undefined)`, and **`Verification` has no `receipts` key** — it holds `state_root`, `transactions_root`, `receipts_root` and `gas_used`, which is what it is for: it answers "what did you check", and receipts are not a verdict, they are the block's own output. So the lookup always answered `undefined`, the branch reserved for "not knowable" was taken every time, and `getPayload` reported `blockValue: 0` for every block this node built. The tip arithmetic below it — `min(priorityFee, maxFee − baseFee)`, and `gasPrice − baseFee` for a legacy transaction — was correct throughout and **never ran once on a real block**. | **Why it survived: the tests agreed with it.** `eth_block_builder_tests` has eight assertions on this function and every one passed the map shape `#{receipts => [...]}`, which is exactly the shape `finalize/1` never produces. So the arithmetic was pinned correctly against a fixture **no production call could have supplied** — *a test that pins the arithmetic and the call shape at once will happily pin a call shape that never happens*. Those eight assertions now pass a receipt list, and a ninth asserts the guard: a `Verification` map is **refused loudly** rather than answered 0. Reverting the call site fails **18** tests, so the regression cannot be reintroduced quietly. | **Not covered, and it is named in the test:** no test exercises `getPayload` on a block that contains a transaction. That needs a funded state in the parent's trie, a signed transaction in a running pool, and a head carrying that state root; `store_head/0` builds a header with no state at all. The existing wire test asserts `blockValue == 0x0`, which is **correct for an empty block** and is why it never noticed. That gap is real and is why this row is closed on a unit-level fix rather than an end-to-end one. |
| **D-7** | ~~**The EVM never enforces the 1024-item stack limit.**~~ **CLOSED 2026-10-03** — enforced in `push/2`, with a `depth` counter on the frame. | the interpreter | **Not a tidiness gap; a measured memory vector.** 10,000,000 `PUSH1` on a 30M gas limit — which the limit permits, at 3 gas each — executed to completion in **3,281 ms** with a **942 MB** peak RSS, about 89 bytes per stack item, i.e. a frame ran 9,765 times past the specified depth and one transaction's calldata bought a gigabyte. After: **55 ms** and **99 MB**, same program, ending in an exceptional halt. | **Enforced at `push/2`, not at `push_n/3` and `dup_n/3`**, because those are not the only callers and a second site is a second thing to forget. **`depth` is a counter, not `length(stack)`**: there are exactly four places that write `stack` — `push/2` (+1), `pop/1` (-1), `popn/2` (-N), `swap_n/4` (0, a reorder) — and `length/1` per push would walk 1024 cells on a program that pushes ten million times. | **An exceptional halt, and that choice is the load-bearing part.** `eth_block:execute_transactions/6` answers *any* `{error, _}` from `run_transaction/5` by refusing the **whole block**, so an overflow raised as an `evm_crash` would let one transaction that pushes 1025 items invalidate a block whose every other transaction is valid — strictly worse than the defect. `{error, stack_overflow}` consumes the frame's whole allowance and fails one transaction. Four tests: two bite the defect on the unfixed tree, and the drift guard is isolated by an injection that breaks `pop/1`'s decrement and fails **only** that one. |
| **D-8** | ~~**`EXP` was priced on `max(base, exponent)`.**~~ **CLOSED 2026-10-04** -- and the row it was recorded against turned out to be the smallest of four defects here. | every fork | **Four defects, and the recorded one was the least.** `geth` 1.17.7 was installed and `evm run` used as an oracle. **(1) The base's width was priced.** `Cost = 10 + 50 * max(len(base), len(exp))`. EIP-160, quoted: "increase the gas cost of EXP from 10 + 10 per byte in the exponent to 10 + 50 per byte in the exponent." It measures the exponent and says nothing about the base. A `PUSH32` base with an exponent of 0 was charged 1,550 gas for nothing. **(2) The coefficient was 50 at every fork.** Before Spurious Dragon it is 10, so every pre-SD block that ran `EXP` paid five times too much. `eth_fork_schedule:exp_byte_cost/1' is the one home for the coefficient now. **(3) The handler's literal `10 +` double-charged the flat cost**, which the interpreter loop already takes from `constant_cost/2 -> base_gas_cost(16#0A, _, _) -> 10`. Every `EXP` cost 10 too much. **(4) The comment cited EIP-2565, which is MODEXP's repricing** -- opcode 0xf0, a different instruction whose cost really does involve both a base and an exponent. **That is why (1) read as deliberate**: a plausible shape borrowed from the wrong EIP. | **The operand order was correct, and it was broken here before being restored.** EXP pops the base first -- `push/1` conses, so the operand pushed *last* is the base, and a program computing `Base ** Exponent` pushes the exponent *first*. Measured on geth, all eight programs agree on `second push ** first push`, and the discriminating pair is `PUSH1 5, PUSH1 0, EXP -> 0` against `PUSH1 0, PUSH1 5, EXP -> 1`. The Yellow Paper was read from memory as having `mu_s[0]` be the exponent, the two pops were swapped, and the swap was "confirmed" with a probe **run against the tree just edited** -- so the probe measured the edit, not the interpreter. **A measurement taken against a tree you have just changed is a measurement of your change**, and the oracle answered in one command the whole time. | **Four tests, each shown to bite** by injection: restoring `max(base, exponent)`, flattening `exp_byte_cost/1` to 50, re-adding the literal 10, and swapping the pops. The pop-order test is table-driven over six pairs and each row carries the value the *reversed* order would answer, so a fixture where the two agree is a test that cannot see the rule. | **What the oracle could not settle, and it is recorded rather than papered over:** `evm t8n` was never made to run. Its transaction file demands a signed transaction, and four separate fixture defects each printed the same empty output -- a preimage naming a different `to` than the emitted transaction (so geth recovered a different sender), `"v": "0x37"` written with `~p` in a hex field (chain id 10), the code on the sender (`"sender not an eoa"`), and a mixed-case alloc key. **Every one of them looked like "no difference", and a missing measurement is the failure mode a fixture defect produces.** So the cross-fork *gas* figures are pinned against EIP-160's text and pinned by test, not against a second implementation. **D-13's harness needs this work anyway.** |
| **D-9** | **WITHDRAWN — the snappy claim was a misreading.** It said snappy was enabled while never advertised, so every frame after the Hello failed against a real peer. The devp2p specification makes compression **unconditional** after Hello at protocol version 5 ("All messages following Hello are compressed using the Snappy algorithm", EIP-706), which is what this node sends; `snappy` is **not** a capability (geth keys off `snappyProtocolVersion = 5` and never lists it); and `frame-size` carries the compressed length, as the spec requires. `snappy = true` was right. | Nothing. What survives is not an interop defect: `compress/1` is literal-only so it expands every body — **measured** +2 bytes on a Ping, +9 on 400 bytes, round trip correct on all nine payloads probed — so compression here is safe and useless. |
| **D-10** | ~~**The txpool has no replacement rule, so two transactions with the same `(sender, nonce)` can both be admitted and the builder's choice between them is `maps:fold` order.**~~ **CLOSED 2026-10-03** — `insert/3` now holds at most one per `(sender, nonce)`, and a strictly higher price replaces. | block building | **Was `eth_txpool.erl:109-113`, keyed on the transaction hash alone.** Measured over 12 runs with a 1 gwei and a 2 gwei transaction at the same `(sender, nonce)`: the 2 gwei one won 8, the 1 gwei one won 4 — **and the 2 gwei one won in exactly the 8 runs where its own hash was the larger of the two. Twelve of twelve.** So the fee was not a weak tiebreaker, it was never consulted: `sender_pending/2` sorts on `nonce` with a `=<` comparator, which is true both ways for equal nonces, so the order came from `by_sender/1`'s prepending accumulator over a flatmap visited in key order — and the key is the hash. A user bumping the price on a stuck transaction had a coin flip on being ignored, and the loser still held a per-sender and a global slot. `cap_sender/2` evicted the highest nonce and so never resolved it; the old eviction fixture gave every transaction a fresh key, so no test could see it. **No price-bump threshold, on purpose:** no EIP specifies one and there is nothing here to derive it from — geth's ~10% is a mempool policy, and importing a peer's policy as a rule is the thing §4.2 exists to prevent. |
| **D-11** | **PARTIALLY CLOSED 2026-10-03 — one of three terms.** ~~`SELFDESTRUCT` charges a flat 5,000.~~ EIP-2929's beneficiary access term is now implemented and fork-gated. **Two terms remain absent and are not derived here**, because this repository has no copy of the specification to derive them from (see D-18). | the interpreter | **Done, with the EIP's own words:** "If the ETH recipient of a SELFDESTRUCT is not in `accessed_addresses` (regardless of whether or not the amount sent is nonzero), charge an additional `COLD_ACCOUNT_ACCESS_COST` on top of the existing gas costs, and add the ETH recipient to the set." Berlin and later, a cold beneficiary costs 5,000 + 2,600. The same EIP adds that the warm case charges **nothing**, "which differs from how the other call-variants work" -- so copying `call_cost/3`'s shape would have charged 100 to every warm SELFDESTRUCT, and `access_prices/1` has no `16#FF` row, so the mistake would have been a function-clause error rather than a wrong number. **Still absent:** the new-account term when the beneficiary is empty, and EIP-3529's pre-London 24,000 refund ("Remove the SELFDESTRUCT refund"). Both are named here rather than guessed -- §4.2 forbids inventing a consensus constant, and neither figure is derivable from anything in the tree. **The original rationale for this row does not hold.** It claimed `eip6780_selfdestruct` at 0 of 5 "independently confirms" a pricing defect. The tally is pinned exactly (`?assertEqual(?EXPECTED, ...)`) and did **not** move with this fix, so that suite diverges for some other reason; its committed fixture is `test_selfdestruct_not_created_in_same_tx_with_revert`, whose transaction is a `CALL` into a pre-existing contract, so the divergence is in EIP-6780's deletion rules or in storage clearing, not in the beneficiary's access cost. A measurement recorded as corroboration was corroborating nothing. |
| **D-12** | ~~Dead code listed as running, and **three `TASKS.md` checkboxes marked complete on the strength of it.**~~ **CLOSED 2026-10-03** — both modules deleted, both removed from `registered`, three Phase 4 items re-opened. | the ledger, and the process | **The original entry understated this.** It said two modules were dead and listed in `registered`. The larger half is that `TASKS.md` marked **state pruning, state expiration and the block hash oracle** `[x]` ✅, and the only implementation of each was in these two modules. `prune_recent/1` computed `_KeepFrom`, carried `%% Prune blocks older than KeepFrom`, and returned `{ok, pruned}`; `expire_state/1` computed `_ExpireAt` and returned `{ok, {expired, _ExpireAt}}`. **Neither touched a store, and neither module was ever a child of `etherlang_sup`.** So three checked boxes were resting on code that reported success for work it did not do. | **`eth_block_hash_oracle` is why the original grep was wrong.** It has five call sites, which reads as live — but all five are inside `eth_state_management`, so it is a **dead cluster**, not two independent modules, and a search for one qualified name would have called it live. Deleted rather than documented: the hazard is not that a reader does not know the modules exist, it is that `{ok, pruned}` reads as the finished article. The other four Phase 4 items are honest and stay `[x]`: `eth_chain` keeps a real hash and transaction index, `eth_mpt` persists to DETS, and `snapshot/0`'s own comment says it is a dump of the in-memory maps rather than a persistent trie. `registered` claimed 16 processes and named 14. |
| **D-13** | No differential, Hive or fuzz harness exists | whole node | 0 configurations anywhere in the tree |
| **D-14** | ~~**A remote UDP sender can terminate the node.**~~ **CLOSED 2026-10-03** — one boundary per remote packet; dropped and logged, node survives. Was: `handle_findnode/5` → `table_closest(Tab, to_bin(Target), K)`, and `to_bin/1` answers `<<>>` for a two-element target, which `distance/2`'s `crypto:exor/2` cannot accept. | `eth_discv4.erl:300,190,401`. **Proven end to end:** a 64-byte target returns the table's node, `<<>>` raises `badarg`, and an empty table with the same bad target returns nothing. Reached from `handle_info` with no `try`; child is `permanent`; `intensity => 5, period => 10`. **≈6 packets in 10 s kills the application.** |
| **D-15** | ~~**The peer manager is unreachable, and one inbound TCP connection makes it unreachable for ten seconds.**~~ **CLOSED 2026-10-03** — `accept/2` with a zero timeout plus a re-poll timer, and the handshake spawned the way `auto_dial/2` always did it. **This was two defects, and the second was the worse one because it was always present.** (i) `handle_info(accept, S)` called `gen_server:start/3` inline and its `init/1` runs `eth_rlpx:recipient/3`, a blocking handshake with a 10 s timeout: measured unreachable at t=2.2, 4.4, 6.6 and 8.8 s, answering only once the handshake logged its own failure. (ii) `gen_tcp:accept(S#st.lsock, 1000)` ran inside the callback, so with **no connection anywhere** the manager sat in a one-second slice at a time, forever. | `eth_peer.erl:163`. (i) No `dial_tick`, no `DOWN`, no `peer_up` for the duration, and `eth_peer:peers/0` — polled by `eth_sync.erl:454` and `eth_statesync.erl:109` — blocks behind it. (ii) Same callers, and it needed no attacker: **20 idle `status` calls measured 798 ms min / 1001 ms median / 1004 ms max**, which is a one-second stall on every poll of a node with no peers at all. After the fix: **1 µs / 2 µs / 67 µs**. The two ranges do not overlap, which is what lets the tests use 300 ms and 3 s as separators rather than tolerances. Each test bites its own half and not the other's, verified by two single-change injections. **`{active, once}` on the listen socket is not the fix and was tried:** `{tcp_passive, _}` is the re-arm message for an *established* socket; on OTP 29 `{active, once}`, `{active, 1}` and `{active, true}` on a `gen_tcp:listen/2` socket each delivered no message at all while a client connected and `accept/2` succeeded. Adopting it would have produced a node that never accepts an inbound connection and reports itself perfectly responsive. The remaining cost is a 10-per-second poll on an idle listener, kept in preference to a dedicated acceptor process because `gen_tcp:controlling_process/2` may only be called by the current owner, so an acceptor cannot hand a socket to a `gen_server:start/3` that does not return until `init/1` has already run the handshake. |
| **D-16** | **One `NewPooledTransactionHashes` announcement stalls its own connection for ten seconds.** Carried as **F15**. `handle_msg/3`'s `Base + 8` arm requests the transactions and then blocks in `await_pooled/2` on a `eth_rlpx:recv/3` with a 10 s timeout, on the connection's own process, inside the poll handler. | **Measured**: peer answered code 25 (`GetPooledTransactions`, so the path ran); `status` timed out at 1500 ms; a second call was answered **8497 ms** later. **Severity is deliberately lower than D-15, and that difference is the finding:** D-15 blocked `eth_peer` — one process shared by every peer — so one connection took `eth_peer:peers/0` down for everybody. Here the blocked process is per-connection, so a peer can stall only its own and the manager stays answerable throughout. Pinned by `a_pooled_hash_announcement_stalls_only_its_own_connection_test`, which asserts both the blast radius and the recovery. **Open, and left so on purpose:** not fetching on an announcement drops an inbound path by which a peer chooses what enters the pool, and a shorter deadline is an invented constant. Deferred behind the fork-model decision. |
| **D-17** | **Every inbound p2p handshake performs a live upstream JSON-RPC fetch, and waits for it.** Carried as **F17**. `maybe_eth/3` → `eth_eth:status_data/1` → `total_difficulty/0` is an uncached `eth_getBlockByNumber`. | **Measured 6059 ms and 6004 ms** on two consecutive eunit runs of a loopback peer. The same code *outside* eunit returns instantly, because the client is uninitialised and the call exits `noproc` — so **most of this suite cannot see this cost at all.** One unavailable upstream delays every inbound handshake by the full timeout, uncached. Correctness is unaffected (`?FALLBACK_TD` covers it), so this is availability, not consensus. Open, behind the same fork-model decision: whether this node computes total difficulty itself decides whether the fetch belongs here at all. |
| **D-18** | **The specification corpus this repository names as its authority is not in the repository.** `AGENTS.md` §1 states "The authority is the specification, and it is four documents: `ethereum/EIPs` ... `ethereum/execution-specs` (EELS) ... `ethereum/execution-apis`", and the table under it lists `ethereum/EIPs` as a file to read before claiming anything works. | the process, not the node | **Verified absent:** there is no `ethereum/` directory, `git ls-files` returns nothing under `ethereum/`, there is no `.gitmodules` and no submodule is registered, and the path is not in `.gitignore` — so it was never tracked rather than merely excluded. **The derivation method still works, and that is the mitigating half:** the code quotes the clause it derives from. `eth_evm.erl:114` is "EIP-2929, 'When a transaction execution begins', in the EIP's own words", and 15 distinct EIPs are cited across `src/` with quoted text. So a reader can verify a rule without the directory, by fetching the EIP themselves. **What does not work is checking a claim against a local copy**, and this cost real time on D-11: the SELFDESTRUCT terms had to be fetched from `eips.ethereum.org` mid-fix. Recorded rather than fixed, because vendoring four specification repositories is a decision about what this project is, not a bug. |
**Not deviations, recorded because they were suspected and are not.** `from_json/1`'s
24-byte nonce is real but has no caller in `src/`. `CALLCODE` does not transfer value —
`From =:= To`, so it nets to zero. The listen socket lacks `send_timeout` while the
outbound connect has one, so the exposure is inbound only.

---

## Cutting a release

1. Tier 0 all `GREEN`.
2. Tier 1 all `GREEN`, or an explicit, dated, signed-off exception per `ABSENT` cell
   naming what it would take to build it.
3. Tier 2 floors raised or held, never lowered.
4. Every deviation either closed or re-affirmed with a new measurement and a revisit
   condition.
5. The release claims only a fork it models, and says which one.
6. `doc/MEASUREMENTS.md` gains the entry for this release's measurements. It is where
   the numbers came from, and where the next person checks whether they mean what
   this file says they mean.

**The gate that matters most is the one that cannot be run.** Today that is Tier 1,
and specifically 1.1: this node verifies a transaction list and three roots, and no
mechanical evidence exists that the block it would build is one another client
accepts. Everything above that line is bookkeeping. Everything below it is the work.
