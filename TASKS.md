# etherlang v1.0 — Execution Client Task List

> **Specification conformance is unverified.** Nothing in this repository has been
> checked against the execution-spec tests (EEST) or `eips.ethereum.org` at scale.
> There is no EEST fixture directory and no fixture runner: `test/vectors/` holds
> three committed Sepolia blocks and nothing else. Every specification claim below
> was checked against the *text* of the `execution-apis` repository's per-fork
> files and against the EIP text, by reading it, and the rules are pinned by unit
> tests — but no conformance fixture has been run, so nothing here should be read
> as a conformance claim. The unwired per-fork gas *pricing* (Phase 5) is a
> precondition for any such result.
>
> The grep that used to be offered as evidence here —
> `grep -rn 'execution-specs\|eips.ethereum\|EELS' apps/etherlang`, asserted to
> return nothing — **no longer returns nothing**, and has been retired rather than
> left in place. `eth_fork_schedule` and its tests now cite execution-specs and
> go-ethereum as the provenance of the per-fork opcode table, so it returns six
> comment hits. A handle that has gone stale reads as a clean result, which is
> worse than having none.

**86 tasks across 9 phases** — Phase 1-5 partially complete (**41 done, 45 remaining**).

> The header used to read "81 tasks … 44/81 done, 37 remaining". Counted against the
> file at `d623f6a` it was 82 boxes, 33 of them ticked — so it overstated completion
> by 11 tasks and understated the total. Every phase's own "(N tasks)" label was
> wrong in six phases for the same reason. The numbers above and the per-phase
> labels are counted, not asserted; re-derive them with
> `grep -cE '^- \[[ x]\]' TASKS.md` before quoting them.

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

**The measurement that would settle it, and it is small:** the node's *actual*
`gasUsed` for these 424 entries, taken from the receipt rather than by inverting a
balance. If it is constant across all 424 -- which it must be, since the execution is
identical -- then the whole of the 20,197-to-139,693 range is the fixture side, and
the node is right. `eest_state_tests` already carries `Detail`'s `gas` map with
`spent_actual` and `spent_expected` separately; what is missing is a run that
separates them and prints both for entries whose post-state carries **no**
`gasUsed`. That is a change to the *reporter*, not to the node, and it is the reason
this cluster has taken this long: **an instrument that can only recover one side of a
comparison by arithmetic will keep reporting a disagreement it cannot attribute.**



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
7. **The divergence fingerprints**  *(next, and these are concrete)*. The tally says
   `state_mismatch` 249 times, which is not a work list. `eest_report`'s gas-delta
   histogram is: a delta of a few thousand gas repeats because it is one missing
   schedule term, and a delta in the millions means a frame consumed its whole
   allowance where the fixture's did not. Of 229 comparable deltas:
   - ~~**The histogram's own blind spot.**~~  **Fixed in `v1.59`.** `add_gas_delta/3`
     kept only `abs(Delta) =< 100,000` and discarded the rest, and the report printed
     `(none in range)` when the map was empty — which is what it printed over the
     1,408-entry cluster in item 6a, all of them `no_comparable_gas`. The accumulator
     now keeps `buckets` (unchanged), `over`/`over_max` for deltas beyond the range,
     and `unseen` — a count **per reason a gas figure could not be computed**:
     `no_comparable_gas`, `zero_price`, `not_divisible`, `no_sender_balance_diff`,
     `no_gas_story`. `eest_report` prints all three. The rule is one line: **a section
     that prints nothing must say what it did not look at.**
   - **What that immediately exposed.** On the 22-file `expectException` set the
     `no_sender_balance_diff` bucket alone is **71** entries — a `state_mismatch` whose
     diff carries no balance for the sender at all, so no gas figure is derivable, and
     nothing before `v1.59` reported that they existed. On `cancun/eip4844_blobs` the
     overflow bucket is **258** deltas beyond 100,000, **largest 4,919,046**. Both are
     now *findable*; neither is *explained*.
   - ~~**And the tally is still not a work list.**~~  **Fixed in `v1.61`.** Counting
     those 71 was necessary and not sufficient: a divergence in a *storage slot* or a
     *nonce* has no gas figure to recover, so the gas instrument structurally cannot
     decompose the largest cluster, and `TASKS.md` item 7 has said "the tally says
     `state_mismatch` 249 times, which is not a work list" for a long time.
     `v1.61` counts the **shape of the diff** — in the diffs' own vocabulary, since the
     comparison already builds them as typed terms:
     `balance` (settlement), `storage` (execution, split into *the fixture says zero*
     = a write the node did not make, and *wrong value*), `nonce` and `code`
     (transaction lifecycle, and both together is a CREATE).
   - **What that says, on the two sets measured.** The counts are per diverging field
     and an entry can count in several, so they exceed the entry count:

     | set | entries | nonce | code | balance | storage |
     |---|---|---|---|---|---|
     | 22-file `expectException` | 122 | **1,005** | **1,002** | 91 | **0** |
     | `cancun/eip4844_blobs` | 275 | 8 | **0** | 544 | **1,063** |

     The two sets are **disjoint in shape**, which is the finding: the validity set is
     *CREATE lifecycle* — code not deployed and nonces not bumped, and not one storage
     write — and the blob set is *execution and settlement*, 1,063 storage writes of the
     **wrong value** and not one code divergence. So "the largest cluster" was two
     clusters wearing one number, and the cheapest lead is the 91 balance diffs on the
     validity set, because a balance with no code and no storage alongside it is a
     settlement defect and nothing else.
   - **Still open, and the largest unattributed figure in the repository:** the
     **4,919,046** overflow delta on `cancun/eip4844_blobs`, and its 257 siblings. A
     delta of that magnitude means a frame consumed its whole allowance where the
     fixture's did not. `v1.61` does not explain it; it makes it visible.
   - **~~`+550` gas, 6 fixtures, `byzantium/eip196_ec_add_mul`, all forks Berlin →
     Prague~~ — cause found and fixed; the fixtures still diverge and the remaining
     400 gas is unresolved.** The contract forwards 150 gas to ECADD and stores the
     success flag. A CALL's `gas` argument is an *allowance*: the precompile's cost
     comes out of it and the rest returns to the caller, so the caller pays exactly
     the cost. `eth_evm` did neither half. The cost was charged against the
     **caller's remaining gas** rather than the forwarded allowance, and the unused
     allowance was **never returned** — `finish_call/8` took the child's leftover gas
     as an argument and discarded it (`_Left`), while the regular CALL path does its
     own refund in `handle_child/9` and passed nothing, so the one argument every
     regular call ignored was the only thing the precompile path relied on. Fixed;
     `add_gas/2` and the misleading `Left` parameter are gone rather than renamed.
     The two errors had opposite signs, so neither read as a consistent overcharge:
     a CALL forwarding *exactly* the cost failed whenever the caller's own remainder
     had dipped below it — the arrangement a tight transaction is in, and why the
     fixture stored **0** where the specification says **1** — and a CALL forwarding
     *more* was charged the whole forwarded amount on top of the cost. The fixture's
     delta fell from **+550 to +400**.
   - **What the remaining 400 actually is, and it is not what I first assumed.** The
     contract's slot 0 holds `0xdeadbeef` in the pre-state and `1` in the expected
     post-state, so the `SSTORE` is a write over a **non-zero** slot: EIP-2200
     clause (2.1.2), `SSTORE_RESET_GAS` = 2,900, with no clear refund because the
     new value is not 0. I had been reading it as a 0 → 1 create at 20,000, which
     is why the arithmetic never closed. The frame's costs are
     `21` (seven `PUSH1`) `+ 2,600` (cold `CALL` to the precompile)
     `+ 150` (ECADD) `+ 2,900` (the reset) = **5,671**; this node spends **5,674**;
     the fixture expects **5,274**. Both the sender's balance and the coinbase's
     independently give 26,274, so the figure is not an artefact of how the runner
     recovers gas. So there are two separate gaps: **3 gas** between this node and
     the plain sum of the rules, and **397 gas** between the plain sum and the
     fixture, which matches no constant in `eth_fork_schedule`. **Unresolved.**
   - ~~**`-1` gas, 3 fixtures, `prague/eip7623_increase_calldata_cost`**~~ — cause
     found and fixed; the fixtures no longer diverge on gas.
     The one gas was a coincidence and the cause was a whole missing rule. The
     transaction is one **zero** calldata byte, so EIP-7623's floor is
     `21000 + 10 * 1 = 21,010`; the node charged 21,009 because it applies no floor
     at all and the frame happened to use exactly 5 gas. It read as an off-by-one
     and would have sent a reader looking at rounding.
     EIP-7623 is now implemented from the EIP's own text:
     `eth_fork_schedule:calldata_floor/2` holds the rule (Prague and later; a token
     is a zero byte or a *quarter* of a non-zero one, so `0x00` is 10 of floor and
     `0x01` is 40), `eth_tx:validate/2` rejects a limit below the floor, and
     `eth_block:run_transaction/5` charges it.
     - **The half that is easy to get wrong, and was:** the floor has to be charged
       to the *sender*, not merely reported. `settle_gas/8` settles a sender by
       refunding the unused allowance against the price `buy_gas/4` charged, so a
       `gasUsed` raised after that settlement is a number the sender was never
       billed. The first version reported 21,010 and credited the coinbase a tip on
       21,010 while the sender's balance still showed 21,009 — `gasUsed` right and
       the post-state wrong, which is a divergence that announces itself in neither
       number. Three end-to-end tests, two injections, both verified.
   - **Unresolved, and it is a measurement defect rather than a node defect.** 243
     of the 249 `state_mismatch` entries carry a coinbase balance diff, because the
     coinbase is paid `gasUsed * (effectivePrice - baseFee)` and the `state_test`
     format has no `baseFeePerGas` in its `env`. The runner used to supply `0`, so
     every London-or-later fixture had a coinbase diff that said nothing about the
     node — a real tip bug and a harness default were indistinguishable, which is
     the one thing a conformance harness must not be. The fee is now **derived from
     each fixture's own expected numbers** (7 for every London+ fork in the corpus,
     which is the protocol minimum a synthetic genesis block has), and where the
     arithmetic does not come out whole the derivation reports itself rather than
     inventing a number. Only 15 of the 243 have the coinbase as their *only* diff,
     so this is not what is wrong with the other 228 — but the remaining coinbase
     diffs are now unexplained rather than known-noise, and that is the next thing
     to run down.
   - **The full-corpus figure is not measured, and the tool made that unmeasurable.**
     The committed 266-entry subset is pinned and reproducible; the full 2,681-file
     upstream run had been going for **four hours** at 100% CPU with an output file
     still on its first line, because `eest_state_tests:survey/1` printed nothing
     until it finished. Four hours with no output is indistinguishable from a hung
     process — the only way to tell them apart was to go and read `ps` — so a long
     measurement could not be left alone and had to be watched.
     `survey/2` now takes a progress interval in files and writes
     `~/25 files, ~p entries, ~p ms~n` to `standard_error`, so it cannot interleave
     with the report on `standard_io'. Off by default, so a test run and a developer
     run of the same function print the same thing. The run is restarted with it.
     **The 2,681-file number is not claimed until that run finishes.**
   - **Twelve-fixture buckets, one per file, three files.** `-22000` on
     `shanghai/eip3651_warm_coinbase`, `-19500` on
     `frontier/identity_precompile/test_identity_precompile_returndata`, `-4200` on
     `shanghai/eip3855_push0`. Each is internally consistent across its sub-cases and
     each is *negative* — the node refunds gas the chain charges — so the likely shape
     is one cause reached three ways rather than three causes. Partly characterised:
     the `identity_precompile` case is not an out-of-gas, and the node spends 23,771
     where the fixture expects 43,271 out of a 200,000 limit. The callee forwards only
     16 gas to the identity precompile, which costs `15 + 3*words` = 18, so the call
     must fail and leave `RETURNDATASIZE` at 0 — and the SSTORE that stores it is the
     dominant term in the expected figure. **Unresolved: the three are not yet
     explained, and the arithmetic above is a hypothesis, not a finding.**
   - **The pairing check was priced by a second module. Fixed** (`v1.31`).
     `eth_pairing_bn128:check_pairing/1` returned `{ok, Out, 34000*K + 45000}` — a
     **three**-element tuple carrying EIP-1108's Istanbul column, hard-coded in a
     module that has no fork and cannot know one. The bug was not a wrong number but a
     wrong *shape*: `eth_evm_precompiles:run/3` matched a two-element `{ok, Out}`, so a
     three-element reply matched nothing and fell through to the catch-all, handing
     the caller that figure unchanged. **Every fork from Byzantium onward was priced
     at Istanbul rates, including the fork that motivated
     `eth_fork_schedule:bn128_cost/2` in the first place**, and the fork plumbing
     added there was never reached. Byzantium's empty pairing check cost 45,000
     instead of 100,000.
     **The lesson is the one this repository keeps having to learn, and it is worth
     more than the fix.** A test pinned `eth_fork_schedule:bn128_cost/2` at *every
     fork* and passed. The table was right, the test was green, and the code that
     should have read the table was dead. **Pinning a table is not pinning a caller.**
     The new tests are at the precompile, and one of them pins the *arity* of the
     reply, because the arity is the thing that fell through the match.
   - ~~**The largest remaining positive bucket.** Two fixtures in
     `byzantium/eip197_ec_pairing/test_gas_costs`, the `enough_gas_False` cases, where
     the node spent its whole **1,000,000** gas limit against the chain's 56,723.
     **Cause found**, by running the nineteen-byte callee directly instead of reasoning
     about the fixture: `PUSH1 0` five times, `PUSH1 8`, `PUSH2 0xafc7`, `CALL`,
     `PUSH1 0`, `SSTORE` — it forwards 44,999 gas to the pairing check with **empty
     input**, which at Istanbul costs 45,000, so the call fails by one gas and the
     `SSTORE` stores the failure. The call is fine. The `SSTORE` is the whole of it,
     and it is a **`SSTORE` at Istanbul**, which this node **refuses** because it has no
     pre-Berlin SSTORE schedule. The refusal was being recorded as an ordinary failed
     transaction, which is charged its whole limit. Fixed — see below.~~
   - **An unpriceable operation was executed into a wrong state root. Fixed**
     (`v1.34`). `eth_block:run_transaction/5` now returns
     `{error, {unpriced, What}}` when the interpreter halts with `unsupported`, and
     `execute_transactions/5` propagates it — the path it already had for a transaction
     it cannot execute, with the state deliberately not committed either.
     **55 of the 266 committed fixtures were affected**: 48 pre-Berlin `sstore`
     (byzantium 14, istanbul 16, petersburg 16, homestead 2) and 7 `precompile 9`, the
     alt_bn128 pairing check. The tally's `state_mismatch` fell 251 → 196 and a new
     outcome, `unpriced`, took those 55. **The tally did not get better; it got
     honest** — a wrong state root committed to the trie is the failure mode this
     project exists to avoid, and a refusal is the correct answer while the schedule is
     missing.
   - ~~**Two named gaps remain behind those 55.**~~ **Both closed** (`v1.35`), and
     `unpriced` is now **0** -- **on the committed subset**. That is the whole scope of
     the claim, and the full-corpus measurement above falsifies the wider reading of it:
     **86** entries on the 229-file non-`static` corpus execute something this node cannot
     price. The sentence used to say "nothing in the corpus", which is a statement about
     the node written from a measurement of 266 entries. Corrected here and in
     `README.md`; the underlying gap is unchanged and still open.
     price.
     - **Pre-Berlin SSTORE is priced.** The flat rule — the yellow paper's, which
       Petersburg put back — with the figures EIP-2200 quotes as its own inherited
       values: "SSTORE_SET_GAS: 20000, not changed", "SSTORE_RESET_GAS: 5000, not
       changed", "SSTORE_CLEARS_SCHEDULE: 15000, not changed". `SLOAD_GAS` is
       fork-selected, **50 / 200 / 800**, from EIP-150 ("Increase the gas cost of
       SLOAD to 200 (from 50)") and EIP-1884 ("The SLOAD (0x54) operation changes from
       200 to 800 gas"). That is eight of the nine pre-Berlin forks.
       **Constantinople is the ninth and is still refused**, and it is the *only* one:
       EIP-1283 replaced the flat rule with net metering and Petersburg reverted it.
       Constantinople is also **unreachable by block number on mainnet** — it and
       Petersburg activate at the same block, 7,280,000, and the last one at a block
       wins — so it is reachable as a name, which is how the corpus reaches it, and not
       as a block. That fact is pinned, because a test expecting a mainnet
       Constantinople block found `fork_at_number(7280000)` answering `petersburg`.
     - **Rejected precompile input is now a call failure, not an absence**, and both
       conflations were mine, in opposite directions. `check_pairing/1` returned one
       `unsupported` for "cannot run this" and "the input is invalid", where an input
       the pairing check rejects is a *call failure* under EIP-197; it now returns
       `{error, invalid_input, Why}` for the second. And `blake2f/1` returned
       `unsupported` for any input not 213 bytes, so the seven `eip152_blake2` fixtures
       — whose DELEGATECALLs carry **zero-length** calldata, where the call should
       simply fail — refused the whole block.
       `precompile/3` has a third answer, `{failed, Why}`, handled by
       `eth_evm:run_call/10` like a precompile it cannot afford: nothing returned,
       forwarded gas consumed, caller carries on.
     - **SLOAD itself was mispriced at both ends.** `access_prices(16#54)` was
       `{200, 2100}` at every fork, right for exactly one span of three: a Frontier
       SLOAD cost a third of what it should and an Istanbul one 400 too little.
     - `match` 12 → **17** there, and the corpus then found three more missing prices,
       all of them on the create and store paths and all of them found by the corpus
       rather than by a test. **17 → 24.**
     - **The code-deposit cost was charged nowhere** (`v1.36`). `G_codedeposit` is 200
       per byte of the code a create hands back, at every fork, and `create_with_value/9`
       never took it. Worse, the EIP-170 size cap was a bare `byte_size(Code) =< 24576`
       in a guard — a predicate with no price behind it, and applied at *every* fork
       including the eight before EIP-170 introduced it. So this node deployed code of
       any size for free, and never went out of gas on a create whose deposit it could
       not pay. `create/test_create_deposit_oog` is the fixture that names it: a
       twenty-three-byte callee that stores a word, then `CREATE`s six bytes of init
       code which itself `RETURN`s 10,000 bytes — a 2,000,000-gas deposit against a
       934,172-gas frame. Seven of those fixtures expected the **whole** 1,000,000
       allowance to be spent; the node spent 57,062 and handed back 918,145 gas the
       chain never returns. EIP-2 item 3 is the rule: "If contract creation does not
       have enough gas to pay for the final gas fee for adding the contract code to the
       state, the contract creation fails (i.e. goes out-of-gas) rather than leaving
       an empty contract."
     - **EIP-170's cap is now a fork fact, not a constant.** `max_code_size/1` answers
       `infinity` below Spurious Dragon, where there was no cap and the only thing
       bounding a deployment was what the caller could pay.
     - **EIP-2929's "additional" `COLD_SLOAD_COST` on `SSTORE` was missing.** The EIP
       has two halves: rewrite EIP-2200's `SLOAD_GAS` to 100 and `SSTORE_RESET_GAS` to
       2,900, *and* charge an extra 2,100 for a `(address, storage_key)` pair not in
       `accessed_storage_keys`. The node had the first and not the second, so every
       **first** touch of a slot cost 2,100 too little and every second touch was right.
       The asymmetry is why it survived: a test that writes a slot twice cannot see it,
       and four existing tests did exactly that. The corpus gave it up as a −2,100
       delta on **40** fixtures, all at the same number.
     - **EIP-2929's transaction-start warm set was never seeded** (`v1.37`). Its own
       text: "When a transaction execution begins ... `accessed_addresses` is
       initialized to include the `tx.sender`, `tx.to` (or the address being created if
       it is a contract creation transaction) -- and the set of all precompiles." None
       of it was, so the transaction's own recipient, its own sender and every
       precompile were each charged `COLD_ACCOUNT_ACCESS_COST` on first touch. The
       corpus named it as a uniform **+2,500** on twenty-four fixtures, and 2,500 is
       `COLD_ACCOUNT_ACCESS_COST - WARM_STORAGE_READ_COST` exactly -- 2,600 − 100 -- at
       every fork from Berlin and at none before it, which is what identifies it as a
       precompile rather than anything else: the `test_gas.py` contracts behind those
       fixtures each call one precompile and do nothing else.
       `eth_fork_schedule:precompile_addresses/1` answers the "set of all precompiles"
       by *asking* `precompile_at/2` rather than keeping a second list, and
       `no_precompile_above_ten_is_the_highest_address_test` is the pin that keeps the
       enumeration's bound and the layout's catch-all clause the same statement.
     - **A `CALL` whose value the caller cannot cover now returns its forwarded gas**
       (`v1.38`). The spec's own `call`, in `forks/berlin/vm/instructions/system.py`:
       `if sender_balance < value: push(evm.stack, U256(0)); evm.return_data = b"";`
       `evm.gas_left += message_call_gas.sub_call`. This module pushed 0 and
       **consumed** the allowance, on a comment's reasoning that "the CALL opcode has
       already paid for it" — and the opcode *has* paid for `sub_call`; `sub_call` is
       what is being refunded, which is the other direction of travel. The corpus named
       it as a uniform **+45,247** across the six forks of
       `eip2929_gas_cost_increases/test_call_insufficient_balance`; it is now **+2,300**.
       `callcode` is in the same fix: the spec's `callcode` is the same block with the
       same check and `should_transfer_value=True`, and `check_call_value/5` had only a
       `call` clause, so `CALLCODE` moved no value and consulted no balance.
     - **What the five fixes did to the histogram.** The `−9xxxxx` cluster (18 fixtures,
       ~928,000 gas each) is gone entirely, as are `+2500` ×24 and `+2497` ×24.
       Comparable gas figures fell from 217 to 136, which is a *change* and not an
       improvement in itself: 81 fixtures no longer yield a figure at all, because the
       sender's balance no longer implies a whole number of gas. That is a symptom of
       the node's balance now differing from the fixture's in a way the derivation
       cannot express, and it is **not yet explained**. Named, not chased.
     - **The runner could not see storage at all** (`v1.39`). Not a node defect, and it
     was worth twenty-one fixtures. `eth_state:new/2` rewrites every `{store, A, S}` key
     of the overlay it is handed through `eth_state:slot_key/1`, so a slot seeded from
     a fixture's `<<"0x00">>` went in under the 32-byte word; the comparison's read path
     looked it up under the **integer** `0`. Every slot therefore read as zero coming
     back. `london/eip1559_fee_market_change/test_eip1559_tx_validity` had been read as
     a node defect for a long time — an instrumented run of it reports `result=ok
     charged0=26006`, and 26,006 is the chain's own figure, so the gas and the write
     were both right. **25 → 46 matches, `state_mismatch` 238 → 217.**
   - **`eth_block:run_transaction/5` read `input` alone** (`v1.39`). `input` is what
     `eth_tx:from_rlp/1` emits; the JSON-RPC field is `data`. A transaction handed in as
     a JSON-RPC object ran with **no calldata** while `eth_tx:intrinsic_gas/5` charged the
     intrinsic cost of calldata that was never executed. `eth_tx:calldata/1` is now the
     one reader, preferring `data` and falling back to `input`, and `eth_call` uses it
     too. **The committed corpus cannot see this** — every fixture arrives carrying
     `input` — so it is pinned by two unit tests and the commit says the corpus did not
     find it.
   - **The EIP-1559 fee side, and it is 18 fixtures with one cause, not five.**
     Sharper than the entry above, and measured. Every one of the **type 2, 3 and 4**
     transactions in the committed corpus fails on the fee side rather than the gas
     side: `test_tx_type::test_eip1559_tx_validity` x5 at `+517,958`, and 13 more whose
     delta is not a number at all but `no_comparable_gas` -- the sender's balance
     difference does not divide by the price, so the runner cannot state a figure. Those
     13 are `test_chainid` x8 (types 2, 3, 4), `test_execution_gas` x2 (types 3, 4) and
     `test_tx_gas_limit` x3. **`+517,958` is `(gasLimit - gasUsed) * price`**: the gas
     is right -- an instrumented run reports `charged0=26006`, the chain's own figure --
     and the price is wrong.
     **Fixed (`v1.40`), and the tally is 46 -> 53.** Two harness defects, no node
     change. `schedule_fork_at/3` asks `current_fork/4'` about the block the runner is
     building, on **mainnet** -- because `fork_point/1`'s numbers are mainnet's, and
     asking the configured network (Sepolia) answers a different question: mainnet's
     Berlin is 12,244,000 and Sepolia's London is long before 12,250,000, so Berlin came
     back as `london`. That was caught by the new invariant test on its first run, which
     is the argument for writing the test before trusting the function.
     `derived_base_fee/3` prefers the fixture's own `env.currentBaseFee`, because the
     derivation **cannot** recover it here: with `baseFee = 7, maxFee = 7, priority = 1`
     the tip is zero, `Gain` is 0, and the sender's spend cannot separate the base fee
     from the effective price. The derivation reads the sender's price as
     `min(maxFee, priority)` = 1, which is the *tip*.
     Seven fixtures flip and **nothing flips the other way**: the five
     `test_eip1559_tx_validity` entries plus `homestead/coverage/test_coverage` at
     Cancun and Prague -- and with them **`+152,536 x2`**, the largest unexplained
     figure the corpus had, which was the base fee all along.
     **The other 11 of the 18 are still open.** They move to different and still-large
     deltas, so a second cause remains in the typed-transaction fee path that none of
     the four measured candidates reaches.
     **The measurement, because the choice was not obvious:**
     `A2+env` (the fix) **+7**; `A2+solve-both-equations` **+2**, needs explicit integer
     arithmetic because the rational form is a float in Erlang and a float became a
     block's `base_fee_per_gas` and raised `badarith` **inside the node**; `A2` alone
     and `env` alone **+0** each; and `merge_base_fee/1`'s first clause **-27** (46 -> 19)
     because it is the thing that stops a base fee being attached to a pre-London block.
     `merge_base_fee/1` is **left alone** for that reason, and `schedule_fork_at/3` has
     no list of fork names in it on purpose -- EEST's `ConstantinopleFix` has no
     schedule atom, so a name list needs a clause that is a lie.
     **A precompile's output was never published, and this is the second-largest win
     in the project (`v1.41`): 53 -> 78, with zero regressions.** `finish_call/8` does
     not set `retdata` -- for an account `CALL` that is `handle_child/9`'s job and it
     does it -- and the **precompile** path had no such job, so all three of its
     branches handed the caller back to the interpreter with the register holding
     whatever the *previous* call had left. `RETURNDATASIZE`, `RETURNDATACOPY` and
     `SHA3` all read it.
     **How it was found: a histogram, not a fixture.** Twenty-four fixtures sat at
     exactly **-19,900**, which is `SSTORE_SET_GAS` (20,000) minus `SLOAD_GAS` (100) --
     EIP-2200's arm (1.) `current == new`, taken because the *new value* read as 0,
     where the chain takes arm (2.1.1). A delta that decomposes onto two neighbouring
     constants is not a mispriced opcode; it is a wrong **value** feeding the right
     price. So it is a **state** defect first and a gas defect second, and the stored
     slot is wrong as well as under-charged.
     **Seven sites, not one,** and the seventh is the one a grep cannot find: a
     successful `CREATE` pushes the address itself and never went through
     `finish_call/8`. The specification is explicit that the **stack** gets the address
     and the buffer gets `b""` -- read, not recalled, because the older reading of
     EIP-211 (the address, 32 bytes left-padded, in the buffer) is **wrong** for the
     current spec and would have been a plausible way to "fix" this.
     The two **depth-limit** sites are fixed and **unpinned**, and the reason is worth
     the note: a frame already at depth 1024 cannot make any call, so it cannot have
     populated the buffer either. The first version of that test set `depth` in the
     message and **passed with the fix deleted**; a test that cannot fail was removed
     rather than kept.
     **Isolated, and it is one word.** The runner builds the block with
     `base_fee_per_gas = merge_base_fee(base_fee_for(Fork), Derived)`, and
     `base_fee_for/1` is:

         base_fee_for(Fork) ->
             case eth_fork_schedule:at_least(Fork, london) of
                 true -> 0; false -> undefined
             end.

     **`Fork` is a binary.** It comes from `fork_of_key/1`, which does a binary capture
     out of the entry's key, so it is `<<"London">>` and `<<"Paris">>` and not the atoms
     `at_least/2` expects. An unrecognised fork ranks as ancient everywhere else in
     `eth_fork_schedule`, so `at_least(<<"London">>, london)` is `false` --
     verified, not inferred -- and `base_fee_for/1` answers `undefined` for **every**
     fork, post-London included. Pre-London that is the correct answer and the bug is
     invisible; from London it is not, so the block carries no base fee,
     `effective_gas_price/4` takes its `undefined` branch, and a typed transaction --
     which has no `gasPrice` -- is executed at an effective price of **0**. An
     instrumented run of `test_eip1559_tx_validity` reports
     `basefee=undefined eff=0 ceiling=7 charged=26006 sender_drop=0`: the sender is
     debited 700,000 at `maxFeePerGas` and refunded nothing.

     That also explains why preferring the fixture's `env.currentBaseFee` moved nothing
     when tried: `merge_base_fee/1`'s first clause is
     `merge_base_fee(undefined, _Derived) -> undefined`, so a derived value was
     **discarded** -- the merge cannot reach it while the fork's own figure is
     `undefined`, whatever it is.

     Two harness defects, one of them a word. **Named, not fixed here**, because the
     fix belongs with a measurement: the corpus is the only thing that can say whether
     the eighteen flip, and the two candidates are `base_fee_for/1`'s argument and
     `merge_base_fee/1`'s clause order, and picking between them on a reading is how the
     tally ends up quoted for the wrong reason.

     **What is *not* true, and was said before it was checked:** that this left the
     node's EIP-1559 fee path "unmeasured". It does not.
     `eth_tx_validity_tests` pins the fee recipient's tip and the sender's refund
     against `min(MaxFee, BaseFee + MaxPriority)` at `BaseFee = 10`, and
     `fee_below_base_fee_is_rejected_test` pins the `fee_too_low` refusal at 1,000.
     What this bug removes is the **corpus's ability to corroborate** those unit tests,
     which is a real loss and a much smaller claim.
     **The largest single cluster of what is left, and one cause rather than eighteen.**
   - **Remaining fingerprints**, largest first: `+517958` ×5, `+152536` ×2
       (`test_coverage`), `−19900` ×24, `−19912` ×6, `−3` ×36, `+10500` ×6,
       `+2576`/`+3746`/`+3776` ×5 each, `+4000` ×6 (`test_acl`), `+2300` ×7,
       `+9139`, `+9439`, `+20176` (BLS12-381 G1MSM), `+2100`, `−23000` ×2,
       `−48300` ×2, `−20700` ×2, `−19800` ×4, `−19200` ×2.
       `+45247` ×6 and `+314626` ×2 are **gone**.
     - **`+2300` ×7 is the EIP-150 stipend, and the fix is known and not shipped.**
       The spec has **two** figures where this module has one: `cost` is the clamped
       gas **plus `extra_gas`** and `sub_call` is the clamped gas **plus the stipend**,
       so the stipend is in the child's allowance and not in the caller's charge, and a
       call that does not happen refunds `sub_call`. `child_gas/4` returns
       `min(gas + stipend, cap)` for both.
       I attempted the split **twice and reverted it both times.** The first attempt
       put the stipend in `cost`, and the same six fixtures then charged their whole
       100,000 allowance -- `Sub + 2300` can exceed the gas remaining, so the error was
       a **halt** and not a wrong total. The second attempt had the right field and the
       fixtures went to a state mismatch I could not explain. A change to every
       value-bearing `CALL`'s accounting is not something to ship on a transcription the
       corpus neither confirms nor refutes, so it stays open with the spec's text
       quoted in the code.
     - **`−3` ×36** (`test_identity_return_overwrite`, four call opcodes × nine forks).
       Every opcode constant in that program is correct -- `MSTORE8` 3, `MSIZE` 2,
       `RETURNDATASIZE` 2, `RETURNDATACOPY` 3, `SHA3` 30, `GAS` 2, all checked against
       the table -- so it is not a price in `access_prices/1` or the opcode table. It
       is the same 3 at every fork, which rules out anything fork-gated. Diagnosing it
       needs a per-opcode gas trace the interpreter does not emit, and building one was
       not a good use of the remaining time against `+517958`, which is larger.
       `−17412`/`−17400` are **gone**; they were `test_modexp_thresholds` at 6 × 2,952,
       and 2,952 is not a number this node's table contains, so the ModExp complexity
       formula was wrong somewhere rather than a constant being off by a little. The
       four fixes above moved them and the residue is elsewhere.
     - **ECADD and ECMUL still conflate the two and are named open.** `bn128_add/2`
       returns `unsupported` for an off-curve point where EIP-196 makes it a call
       failure. I stopped there because the `byzantium/eip196_ec_add_mul` fixtures pass
       with the present shape and a change there could move them in a direction I had
       not measured. Named, not done.
   - **`+56668` and `+56665`.** **Unresolved, and gone — verified on the full
     histogram at `v1.36`, and the verification matters more than the fact.** The entry
     spent several revisions insisting this fingerprint had to be "re-derived rather
     than chased" when it was neither re-derived nor chased: it dissolved, on the
     `create_deposit_oog` and EIP-2929 fixes above, without anything being done to it
     by name.
     It is recorded here rather than deleted because **I first concluded it had
     dissolved from a truncated read** -- `h5`'s output piped through `head -30`, which
     cut the list off below `+517958` and hid exactly the two entries I was looking
     for. The conclusion happened to be right and the observation could not support it.
     A histogram is read in full or not read; a partial one is a list of the entries
     that happened to be near the top.
   - ~~**Where the 2300 stipend sits relative to the 63/64 cap.**~~ **Fixed
     (`v1.47`), 214 -> 220, zero regressions.** This one was open *on purpose* and the
     refusal was correct; what changed is what was available to decide it with.
   - **Why it was open, and the reasoning is worth keeping.** EIP-150's pseudocode
     reads
%%
%%         gas = min(gas, max_call_gas(compustate.gas - extra_gas))
%%         submsg_gas = gas + opcodes.GSTIPEND * (value > 0)
%%
%%     which says the stipend is added **after** the clamp. This module added it before,
%%     symmetric with the charge, which is what it had always done. Implementing the
%%     reading above made the child's allowance `cap + 2300` while the caller was
%%     charged `cap + 2300` -- so with a callee that spends everything it is given, the
%%     child's allowance exceeded what the caller had left and the CALL's own charge
%%     could raise. That is second-order accounting that could not be settled from the
%%     text, and a CALL's gas is not something to change on a reading. **The refusal was
%%     the right call and the reasoning behind it is unchanged.**
   - **What settled it: the specification's source, not the EIP, and then the corpus.**
     `ethereum/forks/berlin/vm/gas.py`, `calculate_message_call_gas`:
%%
%%         call_stipend = Uint(0) if value == 0 else call_stipend
%%         gas = min(gas, max_message_call_gas(gas_left - memory_cost - extra_gas))
%%         return MessageCallGas(gas + extra_gas, gas + call_stipend)
%%
%%     and `forks/berlin/vm/instructions/system.py`, `call`:
%%
%%         charge_gas(evm, message_call_gas.cost + extend_memory.cost)
%%         ...
%%         if sender_balance < value:
%%             push(evm.stack, U256(0)); evm.return_data = b""
%%             evm.gas_left += message_call_gas.sub_call
%%
%%     Three consequences, and the node had two of the three wrong. **`cost` excludes the
%%     stipend** -- it is a gift, created from nothing, and the caller never pays for it.
%%     **The clamp applies to the pre-stipend figure**, so `min(gas + stipend, cap)`
%%     silently swallows the stipend into the cap whenever the cap binds, which is the
%%     common case because `GAS`-forwarding calls saturate it. And **the refund returns
%%     the stipend too**, because it returns `sub_call` and the caller was never charged
%%     it -- so a `CALL` that cannot cover its value hands the caller 2,300 gas it never
%%     paid for, and a frame can finish with *more* gas than it started with.
   - **The prediction was made before the measurement.** A comment on `child_gas/4` had
%%     already recorded that with the forwarded-gas refund in place the same six fixtures
%%     sat at `+2,300` -- "the stipend exactly -- the consequence of the one-figure model
%%     above, and not independently fixable" -- and that the split was "not shippable on
%%     the strength of a transcription". It was not a transcription any more: it was the
%%     Berlin source, which is the code that generated the fixtures disagreeing by 2,300.
%%     **Six fixtures, all of them `eip2929_gas_cost_increases/test_call_insufficient_balance`,
%%     and zero regressions.**
   - **The recorded worry was real and the resolution is that it does not apply.** "The
%%     reading which follows the EIP makes a child's allowance exceed the caller's
%%     remaining" is true, and it is **correct**: the stipend is not the caller's to give,
%%     so the child holding more than the parent has left is specified behaviour rather
%%     than an overflow. The child's gas lives in its own frame and is never drawn from
%%     the caller's. What the earlier attempt got wrong was putting the stipend in
%%     `cost`, which *does* charge the caller a figure that can exceed the gas remaining
%%     -- and that was a **halt**, not a wrong total, which is the only reason it was
%%     caught at all.
   - **Four tests in this repository asserted that the caller pays the stipend.** All
%%     four were wrong by exactly 2,300 and all four were written to pin EIP-150's or
%%     EIP-161's figures rather than this one; they are corrected, not deleted, and each
%%     still catches the defect it was written for. This is the fourth instance of a test
%%     recording a defect as a requirement, and the second whose *justification* is what
%%     made it wrong -- `a_call_the_caller_cannot_afford_returns_its_forwarded_gas_test`
%%     said the residue was "EIP-161's 9000 for the value transfer and nothing else".
   - **`-1208` gas, 1 fixture, `homestead/coverage` at Homestead.** **Unresolved.**
   - **Precompile pricing took no fork at all. Fixed** (`v1.27`). This was a
     structural gap rather than a corpus finding, and it was a large one:
     - **The alt_bn128 prices were Istanbul's at every fork.** EIP-1108's table has
       two columns and the node used the "Updated" one everywhere, so ECADD cost 150
       where Byzantium says 500, ECMUL 6,000 where it says 40,000, and the pairing
       check 45,000 + 34,000k where it says 100,000 + 80,000k. On mainnet that is
       every block from genesis to 9,069,000.
     - **The layout was Istanbul's at every fork too.** 0x08 is the pairing check
       from Byzantium (EIP-197) and stays there; 0x09 is blake2f from Istanbul
       (EIP-152) and is *nothing* before it; 0x06/0x07 arrived with EIP-196. So a
       Byzantium block's CALL to 0x09 ran a BLAKE2b round, where the specification has
       no contract at all and a CALL should succeed on empty code.
     - **ModExp was a mixture matching no fork**: EIP-198's complexity and divisor
       with EIP-2565's floor of 200, and no Berlin switch — so Berlin's divisor of 3
       and its `words**2` complexity were missing. EIP-198 has no minimum, so small
       calls at Byzantium were overcharged, and large ones at Berlin by up to 6.7x.
     `precompile/2` and `is_precompile/1` became `precompile/3` and `is_precompile/2`,
     and the fork now comes from the frame's own `#ctx.fork` in `eth_evm` and from the
     block being simulated in `eth_call` — not from the operator's `ETH_FORK` pin,
     which is what `eth_estimateGas` on a historical block was using.

     **One thing I got wrong while fixing this, and the committed corpus is what
     caught it.** I first wrote the layout as "Istanbul swapped 0x08 and 0x09, so
     blake2f took 0x08 and the pairing check moved to 0x09" — from recollection, and
     wrong. The corpus says otherwise directly: `byzantium/eip197_ec_pairing` contains
     a contract whose code is `PUSH1 8 ... CALL`, and `istanbul/eip152_blake2` contains
     `PUSH1 9, PUSH1 1, DELEGATECALL`. There is no swap. Had the recollection stood,
     the change would have replaced a correct layout with a wrong one while its commit
     message claimed to repair it. The rule this follows is the one §4.2 already
     states — derive the value, then pin it — and the two committed fixtures are a
     derivation from a third party's expected results, whereas my memory of which
     address moved was not.
8. **Block-level conformance**  *(next after that)*. The corpus above is state transitions.
   EEST's `blockchain_tests` and the Ethereum Foundation's own `ethereum/tests`
   exercise what a state test cannot: state roots, receipts roots, logs blooms and
   block headers, over multi-block forks and transitions. Two thirds of the current
   divergences are `state_mismatch`, so fixing those comes first -- but a node that
   cannot produce a block another client would accept has not been measured at all,
   and that is the measurement Lighthouse actually cares about.

### Deliberately later: the rest of the Engine API

These are real gaps, not low-priority decoration, but they are not on the critical
path to a node a consensus layer can drive — items 1 and 2 above are. Left here so
they are not forgotten rather than worked on prematurely.

- **`engine_getPayloadBodiesByHashV1` / `ByRangeV1`** (Phase 1). Blocked on **data,
  not code**: the EIP-2718 wire bytes are not retained, and `eth_chain` stores the
  `eth_getBlockByNumber` response whose `transactions` are decoded RPC objects. The
  prerequisite is a storage change — fetch `eth_getRawTransactionByHash` per
  transaction at sync time and keep the bytes — and that belongs with the other
  chain-store work, not as a bolt-on to the engine.
- **`engine_notifyHeaders`** (Phase 1, and the Beacon requests item in Phase 3). No
  clause in any per-fork file of `execution-apis`; implementing it now would mean
  inventing its shape. The EIP-4788 execution side is already done; only the
  engine-API plumbing is missing.
- **Engine API V4/V5** (Osaka, Amsterdam). Mainnet is not on these, so V3 is the
  highest version a live consensus client calls.
- **`engine_getBlobsV1`** (Phase 5). The point-evaluation check is already local;
  this is the method that surfaces it, and `eth_kzg:blob_to_kzg_commitment/1` is
  still deliberately unimplemented, so it would need that first.


## Phase 1: Engine API — Consensus Layer Interface (14 tasks)
- [ ] **Engine API server** — `eth_engine` serves ten methods over real HTTP with the response shapes the specification defines and a JWT check on every request: `newPayload`, `forkchoiceUpdated` and `getPayload` at V1, V2 and V3, plus `engine_exchangeTransitionConfigurationV1`. The four V1 methods named here previously were all of them, and a post-Merge consensus client — which calls `forkchoiceUpdatedV3` and `getPayloadV3` every slot — got `-32601 method not found` for both. `newPayload` now decodes, checks the block hash, executes and maps the verdict. It still cannot hold the state an arbitrary payload needs, so it answers `SYNCING` in practice.
  The **server** half of this item is done: the ten methods are dispatched, the response shapes are the specification's, and a node with no JWT secret refuses the port rather than serving it open. What keeps the box unchecked is the named remainder at the end of this section — `getPayloadBodiesBy*V1`, `notifyHeaders`, and `createAccessList` — which are absences rather than defects in what is there. (This paragraph previously ended with "This item stays open on the missing methods listed at the end of this section." twice.) What each method actually does:
  - `engine_newPayloadV1` decodes the payload with `eth_block:from_payload/1`, checks `blockHash` against the header the payload's own fields imply, calls `eth_block:finalize/1`, and maps the resulting verdicts. It answers `INVALID_BLOCK_HASH` for a payload whose `blockHash` is not `Keccak256(RLP(header))`, `INVALID` for one that will not decode or a transaction that is invalid, and **`SYNCING`** for a well-formed payload whose parent state this node does not hold — which, for an arbitrary payload, is always. That `SYNCING` is the specification's status for a payload whose "requisite data for the payload's acceptance or validation is missing", and it is honest rather than a fallback: the transactions root *is* verified even with no prestate, because it covers only the block's own transaction list
  - It does not answer `ACCEPTED` either, and that is a deliberate change. `ACCEPTED` is in the status enum, so returning it looks right, but the specification makes it a claim with preconditions — every transaction non-empty, `blockHash` equal to `Keccak256(RLP(header))`, the payload not extending the canonical chain, not fully validated, and its ancestors known and well-formed. None is checked here, so `ACCEPTED` is as unsupported as `VALID`
  - `engine_forkchoiceUpdatedV1` records the client's `headBlockHash`, `safeBlockHash` and `finalizedBlockHash` as this node's head, safe block and finalized checkpoint, and answers **`SYNCING`** for any head it has not itself validated. Per the specification that method's `VALID` *is* the verdict on executing the block, so the previous unconditional `VALID` was the claim the node actually made: a block reported valid without executing it, decoding it, or checking a single one of its three roots. `VALID` is still returned for the one case with nothing to judge — no head claimed and no payload to build on
  - It does **not** check that the head exists, that it descends from the finalized block, or that the finalized block is a checkpoint, and it cannot: the head is now recorded as a *hash*, which is what the specification's field is, where it used to be resolved to a block *number* through `eth_chain`
  - `newPayload` does **not** compare `parentHash` against the recorded head, deliberately. A payload whose parent is not the head is not invalid — it is a side branch, or a block this node has not imported — and the specification answers `SYNCING` to both, so the comparison could only ever produce a wrong `INVALID`. It survives as a log line in `note_parent/2`
  - `engine_getPayloadV1` takes the specification's `payloadId` and answers `-38001 Unknown payload` for all of them. The builder that would issue a `payloadId`, `eth_block_builder`, is not started (see Phase 3), so no id this node could be asked about is one it issued. It used to take no argument at all and return the last payload the client had itself submitted to `newPayload` — not a block this node built, and not necessarily one it believes is valid, which is a block a consensus client would have broadcast
  - `engine_exchangeTransitionConfigurationV1` returns the `TransitionConfigurationV1` object — `terminalTotalDifficulty`, `terminalBlockHash`, `terminalBlockNumber` — which is the whole purpose of the method. It used to return a bare `VALID`, so the client received no configuration at all from the one call that exists to hand it over
  - `eth_engine` calls `eth_block` and `eth_tx` and compares roots. It does not call `eth_mpt` directly, and that is by design: state comes from `eth_block:finalize/1`, which is the only code allowed to switch `eth_state` to the local trie
- [x] **Payload validation** — validate each payload before accepting. The decoder exists (`eth_block:from_payload/1`), the engine calls `eth_block:finalize/1`, and the verdicts are mapped. This item was open because the verification existed in `finalize/1` and was unreachable from the engine's entry point; it is now reached:
  - Parent hash is present and well-formed ✅. It is deliberately **not** compared against the recorded head: a payload whose parent is not the head is not invalid, it is a side branch or an unimported block, and the specification answers `SYNCING` to both, so the comparison could not decide anything
  - `blockHash` equals `Keccak256(RLP(header))` ✅ — checked by `check_block_hash/1` before execution, which is where the specification requires it ("in all cases … even if this branch or any other branches of the block tree are in an active sync process"). A mismatch is `INVALID_BLOCK_HASH`, a status distinct from `INVALID` precisely so a client can tell a corrupt payload from a valid one this node rejected
  - State root matches after execution ✅ **as a verdict**. `eth_block:finalize/1` recomputes it under the local trie and reports `{verified, Root} | {unverified, Reason}`; `eth_engine` maps a checked-and-wrong root to `INVALID` and an unchecked one to `SYNCING`, with a mismatch outranking an unchecked root
  - Receipts and transactions roots match after execution ✅ **as verdicts**, same mapping. The transactions root is verified even with no prestate, since it covers only the block's own transaction list
  - Block number is expected — **not** done. This line was marked complete and is not
  - Fee recipient (coinbase) set — **not** done
  - **Still not done**: this node holds no prestate for an arbitrary payload's parent, so the state root and receipts root come back `{unverified, …}` in practice and the answer is `SYNCING`. The plumbing is real; the state is not there. Snap sync (Phase 4) is what would change that
- [x] **Payload decoding** — `eth_block:from_payload/1` and `eth_block:payload_block_hash/1`, plus 23 tests in `eth_block_payload_tests.erl` against real Sepolia payloads (Paris 1450507, Shanghai 3001655, Cancun 6985356). The contract, stated rather than assumed:
  - The V1 field set is **required**; only V2/V3 additions are optional. A missing required field is `{error, {missing_field, Key}}` and is never defaulted, because a defaulted field would be hashed into a block hash this node then certified
  - The post-Merge header is 16/17/20 fields (Paris / Shanghai / Cancun). `parentBeaconBlockRoot` **is** a header field (EIP-4788, checked against the EIP text); `requestsHash` is not
  - `from_payload/1` assumes post-Merge (difficulty 0, 8-byte nonce). A pre-Merge block cannot be expressed as a payload, so there is no fallback path to write
  - The transactions root is computed from the payload's **wire bytes**, not by re-encoding decoded transactions; the decoder separately verifies that each transaction re-encodes exactly, returning `{error, {transaction_not_re_encodable, Index}}` if not
  - The transactions root and the withdrawals root are recomputed from the payload's own lists for the `blockHash` check, so the hash is tied to the body rather than to the header fields alone
  - An unparseable quantity is `{error, {bad_quantity, Key}}`, never 0
- [x] **Two header-construction constants were wrong** — found by building the header RLP independently in Python and diffing it byte-for-byte against the Erlang output, and now pinned by tests asserting the real block hashes of three Sepolia blocks:
  - `eth_block:new/2` used `?EMPTY_ROOT` (`56e81f…`, the empty **trie** root) for `sha3Uncles`. It must be `Keccak256(RLP([]))` = `1dcc4de8…`. Both constants live in the same module and one had been standing in for the other
  - `eth_block:new/2` set the nonce to `<<0:192>>` — 192 **bits**, 24 bytes, where the nonce is 8. RLP prefixes strings by length, so every header it built was 16 bytes too long. `from_json/1` had the same default
  - Both were live in `eth_block:new/2`, the constructor the builder and the block tests use. They did not affect `newPayload` validation, which decodes rather than constructs — which is why three real block hashes, and not a unit test of the constructor, is what caught them
- [x] **Transition configuration** — the configuration is now parsed and returned, and parsed as what the specification says it is: a `QUANTITY`, i.e. hex. It was decoded with `binary_to_integer/1`, which is base 10, so every real terminal total difficulty — `"0xc70d815d562d3cfa955"` for mainnet, and the `2^256-1` the specification mandates for an undecided value — raised `badarg` and the surrounding catch turned it into `SECURITY_ERROR`. No network with a non-trivial total difficulty could exchange its configuration at all. An absent value is now reported as `2^256-1`, and the map handed to the client is built from the values just parsed rather than the ones being replaced. `TERMINAL_TOTAL_DIFFICULTY` is also the Merge's activation input, and fork selection evaluates a block's total difficulty against it (see EIP-3675 in Phase 5). `TERMINAL_BLOCK_HASH` is carried and echoed, but nothing checks a post-Merge block's difficulty against it or validates that the last PoW block is the one it names — that part is **not** done and is listed under EIP-3675 below
- [ ] **Safe/finalized forkchoice** — the hashes are recorded, as the block hashes the specification defines them to be; they were resolved to block *numbers*, which cannot tell two blocks at the same height apart, and which made an ordinary forkchoice update depend on `eth_chain` being up — a call to it raised `noproc`, which the catch turned into an error for the whole request. What is still missing is resolving them against the local chain: ancestry from head to finalized, checkpoint checks, and `eth_sync:track_finalized/1` respecting CL finality
- [x] **The undecided-TTD sentinel was the wrong constant, and the comment claimed otherwise** — it was `2^256-1`; `src/engine/paris.md` item 7 mandates `2^256-2^10` (`115792089237316195423570985008687907853269984665640564039457584007913129638912`), which is 1023 lower. The comment above the macro purported to quote the clause while quoting a *truncated prefix* of the number — the final `38912` was missing — so the quoted string was both the wrong value and a misquotation. Both layers compare this number, so a node reporting a different one fails every transition-configuration exchange against a spec-reading client. Now written as the expression, with the exact decimal pinned by a test that also checks the `2^256-2^10` identity, so the value is derived and pinned rather than transcribed
- [x] **Engine API authentication** — implemented in `eth_jwt` against `src/engine/authentication.md`: HS256, `alg: none` rejected, the `iat` claim required and bounded to ±60 seconds, unrecognized claims ignored, a hex-encoded 256-bit secret read from `DATA_DIR/jwt.hex` and generated on first start. This was ticked before it existed. The handler read no secret and verified no token, so the port was open to anything that could reach it while TASKS.md and the handler's own header comment described it as authenticated. A node with no secret now refuses the port rather than serving it open
- [x] **Execution engine status** — engine state is held in `eth_engine` and the CL's head/safe/finalized are kept in it. `eth_engine` is now a supervised child, started before the listener that serves it; it was declared in `etherlang.app.src`'s `registered` list — a claim that a process is running — but nothing started it, so every engine method in a real node was answering from a gen_server that did not exist
- [x] **Engine API test vectors** — `eth_engine_tests.erl`, **78 tests** (was 50, originally 38), rewritten against the real payload fixtures rather than a hand-rolled mock map: the status each method may honestly return, the JSON key and hex forms a real request carries, the state actually being kept, the response shapes, the authentication rules, the verdict mapping via the exported pure `status_for_finalize/1` and `status_for_verification/1`, and the HTTP surface end to end through a real listener. The 25 newest cover the V2/V3 gates. Plus 23 in `eth_block_payload_tests.erl` and 7 in `eth_test_util_tests`. There were **none** before: `grep -rl eth_engine apps/etherlang/test/` returned nothing, so every claim this project made about the engine was unchecked
  - The summary table used to say 36 while the Phase 1 item in the same commit said 38, and the file at `d623f6a` has 38 test functions. 36 was a stale number that was never re-derived — the same failure as the "81 tasks / 44 done" header, one line up
- [x] **Engine API version coverage** — `newPayload`, `forkchoiceUpdated` and `getPayload` are served at V1, V2 and V3, plus `exchangeTransitionConfigurationV1`: ten methods. Previously only the four V1 methods existed and a post-Merge consensus client was answered `-32601 method not found` for `forkchoiceUpdatedV3` and `getPayloadV3`, which it calls every slot — the node could not be driven by a CL at all, whatever else it could do. The versions differ along four independent axes, and each is implemented separately:
  - **The structure gate.** `newPayloadV2`'s required structure is a function of the payload's timestamp (`src/engine/shanghai.md`); `newPayloadV3` requires the parameters to "strictly match the expected one" with `null` counting as not provided (`src/engine/cancun.md` item 1). "Strictly" is an *exact key set*, not containment: V3 is a superset of V2, so a presence-only check would admit a Prague payload to a V2 method
  - **The fork gate.** `-38005: Unsupported fork` outside the method's fork time frame, which needed new work in `eth_fork_schedule`: `timestamp_in_frame/3` and `timestamp_frame/2`, read from the same schedule `current_fork/4` uses so they cannot disagree, and half-open at the upper bound
  - **V1 has no structure gate.** `paris.md` never mentions `-32602`; the clause arrives with V2. The first implementation applied it to V1 anyway and the pre-existing V1 tests caught it
  - **`payloadAttributes` versions separately.** `PayloadAttributesV3` is V2 plus `parentBeaconBlockRoot`, *not* plus the blob gas fields. Reusing the payload's key table — the obvious thing to write — checks for the wrong keys twice over
  - **Two distinct codes.** Malformed attributes are `-38003`; well-formed but aimed at the wrong fork are `-38005`. Only the second is retryable on a different method
  - **`INVALID_BLOCK_HASH` is supplanted by `INVALID` from V2 on**, and `getPayload`'s result changes shape per version
  - **Blob versioned hashes are checked on `newPayloadV3`** before and independently of the state-dependent path, as `cancun.md` item 3 requires ("in all cases even during active sync process"). A mismatch is an `INVALID` status; an actual array this node cannot compute is `unchecked`, deliberately not treated as `[]`
  - 25 new tests, each injection-verified: an old engine matcher, a payload-key table used for attributes, the fork frame answered with a closed bound, and a two-sided frame substituted for V2's one-sided comparison all make specific tests fail
  - **Still true after this**: the node cannot *author* a block, because `payloadAttributes` is validated but not acted on and no `payloadId` is ever issued
- [ ] **`engine_getPayloadBodiesByHashV1` / `engine_getPayloadBodiesByRangeV1`** — absent entirely, and the blocker is **data, not code**. `ExecutionPayloadBodyV1` requires each transaction as its EIP-2718 wire bytes, and this node does not retain them: `eth_chain` stores the `eth_getBlockByNumber` response verbatim (`eth_sync:fetch_block/2`), whose `transactions` are *decoded* RPC objects. Re-encoding a decoded object is not a substitute — the RPC object carries no `blobVersionedHashes` field, so a type-3 transaction cannot be reconstructed from it at all. Serving these needs `eth_getRawTransactionByHash` per transaction at sync time, stored.
  - An implementation was written and then **removed** for this reason, which is worth recording. Projecting the stored maps cannot work, and the first version matched `#block{}` records — which nothing on the read path ever builds, since `eth_block:from_json/1` has no caller in `src/`. It would have compiled, passed no test that did not also drive the chain, and returned `null` for every block in production. A method that answers `null` for everything looks conformant and is not, which is why this is listed as a gap rather than shipped
  - Lighthouse requires both methods, so "Lighthouse-compatible" is not currently true of the engine surface
- [ ] **`engine_notifyHeaders`** — absent (see the Beacon requests item under Phase 3). The clause does not appear in any per-fork file of the `execution-apis` repository (`paris`, `shanghai`, `cancun`, `prague`, `osaka`, `amsterdam`, `bogota`, `common`); only the V2 `getPayloadBodiesBy*` methods appear under those names. Its shape would have to be guessed, so it is left undone rather than invented
- [x] **Block authoring** — `payloadAttributes` are read, `forkchoiceUpdated` returns a `payloadId`, and `getPayload` returns a real block. This item said "no `payloadAttributes` handling, so `forkchoiceUpdated` can never return a `payloadId` and the node cannot build a block for the CL", which was true when written and stopped being true when `eth_block_builder` was added to the supervisor's child list; the box outlived the sentence. The builder was rewritten rather than switched on, because the dead version assembled a block with its own header constants, three of which were wrong in ways already found and fixed in `eth_block`, and discarded every `payloadAttributes` field.
  **The block it builds is still not the block the network would build.** Its state root does not match the network's, for the reasons in item 7 — the same gas-schedule divergences that hold the conformance tally at 254 of 266 rather than all of it. So the item is closed as *wiring* and the divergence is tracked where it can be seen, not here.

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
- **The engine had no decoder and never called `finalize/1`.** Both the payload validation and the root comparison existed elsewhere in the tree — real, and tested — and neither was reachable from the engine's entry point. A grep for `eth_engine` against `eth_block`, `eth_mpt` and `eth_tx` returned nothing, which is what established it rather than an assumption

## Phase 2: Full State Trie — Replace Bounded Snap Store (12 tasks)
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
- [x] **Block builder** — constructs execution payloads from the transaction pool through `eth_block:new/3` (not through a second header assembly of its own):
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
- [x] **Execution payload building** — integrated with the consensus client's `engine_getPayload` flow. `forkchoiceUpdated` returns a `payloadId` from a `payloadAttributes`, and `getPayloadV1`/`V2`/`V3` return the block it names. **Not production-usable as a proposer**: a built block's state root will not match the network's while the per-fork gas table is unwired (Phase 5), and a build is refused rather than guessed when the chain does not hold the head
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

## Phase 5: Protocol Compliance (13 tasks)
- [ ] **Per-fork exact gas schedule** — *the pricing half is done; what remains is the conformance measurement, not the schedule.* This item is two questions and only the first has been answered.
  - **Availability: done.** An instruction the executing fork does not have is an
    exceptional halt that consumes the frame's whole allowance, and the interpreter
    now says so. Before this, every clause in `eth_evm:do_op/3` was unconditional, so
    PUSH0 executed in a Paris block, TSTORE executed anywhere before Cancun, and each
    pushed a value and returned successfully — a post-state no other client can
    reproduce, produced without one error and recorded as a result. `eth_fork_schedule:
    opcode_exists/2` is the new predicate; `eth_evm:run/5` requires a `fork` key in the
    Env and every Env builder sets it.
  - **Price: done, Berlin and later.** `eth_fork_schedule` is the execution path's only
    source of prices and `eth_evm:base_cost/1` -- a second, fork-free copy of the
    schedule -- is deleted. The sub-points below record what that took, and what
    comparing the two tables turned up on the way.
  - **The refund cap was Berlin's divisor with London's refund amounts.** EIP-3529 (London)
    sets `MAX_REFUND_QUOTIENT` to 5, so a transaction may refund `gas_used // 5`; before it
    EIP-2200 (Berlin) allowed `gas_used // 2`. The interpreter used `GasUsed div 2` while
    applying EIP-3529's 4800 clear refund, so cap and refund came from different forks. Not
    a rounding difference: a frame that refunds the maximum came back with 40% more gas than
    London allows, which is the difference between a frame that ends with gas left and one
    that runs out. Now `eth_fork_schedule:refund_cap/2`.
  - **EIP-6780 (Cancun) was applied at every fork.** SELFDESTRUCT moves the balance always
    and deletes code and storage only for an account created in the same transaction; before
    Cancun it deleted them unconditionally. So a pre-Cancun block kept code and storage the
    chain removes. Named as a question (`selfdestruct_deletes/1`) rather than a price because
    the cost is 5000 at every fork and only *what it destroys* changes.
  - **EIP-3860's init-code term was charged at every fork**, in the CREATE and CREATE2
    opcodes *and* in a creation transaction's intrinsic gas, so a pre-Shanghai creation
    carried 2 gas per word of init code it does not owe — enough to refuse a transaction
    minted exactly at the pre-Shanghai floor. CREATE2's hashing term is Constantinople's and
    was deliberately left ungated. The term is now `initcode_word_cost/1`, exported so the
    opcode and the intrinsic charge cannot disagree: exactly one of them ever applies to a
    creation transaction, because `eth_block:execute_transactions/5` runs its `data` straight
    through the EVM without reaching the CREATE opcode.
  - **The fork did not reach `eth_tx` at all.** The validator priced a transaction's intrinsic
    gas through `eth_tx:intrinsic_gas/1`, which had no fork to consult, so the EIP-3860 term
    was fixed at 2. It now takes one — `intrinsic_gas/2` — supplied by `eth_block:
    validation_ctx/4` from the block's own fork. The one-argument form remains for admission,
    where no block exists, and falls back to the operator's `ETH_FORK` pin: a documented
    weakening, not a resolution.
  - **Two of those wirings were untested, and the injections said so rather than the code.**
    Hardcoding the fork inside `eth_tx:validate/2` left all 139 tests green, and separately
    dropping the block's fork from `eth_block:validation_ctx/4` did the same — the table was
    pinned and the wiring was not. The second needed a different observable again: the
    validator's copy of the floor decides acceptance, and `run_transaction/5`'s second copy
    only sizes the EVM frame, so a frame two gas short still runs. `gasUsed` is a receipt
    field, so the observable is the **receipts root** — two blocks differing only in timestamp,
    each executing the same transaction at a gas limit both forks accept, must produce
    different roots.
  - **A live Cancun-era SSTORE bug, found while doing the above — and a second defect
    inside the fix.** A no-op write — storing a slot's existing value back to itself — was
    charged **2900 with a 100 refund**, netting 2800. EIP-2200 clause (1) says a no-op costs
    `SLOAD_GAS` and nothing else: 800 at Berlin, and 100 from EIP-2929. So the interpreter
    overcharged **2700 gas net on every no-op write at every fork, London included**. The
    `20000` (create) / `2900` (reset) / `4800` (clear refund) cases beside it were correct,
    which is why this sat unnoticed next to a schedule that had just been called exact.
    It was not fixable as a table edit, because the correct rule is EIP-2200's *net*
    metering, which needs the value each slot held **at the start of the transaction**. The
    EVM tracked no such thing, and the transient map cannot hold it: that map is
    transaction-scoped but is discarded on a child revert, whereas the original value must
    survive one. Substituting the current value for the original would have invented a rule
    no fork specifies, which is the thing this repository has to avoid.
    - **Fixed** by `eth_fork_schedule:sstore_cost/4` plus a second map in the interpreter,
      `#ctx.originals`, keyed on `(address, slot)` and recorded on the first write to that
      slot. `DELEGATECALL` is what makes it observable across a frame boundary: a CALL frame
      writes its own account's storage and can never touch a slot the parent goes on to
      write, so a test built on CALL proves nothing about the map.
    - **The second defect:** the old three-case expression was over the slot's *current*
      value, so it priced a **dirty** write — the case EIP-2200 exists to price — as a
      clean one, and there was nowhere in it to put the distinction.
    - **The first draft of the fix was wrong in a way worth recording.** It reused the
      existing `mark/2` helper, which writes the **transient** set, because a transient write
      is a flag. An original value is a word, so it went into the wrong map: every SSTORE
      was priced as a first write, the dirty write came back out at 2900, and a non-`true`
      value sat in a map every other reader assumes holds only booleans. Caught by a test
      asserting a second write to a dirty slot costs 100.
    - **And a third, in the table:** EIP-2200's arm (2.2.2) is guarded on
      `original == new`. Dropping that guard is silent — the frame still succeeds and still
      returns a plausible amount of gas, just 2800 short on the refund. The first
      `reset_adjustment/2` had a clause returning 0 for any non-zero `new`, which consumed
      every case the arm was written for. The per-arm table tests caught it.
    - **Named, not fixed: pre-Berlin SSTORE.** There are *three* pre-Berlin schedules — the
      flat rule, EIP-1283's net metering at Constantinople, and Petersburg reverting it — and
      EIP-1283 is a different schedule, not a restatement of the flat one (its title is "Net
      gas metering for SSTORE without dirty maps"). Only EIP-2200's text is implemented, so
      pre-Berlin is **refused** (`sstore_supported/1`, reported as
      `{unsupported, {sstore, Fork}}`, which `eth_call` answers with an upstream fallback)
      rather than priced with a figure right for two of the three spans and wrong for the
      third. Unreachable for block execution: this node syncs Sepolia.
  - Fork *selection* is done and driven by real network activation points, including the Merge's total-difficulty activation (`current_fork/4`; see EIP-3675 below).
  - **The fork-parameterized table was dead code, and it was also wrong.** `eth_fork_schedule:gas_cost/3,4` (over `base_gas_cost/3` and `dynamic_gas_cost/4`) took a fork atom, was exported, and had its own unit tests — and nothing in the execution path called it, because the EVM charged `eth_evm:base_cost/1`, which took no fork. So the fork table passing its tests proved nothing about execution.
    - **It is *still* not called from `src/`, deliberately.** The interpreter now charges `constant_cost/2` before the opcode runs and the access term afterwards, because warmth is not knowable before then; `gas_cost/3,4` is the *aggregate* of those two, and an aggregate is the wrong shape for an interpreter that charges at two different moments with two different sets of facts. What is wired in is the table's components, and `gas_cost/3,4` remains the query API that answers "what does this opcode cost at this fork" in one figure — used by its own tests. Anyone reading this as "the table is still disconnected" should check what calls it: nothing in `src/` calls the aggregate, and that is the design.
  - Checking what that dead table actually said, rather than assuming it was a better version of the live one, found it wrong for **19 of the 256 opcodes** (measured by evaluating both tables across the whole range, cold and warm) while its tests stayed green. With a non-zero length argument it is 21, the two extra being `CREATE` and `CREATE2`, which had no init-code term at all. `SELFBALANCE` was 32000 (it shared a clause with `CREATE`/`CREATE2`, the other two opcodes that read the caller's account); `RETURNDATASIZE` was 2600 (routed through `access_cost/3`); `TLOAD`, `TSTORE`, `MCOPY` and `PUSH0` were **0** (no clause at all, so they fell to a catch-all that prices an unassigned opcode at 0); `SLOAD` was 2; `JUMP`/`JUMPI` were 2; `MLOAD`/`MSTORE`/`MSTORE8` were 2; `SSTORE` was 2 rather than 0; `CALLDATASIZE`/`CODESIZE`/`GASPRICE` were 3; `JUMPDEST` was 2; `INVALID` was 5000. The per-word terms were transposed: `RETURNDATASIZE` carried the 3-per-word copy cost and `RETURNDATACOPY` carried none, so reading the size of a return buffer was billed per byte of it and copying it was free. `CREATE`/`CREATE2` also had no EIP-3860 init-code term, and `CREATE2` no hashing term, so deploying a large contract cost nothing for the code about to run.
  - The tests missed all of it because they sampled nine opcodes the table already had right (`ADD`, `MUL`, `SUB`, `DIV`, `MOD`, `ADDM`, `EXP`, `KECCAK256`, `CREATE`) and none it had wrong. So the earlier claim that wiring the table up "is the start of this task, not the end" was too generous: wiring it up as it stood would have made execution worse. The table is now corrected and pinned by a **whole-table** assertion — the priced set exactly, plus every value — so a missing clause shows up as a missing entry rather than as a silent zero. That test is what would have caught all nineteen.
  - Comparing the two tables also found a **live** bug the fork table did not have. `eth_evm:base_cost/1` has no clause for `CALL`, `CALLCODE` or `STATICCALL`, so all three fell to its `base_cost(_) -> 3` catch-all and were charged 3 gas more than EIP-2929 specifies; `DELEGATECALL`, the one member that *was* listed, was correct. Three gas changes no execution outcome, so no test failed and no contract behaved differently — but `gasUsed` is a receipt field, the receipts root is in the block header, and the header is hashed. Fixed, with the whole family pinned at 2600 cold and 100 warm.
  - **The wiring was not a substitution, and the two tables were not interchangeable.** They agreed on the *total* for every opcode but not on how it was composed: `eth_evm:base_cost/1` priced a warm access at 100 and its handler added the cold surcharge separately (2500 for an account, 2000 for a storage slot), while `eth_fork_schedule:access_cost/3` returned the **total**, 2600 or 2100, in one figure. Substituting the fork table for the EVM's base would have charged a cold `BALANCE` 5100 instead of 2600, a cold `SLOAD` 4100 instead of 2100, and a cold `CALL` 5200 instead of 2600. The resolution was one owner: the machine loop charges `constant_cost/2`, which is **zero** for the access-sensitive opcodes because warmth is not knowable before the handler looks, and each handler asks for its whole price supplying only the facts. `base_cost/1` is deleted.
  - **Measuring the two tables against each other, rather than reading either, found two more live bugs.**
    - **`ADDRESS` cost 3, not 2.** It had no clause in `base_cost/1` and fell to the `base_cost(_) -> 3` catch-all -- the same trap that had once mispriced three of the four `CALL` opcodes, which is what "a trap that has now fired twice" in Phase 5 refers to. One gas on every `ADDRESS` in every block, and `gasUsed` is a receipt field. The fork table has 2, so deleting the copy fixed it.
    - **EIP-161's two terms were gated on Berlin.** The 9000 for a value transfer and the 25000 for a new account are Spurious Dragon's, two forks earlier, so a Spurious-Dragon-through-Istanbul `CALL` carrying value paid neither while still being charged the access cost. The gate had never been exercised, because nothing called that function before this change.
  - **EIP-150's pre-Berlin figures existed only in the table and nowhere in execution.** A Frontier `BALANCE` cost 2600, because the interpreter had no path to the pre-Berlin price at all: 400 for `BALANCE` and `EXTCODEHASH`, 700 for `EXTCODESIZE`/`EXTCODECOPY`/the `CALL` family, 200 for `SLOAD`. They are applied now, from one table keyed by opcode rather than taking it as an argument -- the figures differ by opcode and an argument invites the caller to pass the wrong one for its own opcode. `SLOAD` had been a separate function differing in two numbers (200 and 2100 against 400/700 and 2600), which is a second place for the two to drift.
  - What is still missing is the part a price table cannot express at all: **EIP-150's 63/64 gas-retention rule and the 2300 stipend** are applied at every fork. The EIP states the rule it introduced, not the one it replaced, and no client consulted still supports a pre-Whistle block — so the pre-EIP-150 behaviour would have to be invented, and it is not. (An earlier version of this row also claimed `eth_evm` had no EIP-150 pre-Berlin access costs at all. That was fixed in the pass that made the table the only owner of every price — a Frontier `BALANCE` is 400 and a Frontier `SLOAD` 200 — and the row was left behind.)
  - The table is a per-fork schedule at every fork the node's chain has reached, SSTORE included. Before Berlin the `SSTORE` is *absent* rather than wrong, on purpose: see the pre-Berlin note above.
  - `fork_rank/1` used to collapse Frontier through Petersburg into a single rank 0.
    That was invisible while the only gates were Berlin, London, Shanghai and Cancun,
    and it made the availability question above inexpressible: with `byzantium` and
    `constantinople` both at 0, `at_least(frontier, byzantium)` was *true*, so nothing
    could refuse an instruction a fork did not have. Every fork now has its own rank,
    except Muir Glacier, which deliberately shares Istanbul's — it delays the
    difficulty bomb and changes no execution rule, and giving it its own rank made
    `highest_ranked/1` report `muir_glacier` for every mainnet block from 12,244,000 on.
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
  - The two terms do not double-charge, and that is structural rather than lucky: `eth_tx:initcode_gas/3` prices the *transaction's* `data`, and a contract-creation transaction runs that `data` straight through `eth_evm:run/5` in `eth_block:execute_transactions/5` without ever entering `do_create/3`. The opcode's word cost therefore only ever applies to a nested create
  - The Shanghai condition on the init-code term is now applied, in the opcode and in `eth_tx` alike (see the per-fork item above). CREATE2's hashing term is Constantinople's and stays ungated at every fork
  - **Fixed:** a no-op SSTORE was charged 2900 with a 100 refund where EIP-2200 clause (1) says `SLOAD_GAS` and nothing else — 800 at Berlin, 100 from EIP-2929. 2700 gas net, on every no-op write, at London too. It needed the transaction-start value of the slot, which the EVM did not track; see the per-fork item for the map that now holds it and for the pre-Berlin boundary that is still refused rather than priced
  - Run Foundry/vmtests to verify opcode correctness
  - Run generalStateTests to verify state transitions
  - Fix any divergences found

## Phase 6: JSON-RPC API Completion (3 tasks)
- **Out of specification, and not tracked here.** EIP-1474 covers the `eth_*`, `net_*`,
  `web3_*` and `rpc_*` namespaces. The `debug_*`, `trace_*`, `admin_*`, `personal_*` and
  `miner_*` namespaces are geth- or OpenEthereum-specific, are in no EIP, and no
  consensus layer calls them, so they are **not implemented and not tracked**. Removed from
  this list rather than left open with a reason: a box that cannot be closed is not a task,
  and the policy line is a better record than five of them. The count in this heading is
  tasks, and the policy line is not one of them: the 7 was these five out-of-spec
  namespaces plus the two that remained.
  - The one substantive argument for `debug_traceTransaction` is developer speed, and it
    was weighed: the corpus and `eth_call` give a sharper signal per unit of effort than a
    `structLog` tracer, and `tools/eth_call_check.escript` and `tools/eth_bench.escript`
    cover the same ground.
- [x] **Eth API completeness** — `eth_*` methods answer in the specification's response shapes. Seven of the eight that a catch-all clause was proxying are now answered from this node's own state, and each says what it is derived from: `eth_accounts` (`[]` — this node owns no accounts, and proxied it returned the *upstream* node's), `eth_getTransactionByHash` and `eth_getTransactionByBlockHashAndIndex` (a stored transaction plus the three positional fields it does not carry), `eth_getBlockReceipts` (stored receipts, distinguishing an empty block from a block whose receipts were never stored — the specification's `4444`), `eth_feeHistory` (from stored headers, refusing rather than inventing a value where the specification is silent), `eth_maxPriorityFeePerGas` (the minimum tip over the transactions this node would include, using the same `tip/2` the block builder selects on), `eth_getProof` (local trie only) and `eth_estimateGas` (a binary search for the least gas that does not run out). 53 tests in `eth_rpc_extra_tests`. Still outstanding:
  - `eth_createAccessList` — **not implemented**, and the blocker is named: `eth_state` and `eth_evm` do not record which accounts or storage slots an execution touched, so the access list cannot be produced at all, and EIP-2930's gas formula cannot be applied to a list that does not exist. Recording them means instrumenting the hot path of the EVM
  - `eth_getTransactionByBlockNumberAndIndex` now shares the same projection and answers the positional fields; noted here because it was the one that was silently wrong for as long as it existed — it returned a stored transaction with no `blockHash`, consistently, because `eth_getBlockByNumber` with `fullTransactions = false` omits exactly those fields for the same reason. Two methods wrong *together* is why no fixture could tell
  - the `net_*`, `web3_*` and `rpc_*` namespaces named above; the out-of-spec ones are
    not tracked and the policy line says so
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
- [x] **The catch-all, and the three methods it was answering** — done, and it was the
  item in this phase that mattered
  - `eth_rpc_handler:dispatch/3` ended in `dispatch(_Method, Params, _State) -> proxy(_Method, Params)`,
    so **the set of questions this node answered was larger than the set it could
    answer**: a client asked this node something and was told the answer by a
    different node, with nothing in the response saying so. The eight `eth_*` methods
    were unexamined for exactly this reason; the rest of the namespace still was.
  - It now **refuses** with `-32601` and a message naming the method. The deliberate,
    documented fallbacks are unaffected and are not in that clause — `eth_getBalance`
    proxied after a local miss, `eth_estimateGas` when the EVM is disabled — because a
    fallback with a reason is different in kind from answering everything.
  - **`eth_chainId`** now answers from `eth_fork_schedule:chain_id/0`, the same source
    the EVM's `CHAINID` opcode reads, so the RPC surface and the opcode cannot drift.
    It was answered by the catch-all, so the number described the operator's
    `UPSTREAM_RPC_URL` rather than the chain this node executes. EIP-695 made it
    mandatory and every client checks it at startup.
  - **The six uncle methods** now answer locally as `0` and `null` (EIP-3675; this
    chain merged at genesis, so every height has none). By hash they answer only for a
    block this node holds and refuse otherwise, because a hash it does not hold may
    name a pre-Merge block that really did carry uncles. A *short* hash is `not held`
    rather than malformed, matching `eth_getBlockByHash/3`, which does not
    width-check either.
  - 8 tests in `eth_rpc_local_answers_tests`, all injection-verified. The proof that
    an answer is local is a **dead upstream**: the client is pointed at a port nothing
    listens on, so a method that still proxies fails to connect. A control test
    asserts that a genuinely-proxying method *does* fail, without which every other
    assertion in the module would be vacuous.
- [ ] **EIP compliance** — the remainder — EIP-1474 (`eth_feeHistory`) is **done**: the shape comes from `src/eth/fee_market.yaml` in `execution-apis`, not from EIP-1559, which specifies the base fee mechanism and never mentions the method. Three things in it are easy to get wrong and all three are load-bearing — `baseFeePerGas` carries one *more* entry than there are blocks (the next block's, derived from the newest returned block), `gasUsedRatio` carries one per block, so the two arrays are deliberately different lengths, and the ratio is a JSON *number* while every other value in the result is a quantity. EIP-2930 (access lists) is half done: EIP-2930 *transactions* are supported, the `eth_createAccessList` RPC is not. EIP-1898 (`eth_chainId`), EIP-712 (typed data signing) and EIP-2718 (typed transactions) are unchanged

## Phase 7: Consensus Integration (7 tasks)
- [ ] **Lighthouse integration** — test with Lighthouse (Rust, Sigma Prime): Engine API, `eth/68`, ForkID, Payload validation
- [ ] **Prysm integration** — test with Prysm (Go, Prysmatic Labs)
- [ ] **Nimbus integration** — test with Nimbus (Nim, Status)
- [ ] **Teku integration** — test with Teku (Java, Consensys)
- [ ] **Lodestar integration** — test with Lodestar (TypeScript, Chainsafe)
- [ ] **Local test setup** — docker-compose with Lighthouse + etherlang on Sepolia
- [ ] **Mainnet readiness** — test on mainnet with a real consensus client

## Phase 8: Testing & Verification (8 tasks)
- [x] **Deterministic test ports** — `eth_test_util:with_port/1`, plus 7 tests in `eth_test_util_tests`. `free_port/0` listens on port 0, reads back the number the OS chose, and closes the socket, so between the close and the caller's own bind the number is unowned and anything else in the VM can take it. `eth_sync_tests_peer` needs **two** binds on one number (UDP discv4 + TCP peer listener — legal, different protocols) drawn from a `free_port/0` call, and a full suite binds dozens of listeners, so the window was being lost. EUnit reported the loss as a **cancelled** test with no failure and no assertion, which reads like the runner gave up and is not that
  - The port has to stay a number — discv4 and the peer listener both advertise it in an enode URL — so the socket cannot be held open across the handover. `with_port/1` retries instead: draw a fresh port, let the caller bind, and on a lost bind draw another, bounded at five attempts so a port that is never free yields `{port_exhausted, …}` rather than a hang. A non-bind failure is re-raised with the caller's own stack, so a real defect cannot be reported as a port collision
  - **The retry was dead when first written.** `gen_tcp:listen/2` and `gen_udp:open/2` do not raise — they return `{error, eaddrinuse}`; `eth_discv4`/`eth_peer`/`eth_rpc_server` turn that into `{stop, eaddrinuse}` from `init/1`, which `gen_server:start_link/3` reports as `{error, eaddrinuse}`; and every caller writes `{ok, _} = Mod:start_link(...)`. What reached the helper's `catch` was `error:{badmatch, {error, eaddrinuse}}`, which a matcher written for a bare `eaddrinuse` does not recognise — so the first collision re-raised and the retry never ran. A "flaky" test that was a dead code path
  - The tests produce the failure from a **real bind on a real occupied port**, not by raising a term that looks like one. An earlier version raised a literal `{badmatch, {error, eaddrinuse}}` and passed against the broken matcher, which proves the point: the shape the matcher is written against and the shape that arrives are the same shape right up until they are not
  - The remaining `free_port/0` callers (`eth_mock_node`, `eth_call_tests`, `eth_rpc_server_tests`, `eth_txpool_tests`, `eth_peer_tests`, `eth_statesync_tests`, `eth_receipt_tests`, `eth_engine_tests`) each make **one** bind and are not converted here. If one of them ever reports `eaddrinuse`, it is the same race
- [ ] **Foundry tests** — `forge test` with `--rpc-url` pointing to etherlang; contract deployment, execution, opcode regression tests
- [ ] **Geth test vectors** — run geth's test suite: block execution, state transition, transaction, VM tests. Partly superseded by the EEST state tests above, which are *generated from* that corpus; its block-level suites are not covered by them
- [x] **Property-based tests** — `eth_prop.erl`, a property harness in plain Erlang and
  eunit with **no dependency added**, and `eth_word_properties_tests.erl`: 40 properties
  over the EVM's 256-bit arithmetic. Green on five seeds (default, 1, 7, 4242, 99991);
  `ETH_PROP_SEED=<n>` re-runs with another. Three properties of the harness itself, each
  because of a way a property test fails *silently*:
  - **The seed is reported on every failure.** A property test that finds a counterexample
    once and cannot reproduce it is not a test, it is a rumour.
  - **A property returns `{false, GotVsWant}`, never a bare `false`.** One of these
    reported a counterexample that, run by hand against the module, *passed* — so either
    the report or the arithmetic was wrong and the message could not say which. A property
    that returns what it got and what it wanted settles it in the failure itself. That is
    what found the defect below.
  - **The generator is biased to boundaries** (0, 1, 2^255, 2^256-1, the powers of two,
    every shift around 0 and 256). **It is recorded as unproven**: an injection removing it
    caught nothing, which is expected — an algebraic identity holds for all inputs or none,
    so uniform words test it completely. It is kept as insurance for a future property
    whose failure region *is* narrow.
  **Every property is an identity, not a restatement.** `addmod/3` is *defined* as
  `(A+B) rem N`, so asserting that would survive replacing the module with a comment; what
  is asserted is that the result is **congruent** to A+B modulo N, is a valid word, and is
  a valid word for every modulus including zero. Nine properties were false as first
  written and **in every case the code was right**; each is kept as a comment because each
  is one somebody will reach for:
  - `lt/gt/eq/iszero` return **1 or 0**, not `true`/`false` — that is the yellow paper's convention and `bool/1` is `bool(true) -> 1; bool(false) -> 0`. So `lt(A,A) =:= false` fails, and `lt(A,B) =:= not gt(B,A)` fails twice over.
  - `eth_word:shl/2` is **`shl(Value, Shift)`** — the reverse of the paper's `SHL(shift, value)`. The interpreter is right (`shift_op/3` pops Amount then Value and calls `Fun(Value, Amount)`), so only the notation traps. A probe written against the paper produced **six** confident failures from this one.
  - `shr(shl(X,S),S) = X` is **false in general** — a left shift destroys everything above bit `255-S'` — and `shl(shr(X,S),S) = X` is false because a right shift discards the low S bits. Each needs its precondition stated, and stating it is what makes the property informative.
  - Transitivity is the **implication** `(A<B ∧ B<C) → A<C`, not the biconditional: `A<C` holds without the antecedent (A=0, B=2, C=1). The biconditional is false for ordinary integers.
  - `lt(A,B) + gt(B,A) = 1` is false — `gt(B,A)` *is* `lt(A,B)`, so the sum is `2*lt(A,B)`. And `lt(A,B) + gt(A,B) = 1` is false when `A =:= B`. Only `lt + gt + eq = 1` survives.
  - `signextend(0, X)` is the identity only when **`X < 128`**, not merely when bit 7 is clear: with `X = 2^200` the correct answer is `0`.
  - `signed/1` and `unsigned/1` are **not** inverses; only `unsigned(signed(X)) = X` holds.
  - `to_bytes/1` is **big**-endian.
  - `addmod(A,B,M) = addmod(A,B,2M)` is false: congruent modulo M is not equal.
  **A consensus-critical macro is a single token, and this is why.**
  `-define(MASK, 16#FFFF…FF)` in `eth_word` is a hex literal on purpose. Rewritten as the
  obvious `(1 bsl 256) - 1`, `X band ?MASK` becomes `(X band (1 bsl 256)) - 1` — `band`
  binds tighter than `-` — which is **`-1`** for every word. Nine of `eth_word`'s functions
  use it that way, and an injection doing exactly that rewrite fails **23 of the 40
  properties**. `shl(1, 0)` answering 0 would read as an off-by-one in the shift.
  This module made the identical mistake in its own `?MASK` and the signextend cross-check
  caught it, reporting `want => -1, got => 22657, as => 22657, mask => 2^256-1` — a "want"
  not derivable from the inputs by any arithmetic, which is what said the *harness* was wrong
  rather than the module. The cross-check is now an independent derivation (low N bits as a
  signed integer via `rem`/`-`, then one mask) rather than a second copy of the module's
  `bor`/`bxor`, which is the tautology the file's own header warns about and which the
  first version of it was.
  **Fuzzing, differential testing and geth vectors are still open**, and the corpus
  (`execution-spec-tests`, 6,786 of 15,660) does more for EVM correctness than any of
  them; this covers the arithmetic the corpus reaches only indirectly.
- [ ] **Fuzz testing** — fuzz the EVM interpreter for edge cases
- [ ] **Differential testing** — run same block through etherlang and geth, compare outputs
- [ ] **Performance benchmarks** — block processing speed, state access latency
- [x] **Conformance tests** — `eest_state_tests.erl` runs the `execution-spec-tests`
  `state_tests` corpus. **Started, and the first measurement is about 2%**
  (78 of 266 committed entries at the first measurement, 250 of 266 now; see "What
  to do next" item 5 for the number, the real defects it found, and the two harness
  bugs that made the figure irreproducible until they were fixed). The
  Ethereum Foundation's own `ethereum/tests` block-level suites and EEST's
  `blockchain_tests` are **not** run, and the fork table's provenance check against
  instruction counts is a weaker claim than running the fixtures

## Phase 9: Infrastructure & Operations (10 tasks)
- [x] **Docker image** — two-stage build (`Dockerfile`: a build stage that compiles and
  releases, a runtime stage that copies the release and runs as a non-root `ethnode`),
  plus `Dockerfile.test`, `docker-compose.yml`, and `docker-build` / `docker-run` /
  `docker-test` / `compose-up` / `compose-down` / `compose-logs` in the `Makefile`.
  **It was on the wrong Erlang.** All three images were `FROM erlang:27` for the whole
  life of the Dockerfile while `mise.toml` pins `erlang = "29.1"` and every test and
  every measurement in this repository ran on OTP 29. So `make docker-test` — the
  container path CI uses — was testing a runtime nothing else here ever ran, and a
  real incompatibility would have surfaced at release time rather than at build time.
  Both are now `erlang:29.1`, identical to the pin, and the runtime stage **asserts**
  `erlang:system_info(otp_release)` matches so the next bump of one without the other
  fails the build instead of passing quietly.
- [ ] **Release process** — automated versioning, changelog generation
- [ ] **Monitoring** — Prometheus metrics, Grafana dashboards
- [ ] **Logging** — structured JSON logging, log rotation
- [x] **Health check** — `GET /health` on the JSON-RPC port. **200** only if every
  component answered, **503** otherwise, with a body naming which one did not. A health
  endpoint that cannot say "no" is a decoration, so the probes are real
  `gen_server:call/3`s with a timeout rather than `is_process_alive/1` checks: a
  `gen_server` that is alive and wedged — blocked in a DETS write, or in a trie
  operation — passes a liveness probe and cannot serve a single request, and that is the
  state an orchestrator most needs to hear about. Reports the configuration verdict, the
  chain head (number, hash, highest, size), the trie account count, whether sync is
  running, and the pool's size. **Deliberately not said:**
  - Not "in sync with the network". `eth_sync:status/1` is reported as the fact it is — `syncing: true` with the three block numbers `eth_syncing` already returns — and is not folded into the verdict. "Synced" is not a health property of a node that does not author blocks.
  - Not `eth_state:chain_id/0`, which fetches over RPC on first use. A health endpoint that performs a lazy network fetch turns an upstream outage into a restart loop, which is a self-inflicted outage.
  - No `stateRoot`, or anything else this node would have to recompute. See AGENTS.md §4.1 — a health endpoint is not a place to add a way to get a bare root, and a test asserting the report contains no such field is cheaper than a review comment.
  - It **bypasses `RPC_API_KEY` and the rate limiter**, because an orchestrator's probe cannot be expected to carry a bearer token and a probe that 401s is a probe that has been ignored. What it discloses is liveness, the head, the pool's size and whether sync is running — none of which is an oracle. A public bind with no API key is already a startup warning; this is a second reason that combination deserves a thought.
  It is on the **JSON-RPC port, not the Engine API port** — adding it there would bypass the JWT check, which is the one thing that port is for. 8 tests, five of them injections that all still compile. Three defects the tests caught, all invisible to any test that called `report/1` instead of making a real HTTP request:
  - `status_code/1` read `maps:get(status, ...)` against a `<<"status">>` key — an atom against a binary — so the **503 path** raised `{badkey, status}` and cowboy answered **500**. The endpoint was correct and completely broken at the same time, and only when the node was *unhealthy*, which is the path that matters.
  - `init/2` returned `cowboy_req:reply/4`'s value instead of `{ok, Req, State}`, so `cowboy_handler:execute/2` raised `{try_clause, Req}` and no response was sent at all. A cowboy handler's `init/2` must **return** the reply's `Req`; the reply is not the return value.
  - The trie probe was the one component with no seam — it hardcoded the `eth_mpt` singleton — so the all-healthy path could not be tested without opening a DETS file under the un-scoped `DATA_DIR`, the AGENTS.md §10a trap. Its name now comes from the handler options like the other three.
- [ ] **Graceful shutdown** — clean state dump, peer disconnection
- [x] **Configuration validation** — `eth_config_settings:validate/0` checks all 32
  environment variables against a per-kind parser and `etherlang_app:start/2` **refuses
  to start** on any of them, naming the variable, the value as written, and why. The
  accessors are unchanged and still fall back, on purpose: a test that sets a nonsense
  variable should not take the suite down, and the fallback is what a library function
  owes its caller. The gate belongs where "start the node" is a decision.
  **Five real defects, all silent, none of them a crash:**
  - **`int_env/3` answered the *default* for a value it could not parse.** `CHAIN_RETENTION=abc` gave a node retaining 2048 blocks, and nothing anywhere said the setting had been ignored. The same was true of every one of the 32.
  - **`listen_ip/0` ranged over the **first** octet only.** `1.999.1.1` passed it and produced the tuple `{1,999,1,1}`, which `inet:parse_address/1` answers `einval` for — so the malformed bind reached `cowboy` and failed there, as a *listener* error, which says nothing about a setting. `parse_ip/1` used `list_to_integer/1` and checked nothing at all. Both halves are gone: there is now one implementation, `eth_config_settings:ip4/1`, and `eth_config` holds no second copy of the decision to disagree with it.
  - **`RPC_LISTEN_IP=999.1.1.1` silently became loopback.** An operator who asked to expose the JSON-RPC and mistyped the address got an unreachable node, which is the safe direction by luck rather than by design. The fallback is still there — the accessor is a lookup, not a gate — and `validate/0` now reports it so the node refuses to start.
  - **`ETH_NETWORK` and `ETH_FORK` fell back to a default for an unrecognised name**, and neither fallback was the same kind of thing. The network fell back to `sepolia` behind a `logger:warning` emitted from *inside* `configured_network/0`, a function with thirteen call sites, so it was a repeating log line rather than a report. The fork fell back to `cancun` **with nothing at all**, out of a table of twenty-four names, so `ETH_FORK=shangai` produced a node running Shanghai rules that had never said so. The names stay in `eth_fork_schedule`, which is the only list of them; `network_of/1` and `fork_of/1` are now the one place a name becomes an atom, and `validate/0` refuses.
  - **The module header claimed an application-environment source that never existed.** `str_env/3` is `str_env(Env, _Key, Default)` with the key argument underscored and unused, so the "then from the application environment" in the header was a fiction and a reader checking `sys.config` would have found nothing.
  Also checked and left alone: the `ETH_FORK` default (`cancun`) and the `ETH_NETWORK`
  default (`sepolia`) are two hand-picked answers that happen to agree today. Nothing
  derives one from the other; that is recorded, not fixed, because deriving it would
  mean this node choosing which fork a network is on.
  Four settings are **warnings** rather than refusals, because the node is correct in
  each and the operator may have meant it: a bind on `0.0.0.0` without an API key,
  discv4 and RLPx both enabled on their shared default port 30303, and a
  `CHAIN_RETENTION` below `BODY_WINDOW`. Refusing to boot an operator out of a
  configuration they chose on purpose is a worse answer than saying so once.
  **The accessors' own header still documents the old behaviour nowhere**, so a reader
  of `eth_config` is told the defaults fall back and that `validate/0` is the gate.
- [ ] **Upgrade path** — zero-downtime upgrade support
- [ ] **Documentation** — complete deployment guide, architecture guide
- [ ] **Security audit** — third-party security review of execution engine
