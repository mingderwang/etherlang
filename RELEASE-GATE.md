# Release gate

**This file says what a release must show before it can be cut. Every cell below is
`GREEN`, `RED` or `ABSENT`, and `ABSENT` is not `GREEN`.**

A gate that reports `PASS` for something nobody runs is worse than no gate: it stops
the checking. That is the failure this repository has already paid for in prose
(AGENTS.md §10 — "a handle that cannot be trusted is worse than none"), and the reason
the tri-state exists.

**Current state: this node would not pass its own gate.** Tier 0.4 is red, Tier 1 is
five of six `ABSENT`, and thirteen deviations are open. The sections below record that
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
| 0.2 | Whole suite green | `Failed: 0` | `rebar3 eunit` | **GREEN** — 943 passed |
| 0.3 | No commitment returned as a bare value | every entry of a `Verification` map is `{verified,_} \| {unverified,_}`; no exception | review of `eth_block:finalize/1` | **GREEN** |
| 0.4 | Every published figure has a corpus and a date | no number in README/TASKS/AGENTS without both | review | **RED** — see below |
| 0.5 | Known deviations exist, dated, each with a measurement | no entry without all four fields | review of §"Known deviations" | **GREEN** — 13 entries |

**0.4 is red.** At the time this file was written the repository carried four mutually
unequal conformance figures: `?EXPECTED`'s 255, TASKS.md's 226 in two places, and
README's 250 and 224 further along. All are now 255. The gate stays because the
condition, not the number, is what needs enforcing — and because the pin itself was
deleted twice before the cause was found (AGENTS.md §5).

---

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
| 2.4 | test count | ≥ previous release | **943** (`make counts`: 50 src modules / 14,183 lines, 60 test modules / 13,468 lines) |
| 2.5 | every consensus constant | derived-and-pinned, or documented-as-a-gap | review — **13 open, all in §"Known deviations"** |
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
| **D-1** | Block-level header validity is not checked at all — no timestamp, number, gas-limit band, base fee, difficulty or nonce check | every block | `grep` for any of them in `src/`: **0 hits**. `eth_chain:verify_blocks/2` only recomputes the hash. `VERIFY_HEADERS` is that recomputation and nothing else |
| **D-2** | `withdrawalsRoot` is decoded, stored and hashed but never compared against a computed value | every block | `grep -rn check_withdrawals src/`: **0 hits** |
| **D-3** | A payload with more than 16 withdrawals is neither rejected nor refused: the root truncates at 16 while the state transition credits all | every block | `eth_fork_schedule.erl:904` vs `apply_withdrawals_to_state/2`; no count check in `eth_tx.erl`. `eth_withdrawals_tests:124` **asserts the truncation is correct** |
| **D-4** | EIP-7691's blob schedule is not modelled — target 3 blobs and max 6 are EIP-4844's Cancun figures; Prague raises them to 6 and 9 | Prague onward | `eth_fork_schedule.erl:798,804`; the same table carries Prague activations. Legal 7–9-blob blocks are refused and `excess_blob_gas` diverges, changing the state root |
| **D-5** | Any block containing an EIP-7702 transaction gets the empty receipts root | type-4 transactions | `eth_receipt.erl:91-100` maps `0x4` to `unsupported`; `to_wire/1` cannot match and the failure is caught; `eth_block:receipts_root/1` falls back to `eth_trie:root([])`. On the build path the empty root is **stamped and reported verified** |
| **D-6** | `blockValue` is always 0 — the builder reads a `receipts` key the `Verification` map does not have, and reads atom `gas_used` where receipts write `<<"gasUsed">>` | every `getPayload` V2/V3 | `eth_block_builder.erl:514,522` against `eth_block:377-388` |
| **D-7** | The EVM never enforces the 1024-item stack limit | any frame exceeding it | `eth_evm.erl:431` `push/2` has no bound; `grep 1024` in `src/` finds only the two frame-*depth* checks |
| **D-8** | `EXP` is priced on `max(base, exponent)`; EELS charges the exponent's width only | every fork | `eth_evm.erl:532-538`. The 50-per-byte figure is also applied at every fork, where Spurious Dragon changed it from 10 |
| **D-9** | **WITHDRAWN — the snappy claim was a misreading.** It said snappy was enabled while never advertised, so every frame after the Hello failed against a real peer. The devp2p specification makes compression **unconditional** after Hello at protocol version 5 ("All messages following Hello are compressed using the Snappy algorithm", EIP-706), which is what this node sends; `snappy` is **not** a capability (geth keys off `snappyProtocolVersion = 5` and never lists it); and `frame-size` carries the compressed length, as the spec requires. `snappy = true` was right. | Nothing. What survives is not an interop defect: `compress/1` is literal-only so it expands every body — **measured** +2 bytes on a Ping, +9 on 400 bytes, round trip correct on all nine payloads probed — so compression here is safe and useless. |
| **D-10** | The txpool has no replacement rule, so two transactions with the same `(sender, nonce)` can both be admitted and the builder's choice between them is `maps:fold` order | block building | `eth_txpool.erl:109-113`; `cap_sender/2` evicts the highest nonce so it never resolves a conflict. The eviction fixture uses a fresh key per transaction, so no test can see it |
| **D-11** | `SELFDESTRUCT` charges a flat 5,000: no cold-access term, no new-account term, no refund; and `SELFDESTRUCT(self)` leaves the balance intact | Cancun onward | `eth_evm.erl:819-840`. **`eip6780_selfdestruct` is 0 of 5 on the committed subset** — the corpus and the code agree |
| **D-12** | `eth_state_management` and `eth_block_hash_oracle` are dead code, are listed in `registered`, and are not in AGENTS.md §11. Inside, three functions report work they did not perform | whole node | 0 starter call sites; `git grep` finds 0 mentions in either document |
| **D-13** | No differential, Hive or fuzz harness exists | whole node | 0 configurations anywhere in the tree |
| **D-14** | **A remote UDP sender can terminate the node.** `handle_findnode/5` → `table_closest(Tab, to_bin(Target), K)`, and `to_bin/1` answers `<<>>` for a two-element target, which `distance/2`'s `crypto:exor/2` cannot accept. | `eth_discv4.erl:300,190,401`. **Proven end to end:** a 64-byte target returns the table's node, `<<>>` raises `badarg`, and an empty table with the same bad target returns nothing. Reached from `handle_info` with no `try`; child is `permanent`; `intensity => 5, period => 10`. **≈6 packets in 10 s kills the application.** |
| **D-15** | **One inbound TCP connection stalls the peer manager for ten seconds.** `handle_info(accept, S)` calls `gen_server:start/3` inline and its `init/1` blocks in a 10-second handshake. | `eth_peer.erl:163`. No `dial_tick`, no `DOWN`, no `peer_up` for the duration, and `eth_peer:peers/0` — polled by `eth_sync` and `eth_statesync` — blocks behind it. |

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
