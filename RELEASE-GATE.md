# Release gate

**This file says what a release must show before it can be cut. Every cell below is
`GREEN`, `RED` or `ABSENT`, and `ABSENT` is not `GREEN`.**

A gate that reports `PASS` for something nobody runs is worse than no gate: it stops
the checking. That is the failure this repository has already paid for in prose
(AGENTS.md §10 — "a handle that cannot be trusted is worse than none"), and the reason
the tri-state exists.

**Current state: this node would not pass its own gate.** Tier 0.4 is red, Tier 1 is
five of six `ABSENT`, and fourteen deviations are open. The sections below record that
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
| 0.2 | Whole suite green | `Failed: 0` | `rebar3 eunit` | **GREEN** — 955 passed |
| 0.3 | No commitment returned as a bare value | every entry of a `Verification` map is `{verified,_} \| {unverified,_}`; no exception | review of `eth_block:finalize/1` | **GREEN** |
| 0.4 | Every published figure has a corpus and a date | no number in README/TASKS/AGENTS without both | review | **RED** — see below |
| 0.5 | Known deviations exist, dated, each with a measurement | no entry without all four fields | review of §"Known deviations" | **GREEN** — 18 entries |

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
| 2.4 | test count | ≥ previous release | **955** (`make counts`: 50 src modules / 14,255 lines, 61 test modules / 13,780 lines) |
| 2.5 | every consensus constant | derived-and-pinned, or documented-as-a-gap | review — **14 open, all in §"Known deviations"** |
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
| **D-10** | ~~**The txpool has no replacement rule, so two transactions with the same `(sender, nonce)` can both be admitted and the builder's choice between them is `maps:fold` order.**~~ **CLOSED 2026-10-03** — `insert/3` now holds at most one per `(sender, nonce)`, and a strictly higher price replaces. | block building | **Was `eth_txpool.erl:109-113`, keyed on the transaction hash alone.** Measured over 12 runs with a 1 gwei and a 2 gwei transaction at the same `(sender, nonce)`: the 2 gwei one won 8, the 1 gwei one won 4 — **and the 2 gwei one won in exactly the 8 runs where its own hash was the larger of the two. Twelve of twelve.** So the fee was not a weak tiebreaker, it was never consulted: `sender_pending/2` sorts on `nonce` with a `=<` comparator, which is true both ways for equal nonces, so the order came from `by_sender/1`'s prepending accumulator over a flatmap visited in key order — and the key is the hash. A user bumping the price on a stuck transaction had a coin flip on being ignored, and the loser still held a per-sender and a global slot. `cap_sender/2` evicted the highest nonce and so never resolved it; the old eviction fixture gave every transaction a fresh key, so no test could see it. **No price-bump threshold, on purpose:** no EIP specifies one and there is nothing here to derive it from — geth's ~10% is a mempool policy, and importing a peer's policy as a rule is the thing §4.2 exists to prevent. |
| **D-11** | **PARTIALLY CLOSED 2026-10-03 — one of three terms.** ~~`SELFDESTRUCT` charges a flat 5,000.~~ EIP-2929's beneficiary access term is now implemented and fork-gated. **Two terms remain absent and are not derived here**, because this repository has no copy of the specification to derive them from (see D-18). | the interpreter | **Done, with the EIP's own words:** "If the ETH recipient of a SELFDESTRUCT is not in `accessed_addresses` (regardless of whether or not the amount sent is nonzero), charge an additional `COLD_ACCOUNT_ACCESS_COST` on top of the existing gas costs, and add the ETH recipient to the set." Berlin and later, a cold beneficiary costs 5,000 + 2,600. The same EIP adds that the warm case charges **nothing**, "which differs from how the other call-variants work" -- so copying `call_cost/3`'s shape would have charged 100 to every warm SELFDESTRUCT, and `access_prices/1` has no `16#FF` row, so the mistake would have been a function-clause error rather than a wrong number. **Still absent:** the new-account term when the beneficiary is empty, and EIP-3529's pre-London 24,000 refund ("Remove the SELFDESTRUCT refund"). Both are named here rather than guessed -- §4.2 forbids inventing a consensus constant, and neither figure is derivable from anything in the tree. **The original rationale for this row does not hold.** It claimed `eip6780_selfdestruct` at 0 of 5 "independently confirms" a pricing defect. The tally is pinned exactly (`?assertEqual(?EXPECTED, ...)`) and did **not** move with this fix, so that suite diverges for some other reason; its committed fixture is `test_selfdestruct_not_created_in_same_tx_with_revert`, whose transaction is a `CALL` into a pre-existing contract, so the divergence is in EIP-6780's deletion rules or in storage clearing, not in the beneficiary's access cost. A measurement recorded as corroboration was corroborating nothing. |
| **D-12** | `eth_state_management` and `eth_block_hash_oracle` are dead code, are listed in `registered`, and are not in AGENTS.md §11. Inside, three functions report work they did not perform | whole node | 0 starter call sites; `git grep` finds 0 mentions in either document |
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
