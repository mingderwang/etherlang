# etherlang — measurement journal

**This file is history. `TASKS.md` is the status.**

It was lines 30–1393 of `TASKS.md` before the split, and it moved here for one
reason: a reader who opens `TASKS.md` to find out what to do next was reading 960
lines of completed work first, with the authoritative queue buried at line 986 and a
header whose numbers disagreed with the file it sat above. The same drift AGENTS.md
§1 refuses to tolerate in a design document — "a prose description of a system model
is a second statement of the rules, and a second statement drifts" — applies to a
status ledger that carries its own archaeology.

Nothing here is a claim about the node. Every figure below was measured on the tree
at the time it was written and several have been overtaken; where a figure was
wrong, the correction is recorded rather than deleted, because **how a wrong number
got here** is the part that stops the next person re-deriving it.

Read `TASKS.md` for what is true now. Read this for how it was found.

---

## Phase C: re-measuring the full corpus (IN PROGRESS — do not quote a total)

The per-fork table below is annotated stale, and the reason is two measured deltas
against it. This section is the re-measurement, **sharded by fork** so each fork
gets its own number and its own `DATA_DIR` (the §10a trap: two workers sharing one
`DATA_DIR` die at boot with `needs_repair` and produce no output at all).

Two findings already, both independent of any code change:

- **The committed 6-file slice of `prague/eip7702_set_code_tx` is 80 of 80, and the
  full directory is 548 entries at 64.2%.** The `/tmp/rej_set` working set is 22
  files chosen for declaring `expectException`; the real directory has **73**. So
  196 EIP-7702 divergences were never in the set this work has been measuring
  against. "100% of the 7702 fixtures" was true of six files and false of seventy-
  three, and the honest form of the claim was always the narrower one.
- **`static/` runs.** 2,449 files that had never been executed by anything in this
  repository; `eest_report` handles them unchanged (a static test has no post-state,
  so it is ~16x faster: 38 entries/s against 2.3 for a state test). `berlin`'s
  `static` set alone is 2,957 entries.

Shards finished, and their numbers **replace** the corresponding rows of the stale
per-fork table:

| fork | matched | total | pct |
|---|---|---|---|
| berlin | 2,956 | 2,957 | 100.0% |
| homestead | 82 | 82 | 100.0% |
| london | 10 | 11 | 90.9% |
| osaka | 765 | 911 | 84.0% |
| frontier | 3,661 | 5,625 | 65.1% |
| shanghai | 155 | 288 | 53.8% |
| byzantium | 144 | 405 | 35.6% |
| constantinople | 57 | 192 | 29.7% |

**No total is given, and none should be computed from this table yet** — prague,
cancun, istanbul and paris were still running, and the static set was at 2,300 of
2,446 files. What can be said is that these eight forks alone already contain
**7,830 matches**, against the **6,786** the stale full-corpus run reported for
*every* fork. The stale figure predates the blob fee, the refund cap, the
authorization refund and the delegation work, so the corpus-wide number is stale by
a lot more than the two deltas recorded above it.

**The sentence this section used to carry about the two low forks was wrong, and the
per-suite instrument is what refuted it.** It said "**constantinople at 29.7%** is
where EIP-1283's `SSTORE` is refused (item 6a)". Constantinople is 29.7% because of
`eip1014_create2`: **131 of its 135 divergences, against 3 from `eip145_bitwise_shift`**.
EIP-1283 is worth **zero** entries there — the only two entries the directory runs at
a Constantinople fork are `ConstantinopleFix`, which is *Petersburg*, where the rule
is the reverted flat one, not EIP-1283's. Item 6a remains a real gap and remains
unfinished; it is just not what this number was measuring. A number attached to a
guess is still a number attached to a guess, and a per-fork table cannot tell the
difference between "the fork's rule is refused" and "one suite in the fork is broken".

The `eip1014_create2` half of it was **EIP-161 (a)** and is now fixed — see
`AGENTS.md` §10's Closed table. Constantinople went **57 -> 93 of 192** and byzantium
**144 -> 195 of 405**, and the per-fork breakdown of that one file is the clearest
result in this work:

| fork | before | after |
|---|---|---|
| Cancun | 0 of 23 | **23 of 23** |
| Prague | 0 of 23 | **23 of 23** |
| Shanghai | 0 of 23 | **23 of 23** |
| Berlin | 0 of 23 | 0 of 23 |
| Istanbul | 0 of 23 | 0 of 23 |
| London | 0 of 23 | 0 of 23 |
| Paris | 0 of 23 | 0 of 23 |

The nonce is gone at every post-Spurious-Dragon fork, which is what fixed, and the
residual is **a 1-to-2 gas figure at pre-Cancun forks and none at all from Cancun** —
a second, separate defect in the same file, named in the Open table below.

---

## `stTimeConsuming`: 10,374 entries, none of them matching, and it is not a gas rule

**38% of the entire `static/` corpus's divergence is one suite of twelve files.**
`static/state_tests/stTimeConsuming` is 12 files of `sstore_combinations_*` — the
exhaustive SSTORE gas combinations — and it is **0 of 10,374, every entry**, which is
the shape of a harness problem rather than a rule problem: no EIP is wrong in 100% of
a 10,000-entry suite.

The measurements, and they are the whole of what is known:

- **20,748 balance diffs — exactly two per entry**, and the other two shape families
  (`nonce`, `code`, `storage`) are **zero**. So nothing is mis-executed and nothing is
  mis-deployed; this is settlement.
- Every entry reports `no_comparable_gas` with the reason *"one side produced a gas
  figure and the other did not"*. **That message blames the wrong side, and fixing the
  message is a job in its own right**: the node's receipt *does* carry a `gasUsed`, and
  the harness reaches the node's figure by *inverting the balance difference* — which
  is impossible here, so the reason should be `no_gas_from_divisible_balance` and not
  "the other side". The post section of these fixtures has no `gasUsed` at all: its
  keys are `['hash','logs','txbytes','indexes','state']`.
- The sender's balance differs by **201,969 wei at a `gasPrice` of 10**, which is not
  divisible by 10 — and **gas is always an integer, so a wei difference at a price of
  10 must be**. 201,969 + 1 = 201,970 = **20,197 x 10**. The extra wei is the
  transaction's `value`, which is `0x01`.
- The created account `0x6295ee1b...`, which is **not in `pre`**, has
  `{balance, 1, 0}`: the fixture says it holds 1 wei and the node says 0.

**The arithmetic now closes, and it corrects two sentences above.** Working the
sender's balance against the pre-state `0xe8d4a51000` = 1,000,000,000,000 at
`gasPrice` 10:

| | sender ends at | total wei out | = gas x 10 + endowment |
|---|---|---|---|
| fixture | 999,995,752,129 | 4,247,872 | **424,787 x 10 + 1** |
| node | 999,995,550,160 | 4,449,840 | **444,984 x 10 + 0** |

So the corpus's `spent_expected` of 424,787 is right, the node's actual spend is
**444,984**, and the "not divisible by the price" is
**201,969 = 20,197 x 10 + 1** — the `+1` being the endowment.

**Two corrections to what this file said an hour ago:**

1. **No wei is destroyed.** I wrote "a value that leaves the sender and does not
   arrive". It does not leave: the node transfers the endowment *nowhere at all*.
   Conservation holds on both sides (the fixture moves 4,247,872 out and credits
   4,247,872 across two accounts; the node moves 4,449,840 out and credits
   4,449,840). The defect is a **missing transfer**, not a lost balance, and the two
   demand different fixes and different severities.
2. **There are two defects here, not one**, and the gas one is the larger:
   **444,984 - 424,787 = 20,197 gas.** That is the number to explain, it is 5% of the
   transaction, and nothing in the endowment story accounts for it.

**Both resolved in `v1.68`.** The endowment moves, and the frame's rollback that
makes moving it safe arrived with it. The transfer is now applied *after* the
authorizations and *before* the frame:

    State0     gas, blob fee, nonce        <- before the frame, always survives
    StateAuth  + EIP-7702 delegations      <- the snapshot: the restore point
    StateValue + the endowment             <- inside the frame, undone by a revert

which is EELS's `process_message/1` ordering (`copy_tx_state` first, `move_ether`
inside, `restore_tx_state` on `evm.error`) and EIP-7702's ("the authorization list
is processed before the execution portion of the transaction begins, but after the
sender's nonce is incremented"). A revert now returns `StateAuth`.

**A restore point is only a restore point if everything that should be undone sits
after it.** The first version of this fix left the transfer inside
`begin_transaction/8`, where it was already correct for a create but *could not be
undone* -- it lands in `State0`, above the restore. A create whose init code reverted
therefore kept its endowment, and `a_reverted_create_transaction_does_not_keep_the_
endowment_test` failed on it. That test is the reason the mistake is recorded rather
than shipped.

**And EELS's `value != 0` guard had to be applied at the call site, not left to
`transfer/4`.** `transfer/4` reaches the same EIP-161(c) outcome by a different
route -- `{0, _} -> drop_if_empty(S2, To)' -- and repeating the guard looked
redundant. `drop_if_empty/2` sets a **`destroyed` marker**, and `eth_state:code/2`
honours that marker over any code written afterwards. So a zero-value create marked
the address the `CREATE` was about to populate as destroyed, and the deployed code
read back as `<<>>`: `creation_deploys_at_the_derived_address_test` failed with
`committed_code = undefined`. EELS never had that shape -- it guards the *whole*
`move_ether` call, so a zero-value message moves nothing and marks nothing.

That is §10a's "a check that fires early and wrongly does not merely add noise, it
deletes the information about everything behind it", at its sharpest: the marker
deleted the **deployed code**. Following the specification's guard verbatim is not
just simpler than reaching the same outcome another way -- the other way has a
second effect this rule does not have.

+6 tests in `eth_endowment_tests`, all through `eth_block:run_transaction/5' (the
production path -- rule 2 lives in `eth_block', so a unit test against `eth_evm'
would have passed with the node still broken). 2 injections, and they separate:

| injection | result |
|---|---|
| transfer removed | all 6 fail |
| rollback removed (`StateFrame = StateRun`) | **exactly** the 3 rollback tests fail, the 3 presence tests pass |

Committed subset **254 -> 255 of 266**, `state_mismatch` 9 -> 8.

**The corpus does not move, and that is the finding rather than a disappointment.**
`stTimeConsuming` is still **0 of 10,374**: the endowment fix removed one of two
defects on those fixtures, and the second is below.

---

## Open: `stSStoreTest` is 762 of 934, and `sstore_0to0` is the simplest of them

The second-worst cluster in the `static/` corpus, and it is *SSTORE pricing*:

| suite | n | match | diverge |
|---|---|---|---|
| `stSStoreTest` | 933 | 171 | **762** |

`sstore_0to0.json` — a **single `SSTORE` of zero into a slot that is already zero**,
which is EIP-2200's no-op arm and the case the AGENTS.md entry on the EIP-3529 cap
test warns about ("a test whose fixture produces no refund cannot see a refund rule,
and it fails by looking correct") — diverges with gas deltas including
**-85,832** (`-10#85832w`; note the `10#` rendering, this is eighty-five thousand,
not a power of two).

Shapes: **1,196 balance, 104 nonce, 40 storage**, and **no** `code`. So it is
settlement and pricing, not mis-execution. The scattered small deltas in the histogram
(-43, -75, -119, -237, -238, -300, -307, -311, -370) are the interesting half: they
are not a multiple of any single EIP-2200 term, so a single missing clause will not
explain them, and the -85,832 is two orders of magnitude away from the others. **Two
different defects are sharing one suite**, and the histogram is what says so.

Not investigated. Named here so the next pass starts from the measurement rather than
from the suite's name.

### The same fixtures' residual, after the endowment fix

`v1.68` removed the endowment from all 10,374 and the suite is **still 0 of 10,374**
-- so these fixtures carried two defects, and fixing one revealed the other rather
than resolving the cluster. That is worth stating plainly because "10,374 entries"
sounds like a single cause and was not.

The shape also changed in a way that matters: before the fix every entry reported
`no_comparable_gas` / `no_gas_not_divisible`; after it, every entry has a comparable
gas figure. **The endowment was what made the arithmetic impossible** -- the 1 wei
left the sender's balance difference indivisible by the price of 10, so the harness
could not invert it. One wei was suppressing the instrument over ten thousand
entries, which is the §10a "a section that prints nothing must say what it did not
look at" shape with the arithmetic rather than a filter doing the hiding.

Six measured deltas, node minus fixture, from
`sstore_combinations_initial00_2_Paris.json` at Cancun:

| entry | calldata bytes | delta |
|---|---|---|
| d0 | 376 | **20,197** |
| d100 | 372 | **80,193** |
| d101 | 372 | **139,693** |
| d102 | 372 | **80,195** |
| d103 | 376 | **71,412** |
| d104 | 376 | **130,912** |

**What can be closed from this and what cannot.** The smallest, 20,197, is
`20,000 + 197`: one `SSTORE_SET_GAS` plus 197, so a single over-charged write is
*consistent* with this -- but "consistent with" is not "is", and 197 is not a term I
can name. The other five are spread over three magnitudes and differ from each other
by 59,996, 59,500, 8,665 and 59,500 -- **not** multiples of one per-write cost, so no
single missing clause explains the suite. And the deltas do **not** scale with
calldata length: d0 has 376 bytes and delta 20,197 while d100 has 372 and 80,193, so
EIP-7623's `21000 + 10 * tokens` floor is not the axis.

### The residual is a function of one number the program never reads

Two further measurements, and this is the sharpest thing in the whole cluster.

**The `sstore_combinations` init code has no loop.** Disassembled with `PUSH`
immediates skipped, all 187 bytes are straight-line: `PUSH2 <v>, PUSH1 64, MSTORE`,
then five external calls --

| # | op | target | gas forwarded |
|---|---|---|---|
| 1 | `CALL` | `0xb000...` | 300,000 |
| 2 | `DELEGATECALL` | `0x3000...` | 300,000 |
| 3 | `DELEGATECALL` | `0xb000...` | 300,000 |
| 4 | `CALLCODE` | `0x3000...` | 300,000 |
| 5 | `CALL` | `0x2000...` | 600,000 |

-- and no `JUMP` or `JUMPI` anywhere. So "data-dependent execution in a loop", which
the previous revision of this file proposed, is wrong: **the executed work is
identical in all 424 entries.** The callees are equally simple -- three of them are
the same 16 bytes, `PUSH1 i, PUSH1 i, SSTORE` for i in 0..2 then `STOP`, and
`0x3000...` is `PUSH1 0x20, PUSH1 0x00, REVERT`, so it reverts unconditionally and
is called twice.

**And yet the delta is a function of a number the program never uses.** The only
per-entry variable is the immediate of the first `PUSH`, which the program stores to
memory[0x64] and **never reads** -- the calls take their arguments from memory[0..32],
which is zero for every entry. Those immediates run 426 to 849 over the 424 entries,
and the delta is **deterministic in them: 424 distinct values, and not one of them has
more than one delta.**

```
426 -> 20197    427 -> 20695    428 -> 80195    429 -> 20197
430 -> 20695    431 -> 80195    432 -> 20197    433 -> 70910
434 -> 130910   435 -> 71412    436 -> 70910    437 -> 130910
```

**The value repeats with period three** -- 426, 429 and 432 all give 20,197; 427 and
430 both give 20,695; 428 and 431 both give 80,195 -- and the pattern restarts at 433
with a different band. That is the strongest evidence in this cluster and it points
somewhere very specific: **a quantity that changes gas has to be reachable from the
calldata, and the only such quantity in EIP-1559 pricing is `G_txdata`'s split
between zero and non-zero bytes** (16 and 4) -- yet every one of those immediates is
non-zero, so the split is constant per width. The width is 2 bytes for all of them.

So: not a per-write price (42 writes, one pre-state, 68 deltas), not the calldata
length or zero count (5 groups, several deltas each), not a loop (there is none), and
not the execution (it is identical). **What remains is the *expected* figure, not the
node's** -- the harness recovers it by inverting the sender's balance, and if the
corpus's own expected gas varies with a value the program ignores, the divergence is
in the comparison rather than in the state transition. That is the reading the
evidence supports and it is **not** established.

### The node's receipt agrees with the inversion, so this is a real node defect

`gas_story/5` recovered the node's gas by **inverting its balance difference** --
arithmetic on a derived quantity -- while the node's own receipt, the fourth argument
it was already passed, said it outright. It now reads it: `receipt_gas_used` and
`delta_receipt` are in the gas story beside the inferred pair, and the two are not two
figures for one question. The receipt is what the node charged; the inversion is what
its balance arithmetic implies, and where they disagree the node's accounting is
inconsistent with itself.

**They agree in 848 of 848 entries.** So the node's accounting is internally
consistent, and the divergence on `stTimeConsuming` is **real and not an artifact of
how the harness recovered the figure.** That control is what makes the rest of this
entry credible, and it was missing for the whole of the cluster.

**And the fourth hypothesis is dead too.** The expectation was that the node's gas
would be constant across the 424 push-values, because the executed work is identical,
and that the whole 20,197-to-139,693 range would therefore be the fixture side. It is
not: **both** sides vary, each with 62 distinct values over the 424 entries, and they
track each other. The node is consistently higher, and the delta repeats with period
three -- 20,197 / 20,695 / 80,195, then 20,197 / 20,695 / 80,195 again -- which is
three structural variants of the calldata per repeat, not a per-opcode rounding
difference.

### Localised: the delta is a function of which opcode each call uses

The per-entry structure is the call sequence, and nothing else. `sstore_combinations`
generates one transaction per `(opcode, target)` assignment over five calls, and the
five calls' opcodes are what varies: 424 push-values, **51 distinct call sequences**,
and the delta falls into **seven bands** with clean edges.

| band | shape |
|---|---|
| 10,974 - 11,478 | `STATICCALL` in position 2 |
| 20,193 - 20,697 | `DELEGATECALL` in position 2 |
| 70,909 - 70,910 | `CALLCODE` in position 2 |
| 70,911 - 70,912 | `CALLCODE` in position 2, later positions vary |
| 80,193 - 80,197 | a sub-case of the `DELEGATECALL` band |
| 130,474 - 130,912 | `CALLCODE` and `DELEGATECALL` combinations |
| 139,693 - 139,695 | `CALLCODE` combinations |
| 190,409 - 190,411 | `STATICCALL` in both early positions |

The floor is **20,193**, and one signature returns exactly `20,197` and nothing else:
`CALL DELEGATECALL DELEGATECALL CALLCODE CALL`. **So the divergence is a per-call term
that depends on the call opcode**, not a whole-transaction error -- which is the
narrowing from "this transaction costs 20,197 to 190,411 too much" to "one of five
calls is charged a figure that depends on which opcode it is".

That is the work list for this cluster, and it is a small one. What is **not** yet
done is naming the term. The bands' separations are 50,713 and 110,713 -- and
50,713 is not a schedule constant, so it is a *sum* of terms over several calls rather
than one term, and separating them needs one call sequence's worth of hand-traced
EIP-150/EIP-2929/EIP-2200 arithmetic.

### The callee that must run out of gas, and the one arm that is left

`0x2000...` is 166 bytes and disassembles to **33 `SSTORE`s, and every one of them is
a first write to a *distinct* slot from `original = 0`.** For `original == 0` both
EIP-2200 arms cost the same thing -- if `current == new` the no-op arm lands on
`SSTORE_SET_GAS`, and if `current != new` the set arm does -- so all 33 cost 20,000
and the callee needs **660,000**.

**The fifth call forwards 600,000. 660,000 > 600,000, so that frame must halt
out of gas.** That conclusion is arithmetic and does not depend on anything else here:
the callee's requirement exceeds its allowance under any reading of EIP-2200 in which
`original == 0` is not free. It is the single most specific fact this cluster has
produced, because an exceptional halt has consequences the node either gets right or
does not -- the whole forwarded allowance is consumed and **none of it comes back**,
which is a much larger and much sharper term than any of the 20,000s.

And the callee re-writes **slot 1 three times** -- `1`, then `0`, then `1` -- so it
also exercises EIP-2200's **dirty arm**, the one that costs `SLOAD_GAS` rather than a
set price. **The dirty arm's gap is 19,900** (20,000 against 100), against an
observed floor delta of **20,197**.

**The hand-trace does not reconcile, and a hand-trace that does not reconcile is
worth nothing.** Summing the five calls' overheads -- EIP-2929's cold/warm (2,600 then
100, since `0xb000` and `0x3000` are each visited twice) and EIP-150's 63/64 clamp --
gives roughly 740,000 if the fifth call is charged its whole allowance and roughly
237,000 if it is not, and **neither is the 422,396 the node's receipt reports**. So one
of those two assumptions is wrong, and which one is not something to guess: it is
either "the fifth call is charged its whole forwarded allowance" or "the fifth callee
runs out of gas", and those two imply each other's negation.

### Named: EIP-2200's no-op arm, on a slot whose original is zero

**CORRECTION. The "EIP-2200" column in the table below was wrong, the conclusion drawn
from it was wrong, and the code change made to satisfy it was a consensus gas defect
that has been reverted.** The measurement was real; the reading was not. This section
is kept whole because it is the clearest instance in this repository of a
specification rewritten into a nesting, and of what that cost.

The measurement, at Cancun, in a bare frame, with the pre-state seeded explicitly:

| case | node | EIP-2200 | |
|---|---|---|---|
| fresh set: 0 -> 1, `original = 0` | **22,106** | 22,106 | correct |
| no-op: 0 -> 0, `original = 0` | **2,206** | **2,206** | **correct** — was recorded as "19,900 short" |
| dirty: 1 -> 0, `original = 1` | 4,005 | 5,006 | 1,001 short — still open |

EIP-2200's clause is a flat list, and the no-op arm is its first bullet, **one
condition wide**:

    If current value equals new value (this is a no-op), SLOAD_GAS is deducted.
    If current value does not equal new value
        If original value equals current value
            If original value is 0, SSTORE_SET_GAS is deducted.
            Otherwise, SSTORE_RESET_GAS gas is deducted. ...
        If original value does not equal current value ...

What this file used to say, and presented as a quotation, was:

    if current_value == new_value:
        if original_value == current_value:
            if original_value == 0:
                cost = SSTORE_SET_GAS          # <-- 20,000
            ...
    cost = SLOAD_GAS + COLD_SLOAD_COST

**All three of those clauses exist in EIP-2200, and not one of them is under the
no-op arm.** They are under "does not equal new value". The rewrite read as a
correction precisely because it was more elaborate than the original.

EIP-2200 settles it three times independently:

1. **The specification text**, quoted above: one condition, `SLOAD_GAS`.
2. **The Appendix's proof**, for exactly this case — `original = 0`, state A: "We
   always start at state A. The first SSTORE can: **Go to state A: 200 gas is
   deducted.** We satisfy Case I because 200 * N == 200 * 1", where Case I is "If the
   final value ends up still being 0, we want to charge 200 * N gases, **because no
   disk write is needed**."
3. **The EIP's own test-case table**: the `original = 0` row (`0x60006000556000600055`,
   writing 0 into 0) is **the cheapest row in the table** at 1,612 gas, against 5,812
   for the same program with `original = 1`. 20,000 cannot appear in 1,612.

**So a write of zero into a slot that was already zero costs `SLOAD_GAS`, not
`SSTORE_SET_GAS`,** and the node's 2,206 was right. The sentence this file used to
carry here — that the node "under-charges every zero-to-zero write by exactly 19,900"
— describes a real 19,900, in the wrong direction, and it was **introduced by this
file rather than found by it**.

**What followed.** That reading was turned into a change to
`eth_fork_schedule:sstore_cost/4` (`sstore_noop/2`, charging `{20000, 0}` for a
zero-original no-op) plus 68 lines of tests pinning it. It **cost 19 entries on the
committed subset (255 -> 236) and failed three tests**: `eth_evm_tests:457`'s
`RETURNDATASIZE; PUSH1 7; SSTORE` after a rejected precompile call, and its create
counterpart, both went `out_of_gas` because the frame's budget no longer covered a
no-op write; `eth_tx_validity_tests:798`'s `PUSH1 7; SSTORE` of a zero flag reverted
instead of succeeding. All three write zero into an untouched slot — precisely the
case the change altered.

It has been reverted. `?EXPECTED` was removed a second time on the strength of the 236
before the cause was found, and has been restored: **the pin was right all along, and
236 was a correct measurement of a broken tree.** See AGENTS.md §5, and §10a ("A
specification rewritten into a nesting is a specification you have not read").

That is the clause, the figure, and the fixture family: **`stSStoreTest` is
`sstore_0to0` and its siblings**, the exhaustive `SSTORE` price tests, and
`sstore_0to0` is the *simplest* of them. The band floor of 20,197 is 19,900 plus 297,
and 19,900 is this defect -- the remainder belongs to whichever of the other arms the
particular entry also touches.

**The correction to the last revision of this file, and it is the important part:**
it predicted the `0x2000` callee "must halt out of gas", on 660,000 required against
600,000 forwarded. It does not. The node charged that whole 33-write callee
**30,696** and the `CALL` returned **1**. The prediction was arithmetic and it was
still wrong, because it assumed the no-op arm costs 20,000 when the node charges
2,100 -- **so a frame the specification empties runs here instead of halting.** That
is a real and serious consequence, and it is the opposite direction from the
over-charge the residual shows: the corpus delta is positive because the *other* arms
over-charge, and the no-op arm under-charges inside the same frame.

So both directions are present in one function, `sstore_cost/4`, and neither was
visible before because the corpus's own figures come from the same node's price table
whenever the fixture's `post` carries no `gasUsed` -- which these do not.

**Not done:** the `dirty` arm's 1,001. Which direction it should move depends on
whether `originals` records the pre-transaction value before the first write, and
that is a separate reading of `#ctx.originals` against EIP-2200's `original_value`.
Named, not claimed.

The two candidates the shape points at, in the order they should be checked:

- **`CALLCODE` and `DELEGATECALL` run the callee's code against a different storage
  context** -- `CALLCODE` the caller's, `DELEGATECALL` the caller's. `eth_evm` added
  `check_call_value/5`'s `callcode` clause in `v1.47` and `handle_child/9` treats the
  two differently, so a per-opcode divergence in the *forwarded allowance* or in the
  *returned* gas would show up exactly like this and would be invisible in every
  fixture that only uses `CALL`.
- **EIP-2929's warm/cold account access**, charged per call and therefore per opcode
  sequence: `2,600` cold and `100` warm. The same address called twice is warm the
  second time, and the five calls here repeat `0xb000` and `0x3000`, so the order of
  the opcodes changes how many cold charges there are.

The per-entry structure is not yet understood, and the earlier claim that "the only
per-entry variable is the first `PUSH`'s immediate" was too quick: the immediates are
all 2 bytes wide, yet the programs are 185, 187, 189 and 191 bytes, so the bodies
differ too. That is the next thing to read, and it is a disassembly rather than a
measurement.



`v1.68` recorded one plausible lead -- the smallest delta, 20,197, is
`20,000 + 197`, one `SSTORE_SET_GAS` plus 197 -- and five entries contradicting it.
Four more measurements kill the hypothesis outright rather than merely weakening it.

**The callee code is byte-identical across entries, and every entry has exactly 42
`SSTORE`s in it.** The fixtures are `sstore_combinations`, so the writes are in the
*callees*, not in the transaction's init code: the init code disassembles to 45-46
opcodes with **zero** `SSTORE`s and 2-3 `CALL`s, and the storage work sits in five
pre-state contracts of which one is 166 bytes and holds 33 `SSTORE`s. So the write
count per entry is a constant, and it is 42.

**There is exactly one distinct pre-state across all 424 divergent entries in
`sstore_combinations_initial00_2_Paris.json`** -- one hash, covering `d0` through
`d334` -- so the storage's initial values, and therefore the *correct* EIP-2200 price
for each write, are identical too.

Same code, same write count, same starting storage, and **68 distinct deltas**. A
per-write pricing error cannot produce that, because there is nothing per-write to
vary. **The `SSTORE_SET_GAS` lead is eliminated.**

**And it is not the calldata either.** Only five distinct `(length, zero bytes)`
pairs exist across the entries, and **every one of those five groups carries several
distinct deltas** -- `(185, 116)` alone carries 20,193 / 20,197 / 20,695 / 70,909 /
70,913 / 71,411. So the delta is not a function of calldata length or zero-byte
count either, which also rules out a plain mis-priced `G_txdata` or EIP-7623's
`21000 + 10 * tokens` floor as the *whole* of it.

**What is left is the init code's control flow.** The `post` sections of these
fixtures carry no `gasUsed` (`['hash','logs','txbytes','indexes','state']`), so the
harness recovers the expected figure by inverting the sender's balance, and the only
thing left that varies between entries is the calldata *content* -- which determines
how many times the init code's loop runs. So the divergence is **data-dependent
execution inside a create transaction's init code**, and the node charges more than
the fixture by an amount that scales with how much of that loop ran.

The delta bands are consistent with that and with nothing simpler: narrow clusters of
**+/-1 gas** within a band (20,193 / 20,194 / 20,195 / 20,197 / 20,198, and 70,973
through 70,976), separated by large steps, with **8781 and 8783 recurring twice**
between bands and **2419** and **501** recurring as well. None of 8781, 2419 or 501
is an EIP-2200, EIP-2929 or EIP-3529 term.

**Recorded as a measurement, not a diagnosis.** What would settle it: instrument one
entry's gas per opcode and compare the total against a hand-traced EIP-2200 sum, or
add a `gasUsed` to these fixtures so the expected figure stops being an inversion.
The smallest delta (20,197, entry `d0`, 187 bytes, 2 `CALL`s) is the one to trace,
and the recurring step sizes are where to look first -- a defect that produces 8781
twice is not a per-opcode rounding difference.

The pre-state, write-count and calldata measurements that follow were made to test
the `SSTORE_SET_GAS` lead recorded above, and they eliminated it.

## The full-corpus figure, measured for the first time

**229 of the 235 non-`static` files, 15,660 entries: 6,786 match — 43.3%.** This is the
number the documentation had been carrying as "never measured", and it is **less than
half** the 94.0% the committed 25-file subset reports. Both numbers are true and the gap
between them is the most useful thing in this section.

**Why the subset flatters.** The committed subset was chosen by a rule -- *the smallest
file in each suite* -- to keep it under 150 KB per fixture. The smallest file in a suite
is the one with the fewest entries and the least state, so the subset is systematically
the easiest material. 25 files, 266 entries, 94.0%. 229 files, 15,660 entries, 43.3%.
**The subset measures that the fixes work; the corpus measures what is still broken.**

Per fork, biggest first:

| fork | files | entries | match | |
|---|---|---|---|---|
| frontier | 28 | 5,625 | 3,384 | 60.2% |
| berlin | 6 | 2,957 | 1,486 | 50.3% |
| cancun | 60 | 2,990 | 436 | 14.6% |
| prague | 105 | 2,019 | 279 | 13.8% |
| osaka | 11 | 911 | 763 | 83.8% |
| byzantium | 3 | 405 | 128 | 31.6% |
| constantinople | 2 | 192 | 57 | 29.7% |
| paris | 2 | 180 | 36 | 20.0% |
| shanghai | 8 | 288 | 125 | 43.4% |
| homestead | 3 | 82 | 82 | **100%** |
| london | 1 | 11 | 10 | 90.9% |
| **total** | **229** | **15,660** | **6,786** | **43.3%** |

`istanbul` (6 files, 4 MB, all `test_blake2b*` gas-limit sweeps) was still running at
45 minutes of CPU when this was written and is **excluded**; it is 1.3% of the files.

> **This table predates `v1.55` and no full-corpus run has been repeated since, and it
> is now stale in two separately-measured ways.** Both are recorded rather than
> corrected, because the correction would be arithmetic dressed as a measurement.
>
> 1. **The EIP-4844 blob-fee fix (item 6a) fixed 1,408 entries**, all at Cancun and
>    Prague, so those two rows are understated. Measured on the 22-file set as +56.
> 2. **The rejection vocabulary (`v1.60`) moved `rejection_mismatch` to 0** on the
>    22-file set, from 1,974. Corpus-wide that row was 1,975 entries, so the corpus
>    total would rise by roughly that much.
>
> Adding them would give ~8,770, and **that number is not written here as a result.**
> The two deltas were measured on 22 files that declare `expectException`; the
> corpus-wide row was 1,975 across the whole run. Multiplying one by the other is not a
> measurement. The full run is a developer step; until it is repeated, treat every
> figure in this table as "at the time it was taken" and check the date. **The
> committed subset has been re-measured and is unchanged at 224 of 266 (84.2%)** — it
> never had a `rejection_mismatch`, so the vocabulary change did not touch it, which is
> itself the most useful single fact about how the two figures relate.

### The outcome breakdown is the more useful number than the percentage

| outcome | count | share |
|---|---|---|
| `match` | 6,786 | 43.3% |
| `state_mismatch` | 6,434 | 41.1% |
| **`rejection_mismatch`** | **1,975** | **12.6%** |
| `fork_unreachable` | 363 | 2.3% |
| **`unpriced`** | **86** | **0.5%** |
| `expected_rejection_not_raised` | 16 | 0.1% |

**`rejection_mismatch` at 12.6% is the largest cluster, and it is now measured rather
than merely counted.** It reproduces **exactly** from the 22 of 229 files that declare
`expectException` -- 2,006 branches, 134 seconds, against a full corpus run measured in
hours -- so the cluster is entirely `expectException` branches and has no other source.
`eest_report` now prints a rejection histogram over `{corpus code, node code, node
reason}`, because the 40-entry sample could not distinguish a renamed rule from a
different one. The split:

| count | what it is |
|---|---|
| **1,639** | **the node refused for the rule the fixture names, under a different name.** 1,547 are `INTRINSIC_GAS_TOO_LOW` where the node says `INTRINSIC_GAS`; 62 are `INTRINSIC_GAS_BELOW_FLOOR_GAS_COST` where it says `GASLIMIT_TOO_LOW`; 30 use the corpus's `\|` alternative syntax, which `exception_code/1` string-compares and can never match. **A harness vocabulary problem, not a node defect, and not yet fixed** -- aligning the names moves the headline figure, so it is a change to the ruler and wants its own review |
| **326** | **the node refused for a different rule**, and in every one it said `bad_blob_hashes` where the corpus expected a funds, intrinsic-gas or max-fee reason. 288 of them are one file. A validation-*order* defect: the blob check runs before the checks those fixtures are about |
| **16** | **the node did not refuse at all.** 15 of them are **now implemented** (below); 1 remains |
| **9** | the rule is implemented and the harness cannot name it: 8 are the blob-versioned-hash rule behind the node's coarse `bad_blob_hashes`, 1 is `null_destination` for a type-4 contract creation, which is *correct* behaviour reported as `{unmapped, ...}` |

The 15 that are fixed, and the class they are in — **the node admitted transactions every
other client refuses**, which is the most serious defect class in this project, because a
node that admits an invalid transaction imports a block containing one:

- **EIP-3607, `SENDER_NOT_EOA` (8 entries).** A transaction whose sender has deployed
  code. Not implemented at all: grep found no check. It reads the sender's code through a
  new `code_of` reader in the validation context, and **`eth_block:validation_ctx/4` now
  supplies it** — without that the rule could fire in the corpus and not on the real
  admission path, which would have made the gain a fixture-only fiction. One byte of code
  is code: all eight fixtures carry `code = 0x00`.
- **EIP-3860, `INITCODE_SIZE_EXCEEDED` (6 entries).** `MAX_INITCODE_SIZE = 2 *
  MAX_CODE_SIZE`, derived from the `?MAX_CODE_SIZE` the fork schedule already held rather
  than transcribed. The module priced init code per word from Shanghai (`v1.7`) and did
  not carry the limit. All six fixtures are **exactly one byte over** — 49,153 — so the
  `=<` boundary is what is under test.
- **EIP-1559's fee fields, for type-4 transactions (1 entry).** Not a missing rule: a
  missing **clause**. `fee_fields_ok/4` matched `eip1559` and `eip4844` and let everything
  else fall to the legacy `gasPrice >= 0` branch — and a type-4 transaction has no
  `gasPrice`, so `field/3` supplied 0 and **every** fee-field rule was skipped for type 4.
  A fall-through clause turns "not mentioned" into "no rules at all" rather than an error.

### `rejection_mismatch` is 0 on the 22-file set, and that is a measurement change, not progress

**Read this section before quoting any conformance number.** The cluster went
`rejection_mismatch` 1,974 → **0**, `match` 1,784 → **3,760** (45.9% → 96.8%) on the
22 files that declare `expectException`. **The node's behaviour is unchanged.** Not one
refusal differs, except that one reason was split into the two conditions EIP-4844
names. What changed is that the runner was asking the wrong question for 1,974 entries.

The cluster was classified before anything was changed, into the three categories that
can own a rejection mismatch, and the split closes exactly:

| category | count | owner | what fixed it |
|---|---|---|---|
| **A. Behavioural / implementation gaps** | **0** | — | — |
| **B1. Error-vocabulary** — same rule, different string | 1,933 | the runner's table | `v1.60` |
| **B2. Error-vocabulary** — the node conflated two of EIP-4844's asserts into one reason | 10 | the node | `v1.60` |
| **C. Test/reporting** — the harness could not express the outcome at all | 31 | the runner | `v1.60` |
| | **1,974** | | |

**Category A being zero is the whole finding.** Every one of the 1,974 was a refusal
the corpus asked for, produced by the rule the corpus names. It was 98.4% measurement
and 1.6% harness, and not one behavioural gap. The two *real* gaps in the bucket were
outside it: the 2 `expected_rejection_not_raised` entries, which were a missing rule and
were fixed in `v1.58` (`MAX_BLOB_GAS_PER_BLOCK`).

Three things were wrong, and only the third needed the node:

- **The table's names were wrong in ten of eleven clauses.** It said `INTRINSIC_GAS`
  where the corpus says `INTRINSIC_GAS_TOO_LOW`, `GASLIMIT_TOO_LOW` for
  `INTRINSIC_GAS_BELOW_FLOOR_GAS_COST`, `BLOB_GAS_PRICE_TOO_LOW` for
  `INSUFFICIENT_MAX_FEE_PER_BLOB_GAS`, and it carried a clause for
  **`insufficient_funds`, a reason `eth_tx:validate/2` never throws** — the node says
  `insufficient_balance`. So one clause was dead and the rest were answering a question
  nobody asked. The comment above the table claimed "every code below is one the corpus
  has actually asked for". **That claim was false**, and the fix is to derive the list
  rather than assert it: the corpus has exactly **18** distinct `expectException` codes
  and they are now printed in the comment with their measured counts.
- **`|` alternatives were unreachable.** `exception_code/1` returned the whole
  `"A|B"` string and compared it with `=:=`, so those 31 entries could never match
  anything — including the answer the node actually gives. `exception_codes/1` now
  splits, strips the namespace per alternative, and the comparison is membership. A
  fixture offering alternatives is saying "this transaction is invalid and the test does
  not distinguish which rule caught it", and the node's answer is one of them.
- **The node conflated two of EIP-4844's asserts.** `bad_blob_hashes` covered both
  "there must be at least one blob" and "all versioned blob hashes must start with
  `VERSIONED_HASH_VERSION_KZG`", and the corpus names them separately. Split into
  `zero_blobs` and `invalid_blob_hash`.

**That the mapping cannot manufacture matches is measured, not asserted.** The obvious
risk of a vocabulary table is that a wrong clause invents conformance, so it was
injected: mapping EIP-7623's `calldata_floor` to `INTRINSIC_GAS_TOO_LOW` instead of
`INTRINSIC_GAS_BELOW_FLOOR_GAS_COST` **loses 76 matches and invents none**
(`rejection_mismatch` 0 → 76, `match` 3,760 → 3,684). A wrong mapping is strictly
costly, which is the property that makes this a safe change to make. Two further
injections: reverting the `|` split costs 33, and reconflating the two EIP asserts costs
exactly the predicted 10.

**What this does not change.** The committed 266-entry subset is **unchanged at 224 of
266 (84.2%)**, because it never had a `rejection_mismatch` — its `?EXPECTED` pin reads
`rejection_mismatch => 0` and still does. The 96.8% is a property of the 22-file
`expectException` set and **must not be quoted as a conformance figure for this node**.
The full-corpus per-fork table at the top of this file is now stale in a specific and
predictable way: its `rejection_mismatch` row (1,975, 12.6%) is that vocabulary, so the
corpus total of 6,786 would rise by roughly that amount. **It has not been re-run, and
the figure is not restated from the delta**, because the delta was measured on 22 files
and arithmetic dressed as a measurement is the thing this file exists to prevent. The
full run is a developer step.

**And the reporting defects were never in this cluster.** The gas histogram's blind
spot — item 7, fixed in `v1.59` — was hiding 1,408 entries in `state_mismatch`, a
different bucket entirely. `rejection_mismatch` was the *well-instrumented* cluster;
`state_mismatch` was the dark one, and it is 6,434 entries corpus-wide. Fixing the
ruler did not touch it, which is the reason the headline moved by 1,974 and the largest
real cluster by 0.

**`unpriced` is 86, not 0.** The documentation claimed -- in `README.md` and here --
that `unpriced` is **0**, "nothing is executed that this node cannot price". That is true
of the committed subset and **false of the corpus**: 86 entries execute something this
node cannot price, which `AGENTS.md` §3 makes a refusal rather than a number, so those
86 commit no state root. The claim was measured on the easy 2% of the material and stated
as if it were a property of the node. **Corrected below.**

### The gas histogram, in full, and it corrects two more claims

Top schedule-sized deltas (positive = this node spent more), as a share of all 15,660
entries:

| delta | count | share |
|---|---|---|
| **−70,919 / −70,920** | **649** | **4.1%** |
| +2 | 118 | 0.8% |
| **−19,880** | **96** | **0.6%** |
| −100 | 50 | 0.3% |
| −29,436 | 47 | 0.3% |
| −39,972 | 47 | 0.3% |
| **+10,500** | **47** | **0.3%** |
| −200 | 46 | 0.3% |
| −47,900 | 45 | 0.3% |
| −17,811 / −18,072 | 88 | 0.6% |
| −4,800 | 44 | 0.3% |
| +10,400 | 42 | 0.3% |
| +3,717 | 36 | 0.2% |
| +2,500 | 32 | 0.2% |

Two of these contradict the documentation directly:

  * **−19,880 on 96 entries is `SSTORE_SET_GAS` (20,000) − `SLOAD_GAS` (100)** -- the
    exact EIP-2200 arm-(1.) signature the README describes as *found and fixed*. It is
    fixed on the committed subset and **live on 96 corpus entries**. So either the fix is
    partial (some path still takes arm (1.) when `new' reads as zero) or these 96 go
    through a route the subset does not exercise. **Unattributed; it is a queue item.**
  * **−70,919 / −70,920 on 649 entries is the single largest signature in the corpus**
    and nothing in this repository has a note about it. It is 4.1% of everything. The
    pair differing by exactly 1 across 649 entries is a strong hint it is an
    off-by-one in a price or a refund rather than a missing rule -- but that is a
    hypothesis, not a finding, and it is recorded as one.

`+10,500` on 47 entries is the `eip196_ec_add_mul` `enough_gas_False` delta the committed
subset shows on 4 fixtures; it is the same defect at corpus scale, still unattributed.

### What the measurement is and is not

  * It is **not** a block-level or Engine-API figure. Nothing here says the node builds
    or validates a block correctly; it is the state transition alone, per transaction.
  * It is **from one fork per fresh VM**, which is the only valid methodology: outcomes
    **drift** between a fresh VM and the suite (see the `DATA_DIR`/drift note below), and
    a single-VM run over 15,660 entries would be scoring some entries against state
    another entry left behind.
  * It is the **non-`static`** half. The 2,446 `static/` files are 315 MB of legacy
    VMTests and were not run; they are 90% of the file count and are where the
    documentation says the time goes. **So "the full corpus" is not what this measures**
    and the number above is "the full EIP-named corpus", which is what
    `PROVENANCE.md` calls the practical run.
  * `rebar3 eunit` pins the **266-entry subset** at 220 matches. That pin is unchanged
    and still passes; it is a regression gate, not a quality claim, and the two numbers
    should never be quoted interchangeably again.

## Two defects in the corpus tool, found by finally running the full corpus

Both were in `eest_state_tests` / `eest_report` — the **harness**, not the node — and
between them they are why the full-corpus figure had never been produced. They are
recorded here rather than as consensus gaps, because neither is a gas figure and neither
is a state answer.

1. **`survey_one/2`'s per-fork fold grew quadratically and crashed the report.**
   `by_fork` was accumulated as
   `fun(N) -> [{Outcome, N} | N] end` with initialiser `[{Outcome, 1}]`, where `N` is
   already the **list** of `{Outcome, Count}` pairs for that fork — so each entry's
   "count" became the whole accumulation so far. Three consequences, **none of them
   visible on the committed 266-entry subset**, which is how it survived:
   - `eest_report:print_by_fork/1` does `lists:sum/1` over the counts and was handed a
     **list** where it wanted a number: `badarith, 0 + [{match, [{match, ...}]}]`, at
     the **second** entry of the first fork with two entries. **The by-fork breakdown
     had therefore never been printed, on any corpus, by the tool whose job is to print
     it.**
   - the structure grew with the **square** of the entries per fork, so memory was the
     real blocker on a large run rather than time;
   - the `n=` and `match=` figures it would have printed, had it printed anything, were
     sums of `1`s and lists.

   Fixed to `fun(L) -> [{Outcome, 1} | L] end` with initialiser `[]`, and pinned by
   `eest_conformance_tests`, whose new test asserts the shape (**flat list, integer
   counts**) and that each fork's counts sum to its own length. It bites: the old fold
   fails `well_formed_count/1` on the first fork.

2. **`DATA_DIR` was documented and inert for the trie.** `eth_mpt:ensure_dets/0` read
   `Dir = "./data"` and `?SNAPSHOT_DIR` was a relative literal, so the MPT's persistent
   state followed the **working directory** and `DATA_DIR` — `AGENTS.md` §7's "directory
   for persisted chain data" — did nothing for the one thing that is persisted. It is
   also what made a sharded run impossible: `eth_test_util:tmp_dir/0` scopes the *test*
   directories by pid, it is easy to read that as covering everything a run touches, and
   six concurrent `eest_report` workers therefore shared one `mpt_state.dets` and every
   worker but the one that won the race died at boot with `{needs_repair, ...}` or
   `{not_a_dets_file, ...}` and **no conformance output at all**. Now honours
   `eth_config:data_dir/0` for both the DETS file and the snapshot.

### Open: `total` and `by_fork` disagree inside the suite, and I could not attribute it

**Measured, unresolved, and deliberately not asserted.** On the committed corpus, same
code, same corpus:

| where | `total` | sum of `length` over `by_fork`'s lists | forks |
|---|---|---|---|
| fresh VM (`erl -noshell -s eest_report main <corpus>`) | 266 | **266** | 11 |
| inside `eest_conformance_tests` | 266 | **255** | 11 |

**11 short, exactly one per fork, all eleven of them.** `total` and `by_fork` are
updated in the **same map literal** in `survey_one/2`, one line apart, so every `T + 1`
is accompanied by a `maps:update_with/4` on `by_fork` and they cannot legitimately
disagree. Which means either my reading of the code or my reading of the measurement is
wrong, and the two possibilities have very different fixes — so this is recorded, not
guessed at.

The test asserts the *shape* (which is what the crash needed) and **deliberately does
not** assert the cross-fork sum: asserting `266 = 255` would make the suite green on a
defect, and asserting either figure alone would pin one of them without knowing which is
right.

Separately, and also recorded in `PROVENANCE.md` and not fixed here: **the outcomes
drift between a fresh VM and the suite.** Measured on Berlin: a fresh VM gives 5
`match` / 18 `state_mismatch`; inside the suite, 19 / 3. That is the store-leakage
hazard `PROVENANCE.md` describes, and it means a full-corpus figure is only meaningful
from a fresh VM, one fork per process.

## The queue, re-derived

**Re-measured after `v1.62`, from the committed corpus: 226 of 266 match, 3 are
`fork_unreachable`, and 43 are `state_mismatch`. `crash`, `unpriced`,
`sender_mismatch` and `expected_rejection_not_raised` are all 0.**

(The 78/185 figures below are the *pre-`v1.42`* measurement, kept because the two
differs only in the fee path and the gas histogram below is the pre-`v1.42` one. Both
were re-measured; neither is quoted from memory.)

Two numbers decide what the work is, and neither is the tally:

**Only 28 of the 185 have a gas delta, in six values.** Everything else reports
`gas => unavailable`, which is `gas_story/5`'s answer when the **sender's balance is
not among the differing accounts**. So for **157** fixtures the node is not diverging
in what the sender paid, and the six gas figures below are the whole of the priced
part:

| gas delta | n | note |
|---|---|---|
| `+978527` | 5 | a whole 1,000,000 allowance: the code's own comment says this "says that something is wrong and nothing about which rule" |
| `+928876` | 5 | same magnitude class |
| `+156732` | 5 | schedule-sized, so a real rule |
| `+54154` | 6 | schedule-sized |
| `+32030` | 6 | schedule-sized |
| `+76268` | 1 | schedule-sized |

**All 22 remaining files, largest first.** Checked and ruled out as a shortcut:
`CHAINID`, `PUSH0`, `MCOPY`, `TLOAD`, `TSTORE`, `BLOBHASH` and `BLOBBASEFEE` are **all**
implemented, so none of the 12/4/2/1 fixtures in those files is a missing opcode.

| n | file | what is likely, and what would settle it |
|---|---|---|
| 6 | `byzantium/eip196_ec_add_mul/test_gas.py` | **26 -> 6 across `v1.42`/`v1.43`, and the cause was neither the precompile nor the fee path this row guessed.** Every one of the 26 is `enough_gas_False` or `True` with a contract that forwards **149** gas to a 150-gas ECADD and **5,999** to a 6,000-gas ECMUL -- one gas short in both cases, by design, so the precompile never runs and the chain's own post-state is `storage = {}`. The node's EVM does exactly the same. All ten `enough_gas_True` cases were the **fee path** (`v1.42`, `v1.43`). The six that remain are also `enough_gas_False`, and their residue is `+10500` (pre-London) and `+3746`/`+2576` (London+) in *gas*; it is **not yet attributed**, and the two groups differing suggests more than one cause. |
| ~~24~~ | `shanghai/eip3651_warm_coinbase/test_warm_coinbase.py` | **Fixed (`v1.45`), and the queue's guess was wrong.** `eth_evm:initial_access/2` was not failing to apply -- it was **incomplete**: seeded with the sender, `tx.to` and the precompiles, and not with the coinbase. A uniform +2,500 on twelve fixtures. |
| 20 | `homestead/identity_precompile/test_identity.py` | 16 of this file's 28 entries were fixed by `v1.41`. Six remain, in the same code. |
| 18 | `istanbul/eip1344_chainid/test_chainid.py` | `CHAINID` **is** implemented, so this is a value or a chain-id source defect. 18 fixtures with one wrong value is the cheapest thing on this list, if that is what it is. |
| 12 | `shanghai/eip3855_push0/test_push0.py` | `PUSH0` **is** implemented and Shanghai-only, so suspect the fork gate or its gas. |
| 11 | `frontier/create/test_create_deposit_oog.py` | The "cannot pay `G_codedeposit`" arm, directly downstream of the `v1.36` fix. |
| 10 | `frontier/identity_precompile/test_identity_returndatasize.py` | 8 of 16 fixed by `v1.41`; 8 remain in the same code. |
| 10 | `byzantium/eip197_ec_pairing/test_gas.py` | Same shape as the `ec_add_mul` cluster, and the pairing check's own price. |
| 7 | `istanbul/eip152_blake2/test_blake2_delegatecall.py` | Already narrowed once; the `DELEGATECALL` calldata-length question. |
| 6 | `cancun/eip6780_selfdestruct/test_selfdestruct_revert.py` | The same-tx-created restriction, Cancun. |
| 6 | `berlin/eip2930_access_list/test_acl.py` | The long-standing `+4000 x6`. EIP-2930 intrinsic. |
| 6 | `berlin/eip2929_gas_cost_increases/test_call.py` | Holds the `+152536`-class deltas. |
| 5 | `prague/eip7623_increase_calldata_cost/test_execution_gas.py` | EIP-7623, not implemented. |
| 5 | `osaka/eip7883_modexp_gas_increase/test_modexp_thresholds.py` | Osaka. |
| 5 | `osaka/eip7825_transaction_gas_limit_cap/test_tx_gas_limit.py` | Osaka. |
| 4 | `cancun/eip5656_mcopy/test_mcopy_contexts.py` | `MCOPY` is implemented. |
| 3 | `homestead/coverage/test_coverage.py` | |
| 2 | `frontier/opcodes/test_all_opcodes.py` | |
| 2 | `cancun/eip1153_tstore/test_basic_tload.py` | `TLOAD`/`TSTORE` are implemented. |
| 1 each | `prague/eip2537_bls_12_381...`, `cancun/eip7516_blobgasfee...`, `cancun/eip4844_blobs/test_point_evaluation_precompile` | |

**Then the structural items, which are not conformance and are not ordered by size:**

- ~~**`buy_gas/4` charges the sender at the ceiling**~~ **Fixed (`v1.43`), +5
  fixtures, zero regressions.** EIP-1559's reference implementation is explicit:
  `signer.balance -= transaction.gas_limit * effective_gas_price`, then
  `+= gas_refund * effective_gas_price`. The cap appears in **neither** line, so the net
  is `gas_used * effective_gas_price`. `buy_gas/4` charged
  `gasLimit * max_fee_per_gas` and `settle_gas/8` refunded at the effective price,
  charging an overpaying sender an extra
  `(gas_limit - gas_used) * (max_fee_per_gas - effective_gas_price)` -- **zero**
  whenever `max_fee == base_fee + max_priority`, which is what every test set.
  `gas_ceiling/1` is deleted; it had one caller and it was the thing that was wrong.
  The ceiling is not lost: it is what the sender must be *able* to pay, and
  `eth_tx:fee_ceiling_ok/4` still checks it, which is a validity rule and belongs where
  the EIP puts it. The two jobs were conflated into one number used for both.
  **The five fixtures are the `typed_transaction_2` cases of `test_chainid`** -- the only
  ones with `maxFee > baseFee + maxPriority`, which is the confirmation the diagnosis
  predicted. And the existing test that *did* use a high cap asserted the buggy figure
  and defended it in a comment; corrected, not deleted.
- ~~**EIP-2930's access list is priced and never applied.**~~ **Fixed (`v1.46`),
  206 -> 214, zero regressions.** The reverted first attempt is below, and the reason it
  failed is worth more than the fix. `eth_tx:intrinsic_gas/2` charges
  `ACCESS_LIST_ADDRESS_COST * n + ACCESS_LIST_STORAGE_KEY_COST * k` **correctly** --
  verified directly, 21,000 -> 29,600 for the two-entry list in
  `eip2930_access_list/test_repeated_address_acl`, a difference of exactly 8,600 =
  `2400 * 2 + 1900 * 2`. And **nothing anywhere puts the entries in the warm sets**:
  EIP-2930 says "The address and storage keys would be immediately loaded into the
  accessed_addresses and accessed_storage_keys global sets", and there is no such code.
  The corpus figure is **`+4,000` on six fixtures** = `(COLD_SLOAD_COST -
  WARM_STORAGE_READ_COST) * 2` = `(2,100 - 100) * 2` -- exactly two cold `SLOAD`s of
  slots the list had already paid to warm, and **no intrinsic term at all**, which is
  what confirmed the intrinsic was right and the application was missing.
- **The attempted fix, and why it was reverted.** Seeding `eth_evm:initial_access/3`
  from the transaction's access list took the tally **206 -> 195**: eleven
  `istanbul/eip1344_chainid` fixtures stopped matching and **nothing** improved. Two
  things that should have made it inert, and did not:
  1. **Every fixture in both affected files spells the field `accessLists`, plural.**
     The node reads `<<"accessList">>`, singular, so it saw no list at all -- and yet
     the change moved 11 fixtures. Unexplained, and that is why it was reverted rather
     than investigated further on the same commit: a change that is net **-11** with no
     positive result is not worth landing to keep a note, and the note is here.
  2. The key had to be `{warm_store, Addr, IntegerSlot}` and **not**
     `{warm_store, Addr, <<0:256>>}`: `SLOAD` and `SSTORE` both `pop` the slot off the
     stack, where it is a word, and the access list carries 32 bytes. The wrong key is a
     warm set that is present, correct-looking and completely inert -- the third time
     this repository has paid for that asymmetry.
  **The cause of the regression, found afterwards: the runner never uses the fixture's
  `transaction` dict.** It decodes from the post-state's `txbytes` via
  `eth_tx:from_rlp/1`, so the node always saw a proper `<<"accessList">>` -- and the
  plural spelling is confined to the JSON, which nothing reads. The list was **priced**
  (`validate/2` and `intrinsic_gas/2` both call `access_list_field/1`) and never
  **applied**.

  The fix is one line in each of three places, and the second of them is the whole
  lesson:

  1. `eth_block:run_transaction/5` puts `eth_tx:access_list_field(Tx)` on the **Msg** --
     the *same function `validate/2` priced*, so the list that is charged for and the
     list that is applied cannot disagree.
  2. `eth_evm:initial_access/3` seeds the warm sets from it, converting each slot to the
     interpreter's **word**: `SLOAD` and `SSTORE` both `pop` the slot off the stack, and
     the list carries 32 bytes, so `{warm_store, Addr, <<0:256>>}` is a **different
     key** from `{warm_store, Addr, 0}`. A warm set written under a key nothing reads
     is present, correct-looking and inert.
  3. The **expected difference is 2,000, not 2,500.** The three warm-set tests beside it
     measure *account* accesses (`COLD_ACCOUNT_ACCESS_COST - WARM_ACCESS`), this one
     measures a *storage* access (`COLD_SLOAD_COST - WARM_STORAGE_READ_COST`). EIP-2930
     warms both sets and they are priced from two different constants.

  **Eight fixtures, zero regressions**: the six `eip2930_access_list/test_acl` entries
  and two `osaka/eip7825_transaction_gas_limit_cap` entries, which also carry an access
  list. Independently confirmed by the second file, which was not part of the
  diagnosis.
- **Nothing in the corpus exercises an invalid ECADD or ECMUL.** Worth stating because
  it is why `v1.44` moved the tally by zero and was still the right change: the
  committed fixtures only ever call 0x06/0x07 with *empty* input (valid -- EIP-196 pads
  it to the point at infinity) or with gas they cannot afford (so it never runs). The
  defect it fixed was not a gas figure at all but `unsupported` refusing the block.
- **Block-level conformance is never run.** Every figure above comes from
  `eth_block:run_transaction/5`; nothing in this repository executes a whole block
  against a fixture. That is a different measurement and the one a block-producing node
  needs.
- **`eth_createAccessList`** — the one RPC method genuinely absent.
- **Hive.** The interoperability row in `README.md` is empty: `etherlang` is not in
  Hive, has never been driven by a mock consensus client, and has never spoken to
  another client. See the "What compatible means here" table.
- **The full-corpus figure** (2,681 files) has still never been measured. The 5.6-hour
  run was killed. No number is claimed.
- ~~**EIP-7702's state transition** — named, not done; 3 fixtures execute a type-4
  transaction as though it carried no authorizations.~~ **Done (`v1.62`).** The
  authorization list is applied: authority recovery, the seven per-tuple validity
  steps, `0xef0100 || address` (or a **clear** for the zero address), and the
  authority's nonce bump, applied after the sender's increment and **not rolled
  back** on a revert. `prague/eip7702_set_code_tx` 54/80 -> **69/80**,
  `state_mismatch` 26 -> 11. **Two parts of EIP-7702 remain open and are listed
  under "What to do next, in order" below**: the `PER_EMPTY_ACCOUNT_COST` refund,
  and EIP-3607's relaxation plus following a delegation in the EVM.
- **Pre-Berlin `SSTORE` at Constantinople** (EIP-1283) — named, not done, and
  unreachable by block number on mainnet.

## What to do next, in order

This list exists so that work is not chosen by whichever item is nearest to hand.
It is ordered by what unblocks the most, and the ordering is deliberate. One
behavioural change per commit, and each step says what it now does.

1. ~~**Start `eth_block_builder` and make `forkchoiceUpdated` issue a `payloadId`.**~~
   **Done.** The builder is a supervised child and in the `registered` list, and it
   was *rewritten* rather than switched on — see the Phase 1 item for the four header
   defects the dead version would have shipped the moment it was started.
   `eth_block:to_payload/1` was added as the inverse of `from_payload/1` and
   round-trips all three real Sepolia payloads hash-identically. The honest limit
   stands, though the reason has narrowed: a block this node builds has a state
   root that is **not known** to match the network's. The gas table is wired now,
   SSTORE net metering included, and what remains is the standing caveat: no
   state-root divergence has been checked end to end, so the schedule being
   complete is not evidence that a root this node computes would match the
   network's. The node can serve a CL's requests but is not yet safe to propose
   from.
2. ~~**Add the missing JSON-RPC methods**~~  **Done**, and the framing was wrong:
   they were not missing so much as unexamined. A catch-all clause proxied every
   unknown method, so all eight *answered* — with another node's view. Seven are now
   answered from this node's own state and each says what it is derived from, and
   `eth_getTransactionByBlockHashAndIndex` came along because it shares the
   projection. `eth_createAccessList` is still absent; the blocker is named in Phase 6.
3. ~~**Wire the per-fork gas table into the EVM.**~~  **Done.**
   *Availability* — an instruction the executing fork does not have is an
   exceptional halt rather than a cheap one, and the fork reaches the interpreter
   through the Env. *Pricing* — `eth_fork_schedule` now owns every price the
   interpreter charges and `eth_evm:base_cost/1`, a second fork-free copy of the
   schedule, is deleted. SSTORE included; see item 4.
4. ~~**SSTORE net metering.**~~  **Done, Berlin and later.** It needed the
   transaction-start value of each slot, which the EVM did not track, and the
   transient map could not hold it: that map is transaction-scoped but is
   discarded on a child revert, whereas an original value must survive one. It
   lives in `#ctx.originals` now, recorded on the first write to each
   `(address, slot)` -- the read that supplies it *is* the transaction-start
   value, but only because nothing has written the slot yet, which is why the
   record has to precede the write. The 2700-gas-per-no-op-write overcharge is
   gone, and with it a second defect the old code had: it priced a *dirty* write
   as a clean one, because a three-case expression over the slot's current value
   has nowhere to put one.
   - **Named, not done: pre-Berlin SSTORE.** Three schedules exist before Berlin
     -- the flat rule, EIP-1283's net metering at Constantinople, and Petersburg
     reverting it -- and EIP-1283 is a different schedule, not a restatement of
     the flat one. Only EIP-2200's text is implemented, so pre-Berlin is
     **refused** (`sstore_supported/1` -> `{unsupported, {sstore, Fork}}`, which
     `eth_call` answers with an upstream fallback) rather than priced with a
     figure that would be right for two spans and wrong for the third.
5. ~~**EEST conformance work.**~~  **Done as far as it can be, and the answer is
   bad.** `apps/etherlang/test/eest_state_tests.erl` runs the `execution-spec-tests`
   `state_tests` corpus against this node's state transition and classifies every
   entry. **226 of 266 committed entries match — 85.0% — and the figure is
   reproducible**, identical per entry from a fresh VM and from inside the suite.
   (`v1.62` moved it 224 -> 226, from EIP-7702's authorization state transition;
   the previous figures here and at "Re-measured after `v1.55`" are updated in the
   same change as the number they describe, which is the only thing that keeps
   them from being the second thing to forget.)
   (This paragraph said 78 of 266 for several commits after it had stopped being
   true; the live figure is at "Re-measured after `v1.47`" above, and a second copy
   of a number that drifts is a second thing to forget to update.)
   Nothing in this repository had ever been measured against a third party's
   expected results before; the opcode table was cross-checked against instruction
   *counts* and the gas schedule was derived from the EIPs, and a schedule can be
   wrong in both of those senses and still self-consistent.
   - **EIP-7702 (type 4): representation done, state transition not.** The corpus
     reported four entries as `tx_decode_failed`, which is the weakest of the
     outcomes — it says the node cannot *represent* the transaction, not that the
     state differs — and it concealed that three separate things were missing:
     - `eth_tx:from_rlp/1` had no type-4 clause, so a type-4 transaction could not
       be decoded at all.
     - `eth_tx:sighash/1` had no type-4 clause either. **This is the part that
       mattered.** The first fix decoded the transaction and re-encoded it
       byte-for-byte, and it still had no recoverable sender: `sighash/1` fell
       through to its `unsupported` clause and `sender/1` — which catches every
       exception — answered `{error, bad_signature}`. Three capabilities and no way
       to get from one to another, and the only symptom was that four transactions
       had nobody who had signed them.
     - `eth_tx:intrinsic_gas/2` charged nothing for the authorization list. The EIP
       prices it at `PER_EMPTY_ACCOUNT_COST * authorization list length` (25,000 a
       tuple) and says the sender "will pay for all authorization tuples, regardless
       of validity or duplication", so the price is a function of the list's
       *length* and nothing about a tuple's contents may appear in it.
     - Both validity rules the EIP states are implemented and verified: a
       zero-length authorization list is invalid, and — because the outer fields
       follow EIP-4844's semantics — a null destination is invalid, which is a
       change from every earlier type and is checked for type 4 only.
     - **The state transition is now implemented (`v1.62`); the rest of the EIP is
       not, and the difference is worth stating precisely** because "EIP-7702 is
       implemented" and "a type-4 transaction executes" are now both true and
       neither means the feature works.
       - **Done:** for each tuple in order, recover the authority over
         `keccak(0x05 || rlp([chain_id, address, nonce]))` with EIP-2's `s =< n/2`
         enforced; check the chain id is 0 or this chain's; check the nonce is below
         `2**64 - 1`; require the authority's code to be empty or already a
         delegation; require its nonce to match; write `0xef0100 || address`, or
         **clear the code** when `address` is the zero address; increment the
         authority's nonce. Any failure skips that tuple and continues with the
         next. Applied after the sender's nonce increment and before the frame, so
         it is **not rolled back** when execution reverts — which is the EIP's own
         wording and the opposite of the intuitive reading.
       - **The EVM half was missing too, and `v1.63` did it** — see item 6b. What
         is left is **one** thing, and it is a price rather than a state change:
         1. The `PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST` = 12,500 refund per
            **non-empty** authority. The `v1.62` objection — that EIP-3529 caps the
            *combined* refund while `eth_evm:run/5` caps inside the frame and returns
            only the capped figure — is **solvable**: seed the frame's refund counter
            with the authorization refund and the existing cap applies to the sum.
            **This is all 11 remaining divergences** in
            `prague/eip7702_set_code_tx/test_intrinsic_gas_cost.json`, which the
            `v1.62` note here claimed the corpus could not reach. Tracked as item 6e.
       - So the corpus's type-4 execution entries now land in `state_mismatch` for a
         single reason: a missing refund, which moves one balance and nothing else.
   - What the corpus found, immediately and without any new code being written for
     it: the node **accepted a type-2 (EIP-1559) transaction at a pre-London fork**,
     which the specification rejects — 5 entries, and the worst kind of divergence
     because it is a validator that admits something invalid. **Fixed and verified**;
     see the entry below. And it **cannot decode an EIP-7702 (type 4) transaction at
     all**, 4 entries — decode, signing, pricing, validation **and now the state
     transition are implemented**; the EVM's half is not, see the entry above.
   - `eth_block:run_transaction/5` is now exported for the runner. It was already
     the function `finalize_against/5` calls, so this is not a test-only export; it
     is one transaction's effects, and `finalize/1` cannot serve the runner because
     it resolves the parent's state root through `eth_chain` and then requires the
     local MPT to *hold* that root.
   - **Getting the figure to be reproducible found two harness bugs, and one of them
     was hiding the defect the corpus was added to find.**
     - A storage slot the fixture's code reads but never declares falls through
       `eth_state`'s process-wide `base_source` to the local MPT, which is shared
       with the rest of the suite. Seeding cannot fix it — the slot is not knowable
       without executing the code. `eth_state:with_base_source/2` now lets a state
       term carry its own base, and the runner uses a new `empty` source, so an
       undeclared account or slot reads as *does not exist*.
     - **The runner inherited `ETH_NETWORK` from its caller.** The eunit path
       therefore ran the corpus under Sepolia's chain id, 11155111, against
       fixtures declaring chain 1. Five EIP-1559 validity fixtures flipped from
       `expected_rejection_not_raised` to `rejection_mismatch` — because the
       validator correctly rejects a transaction from the wrong chain, so the
       harness had been suppressing exactly the finding it was written to make. A
       harness that sets up its own preconditions and then lets the ambient
       environment choose the rest is not a harness.
   - 25 of upstream's 2,681 files are committed (1.2 MB, one per suite, the
     smallest in each). `PROVENANCE.md` beside them records the release, the rule
     the subset was chosen by, and the command for the full 503 MB run.
6. ~~**An isolated state base for the conformance runner.**~~  **Done**, as
   `eth_state:with_base_source/2` and its new `empty` source. See item 5. The tally
   is now assertable and is asserted, exactly and as a bound.
6a. **~~EIP-4844's blob fee was never charged.~~  Closed in `v1.55`** — the single
   largest measured divergence in the corpus, and a consensus defect rather than a
   conformance figure. `eth_fork_schedule:blob_gas_price/1` and `blob_base_fee/2`
   were correct and had exactly **two** consumers: `eth_call.erl:409` (the
   `BLOBBASEFEE` opcode's environment) and `eth_tx.erl:775` (the
   `maxFeePerBlobGas` admission floor). A grep for blob pricing across
   `apps/etherlang/src` found **no reference in `eth_block.erl` at all** — the
   settlement path computed nothing. The node priced the transaction, admitted it,
   and then never took the money.
   - **1,408 entries**, in two files: `cancun/eip4844_blobs/test_sufficient_balance_blob_tx`
     (1,152) and `test_blob_gas_subtraction_tx` (256). All 1,408 were
     `state_mismatch` with **one** diff shape.
   - The signature is **786,432** on every diff, and it decomposes exactly:
     `6 * 131,072` = `6 * GAS_PER_BLOB`, the six versioned hashes those fixtures
     carry. The sender was **too high** by exactly the fee, which is what "not
     charged" looks like.
   - The price is **1**, both by this node's own `blob_gas_price(917504)` and by an
     independent transcription of EIP-4844's `fake_exponential`. So the defect is
     not the curve — it is that nothing consumes it.
   - The corpus also reported the same 786,432 on **two storage slots** of the
     target contract, and that is what made it look like two defects. The
     fixture's code is `0x3231600055…` = `ORIGIN BALANCE PUSH1 0 SSTORE`, so
     slot 0 *is* the sender's balance as the frame saw it. One missing debit, read
     back twice. Decoding the fixture's bytecode was cheaper than modelling the EVM.
   - **Why it was invisible to the report.** These fixtures set
     `maxPriorityFeePerGas = 0` against `currentBaseFee = 7`, so the effective price
     is the base fee and the sender's net gas cost is zero. The gas-delta histogram
     buckets `abs(Delta) =< 100000` and every one of the 1,408 reported
     `no_comparable_gas`, so the section printed `(none in range)`. The instrument
     could not see the largest cluster in the corpus. The diffs were always printed;
     the *summary* was quiet. **The report's gas histogram needs an overflow bucket
     before it can be called a summary** — still open, and now known to be
     load-bearing rather than cosmetic.
   - Fixed by `eth_block:blob_fee/2`, which buys the fee in `begin_transaction/8`
     next to the gas, and by no arm of `settle_gas/9` returning it. The EIP: the fee
     "is deducted from the sender balance **before transaction execution** and
     burned, and is not refunded in case of transaction failure." Both halves are
     pinned separately, and the ordering is pinned by a test that asserts the
     **in-frame** balance — after the whole allowance, before the refund — which is
     the only way a node charging the right amount at the wrong moment fails. Five
     injections, all shown to bite: charging nothing, crediting it back, reading the
     price off the wrong excess, charging per blob rather than per blob gas, and
     charging it *after* the frame. The last fails exactly one test.
   - **The per-block cap (`MAX_BLOB_GAS_PER_BLOCK`) was missing too, and is fixed in
     `v1.58`.** EIP-4844 requires `blob_gas_used <= 786432` over the whole block and
     this node had no such check, so the 2
     `TYPE_3_TX_MAX_BLOB_GAS_ALLOWANCE_EXCEEDED` fixtures (7 and 9 versioned hashes)
     were admitted. `expected_rejection_not_raised` on this set is now **0**.
     - It is a **cumulative** condition and cannot be a per-transaction one: a 4-blob
       transaction followed by a 3-blob one is an invalid block whose transactions are
       each valid. So the total is threaded through `eth_block:execute_transactions/6`
       into the validation context.
     - **The total is an argument and not `Block#block.blob_gas_used`,** because on
       an imported payload that field holds the block's *declared* header value.
       Writing an executed total into it would put a recomputed number under a key
       named after a header field, which is AGENTS.md §4.1's one prohibition. The
       limit ("may this block carry this much") and the commitment ("does this
       block's header tell the truth") are two questions and must not share a value.
     - **Still open, and a different gap:** the header's `blobGasUsed` is not *checked*
       against the executed total. It is plumbed (`eth_block:from_payload/1` decodes
       it, `payload_roots/2` puts it in the header RLP) and nothing compares it with
       what the block's transactions actually consumed. `eth_block_builder` states
       `blob_gas_used = 0` and admits no type-3 transaction, so a locally built block
       is right by construction.
6b. **~~EIP-4844's blob transaction *validity*.~~  Closed in `v1.56`** — three rules
   in one EIP, all wrong, and **none of them visible in the tally** until the first
   was removed.
   - **(i) A fabricated rule.** `eth_tx:valid_versioned_hashes/1` required a versioned
     hash's 31-byte remainder to be non-zero, on the reasoning that "a zero hash would
     commit to nothing". EIP-4844 says no such thing. Its `validate_block` states the
     whole rule — `assert len(tx.blob_versioned_hashes) > 0` and
     `assert h[0] == VERSIONED_HASH_VERSION_KZG` — and the remainder is
     `sha256(commitment)[1:]` over a 48-byte commitment the transaction does not carry,
     so **the execution layer cannot answer the question even in principle**. This is
     §4.2 in its purest form: a consensus constant invented here and pinned by a test
     that argued for it in a comment.
   - The corpus settles it without appeal. Across the whole `state_tests` corpus,
     **1,502 transactions carrying `0x01 || 31 zero bytes` are expected to SUCCEED**
     and 325 to be rejected, across 9 files — and 1,827 carry one, which is **every
     type-3 transaction the corpus has**. The 325 rejections name other rules
     (`INSUFFICIENT_ACCOUNT_FUNDS`, `INTRINSIC_GAS_TOO_LOW`, ...), never this one.
   - **(ii) `max_total_fee` omitted the blob term.** EIP-4844 modifies the balance
     rule: `max_total_fee = tx.gas * tx.max_fee_per_gas` and, for a blob transaction,
     `+= get_total_blob_gas(tx) * tx.max_fee_per_blob_gas`. The node computed the first
     line only, so a sender who could not pay for its blobs was admitted. The
     arithmetic is exact: for all **288** entries in
     `cancun/eip4844_blobs/test_insufficient_balance_blob_tx` (144 Cancun + 144
     Prague), `balance < gasLimit * maxFee + value` is **false**; adding the blob term
     makes it true for **288 of 288**.
   - **(iii) The blob base fee floor could not fire.** `check_blobs/2` implemented
     `maxFeePerBlobGas >= get_base_fee_per_blob_gas(block.header)` correctly, reading
     the price from the context — and **no caller passed one**. The `undefined` branch
     was taken on every call in the program and the `ensure/2` below it was dead code.
     EIP-3607's shape, exactly: a rule present, correct, and unreachable. The four
     `INSUFFICIENT_MAX_FEE_PER_BLOB_GAS` fixtures bid 1 wei per blob gas against
     `currentExcessBlobGas = 0x240000` (2,359,296), where the Cancun curve gives 2.
   - **The lesson is the part worth keeping.** Rule (i) fired *before* (ii) and (iii)
     and answered `bad_blob_hashes` for all of them, so **322 entries were refused for
     a reason that does not exist and every one of them was a case of a rule the node
     genuinely lacked**. A check that fires early and wrongly does not merely add
     noise — it deletes the information about everything behind it. Fixing the
     fabricated one first is right even though it exposed the other two as outright
     failures, and the exposure is the point: 322 wrong reasons became 322 right
     reasons, and 4 refusals became non-refusals that are now named below.
   - **The headline did not move and that is the point.** All 322 remain
     `rejection_mismatch`, because the *names* still differ —
     `insufficient_balance` against the corpus's `INSUFFICIENT_ACCOUNT_FUNDS`. They
     are now right reasons under different names, which is the vocabulary boundary,
     not a fix and not a failure. `rejection_mismatch` 1,975 → 1,971,
     `expected_rejection_not_raised` 1 → 5, `match` unchanged at 1,784, `state_mismatch`
     unchanged at 122. Zero fixtures that used to match now fail.
   - **Open as a direct result — the per-block blob gas limit.** EIP-4844 also
     requires `blob_gas_used <= MAX_BLOB_GAS_PER_BLOCK` (786,432 = 6 blobs), and this
     node has **no such check**, so the 2
     `TYPE_3_TX_MAX_BLOB_GAS_ALLOWANCE_EXCEEDED` fixtures (7 and 9 hashes) are now
     admitted where they used to be refused for the wrong reason. The rule is
     *cumulative over a block*, so it needs the block's accumulated blob gas, and
     **that is not a one-line change**: `eth_block:from_payload/1` puts the payload's
     **declared** `blobGasUsed` in the record, so accumulating into
     `Block#block.blob_gas_used` during execution would double-count on the
     `finalize/1` path. The design question — where the running total lives, and what
     it is initialised from on a block that arrived with a declared value — has to be
     answered before the check is. Recorded, not guessed. (It is the same
     `blobGasUsed` commitment named in item 6a, seen from the admission side.)
   - 5 tests, 6 injections, all shown to bite: restoring the non-zero clause, zeroing
     the blob term, dropping `GAS_PER_BLOB` from the balance term, adding the blob
     term to *every* transaction, hardcoding the context's price to the floor, and
     making `blob_base_fee/1` a second derivation that always answers 1. The last two
     fail only the tests that own those two claims, which is what they are for.
6b. ~~**EIP-7702: make the EVM follow a delegation, and relax EIP-3607.**~~
   **Done (`v1.63`), +19 tests, 11 injections.** `eth_tx:resolve_delegation/3`
   resolves **at most one hop**, and `eth_evm:do_call/4` calls it **once**, using the
   answer for both the price and the code — so the hop that was billed and the hop
   that runs cannot be two separate readings. EIP-3607 now reads "no code *except* a
   delegation indicator". Three rules the EIP states and intuition does not:
   - **one hop, then stop.** A delegation pointing at a delegation resolves to that
     indicator's bytes, and `0xef` is not an instruction, so the frame halts. A
     recursive resolver is wrong **and** looks right: it terminates on no input,
     because a cycle is indistinguishable from a chain.
   - **a delegation to a precompile is empty code.** `0x01` does not run
     `ecrecover`; the call succeeds with no execution.
   - **the account keeps its own identity.** The delegate's code, the account's
     storage, balance and `ADDRESS`. This is an authorised `DELEGATECALL`, not a
     call *to* the delegate.
   The resolution costs EIP-2929's **additional** account access — 2,600 cold, 100
   warm — in `eth_fork_schedule:delegation_resolution_cost/2`, which exists because
   `2600` was already written out four times in `access_prices/1`.
   **The corpus does not move: `prague/eip7702_set_code_tx` 69/80 and the committed
   subset 226/266, both unchanged.** That is the finding, not a disappointment — no
   committed fixture has a delegated destination or a delegated `CALL`, so this half
   of the EIP is **not measurable by the corpus at all** and the tests are the only
   evidence for it. Both figures also confirm **zero regressions** across every
   warm-set, access-cost and `CALL` change the work touches.
6g. **A create _transaction_ deploys code for free: `G_codedeposit` is charged for
   a `CREATE` opcode and not for a create transaction.** **Diagnosed, not fixed.**
   The whole of it is in `eth_block:deploy/5`:

   ```erlang
   deploy(State, ok, Output, Address, true) when byte_size(Output) =< 24576 ->
       S1 = eth_state:set_code(State, Address, Output),
       S2 = eth_state:set_nonce(S1, Address, 1),
   ```

   No deposit, and **no "cannot pay the deposit" branch at all**. `eth_evm:do_create/5`
   charges `code_deposit_cost(Fork) * byte_size(Code)` and fails the create when the
   frame cannot cover it, so the two create paths disagree -- and the transaction
   one is the one a user writes.
   - **Two consequences, both consensus.** A transaction deploys up to 24,576 bytes
     of code for **free**, 200 per byte; and a create that cannot afford its own
     deposit still **succeeds** and hands its gas back. This is the same class as
     the blob-fee defect `v1.55` fixed -- a price the node knows, computes a
     constant for, and never charges on one of the two paths that can incur it.
   - **The 200s are closed by arithmetic.** From the runner's own gas map:
     `initcode_32_bytes-exact_execution_gas` is `spent_actual 1198062` against
     `spent_expected 1198262`, and the **only** diffs are two balances -- the
     deployed code is **identical**, so the code is not the variable. A one-byte
     deposit is 200. The node returns exactly that much too much gas.
   - **The 199s are NOT explained and are not claimed to be.**
     `initcode_32_bytes-too_little_execution_gas` is `1198062` against `1198261` --
     199. The fixture's two cases differ from each other by **1** gas of execution,
     and the node's two are identical, so the node is missing 200 in one and 199 in
     the other. A deposit is 200 x n, so 199 is not one. The
     "cannot-pay-fails-the-create" branch is the obvious candidate and it may well
     account for it, **but that is a hypothesis and the two paths have not been
     separated by a measurement.**
   - **Why nothing is committed.** A consensus price is not a thing to land on a
     partial explanation, and the remaining budget would not have covered the suite
     twice, the injections and the corpus. The fix is well defined -- `deploy/5`
     needs the fork and the gas left, so it becomes `deploy/6` returning
     `{State, GasLeft'}`, the deposit is subtracted, and `GasCharged0` is computed
     from the adjusted `GasLeft` -- and it needs one more measurement to be
     trustworthy.
   - **The one measurement that closes it:** for one `*-too_little_execution_gas`
     case, print whether the node's create **succeeded**, and what `byte_size` of
     `Output` it was about to deploy. If it succeeded where the fixture failed, the
     missing branch is the 199 and both are one defect; if it succeeded on both,
     there is a second, smaller one.

~~**EIP-2930: warm the access-list _address_, not only its storage keys.**~~
   **Done.** `eth_evm:access_list_access/2` seeded `{warm_store, Addr, Slot}` and
   never `{warm_account, Addr}`, so a listed address was charged 2,400 intrinsic and
   re-charged 2,600 as a cold access on first use. EIP-2930's specification-in-code
   does both, and its motivation names the half that was missing -- "the SLOAD and
   EXT\* opcodes would only cost 100 gas", and `EXT\*` is an *account* access.
   The function's comment claimed the addresses were "already warm", on the reasoning
   that the frame's own address is the transaction's recipient: not a justification,
   since that says nothing about any *other* address. **Measured:** 22-file set
   3,831/3,884 and the committed subset 226/266, both unchanged, which is the result
   to want from a change to every access-list transaction's warm set.
6f. ~~**EIP-3529: the refund cap's base is the frame's gas, not the transaction's.**~~
   **Done (`v1.65`).** EIP-3529's own words: "the max gas refunded **after a
   transaction** to `gas_used // MAX_REFUND_QUOTIENT`", and EIP-7623 spells
   `gas_used` out as `21000 + ... + execution_gas_used` -- so the 21,000 is inside
   it. The node capped on the frame's own consumption, so its cap was smaller by
   `intrinsic / 5` and it **under-refunded** by that much whenever the cap bound.
   The *divisor* had always been right; only the base was wrong.
   - **Measured: the committed subset 226 -> 249 of 266**, `state_mismatch` 37 -> 14.
     The largest single move since the access list, **and the 22-file set is
     completely unchanged at 3,831 of 3,884** -- those are transaction-*validity*
     files with little refundable work, so the whole rule is invisible to them. Two
     corpora, two samples; "the corpus does not exercise it" is a claim about a
     *named* corpus and this commit is the proof of why.
   - `eth_evm:run/6` takes the enclosing transaction's already-spent gas on
     `#ctx.intrinsic`, so every child frame inherits it. `run/5` is a bare frame and
     passes 0, which is **right**: an `eth_call` and a system call both charge no
     intrinsic, so there the frame's gas *is* the transaction's gas used.
   - **6e is now unblocked** and its result will be correct rather than differently
     wrong: seeding the frame's refund counter flows through the right cap.

6e. ~~**EIP-7702: the `PER_EMPTY_ACCOUNT_COST` refund, and it is 11 corpus entries.**~~
   **Done (`v1.66`).** `prague/eip7702_set_code_tx` is **80 of 80** and the 22-file
   set went 3,831 -> 3,842 with `state_mismatch` 51 -> 40.
   - The refund is `PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST` = 12,500, **per
     non-empty authority**, and it is written as the EIP's **difference** rather than
     a literal 12,500: the subtraction is the specification, because the rule *is*
     that delegating yourself costs half what delegating a new account costs.
     `PER_AUTH_BASE_COST` did not exist in the node before this.
   - **Seeded into the frame's starting refund counter**, not applied after the
     frame returns. The EIP says *global refund counter*; the frame's counter is the
     only global counter there is; and seeding means the frame's own refunds stack on
     top and the cap applies to the sum. `v1.65` made this correct — the cap is now
     taken over the transaction's gas used.
   - **`exists/2` is read before the nonce bump.** `set_delegation/4` increments the
     nonce, so reading it afterwards makes every account non-empty and refunds every
     delegation the EIP exempts. The injection that moves the read bites.
   - **Two of five injections do not bite, and neither should be chased.** A bare
     `12500` cannot be distinguished from the difference because they are the same
     number today — that is a *maintenance* property, not a runtime one, and no test
     settles it. Seeding a child frame with the refund too largely cancels against
     the parent; the residual is the child's own cap, and pinning that needs a fixture
     tuned to a fraction of the refund, which is asserting the tuning.
   - Committed subset 249 -> 250: **one**, because the subset holds one such fixture
     and the directory holds eleven.

   That is recorded rather than acted on, because the honest position is that the
   order is **unverified in both directions**: this node cannot show its order is
   right, and the corpus cannot show it is wrong. Reordering `validate/2` on the
   strength of a reading of someone else's `case` statement would be changing a
   consensus path to match a document rather than to match a result, which is the
   mirror image of the fabricated clause in item 6a. If it is ever changed it should
   be changed because a *fixture* demands it.
