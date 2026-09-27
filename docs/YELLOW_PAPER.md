# etherlang — design and current state

**Status**: v1.0 in progress. 695 eunit tests, green.

This document describes what the node *is* and what it is *becoming*: the system
model, the trust assumptions, the data structures, and — at least as important —
the boundary between the two. It is not a re-derivation of the Ethereum Yellow
Paper, and it is not a conformance claim. See §1.3 for what "not a conformance
claim" means here, precisely.

Where this document and the code disagree, the code is wrong. Fix one or fix
this file in the same change; never leave them disagreeing. `README.md` carries
the feature-status table, `TASKS.md` the ordered task list, and `AGENTS.md` the
rules this repository has had to learn the hard way.

---

## 1. What this node is

### 1.1 The short version

An Ethereum execution-layer node in pure Erlang/OTP. It syncs the canonical chain
over devp2p/RLPx with a JSON-RPC fallback, keeps state in a Merkle-Patricia trie,
runs a pending-transaction pool, serves JSON-RPC, and speaks the Engine API well
enough for a consensus client to drive it.

It is **not yet a production execution client**. It does not author blocks that
would survive submission, it has no consensus layer of its own, and its per-fork
*gas pricing* is not wired in. Each of those is a named item in `TASKS.md`, not a
vague future.

### 1.2 What it does today

- **Engine API** — `newPayload`, `forkchoiceUpdated` and `getPayload` at V1, V2
  and V3, plus `engine_exchangeTransitionConfigurationV1`. JWT-authenticated; a
  node with no secret refuses the port rather than serving it open.
- **Block building** — `eth_block_builder` is a supervised child.
  `forkchoiceUpdated` issues a `payloadId` from a `payloadAttributes`, and
  `getPayload` returns a real block with a computed `blockValue`.
- **Local JSON-RPC** — 28 `eth_*` methods are answered from this node's own
  state, each saying what it derives from. The rest proxy.
- **Execution** — a full EVM interpreter with EIP-2929 warm/cold access tracking,
  EIP-1153 transient storage, EIP-4844 point evaluation, and system calls for
  EIP-4788 and EIP-2935 that run the *deployed contract's code* rather than
  writing the slots directly.

### 1.3 What this document does not claim

**No conformance claim of any kind.** Nothing in this repository has been run
against the Ethereum Foundation's execution-spec tests. There is no EEST fixture
directory and no fixture runner; `apps/etherlang/test/vectors/` holds three
committed Sepolia blocks and nothing else. Every specification claim here was
checked against the *text* of the `execution-apis` repository's per-fork files
and against the EIP text, by reading it, and is pinned by unit tests — but a test
that encodes a reading of a specification is not the same as a test that executes
one.

> The obvious grep for this used to be `grep -rn 'execution-specs\|eips.ethereum\|
> EELS' apps/etherlang`, asserted to return nothing. **It no longer does**, and the
> handle had to be retired rather than left in place: `eth_fork_schedule` and its
> tests now *cite* execution-specs and go-ethereum as the provenance of the opcode
> table, so the grep returns six comment hits. A verification handle that has gone
> stale is worse than none, because it reads as a clean result. Cite the fixture
> directory, which is checkable.

Two specific non-claims, because both are easy to overstate:

- **The opcode availability table was cross-checked against other
  implementations, not against a specification test.** The per-fork sets in
  `eth_fork_schedule:opcode_exists/2` reproduce the instruction counts of
  go-ethereum's `newFrontierInstructionSet()` and execution-specs' per-fork
  `Ops` enums exactly. That is a strong provenance check and it is still not
  EEST.
- **"The gas schedule is the single reason state roots diverge" is unverified
  and must not be restated as fact.** It cannot be checked end to end without real
  prestate, which this node does not hold for arbitrary blocks.

### 1.4 An unverified claim, flagged where it appears

There was a period when `README.md` and `TASKS.md` both said the unwired gas table
was why a built block's state root would not match the network's. The table is
wired now, and the claim had to be retired rather than kept and softened, because
it had quietly become a *different* claim: "the table is the reason" reads as a
diagnosis, and by the time the table was complete it had been found wrong four
times over by reading it against the EIPs — a no-op `SSTORE` overcharged by 2700
gas net, a dirty write priced as a clean one, `ADDRESS` at 3, and EIP-161's terms
gated on Berlin rather than Spurious Dragon. A schedule found wrong four times by
inspection is not a schedule one should then nominate as *the* remaining reason.

The correct statement is narrower and is what the documentation now says: the root
is **not known** to match. Completing the schedule is necessary for it to match
and is not evidence that it does. It cannot be checked end to end without real
prestate, which this node does not hold for arbitrary blocks. See §7.

---

## 2. System model and trust assumptions

### 2.1 The three sources of truth, and which one counts

`eth_state:base_source/0` is process-wide and has two values:

| Value | Meaning | May a commitment come from it? |
|---|---|---|
| `upstream` | read-only, lazily fetched over JSON-RPC | **No** |
| `mpt` | the local Merkle-Patricia trie | **Yes — the only one** |

Only a write under `mpt` is a real commitment. `eth_block:finalize/1` switches to
`mpt`, executes, and restores it in a `finally`. **Any path that computes or
reports a root must set `mpt` first.** A root computed over the upstream view, or
over an empty trie, is not a result; it is a fabrication.

This is the single most load-bearing rule in the codebase and the easiest to
violate by accident, because the global silently redirects every other module's
reads for the rest of the VM's life. Tests that touch it must restore it —
`eth_test_util:finalize_ctx/1` is the reference pattern.

### 2.2 Trust boundary

1. **Canonicality** — the consensus client supplies the canonical chain through
   the Engine API; this node executes what it is given. Where the chain arrives by
   RPC instead, canonicality is *assumed*, and header hashes are recomputed rather
   than copied (`eth_header`, `eth_chain:verify_blocks/2`).
2. **Finality** — the `finalized` checkpoint is *learned*, not derived, and is
   only **accepted** when it is at or below the local head **and** matches the
   locally recomputed canonical hash at that height. A checkpoint that would
   otherwise brick the store is logged and ignored.
3. **Hash integrity** — except under `VERIFY_HEADERS=false`, every header is
   RLP-encoded and keccak-256 hashed locally before storage.
4. **State reads** — served from the local trie, or fetched and cached, depending
   on `base_source`. `eth_getProof` answers from the local trie **only**; a peer
   sends balances, not RLP nodes, so a proof it cannot produce locally is
   `{error, {state_not_local, _}}` and the handler proxies.

### 2.3 Non-goals, stated so nobody re-opens them

Staking, validators, beacon-chain consensus, WebSocket transport.

### 2.4 Block production and consensus integration are goals, not current state

`forkchoiceUpdated` returns a `payloadId` and `getPayload` returns a block. That
is the *plumbing*. Whether the block would be accepted on the network is a
separate question with a known answer today: **no**, for the reason in §7.

---

## 3. OTP kernel

```
etherlang_app (application)
└─ etherlang_sup (one_for_one, 5 restarts / 10 s per child)
   ├─ eth_mpt            (gen_server) — the one stateful trie
   ├─ eth_state          (gen_server) — delegate; reads/writes via base_source/0
   ├─ eth_chain          (gen_server) — canonical chain store (DETS)
   ├─ eth_sync           (gen_server) — peer-first sync, gap fill, follow
   ├─ eth_txpool         (gen_server) — pending/queued tiers, eviction, gossip
   ├─ eth_engine         (gen_server) — Engine API state; started *before* its listener
   ├─ eth_block_builder  (gen_server) — issues payloadIds
   └─ eth_rpc_server     (gen_server) — cowboy on :8545, plus :8551 for Engine
```

48 modules in `apps/etherlang/src`, 46 test modules alongside. Every stateful
module is a `gen_server` registered under its own name. The rest are pure or
stateless — `eth_rlp`, `eth_keccak`, `eth_hex`, `eth_word`, `eth_trie`,
`eth_fork_schedule`, `eth_evm`, and the rest of that list.

**Keep new logic out of the `gen_server`s where it can be pure.** That is what
makes it testable without holding state, and several of the mistakes this project
has had to unpick were a rule living inside a process where it could not be
reached by a test.

`eth_engine` is started before the listener that serves it. It used to be declared
in `registered` — a claim that a process is running — while nothing started it,
so every engine method in a real node was answering from a `gen_server` that did
not exist.

---

## 4. Configuration

Every runtime knob is an environment variable first (`eth_config`). Frequently
touched: `UPSTREAM_RPC_URL`, `ETH_NETWORK`, `ETH_FORK`, `DATA_DIR`,
`RPC_LISTEN_PORT`/`RPC_LISTEN_IP`, `ENGINE_PORT`, `RPC_API_KEY`, `CHAIN_RETENTION`
(2048), `BODY_WINDOW`, `ETH_START_BLOCK`, `DISCV4_ENABLED`, `RLPX_ENABLED`,
`STATE_SYNC_ENABLED`, `EVM_ETH_CALL`, `VERIFY_HEADERS`.

`config/sys.config` is **empty on purpose**. Do not add a default to it.

Two invariants are structural rather than configurable: retention is clamped
`≥ max_reorg_depth`, so a rewind target can never be pruned; the finalized
checkpoint is never pruned and rewinds never go below it.

---

## 5. The chain store

Three DETS "set" tables under `DATA_DIR`: `chain.num.dets`, `chain.hash.dets`,
`chain.meta.dets`. Only canonical blocks are kept. `head` is `{Num, Hash}`;
`finalized` is monotonic and never moves backwards; `low` is a persisted
pruning watermark.

DETS has a hard 2 GiB per-file ceiling and the open crashes on overflow, which is
what the bounded-retention design exists to avoid. After each append, a bounded
batch of blocks below the retention window is deleted, retiring each deleted
number's hash-index row as it goes, and the finalized block itself is skipped so a
rewind to the checkpoint always remains possible.

### 5.1 The read path's silent trap

`eth_chain` is keyed by the `hash` field of the stored map — the **0x-hex
string**, not 32 raw bytes. `eth_header` reads `parentHash` via `hex_to_bin/1`,
which has no binary clause, so a raw hash dies in `hexval(N)`. Three modules
disagree about this and the disagreement is silent until a block is stored by one
path and read by another.

### 5.2 Pruned and absent are not an error surface

`get_by_number/1` and `get_by_hash/1` return `not_found`, and the RPC layer falls
back to the upstream proxy. A header-only block requested full also proxies rather
than fabricating a body. "Garbage-collected historical data" is therefore
invisible to callers, which is the intended behaviour and also the reason the
local-serving gaps in `TASKS.md` are so easy to miss.

---

## 6. Synchronisation

Peer-first, RPC second. Each tick tries eth-capable peers before the upstream
endpoint.

- **Peer sync** — backward walk from a peer's best hash to a local anchor, then
  forward fill: bodies fetched per header and `transactionsRoot`-verified,
  receipts fetched and `receiptsRoot`-verified, assembled and appended through the
  normal chain path so reorg logic is reused.
- **RPC fallback** — `eth_blockNumber` from upstream, the finalized checkpoint
  tracked under the guard in §2.2, then three branches: empty store (gap fill from
  the anchor), head below upstream (`sync_range`), head above upstream (reconcile
  against the canonical hash of the upstream head).

`sync_range` works in **windows**: `min(concurrency, span)` blocks fetched in
parallel under a deadline and re-sorted into number order before append.
Per-tick progress is bounded by `SYNC_BUDGET`.

Error handling is deliberately graceful: window failures count and retry next
tick; a rewind refused below the finalized floor triggers a backoff rather than
hot-looping; a deep reorg is given up on with an error and a backoff.

---

## 7. Execution: what is right, and what is not

This is the section to read before trusting any state root this node reports.

### 7.1 The commitment rule

`eth_block:finalize/1` returns `{ok, Block, Verification}` where every commitment
in `Verification` is a **verdict**:

```erlang
{verified, Root} | {unverified, Reason}
```

**There is no way to get a bare root out of it, on purpose.** A recomputed value
stored under a key named after a header field is indistinguishable from a
confirmed one, and that is exactly how a wrong receipts root once passed
unchecked through this project.

- An absent context key means the rule is **unchecked**, not passed.
- `{unverified, state_not_local}` is a correct, complete answer when the node
  holds no prestate. Do not paper over it.
- "It should be fine" is not a reason. If you cannot check it, report it unchecked.

### 7.2 Fork selection is done; fork *pricing* is not

`eth_fork_schedule:current_fork/3,4` selects the fork from real network
activation points, including a `{ttd, N, Fork}` activation kind so the Merge turns
on total difficulty rather than a guessed block number. An **unknown** total
difficulty reports the *pre*-Merge fork, on purpose: a caller that guessed
"merged" would apply PoS rules to a block it has not established is post-Merge,
and would not know it had.

Two halves of "per-fork exact" must not be confused:

| | Status |
|---|---|
| **Availability** — may this fork run this instruction at all? | **Done.** An instruction the fork lacks is an exceptional halt consuming the frame's whole allowance. |
| **Conformance** — does it agree with anybody else? | **Measured once, and it is about 2%.** The `execution-spec-tests` `state_tests` corpus runs against this node's state transition. Two real defects came out of it. The figure is not reproducible yet and is reported rather than asserted. §7.3 |
| **Price** — what does it cost? | **Done, Berlin and later.** `eth_fork_schedule` owns every price; the interpreter's duplicate table is deleted. SSTORE included; pre-Berlin SSTORE is *refused* rather than priced (§7.2.3). |

The availability half was the more dangerous of the two, because every clause in
`do_op/3` was unconditional: PUSH0 executed in a Paris block and TSTORE executed
anywhere before Cancun, each pushing a value and each returning *successfully*. A
frame that succeeds where the chain's must halt is a different post-state, and
nothing in the result says so.

### 7.2.1 One owner of a price's composition

`eth_evm` used to carry its own copy of the base schedule, `base_cost/1`, taking
no fork, alongside `eth_fork_schedule`'s fork-parameterized one. Two copies of a
consensus constant is one too many, and they had already drifted — not in most
values, but in how four groups were *built*:

| | `eth_evm:base_cost/1` | the fork table |
|---|---|---|
| `BALANCE`, `EXTCODESIZE`, `EXTCODECOPY`, `EXTCODEHASH`, `SLOAD` | warm base 100, plus a hardcoded 2500/2000 in the handler | the whole figure, 2600 or 2100 |
| the `CALL` family | 0, with `do_call/3` charging the access cost itself | the whole figure |
| `LOG0`–`LOG4` | flat 375, plus 375 a topic in the handler | `375 * (topics + 1)` |

Both were internally consistent, which is why neither was wrong on its own and why
neither could be substituted for the other: a cold `BALANCE` would have cost 5100.
The resolution is one owner. The machine loop charges
`eth_fork_schedule:constant_cost/2`, which is **zero** for the access-sensitive
opcodes — whether a target is warm is not knowable before the handler looks — and
each of those handlers asks the table for its whole price, supplying only the
facts: is the target warm, is value moving, does the account exist.

### 7.2.2 What the comparison found

Measuring the two tables against each other across the whole `0x00-0xFF` space,
rather than reading either, is what turned up the rest:

- **`ADDRESS` cost 3, not 2.** It had no clause in `base_cost/1` and fell to the
  `base_cost(_) -> 3` catch-all — the same trap that had once mispriced three of
  the four `CALL` opcodes. One gas on every `ADDRESS` in every block, and
  `gasUsed` is a receipt field. The fork table has 2, so deleting the copy fixed
  it.
- **EIP-150's figures existed only in the table.** A Frontier `BALANCE` cost 2600,
  because execution had no path to the pre-Berlin price at all. `BALANCE` and
  `EXTCODEHASH` are 400, `EXTCODESIZE`/`EXTCODECOPY`/the `CALL` family 700, `SLOAD`
  200 — and `SLOAD` is not an account, which is why its cold cost is 2100 where an
  account's is 2600.
- **EIP-161's two terms were gated on Berlin.** The 9000 for a value transfer and
  the 25000 for a new account are Spurious Dragon's, two forks earlier, so a
  Spurious-Dragon-through-Istanbul `CALL` with value paid neither while still
  being charged the access cost. The gate had never been exercised, because
  nothing called the function.

### 7.2.3 SSTORE: the one price that is not derivable from the frame

SSTORE was the one thing still wrong, and it was wrong at every fork. It is now
implemented, and the shape of the problem is worth keeping because it is the only
place in the schedule where the answer is not a function of the opcode and the
fork.

A no-op write — storing a slot's existing value back to itself — was charged
**2900 with a 100 refund**, netting 2800, where EIP-2200 clause (1) says `SLOAD_GAS`
and nothing else: 800 at Berlin, 100 from EIP-2929. **2700 gas net overcharged on
every no-op write, London included.** The `20000` / `2900` / `4800` cases beside it
were correct, which is why this sat undetected next to a schedule that had just
been described as exact within Cancun-era rules.

The whole of the old implementation was a three-case expression over the slot's
**current** value. EIP-2200's rule needs a third value the frame does not carry —
what the slot held at the **start of the transaction** — and a three-case
expression over one of the other two has nowhere to put the distinction between a
first write and a rewrite. So there were two defects, not one: the no-op was
overcharged, and a *dirty* write was priced as a clean one. The second is the more
interesting of the two, because the dirty write is the case EIP-2200 exists to
price, and the code did not merely get it slightly wrong — it had no term for it.

The original values live in a second map, `#ctx.originals`, keyed on
`(address, slot)` and recorded on the first write to each. The read that supplies
one *is* the transaction-start value, but only because nothing has written the
slot yet, which is why the record has to precede the write. The transient map
cannot hold them: that map is transaction-scoped but is discarded on a child
revert, whereas an original value must survive one.

Two things about that arrangement are traps rather than insights, and both were
hit rather than foreseen. The first draft reused the existing `mark/2` helper,
which writes the *transient* set — correct for a flag, wrong for a word — so every
original landed in the wrong map and every SSTORE was priced as a first write.
And a `CALL` frame writes its own account's storage, so a `CALL` can never touch a
slot its parent goes on to write; only `DELEGATECALL` can, and a test built on
`CALL` to check the map crosses a frame boundary asserts nothing at all.

**Pre-Berlin SSTORE is refused, not priced.** There are *three* pre-Berlin
schedules, not one: the flat rule from Frontier to Byzantium, EIP-1283's net
metering at Constantinople, and Petersburg reverting it. EIP-1283 is a different
schedule and not a restatement of the flat one — its title is "Net gas metering for
SSTORE without dirty maps", and the absence of a dirty map is exactly what
EIP-2200 later introduced. Only EIP-2200's text is implemented here, so a single
pre-Berlin figure would be right for two of those three spans and wrong for the
third. Wrong *only* at Constantinople is the kind of gap that is never noticed,
because nothing on this node executes a Constantinople block and a test
exercising the flat rule at both neighbours would pass. So
`sstore_supported/1` refuses before Berlin and the interpreter reports
`{unsupported, {sstore, Fork}}`, which `eth_call` answers with an upstream
fallback: a pre-Berlin call degrades to another node's answer rather than to a
plausible wrong one of this node's own. Block execution is unaffected — this node
syncs Sepolia.

### 7.3 Conformance: measured, and it is bad

Everything above in this section is about the node agreeing with *itself* and with
the EIPs. The question this section is about is whether it agrees with anybody
else, and until `v1.18` the honest answer was that **nothing in this repository had
ever been run against a third party's expected results**. The opcode table was
cross-checked against go-ethereum's Frontier instruction set and execution-specs'
per-fork `Ops` counts; the gas schedule was derived from the EIP texts and pinned by
unit tests. Both of those are real checks, and neither can catch a schedule that is
wrong in a way its own tests agree with.

`apps/etherlang/test/eest_state_tests.erl` closes that. It runs EEST's `state_tests`
corpus, and **about 2% of the committed subset matches**. Two findings, neither of
which needed any new code to surface:

- the node **accepts an EIP-1559 transaction at a pre-London fork**, which the
  specification rejects — a validator admitting something invalid, which is the
  worst category there is;
- `eth_tx:from_rlp/1` **has no clause for an EIP-7702 (type 4) transaction**.

**The figure is reproducible, and getting it there was two harness bugs.** It
drifted at first — 5, 6, 7 and 2 across runs of identical code — for two
independent reasons. A storage slot a fixture's code reads but never declares fell
through to a process-wide MPT shared with the rest of the suite, and the runner
inherited `ETH_NETWORK` from its caller, so the in-suite run answered under
Sepolia's chain id against fixtures declaring chain 1. The second is the one worth
remembering: it made the validator *correctly reject* five EIP-1559 transactions
from the wrong chain, which reclassified them from "this node admits something
invalid" to "this node rejects it" — the harness suppressing the exact finding it
was added to make.

The 2% is not a rounding of a good number. It says the EVM and the transaction
wrapper are broadly not yet conformant, and that every state root this node has
ever computed was computed by code that disagrees with the specification on the
large majority of transactions it is given. That is a more useful sentence than the
one this document used to carry.

The figure is pinned by the suite, both exactly and as a bound, because it is now
reproducible. It was briefly not, and the episode is the argument for checking
whether a number can be asserted before asserting it: a pinned conformance figure
whose expected value flips between runs is worse than no figure, because it gets
read as a certificate.

Not covered: EEST's `blockchain_tests` and the Ethereum Foundation's own
`ethereum/tests`. This is a state-transition measurement, not a block-level one.

### 7.2.4 Still not implemented

- **EIP-150's 63/64 gas-retention rule and the 2300 stipend**, applied at every
  fork. Named as a gap rather than implemented: the EIP states the rule it
  introduced and not the one it replaced, and no client consulted still supports a
  pre-Whistle block, so the earlier behaviour would have to be invented.

### 7.3 The engine's status mapping

`newPayload` decodes the payload, checks `blockHash`, calls `finalize/1`, and maps
the verdicts:

| Condition | Status |
|---|---|
| A root was **checked** and is wrong | `INVALID` |
| A root is **unchecked** (no prestate held) | `SYNCING` |
| A mismatch outranks an unchecked root | `INVALID` |
| Unknown parent | `SYNCING` |
| Invalid transaction | `INVALID` |
| Other `finalize/1` error | `INVALID` |
| `blockHash` ≠ `Keccak256(RLP(header))` | `INVALID_BLOCK_HASH` |

Return shape follows the specification's `validationError` rule: a bare status
binary for `VALID`/`SYNCING`; `{Status, Reason}` only for `INVALID` and
`INVALID_BLOCK_HASH`. Reasons on `SYNCING` are logged, never returned.

`ACCEPTED` is deliberately **not** returned. It is in the status enum, so
returning it looks right, but the specification makes it a claim with
preconditions — every transaction non-empty, `blockHash` correct, the payload not
extending the canonical chain, not fully validated, ancestors known — and none is
checked here.

`forkchoiceUpdated` deliberately does **not** compare `parentHash` to the head. A
non-matching parent is a side branch or an unimported block, and the
specification answers `SYNCING` to both, so the comparison could only ever produce
a wrong `INVALID`. It survives as a log line.

`status_for_finalize/1` and `status_for_verification/1` are exported and pure so
the mapping is testable without holding the parent state locally.

### 7.4 The interpreter is honest about its own limits

`eth_call` is the one method that executes locally and can therefore be wrong.
It degrades rather than lying: on an unsupported opcode, an internal crash, or an
unverifiable condition it returns `fallback` and the handler proxies the original
request upstream. A correctness hole becomes a round trip, not a wrong answer.

Two distinctions inside that are load-bearing:

- `unsupported` means "this node cannot run this, ask someone else" and is
  answered with a proxy. A precompile that *ran and failed* is not that: the
  input is invalid, the answer is a hard failure that consumes the frame, and
  proxying would substitute another node's verdict for this one's. A failed
  `0x0A` halts with `{error, {kzg, point_evaluation_failed}}` and refunds its
  caller nothing.
- `invalid_opcode` is 0xFE, a specified instruction at every fork.
  `{undefined_opcode, Op}` is a byte the fork has never had. Both halt the frame
  and consume its allowance, so they agree on every state root and differ only in
  the label; they are kept apart so a caller can tell them.

`eth_evm:run/5` **requires** a `fork` in the Env and has no default. A default
would be a fork this node chose rather than one the chain chose: run against a
Paris block with Cancun's instructions available and the frame succeeds where the
chain says it must halt. A `badkey` is the loud version of that, and every Env
builder in `src/` sets it — `eth_call:env_from_block/2`,
`eth_block:block_env/2`, `eth_fork_schedule:run_system_call/6`.

### 7.5 Constants are derived and pinned, or documented as gaps

Every consensus constant is one or the other. Never both, never neither.

- **Derived and pinned:** `?EMPTY_UNCLE_HASH` = `Keccak256(RLP([]))`, previously
  `?EMPTY_ROOT` — the empty *trie* root, a completely different constant that was
  standing in for it in the same module. Now pinned by asserting the three real
  Sepolia block hashes. The 2 GiB DETS ceiling, the undecided-TTD sentinel
  `2^256-2^10`, the per-fork opcode counts.
- **Documented as a gap:** `eth_kzg:blob_to_kzg_commitment/1` is *deliberately*
  unimplemented — it needs the `g1_lin` derivation and the EIP-4844 vector could
  not be fetched, so it is not in the repository. Do not "finish" it with an
  approximation. EIP-7685's `requestsHash` (the EIP does not fix the header field
  position, and without EIP-7251 there are no requests). `TERMINAL_BLOCK_HASH`
  (chain-config data, not in the EIP; carried and echoed, never checked).

Never tune a constant until a test passes. That is fitting the test.

---

## 8. Testing

- **No network.** Every test runs against `eth_mock_node` (in-process JSON-RPC)
  or a loopback devp2p stack on real sockets. **A unit test must never perform a
  lazy upstream fetch** — it hangs when the node is offline rather than failing.
  Two of this document's own findings came from that: `SELFBALANCE` reaches
  `eth_state`, which falls through to its upstream reader unless the account is in
  the state's overlay, and `eth_rpc_client` is process-wide and points at a public
  Sepolia node by default, so any test whose *failure* path proxies makes a live
  network call.
- **Real chain data is committed, not fetched** — `test/vectors/*.json`,
  `eth_payload_fixture.erl` (real Sepolia payloads: Paris 1450507, Shanghai
  3001655, Cancun 6985356), `eth_test_util.erl`.
- **Fixtures must be independent of the code under test.** A payload whose
  transactions were re-encoded with this repo's own codec makes the transactions
  root and block hash checks circular.
- **Give every fork variant a fixture, including a non-degenerate one.** The small
  real Cancun block has `blobGasUsed = "0x0"`, so a decoder that passed the string
  through undecoded agreed with a correct one.
- **Test names are the specification.** If a name had to be softened to make it
  pass, the test is wrong.
- **A test that has never failed has never been tested.** Inject a defect into the
  live path and watch the test catch it, restoring from a pristine copy in a
  `finally` and `touch`ing afterwards. Pick an injection that still compiles: an
  injection that orphans a helper is a warning, warnings are errors, and the
  *build* catches it — which proves nothing about the test.
- **After a timeout, verify the tree against the pristine copy** before trusting
  any result. A killed injection script has left a dirty tree before, and the next
  run then tested injected code and reported it as the baseline.
- **Never restore a snapshot taken before the change it is meant to protect.** It
  silently reverts work. Use `git diff` to confirm the tree is what you intended.

EUnit truncates assertion values; write diagnostics to a file from a temporary
probe and read it with the shell. Delete probe files before committing — two
leftovers were once silently compiled and inflated the test count by 2.

---

## 9. Where the work is

`TASKS.md` holds the authoritative ordered list. In order:

1. **Finish the per-fork gas *pricing*** — the refactor described in §7.2. A
   precondition for any state-root claim, and for a block this node builds being
   proposable.
2. **EEST conformance work** — run the execution-specs fixtures and record what
   fails. Nothing here has been checked against them (§1.3).

Deliberately later, with reasons recorded in `TASKS.md`: the rest of the Engine
API (`getPayloadBodiesBy*V1` — blocked on **data**, since EIP-2718 wire bytes are
not retained; `notifyHeaders` — no clause in any per-fork `execution-apis` file,
so implementing it would mean inventing its shape; V4/V5; `getBlobsV1`),
`eth_createAccessList` (needs access recording on the EVM's hot path), and
`debug_*`/`trace_*`/`miner_*`/`admin_*`/`personal_*`.

---

## 10. Deliberately not done

Do not "fix" these by guessing. Each is in `TASKS.md`.

| Item | Why |
|---|---|
| `eth_kzg:blob_to_kzg_commitment/1` | Needs the `g1_lin` derivation; no local blob fixture, and the EIP-4844 vector fetch 404'd. |
| EIP-7685 `requestsHash` | Hashing rule sourced, but the EIP does not fix the header field position, and without EIP-7251 there are no requests. |
| `TERMINAL_BLOCK_HASH` (EIP-3675) | Chain-config data, not in the EIP. Carried and echoed, never checked against a post-Merge block's difficulty. |
| Per-fork gas *pricing* | A refactor of the charging path, not a substitution. See §7.2. |
| `eth_block:to_rlp/1` fork-awareness | Unconditionally includes the Cancun trailing fields, so it is only correct for Cancun-or-later headers. Pre-existing, documented, unfixed. |
| Snap proof serving | Leaf store only; strict requesters reject our ranges. Needs inner-node retention. |

---

## 11. Known dead and unwired code

Named so it is not mistaken for working code:

- `eth_block:hash/1`, `eth_block:header/1`, `eth_block:to_rlp/1` — unused in
  `src/`, tests only.
- `eth_header:header_fields/0` lists `requestsHash`, which is not a header field.
  Inert, because upstream block JSONs do not carry it.
- `eth_rpc_server:start_engine_api/2` swallows a listener failure
  (`{error, Reason} -> logger:error(...), ok`).
- `eth_tx:intrinsic_gas/1` charges EIP-3860 init-code gas unconditionally, because
  a transaction has no block context to resolve a fork from. A pre-Shanghai
  creation transaction is therefore overcharged at admission. Named rather than
  fixed, because fixing it means giving the validator a fork argument it cannot
  honestly obtain on the pool path.
