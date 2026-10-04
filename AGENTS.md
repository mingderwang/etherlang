# AGENTS.md

Working notes for anyone (human or agent) changing this repository. It records
the build, the architecture, and — mostly — the rules this project has had to
learn the hard way. Those rules exist because each of them was violated at least
once and the violation shipped.

If a rule here conflicts with what the code does, the code is wrong. Fix the
code or fix this file in the same change; never leave them disagreeing.

---

## 1. What this project is

`etherlang` is an Ethereum execution-layer node in pure Erlang/OTP. It syncs the
canonical chain over devp2p/RLPx (RPC fallback), heals state via snap, runs a
pending transaction pool, serves JSON-RPC, and is being turned into a
Lighthouse-compatible execution client with a working Engine API.

It is **not** yet a production execution client. It does not author blocks, it
has no consensus layer, and its per-fork gas schedule is not wired in. `README.md`
§"Current Status" and `TASKS.md` are the authority on what is and is not done.

**There is no design document here, and that is deliberate.** A prose description
of a system model is a second statement of the rules, and a second statement drifts:
the one this repository carried said "724 eunit tests" when the suite was at 932 and
"58 test modules" when there were 59, and it had to be hand-patched on every commit
that changed a number -- which is a maintenance tax with no correctness benefit and a
guaranteed staleness cost. It was removed.

**The authority is the specification, and it is four documents:**
`ethereum/EIPs` for the per-fork rules, `ethereum/execution-specs` (EELS) for the
state transition those rules add up to, `ethereum/execution-apis` for the Engine
and JSON-RPC surface, and the networking specs (discv4, devp2p/RLPx) for the wire.
Derive a rule from one of those, quote the clause, and pin it with a test.

### Read these before claiming anything works

| File | What it is |
|------|------------|
| `README.md` | Feature status, honesty notes, config, layout. |
| `TASKS.md` | The 82-task / 9-phase list. Every unchecked box is a real gap. |
| `RELEASE-GATE.md` | **What a release must show before it can be cut.** Three states per cell — `GREEN`, `RED`, `ABSENT` — and `ABSENT` is not `GREEN`. Holds the known-deviations list. Read it before claiming the node is in a releasable state; today it is not, and the file says so. |
| `ethereum/EIPs` | **The authority for every rule in `src/`.** Derive from the EIP text, quote the clause in a comment, pin it with a test. |
| `ethereum/execution-specs` (EELS) | The state transition, as an implementation. **A second reading of the same EIPs**, and it finds what the EIP text alone does not: EIP-7702's step-4 `accessed_addresses` is one line of its `validate_authorization` and no fixture in this repository exercises it. |
| `ethereum/execution-apis` | The Engine API and JSON-RPC surface this node serves. |
| `ethereum/consensus-specs`, the networking specs | devp2p/RLPx, discv4, the beacon-node boundary. |

**`RELEASE-GATE.md` is suspended, by the operator's instruction of 2026-10-04: do not use
it.** Not as an authority, not as a source to quote, not as a file to edit. It is left in
the tree unchanged and its cells are stale.

**Where the decisions that would have gone there went instead.** `TASKS.md` §"Three things
settled" — including the one that mattered, **p2p is on the critical path**, which makes the
peer-path findings release blockers and makes Phase 7 (0 of 7 done) load-bearing. If you are
looking for the release criteria and they are not in `RELEASE-GATE.md`, they are in
`TASKS.md`'s "What to do next, in order", which §12 already names as authoritative.

**Why it is worth saying where the inversion is.** The one place the two files disagree
about a finding's status, `TASKS.md` is the one that was updated. So a reader who consults
the suspended file for a current answer will get a stale one *and* have no way to tell.

**None of those four directories is in this repository** (see `RELEASE-GATE.md`
D-18), so the paths above do not resolve and must be fetched. The canonical
locations, which are what every derivation here was checked against on
2026-10-03:

| What | Where |
|------|-------|
| EIPs | `https://eips.ethereum.org/EIPS/eip-<number>` -- the rendered text, one document per EIP |
| execution-apis (Engine API) | `https://raw.githubusercontent.com/ethereum/execution-apis/main/src/engine/cancun.md` and the per-fork files beside it |
| execution-specs (EELS) | `https://github.com/ethereum/execution-specs` |
| networking specs | `https://github.com/ethereum/devp2p-specs`, `.../discv5` |

The Engine API one is worth singling out: `src/engine/cancun.md` carries the
complete `ExecutionPayloadV3` field list, and it settled a recorded finding
(D-2) that had been wrong for the wrong reason -- see that entry. **A payload
schema is a list you check, not a list you remember**, and this repository got one
of its fields wrong by memory for long enough to record a deviation about it.

Documentation in this repo is deliberately adversarial: it names specific gaps
rather than softening them. **Keep it that way.** A README that says "partial"
where the code says "broken" is a bug, not modesty.

---

## 2. Build and test

```bash
/Users/mingderwang/.bin/rebar3 compile          # must be warning-free
/Users/mingderwang/.bin/rebar3 eunit            # the whole suite (~4 min)

# Much faster iteration on one module:
/Users/mingderwang/.bin/rebar3 eunit --module=eth_engine_tests,eth_block_payload_tests
```

`make docker-test` runs the same suite in a container. `rebar.config` sets
`warnings_as_errors`, so **any warning fails the build** — including "function
X is unused", which is how a refactor that orphans a helper announces itself.

Erlang/OTP 29 (pinned in `mise.toml`, which says `erlang = "29.1"`). The
Docker images are pinned to the same `erlang:29.1`, and the runtime stage asserts
`erlang:system_info(otp_release)` rather than trusting the tag: the images were on
`erlang:27` for the whole life of the Dockerfile, so `make docker-test` was
exercising a runtime nothing else in this repository ran. No CT suites exist; CI's
`rebar3 do eunit, ct` runs eunit only.

### rebar3 compiles by mtime. This will lie to you.

The single most expensive debugging session in this repo was a "flaky" test that
was not flaky: `eth_engine_handler.beam` and `eth_engine.beam` in `_build/test`
were **stale**, compiled before the sources were edited. rebar3 compared mtimes,
decided nothing had changed, and the suite faithfully ran the old code — so a
handful of tests passed or failed according to code that no longer existed.

**Symptom:** a result that does not follow from the source you are reading, or a
test that fails alone and passes in the full suite (or the reverse) with no
plausible mechanism.

**Fix:** `find apps/etherlang/src apps/etherlang/test -name '*.erl' -exec touch {} +`
and re-run. Do this whenever you have restored a file from a pristine copy, after
an injection, and whenever a result is inexplicable. When a test's outcome
depends on execution order, suspect the build before you suspect the code.

---

## 3. Architecture

49 modules in `apps/etherlang/src` (14,437 lines of code), 65 test modules in
`apps/etherlang/test` (14,328), and 1020 eunit tests. **These counts drift and this
one had drifted** -- it said 47 and 44 for several commits after it stopped being
true, which is the same defect as a stale conformance figure: a number in the
architecture section that a reader will use as a measure of size and that no longer
describes the tree. **Run `make counts` and paste its output; do not edit these by
hand.** The derivation is `tools/counts.escript`, and it is a script because the
counting was never the problem: "lines of code" was undefined and the *procedure*
was prose, so two derivations that both looked reasonable gave 13,527 and 13,584,
and a number nobody can reproduce is not a measurement. "Code" there means
non-blank and non-comment lines, and nothing else is subtracted -- attribute
lines, `-include`s and `-export`s are code. Excluding them was tried and yields a
different number that is no more defensible.

Every stateful module is a `gen_server` registered under its own module name;
the tree is in `etherlang_sup`. The rest are pure or stateless (`eth_rlp`,
`eth_keccak`, `eth_hex`, `eth_word`, `eth_fork_schedule`, `eth_evm`, …) — keep
new logic out of the `gen_server`s where it can be pure, because that is what
makes it testable without holding state.

### The singletons that matter

| Process | Role |
|---------|------|
| `eth_mpt` | The one stateful trie. A `gen_server` holding accounts/storage/code. `eth_trie` is the pure node/root/proof algorithm underneath it and has no state of its own. |
| `eth_state` | Delegate. Reads and writes through `base_source/0`. |
| `eth_chain` | Canonical chain store (DETS): blocks, receipts, tx index, head, reorg. |
| `eth_sync` | Peer-first sync, gap fill, follow, finalized floor. |
| `eth_engine` | Engine API server. Started by the supervisor, before its listener. |
| `eth_rpc_server` | Cowboy on `:8545` (JSON-RPC) and a second listener on `:8551` (Engine API). |
| `eth_txpool` | Pending/queued nonce tiers, eviction, gossip. |
| `eth_fork_schedule` | Stateless. Fork selection, gas costs, beacon/history constants. |

### `base_source`: the trap that will cost you an hour

`eth_state:base_source/0` is process-wide (`application:get_env/2`) and has two
values:

- `upstream` — read-only, lazily fetched over RPC. The default.
- `mpt` — the local trie. **The only source a commitment may be taken from.**

A *state term* may carry its own base via `eth_state:with_base_source/2`, which adds
a third value:

- `empty` — nothing else exists. An account or slot the caller did not put there
  reads as zero. Its only caller is the conformance runner, and it is named here so
  that is not a surprise: a state built from a fixture is complete, and answering
  for a key it omits from the shared trie is silently wrong rather than loudly
  absent. The process-wide value is still the default, so nothing relying on it
  moves — this is an addition, not a replacement.

Only a write under `mpt` is a real commitment. `eth_block:finalize/1` switches
to `mpt`, executes, and restores it in a `finally`. **If you add a path that
computes or reports a root, it must set `mpt` first** — a root computed over the
upstream view, or over an empty trie, is not a result, it is a fabrication.

Tests that touch this global **must** restore it, or they will silently redirect
another module's reads for the rest of the run. `eth_finalize_tests:with_ctx/1`
is the reference pattern.

### Blocks

`eth_block:new/2,3` builds a `#block{}` (record in
`apps/etherlang/include/eth_block.hrl`). `eth_block:from_payload/1` decodes an
Engine API `ExecutionPayloadV1` into one; `eth_block:payload_block_hash/1`
recomputes the header hash from the payload's own fields.

`eth_block:finalize/1` is the commitment point. It returns
`{ok, Block, Verification}` where every commitment in `Verification` is
`{verified, Root} | {unverified, Reason}`. **There is no way to get a bare root
out of it, on purpose.**

### Transactions

One validator, used by the peer path, the pool, and the engine:
`eth_tx:validate/1,2`, `eth_tx:intrinsic_gas/1,3`, `eth_tx:tx_type/1`. Do not
write a second one. A block containing an invalid transaction is refused whole —
nothing is committed.

### Fork awareness

`eth_fork_schedule:current_fork/3,4` selects the fork, and it now reaches the
interpreter: `eth_evm:run/5` **requires** a `fork` key in the Env and refuses an
instruction the fork does not have (`eth_fork_schedule:opcode_exists/2`). Do not
give that key a default. A default is a fork this node chose rather than one the
chain chose, and the only symptom is a plausible answer.

The gas *table* is now the execution path's only source of prices.
`eth_fork_schedule:constant_cost/2` is what the machine loop charges, and the
handlers whose price depends on the frame ask for the whole figure via
`access_cost/3` or `call_cost/3`. `eth_evm:base_cost/1` — a second, fork-free copy
of the schedule — **is deleted**; do not add it back. Two copies of a consensus
constant is one too many, and they had drifted in how they decomposed four groups
rather than in their values, which is why neither could be substituted for the
other. The rules now fork-selected are every opcode's constant price, EIP-150's
pre-Berlin access costs, EIP-2929's warm/cold split, EIP-161's 9000/25000 (which
are Spurious Dragon's, not Berlin's), the refund cap, EIP-6780, EIP-3860,
`eth_tx`'s intrinsic floor, and SSTORE's net metering.

**SSTORE is EIP-2200's net metering, Berlin and later.** It is the one price
that cannot be derived from the frame: the cost depends on the value the slot held
at the *start of the transaction*, not the value it holds now. The interpreter
keeps those in `#ctx.originals`, keyed on `(address, slot)`, recorded on the first
write to that slot — the read that supplies it *is* the transaction-start value,
but only because nothing has written the slot yet, which is why the record has to
precede the write.

Three things about that arrangement are easy to get wrong, and each was:

- **It is not the transient map.** `mark/2` writes the transient set, because a
  transient write is a flag; an original value is a word. Using `mark/2` put every
  original in the wrong map, so every SSTORE was priced as a first write and a
  non-`true` value sat in a map every other reader assumes holds booleans.
- **A CALL frame cannot write a slot its parent goes on to write** — it writes its
  own account's storage. `DELEGATECALL` can, and it is the only way to observe the
  map crossing a frame boundary. A test built on CALL proves nothing.
- **Pre-Berlin is refused, not priced** (`sstore_supported/1` →
  `{unsupported, {sstore, Fork}}`, which `eth_call` answers with an upstream
  fallback). There are *three* pre-Berlin schedules — the flat rule, EIP-1283's net
  metering at Constantinople, and Petersburg reverting it — and EIP-1283 is not a
  restatement of the flat one. Do not add a pre-Berlin price without reading
  EIP-1283's text; a single figure would be right for two spans and wrong for the
  third, and wrong *only* at Constantinople is never noticed.

---

## 4. Rules

### 4.1 Never commit a root you cannot justify

This is the project's central value. A recomputed value stored under a key named
after a header field is indistinguishable from a confirmed one, and that is
exactly how a wrong receipts root passed unchecked through Phase 5.

- Every commitment is a **verdict**: `{verified, Root} | {unverified, Reason}`.
- An absent context key means the rule is **unchecked**, not passed.
- `{unverified, state_not_local}` is a correct, complete answer when the node
  holds no prestate. Do not paper over it.
- "It should be fine" is not a reason. If you cannot check it, report it unchecked.

### 4.2 Never fabricate a consensus constant

Every constant is either **derived from the live chain and pinned by a test**, or
**documented as a limitation**.

- Derive the value. Then pin it with a test that fails if it changes.
- If the value cannot be derived (the derivation needs data the repo does not
  have), say so in the module comment, the README, *and* TASKS.md. Name the
  specific gap. "Simplified" and "approximate" are not gaps; "not implemented"
  and "not wired in" are.
- Never tune a constant until a test passes. That is fitting the test.

Worked examples of both directions, kept as precedent:

- **Derived:** `?EMPTY_UNCLE_HASH` = `Keccak256(RLP([]))` = `1dcc4de8…`. It was
  previously `?EMPTY_ROOT` (the *empty trie* root, `56e81f…`), which is a real
  constant in this codebase and a completely different thing. Now pinned by a
  test asserting the three real Sepolia block hashes.
- **Not derivable:** `eth_kzg:blob_to_kzg_commitment/1` is **deliberately
  unimplemented** — it needs the `g1_lin` derivation, and the EIP-4844 test
  vector is not in the repo. Do not guess it. Do not "finish" it with an
  approximation.

### 4.3 A test that has never failed has never been tested

After writing a test that should catch something, **inject a defect into the live
path and confirm the test catches it.** A green test that passes against
deliberately broken code proves nothing.

Discipline that makes this reliable:

1. Keep a pristine copy of the target in `/tmp/pristine` before editing.
2. Inject, run `rebar3 eunit --module=<the one module>`, restore in a `finally`.
3. `touch` the file after restoring — see §2.
4. **After a timeout, verify the tree against the pristine copy before trusting
   any result.** A killed injection script has left a dirty tree before, and the
   next run then tested injected code and reported it as the baseline.

Pick an injection that still compiles. An injection that orphans a helper is a
warning, warnings are errors, and the *build* catches it — so it proves nothing
about the test.

### 4.4 Grep before you believe

`grep -rn 'eth_block:to_rlp' apps/etherlang/src` is faster and more reliable than
reasoning about who calls what. The orphaned `eth_block_builder`, the unregistered
`eth_engine`, the uncalled `finalize/1` — all were found by grep, after the
documentation had already claimed they worked.

Ask of any new function: **who calls this?** If the answer is "a test", it is not
wired up, and it must be documented as unwired.

### 4.5 Test names are the specification

EUnit names are sentences stating the invariant:

```erlang
?assertEqual({unverified, state_not_local}, maps:get(state_root, V))
%% "reports state that is not local"
```

If a test name had to be softened to make it pass, the test is wrong.

### 4.6 A comment that explains a bug explains *that* bug

The codebase carries long comments recording what was wrong and why. Keep them.
When you fix a defect, the comment is the only thing stopping the next person
from reintroducing it. Match the existing register: what the code used to do,
what it does now, and what the symptom was — concretely, with the values.

```erlang
%% `head' was additionally typed `{integer(), binary()}' while being stored as
%% `{HeadHash, undefined}' and read out of the *second* position, so the value it
%% compared a payload's parentHash against was always `undefined'.
```

---

## 5. Testing

- **Conformance.** `eest_state_tests.erl` runs the `execution-spec-tests`
  `state_tests` corpus against the state transition, and classifies every entry
  into a vocabulary that keeps "did not decode", "recovered the wrong sender",
  "should have been rejected but was not" and "state differs" apart. Do not
  collapse them: one `fail` bucket would sum four different bugs and hide all
  four, and the totals would look identical. The committed subset lives in
  `test/vectors/eest/` with a `PROVENANCE.md`; the full 503 MB run is a developer
  step (`eest_report`).

  **The tally is asserted, and the reason it is asserted is weaker than the one that
  removed it.** It used to drift between runs of the same code, because a storage read
  a fixture's code performs but does not declare falls through `base_source` to the
  local MPT, which is process-wide and shared with the rest of the suite. That was
  measured, not hypothesised -- 6 matches in a fresh VM against 7 under eunit -- and
  `?EXPECTED` was deleted on the strength of it.

  **That drift no longer reproduces.** The pin is back and holds: 255 of 266,
  `state_mismatch` 8, `fork_unreachable` 3, checked three ways (this module alone, the
  full suite, and `eest_report` against the same directory). Seeding everything the
  fixture mentions is the likely cause, but at the time it "removed most of it" with
  no figure saying how much, so the two measurements were never made against each
  other. The honest description is **observed stable, not known stable**, and an
  isolated state base for this runner -- the task in `TASKS.md` -- is what would make
  it the second. The pin is paired with `assert_not_mostly_matching/1`, which fails
  if the runner ever stops comparing, because a pin that has quietly stopped meaning
  anything still passes.

  **A measurement taken against a tree that is already broken is not evidence about
  the pin.** The pin was removed a second time, on a run that measured **236** against
  its 255 -- reproducibly, in every context. The tree producing 236 had an
  uncommitted `sstore_cost/4` change charging `SSTORE_SET_GAS` for a no-op write into
  a slot whose original was zero, which EIP-2200 does not price that way. Reverted,
  and 255 is what three paths produce. Three tests failed alongside the 236 and said
  so; the pin did not. **Establish the baseline before you believe the number**, and
  when a pin disagrees with a run, suspect the tree before suspecting the pin.

- **No network.** Every test runs against `eth_mock_node` (in-process JSON-RPC)
  or a loopback devp2p stack on real sockets. **A unit test must never perform a
  lazy upstream fetch.** If a test needs real chain data it belongs in
  `apps/etherlang/test/vectors/`.
- Real chain data is **committed**, not fetched. `test/vectors/*.json`,
  `eth_payload_fixture.erl` (real Sepolia payloads: Paris 1450507, Shanghai
  3001655, Cancun 6985356), `eth_test_util.erl`.
- **Test dirs are pid-scoped** (`eth_test_util:tmp_dir/0`). `erlang:unique_integer/1`
  restarts from the same base in every fresh VM, so paths derived from it alone
  collide across runs and leak stale DETS state. This caused phantom
  `missing_parent`/reorg failures. If a run goes red,
  `rm -rf /tmp/etherlang_test_*` isolates stale-state contamination before you
  blame the code.
- **EUnit truncates assertion values.** For full diagnostics, write to a file
  from a temporary probe and read it with the shell.
- **Property tests (`eth_prop.erl`).** Fixed seed unless `ETH_PROP_SEED` says otherwise,
  and the seed is reported on every failure -- a counterexample you cannot reproduce is not
  a test, it is a rumour. A property returns `{false, GotVsWant}` rather than a bare
  `false`, so the failure carries its own arithmetic; one that reported a bare `false`
  produced a counterexample that, run by hand, *passed*, and there was no way to tell from
  the message whether the report or the arithmetic was wrong.
- When writing one, assert an **identity**, not a restatement of the implementation.
  `addmod(A,B,N)` is *defined* as `(A+B) rem N`, so asserting that would survive deleting
  the module; what is worth asserting is that the result is **congruent** to A+B modulo N,
  is a valid word, and is a valid word for every modulus including zero. Nine properties in
  `eth_word_properties_tests` were false as first written and the code was right in every
  case, so they are kept as comments. **Treat a property failure as a question about the
  property first** -- that ordering is what found all nine, and assuming the code is wrong
  is what produced six false "the EVM is broken" reports from one probe.
- Fixtures must be **independent** of the code under test. A payload whose
  transactions you re-encoded with this repo's own codec makes the transactions
  root and block hash checks circular. `publicnode`'s `eth_getBlockByNumber`
  returns *decoded* transaction objects, not the wire bytes the Engine API
  specifies — use `eth_getRawTransactionByHash` per transaction.
- Give every fork variant a fixture, including a non-degenerate one. The small
  real Cancun block has `blobGasUsed` = `"0x0"`, so a decoder that passed the
  string through undecoded agreed with a correct one. Hence
  `eth_payload_fixture:blobs/0`.

### Debugging against real data

When a header hash does not match, **rebuild the header RLP in Python** with an
independent Keccak-256 (verify it against the `""` and `"abc"` vectors first),
then diff it byte-for-byte against the Erlang RLP, walking elements by RLP
prefix to find the one with the wrong length. This located a 24-byte nonce (it
was `<<0:192>>` — 192 *bits* where the nonce is 8, and RLP prefixes strings by
length, so every header was 16 bytes too long) in one step.

### Authoring traps, all of which cost time

- A map literal's field shadowing a function of the same name does not compile:
  `{cancun, cancun()}`.
- `put_in(Foo()[Key], …)` is invalid.
- `<<A/binary>>` where `A` is already a binary.
- A record field with no default is `undefined`, not a placeholder.
- `maps:get(payload, {paris, Map})` raises `badmap` — match the tuple first.

---

## 6. Engine API status mapping

Currently in force. Do not simplify it.

`newPayload` decodes the payload, checks `blockHash`, calls `finalize/1`, and
maps the verdicts:

| Condition | Status |
|-----------|--------|
| A root was **checked** and is wrong | `INVALID` |
| A root is **unchecked** (no prestate held) | `SYNCING` |
| A mismatch outranks an unchecked root | `INVALID` |
| Unknown parent | `SYNCING` |
| Invalid transaction | `INVALID` |
| Other `finalize/1` error | `INVALID` |
| `blockHash` ≠ `Keccak256(RLP(header))` | `INVALID_BLOCK_HASH` |

**Return shape follows the specification's `validationError` rule:** a bare
status binary for `VALID`/`SYNCING`; `{Status, Reason}` only for `INVALID` and
`INVALID_BLOCK_HASH`. Reasons on `SYNCING` are logged, never returned to the
client.

`forkchoiceUpdated` deliberately does **not** compare `parentHash` to the head. A
non-matching parent is a side branch or an unimported block, and the
specification answers `SYNCING` to both — comparing it could only ever produce a
wrong `INVALID`. The comparison survives as a log line in `note_parent/2`.

`status_for_finalize/1` and `status_for_verification/1` are exported and pure so
the mapping is testable without holding the parent state locally.

**A node with no JWT secret refuses the port (503)** rather than serving it open.

---

## 7. Configuration

All runtime configuration is environment variables (`eth_config`). Defaults:
upstream `https://ethereum-sepolia-rpc.publicnode.com`, network `sepolia` via
`ETH_NETWORK`, JSON-RPC `:8545`, Engine API `:8551`.

Frequently touched: `UPSTREAM_RPC_URL`, `ETH_NETWORK`, `ETH_FORK`, `DATA_DIR`,
`RPC_LISTEN_PORT`/`RPC_LISTEN_IP`, `ENGINE_PORT`, `RPC_API_KEY`,
`CHAIN_RETENTION` (2048), `BODY_WINDOW`, `ETH_START_BLOCK`, `DISCV4_ENABLED`,
`RLPX_ENABLED`, `STATE_SYNC_ENABLED`, `EVM_ETH_CALL`, `VERIFY_HEADERS`.

**The OS environment is the only source.** The module header used to say "then from the
application environment", and `str_env/3` is `str_env(Env, _Key, Default)` with the key
argument underscored and unused — the second source never existed.

**All 32 are validated at startup, and a bad one refuses the boot.**
`eth_config_settings:validate/0` checks each against a per-kind parser, and
`etherlang_app:start/2` returns `{error, {invalid_configuration, Problems}}` rather than
starting, naming the variable, the value as written, and why. Before this, an
unparseable value was answered with the **default** and a nonsensical one was answered
**as written**: `CHAIN_RETENTION=abc` retained 2048 blocks silently, and
`CHAIN_RETENTION=-5` retained −5 of them and used it.

Adding a setting means adding it to `settings/0`. The test
`every_variable_eth_config_reads_is_in_the_table_test` in `eth_config_tests` scans the
source for the string literals `eth_config` reads and fails if one is not in the table,
so an unvalidated setting is a test failure rather than a thing nobody notices.
`ETH_NETWORK` and `ETH_FORK` are in the table but their rules are `eth_fork_schedule`'s,
which holds the only list of names.

Do not add a default to `config/sys.config`; it is empty on purpose.

---

## 8. Definition of done for a change

- [ ] `/Users/mingderwang/.bin/rebar3 compile` — zero warnings.
- [ ] `/Users/mingderwang/.bin/rebar3 eunit` — `All NNN tests passed`, run
      **twice** if anything failed once, and the full suite **not** just the
      module you touched.
- [ ] Every new test has been shown to **bite** (inject a defect, watch it fail,
      restore, `touch`).
- [ ] No new constant that is not derived-and-pinned or documented-as-a-gap.
- [ ] No new commitment returned as a bare value.
- [ ] `README.md` and `TASKS.md` updated in the same commit, naming the specific
      gap — not softening it.
- [ ] Anything unwired is *documented* as unwired.

## 9. Commit and tag conventions

- One behavioural change per commit; the message says what the node now does, in
  the imperative, and what was wrong before if the commit fixes a defect.
  Recent examples: *"Make block finalization honest about the state root"*,
  *"Fix withdrawalsRoot: it is a trie root, not an SSZ hash"*.
- **Attribute a figure to a commit, not to a version tag.** `git rev-parse --short HEAD`
  is unique by construction. A `v1.N` is a name somebody chose and it does not identify a
  commit: `v1.0` carries **six** tags and `v1.5` carries **two**, `v1.53` does not exist,
  `v1.67` and `v1.68` carry no slug, and `v1.63.1-access-list-address` is a patch-level tag
  inside the `v1.N` series. **An ambiguous attribution is the same failure as a missing one**,
  because a reader who trusts it is worse off than one who sees none. The full inventory is
  in `TASKS.md` §"Three things settled" — 97 tags, 22 semantic and 72 slug-shaped and 3
  neither, and the semantic scheme stopped being used at `v0.7.4`.
- **Tag the window.** 29 commits carried no tag (everything since `v1.68`, 2026-09-30) and
  they were the most recent ten completed passes, whose figures are quoted in `README.md` and
  `TASKS.md`. **Closed 2026-10-04** — tagged `v1.69` .. `v1.97`, one tag per commit, no pass
  boundaries guessed, and each `v1.N` checked for uniqueness first because the historical
  `v1.0` and `v1.5` collisions are what reusing a number looks like. **Note that the count
  was 28 in the sentence that said 29 commits existed and was written before the last of
  them landed: a published figure expiring on the commit that completes the work it
  describes.**
- Update the test count in `README.md` and `TASKS.md` with the same change that
  moves it, from `make counts`. And **a hand-written tally of finished work is a claim about
  the work**: `TASKS.md` said 49 done / 33 remaining and the counts were 46 / 36, wrong by
  three in the flattering direction, because three Phase 4 boxes were re-opened when the two
  dead modules were deleted and the sentence was never updated. `grep -c` it.

---

## 10. Deliberately not done, and decided against

**This table used to be one list under one heading, and the heading was wrong for
nine of its twelve rows.** It said "Do not fix these by guessing" over rows that
described fixes already made, so a reader looking for what was *left undone* got a
list where three-quarters of the entries began "Done", "is now", or "was charged
nowhere". That is the same defect as a wrong number: a handle that cannot be trusted
is worse than none. It is now two tables.

### Open. Do not fix these by guessing; each is in `TASKS.md`.

| Item | Which EIP | Why it is open |
|------|-----------|----------------|
| `eth_kzg:blob_to_kzg_commitment/1` | EIP-4844 | Needs the `g1_lin` derivation. No local blob fixture, and the EIP's own test vector fetch 404'd. Do not "finish" it with an approximation. |
| ~~`TERMINAL_BLOCK_HASH`~~ | EIP-3675 | **Closed by scope, on the EIP's own words.** It is chain-config data — §"Client software configuration" says these values "MUST be included into its binary distribution", so the EIP mandates that it be *configured*, and names no value for it (unlike `TERMINAL_TOTAL_DIFFICULTY`, which it pins to `58750000000000000000000` for mainnet). Its one normative use is a **fork-choice** rule: "Canonical blockchain **MUST** contain a block with the hash defined by `TERMINAL_BLOCK_HASH` parameter at the height defined by `TERMINAL_BLOCK_NUMBER` parameter." That is an assertion about a chain's *contents*, not a per-block validity rule, and this node's head comes from the beacon chain over the Engine API — so there is no point at which a block could be refused for it. Carried and echoed, never checked, and that is now the correct behaviour rather than a deferral. |
| Pre-Berlin `SSTORE` **at Constantinople** | EIP-1283 | The only fork still refused. EIP-1283 replaced the rule and Petersburg reverted it, so a single figure would be right for two spans and wrong at the third -- and wrong *only* at Constantinople is never noticed. Unreachable by block number on mainnet. |
| ~~A warm-set entry keyed on a value the frame cannot name~~ | EIP-2929/3651 | **Closed as unreachable on every path that exists.** EIP-3651 is one sentence — "At the start of transaction execution, `accessed_addresses` shall be initialized to also include the address returned by `COINBASE`" — and `eth_block:block_env/2` sets `coinbase => Miner` from the block record **unconditionally**, so the Env never omits it. The `maps:get/3` default and `coinbase_at/2`'s `[]` are correct *defensive* code: if the key were ever absent, warming nothing is right and warming the atom `undefined` would be a warm entry no 160-bit address can equal. This sat in the Open table across several passes because the defensive branch looked like a defect, and the fix (`v1.45`) was correct all along. A "what if the key is missing" branch is not a gap when nothing can make the key missing. |
| `eth_createAccessList` | — | The one genuinely absent JSON-RPC method. |
| `eth_tx:intrinsic_gas/1` takes no fork | — | Falls back to the operator's `ETH_FORK` pin. Correct for pool admission, where no block exists; **wrong** for `eth_call`, `estimateGas` and block execution, which must use `intrinsic_gas/2`. Not a gap so much as a hazard: it is a one-argument function that answers correctly in the one place nobody calls it wrongly. |

### Closed by a decision, or fixed. Do not "re-open" these.

| Item | Which EIP | Where it ended |
|------|-----------|----------------|
| EIP-7702's authorization list was never applied | EIP-7702 | **Fixed (`v1.62`)**, +16 tests, 13 injections. A type-4 transaction was **priced** for its authorizations (25,000 each) and **validated** structurally (a non-empty list, a non-null destination) and then executed **as though it carried none**: no authority recovery, no `0xef0100` designator, no nonce bump anywhere in `src/`. `grep` for `0xef0100`, `0x05` and `designator` found nothing, which is what the open-items table had been saying. **The corpus found it as the largest shape in the `state_mismatch` cluster** -- and the shape is what named it: 1,005 nonce and 1,002 code divergences and **not one storage write**, on `prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json`, whose 84 entries carry 10 authorization tuples apiece. A delegation is 23 bytes of code written and a nonce bumped and nothing else, and `v1.61`'s shape histogram is what made the number 10-for-10 rather than a guess. `eth_block:process_authorizations/3` now applies the EIP's seven steps per tuple, in order, skipping a tuple that fails any of them. **Measured:** `prague/eip7702_set_code_tx` 54 of 80 (67.5%) -> **69 of 80 (86.3%)**, `state_mismatch` 26 -> 11; the 22-file validity set 3,760 -> **3,831 of 3,884 (98.6%)**, `state_mismatch` 122 -> **51**; the committed subset 224 -> **226 of 266 (85.0%)**. Two EIP clauses were read rather than assumed, and **one of them is the opposite of what intuition says**: "if transaction execution results in failure ... the processed delegation indicators is *not rolled back*." That falls out of *where* the call sits -- after `begin_transaction/8`'s nonce increment and before the frame, so the frame's revert restores to a state that already carries the delegations. Putting it inside the frame's starting state rolls them back and diverges on exactly the failing transactions, and injection 8 is that mistake. The other is EIP-2's `s =< n/2`, which `eth_secp256k1:recover/4` did **not** enforce: it checks `s < n` and recovers happily, so a validator without the check accepts a malleated tuple. Two gaps remained open when this was written: the `PER_EMPTY_ACCOUNT_COST` refund, and EIP-3607's relaxation plus following a delegation. **The second closed in `v1.63`**; the first is still open, and `v1.63` also showed that the corpus *does* exercise it, which this entry had denied. |
| EIP-7702 wrote the designator and nothing read it | EIP-7702 | **Fixed (`v1.63`)**, +19 tests, 11 injections, all shown to bite. `v1.62` applied the authorization list, so an account held `0xef0100 || address` -- and no code-executing operation loaded the code it named, so the delegation did not run, which is the entire feature. `eth_tx:resolve_delegation/3` now resolves **at most one hop**, and `eth_evm:do_call/4` calls it **once**, using the answer for both the price and the code so the hop that was billed and the hop that runs cannot be two separate readings. Three of the EIP's rules here are counter-intuitive and all three are pinned: **one hop, then stop** (a chain resolves to a designator *executed as bytes*, and `0xef` is not an instruction, so the frame halts -- a recursive resolver is the wrong implementation *and* the one that looks right, because it terminates on no input); **a delegation to a precompile is empty code**, so `0x01` does not run `ecrecover`; and **the account keeps its own identity**, the delegate's code in the account's storage, balance and `ADDRESS`. EIP-3607 is relaxed to "no code **except** a delegation indicator", and `CODESIZE`/`CODECOPY` are left alone while `EXTCODESIZE` still reports the indicator's 23 bytes. The resolution carries EIP-2929's **extra** account access, 2,600 cold / 100 warm, in `eth_fork_schedule:delegation_resolution_cost/2` -- and that function exists because `2600` was written out in `access_prices/1` four times already and a fifth copy would have been a sixth home. **Measured: the corpus does not move.** `prague/eip7702_set_code_tx` 69 of 80 and the committed subset 226 of 266, both unchanged, and **that is the finding rather than a disappointment**: no committed fixture has a delegated destination or a delegated `CALL`, so this half of the EIP is not measurable by the corpus at all and the tests are the only evidence for it. Both figures also confirm **zero regressions** across every warm-set, access-cost and CALL change the work touches. |
| EIP-7702 step 4: a refused authorization warmed nothing | EIP-7702 | **Fixed (`v1.64`)**, +2 tests, 3 injections. `v1.62`'s `apply_authorization/3` validated the EIP's seven steps inside a `try`, and steps 5 and 6 were signalled by `true = (...)`, so a **refused** tuple raised a `badmatch` and landed in the `catch` — and **a `catch` clause cannot see the variables bound in the `try` body**. So `Authority`, which step 3 had just bound, was gone for exactly the tuples that were refused, and step 4's `accessed_addresses.add(authority)` applied only to tuples that *applied*. The steps are now three predicates and an action, with the authority in scope throughout. The EIP puts step 4 **immediately after recovery and before the code and nonce checks**, and so does this: a tuple naming an authority whose nonce does not match is skipped and still leaves that account warm, so its `BALANCE` in the same transaction costs 100 rather than 2,600. Warming only the authorities that succeeded is the tidier-looking rule and it disagrees on precisely the tuples a user gets wrong. **Found by reading `execution-specs`' `validate_authorization`, which is one line long and is the step this node had been reading past for two commits.** Corpus unchanged at 3,831 of 3,884 and 226 of 266 — no committed fixture has a type-4 transaction whose frame reads one of its own authorities, so this is the third EIP-7702 change the corpus cannot see. |
| EIP-3529's refund cap was taken over the frame's gas, not the transaction's | EIP-3529 | **Fixed (`v1.65`)**, +1 test, 3 injections. EIP-3529 says "Reduce the max gas refunded **after a transaction** to `gas_used // MAX_REFUND_QUOTIENT`", and EIP-7623 spells the same quantity out as `21000 + ... + execution_gas_used` — so the 21,000 is **inside** `gas_used`. `eth_evm:run/5` was capping on the frame's own consumption, so the cap was smaller by `intrinsic / 5` and the node **under-refunded** by that much whenever it bound. The *divisor* had always been right (1/5 London, 1/2 before); only the base was wrong, and the base is the term a reader checks least. `eth_evm:run/6` now takes the enclosing transaction's already-spent gas, which lives on `#ctx.intrinsic` so every child frame inherits it — a parameter threaded through `run_t` would have had to be passed at the two internal call sites and a third the day a fourth appeared. **`run/5` is a bare frame and passes 0, which is right rather than convenient**: an `eth_call` and a system call both charge no intrinsic to anyone, so there the frame's gas *is* the transaction's gas used. **Measured: the committed subset 226 -> 249 of 266, `state_mismatch` 37 -> 14 — the largest single move since the access list, and from a rule the 22-file set cannot see at all**, because those are transaction-*validity* files with little refundable work: 3,831 of 3,884 is unchanged by this commit. Two corpora, two samples, and "the corpus does not exercise it" is a claim about a *named* corpus. |
| EIP-7702's `PER_EMPTY_ACCOUNT_COST` refund was never charged | EIP-7702 | **Fixed (`v1.66`)**, +3 tests, 5 injections of which 3 bite. Step 7 — "Add `PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST` gas to the global refund counter **if `authority` is not empty**" — was absent, so a delegation by an account that already existed cost twice what one by a new account did. The refund is `eth_fork_schedule:set_code_refund/1' and it is the **difference of the two EIP parameters**, not a literal: the EIP states a subtraction and the subtraction *is* the specification, since a delegation by an existing account is meant to cost half of one by a new account. `PER_AUTH_BASE_COST` (12,500) did not exist in the node until this commit. **It is seeded into the frame's starting refund counter, not applied afterwards** — the EIP says *global refund counter*, the frame's counter is the only global counter there is, and seeding means the frame's own `SSTORE` refunds accumulate on top and EIP-3529's cap — which `v1.65` took over the transaction's gas — applies to the **sum**. Charging it after the frame returned would add to a figure the cap had already trimmed, which is the objection `v1.62` recorded and `v1.65` dissolved. **`exists/2` is read before `set_delegation/4`**, because that function increments the nonce and would make every account non-empty by construction; the injection that moved the read afterwards bites, and so does the one that drops the condition entirely. **Measured: `prague/eip7702_set_code_tx` 69 of 80 -> 80 of 80 — every entry, 100% — and the 22-file set 3,831 -> 3,842 with `state_mismatch` 51 -> 40.** The committed subset moved 249 -> 250: one, because the subset holds one such fixture and the directory holds eleven. Saying "+1" without saying that would understate the change by a factor of eleven. |
| EIP-196: an invalid point answered `unsupported` | EIP-196 | **Fixed (`v1.44`).** Note what the corpus could not tell us: the tally did **not** move, because the committed fixtures only ever call ECADD with *empty* input (valid -- the point at infinity) or with gas they cannot afford (so the precompile never runs). Nothing in the corpus exercises an invalid ECADD. The severity was not in a gas figure at all: `unsupported` is a halt, and `eth_block:run_transaction/5` turns a halt into a **refusal to produce the block**, so a mainnet contract doing a real curve operation would have made this node reject its block. `ECADD`/`ECMUL` now answer `{failed, {ecadd, not_on_curve}}` and `{failed, {ecmul, not_on_curve}}`, with the two EIP invalidity conditions -- off the curve, and a coordinate at or above `p` -- told apart. |
| EIP-150's stipend: one figure where the spec has two | EIP-150 | **Fixed (`v1.47`)**, +6 fixtures, zero regressions. `child_gas/4` returned `min(request + stipend, cap)` for both roles. The spec's `MessageCallGas` has two: `cost = gas + extra_gas` (**no stipend**) and `sub_call = gas + stipend`. So the clamp belongs on the **pre-stipend** figure, and the insufficient-balance refund returns `sub_call` -- a `CALL` that cannot cover its value hands the caller 2,300 gas it never paid for, and a frame can finish with more gas than it started with. The old form swallowed the stipend into the cap whenever the cap binds, which is every `GAS`-forwarding call. The child legitimately holding more than the parent has left is **specified**, not an overflow: the stipend is a gift. |
| EIP-2930's access list: priced, never applied | EIP-2930 | **Fixed (`v1.46`)**, +8 fixtures, zero regressions. The list was charged for and ignored, so a declared access was paid for twice -- once in the intrinsic and again as a cold access on every use. `eth_block` now puts `eth_tx:access_list_field/1` on the Msg -- the *same function* `validate/2` priced, so the list that is charged for and the list that is applied cannot disagree -- and `initial_access/3` seeds the warm sets, converting each slot to the interpreter's **word**. |
| EIP-7685 `requestsHash` field position | EIP-7685 | The EIP does not fix the position. It is **pinned** by a test against a real Sepolia Prague header, and appending last reproduces the claimed hash exactly. Not open. |
| Per-fork gas *price* wiring | many | Done. `eth_fork_schedule` is the execution path's only owner of prices; the interpreter's duplicate table is deleted. |
| The code-deposit cost | EIP-2 | `G_codedeposit` = 200 per byte at every fork, from `eth_fork_schedule:code_deposit_cost/1`; a create that cannot pay it fails and its whole forwarded allowance goes. |
| EIP-2929's cold `SSTORE` term | EIP-2929 | `sstore_cold_cost/2` adds the **additional** `COLD_SLOAD_COST` for a pair not in `accessed_storage_keys`. |
| EIP-2929's transaction-start warm set | EIP-2929 | `eth_evm:initial_access/2`, gated on Berlin, seeds `tx.sender`, `tx.to` (or the address being created) and the precompiles -- asked of `precompile_at/2` rather than kept as a second list. |
| A `CALL` the caller cannot afford | EIP-150 / the yellow paper | Pushes 0, **empties the return data**, and adds `sub_call` back. `CALLCODE` gained the check and the transfer it never had. |
| EIP-150's 63/64 rule and the 2300 stipend | EIP-150 | Both fork-gated (Tangerine Whistle and later; zero before), and the stipend's *position* is now the specification's rather than a reading. See the row above. |
| Pre-Berlin `SSTORE` at every other fork | EIP-2200 | The flat rule with EIP-2200's inherited figures; `SLOAD_GAS` fork-selected 50/200/800 by EIP-150 and EIP-1884. |
| A precompile's return data | EIP-211 | `v1.41`. Seven sites, one of which a `grep finish_call(` cannot find. |
| EIP-4844's blob fee was never charged | EIP-4844 | **Fixed (`v1.55`)**, +5 tests, **1,408 corpus entries**, +4 on the committed subset. `eth_fork_schedule:blob_gas_price/1` and `blob_base_fee/2` were correct and had exactly two consumers — the `BLOBBASEFEE` opcode's environment and the `maxFeePerBlobGas` admission floor. The *settlement* path had no reference to blob gas pricing at all: the node computed the price, checked the transaction against it, and then never charged it, so every blob transaction's sender kept `total_blob_gas * price` wei the chain has burned. This is a consensus defect with an economic consequence, not a conformance figure. `eth_block:blob_fee/2` now buys it in `begin_transaction/8`, next to the gas, and **no arm of `settle_gas/9` returns it** — the EIP says the burn happens "before transaction execution" and is "not refunded in case of transaction failure", and the corpus's storage diffs are what prove the ordering: a contract doing `ORIGIN BALANCE SSTORE` stores the in-frame balance, so a node that charged the fee after the frame gets the number wrong twice. |
| EIP-4844's blob *validity* rules: one fabricated, two absent | EIP-4844 | **Fixed (`v1.56`)**, +5 tests. Three rules in the same EIP, all wrong, none of them visible in the tally. **(i)** `valid_versioned_hashes/1` required the hash's 31-byte remainder to be non-zero. **EIP-4844 has no such rule** — its `validate_block` says only "there must be at least one blob" and "all versioned blob hashes must start with `VERSIONED_HASH_VERSION_KZG`" — and whether the remainder is zero is a question about a 48-byte commitment the transaction does not carry, so the execution layer cannot answer it. The clause refused **1,827** corpus branches. **(ii)** `check_state/7` computed `max_total_fee` as `gas * maxFeePerGas + value`, omitting the EIP's `+= get_total_blob_gas(tx) * tx.max_fee_per_blob_gas`, so a sender who could not pay for its blobs was admitted — the 288-entry `INSUFFICIENT_ACCOUNT_FUNDS` cluster. **(iii)** `check_blobs/2` implemented the `maxFeePerBlobGas >= blob_base_fee` floor correctly and **could not fire**: no caller passed `blob_base_fee`, so the `undefined` branch was taken on every call and the `ensure/2` was dead — EIP-3607's shape exactly. Removing (i) is what made (ii) and (iii) *observable*: the fabricated clause had been answering `bad_blob_hashes` for all three, and all 322 now refuse for the right rule. The headline does not move (see the vocabulary boundary), and 4 entries stopped refusing for the wrong reason and now do not refuse at all — the per-block blob gas limit and the check-ordering question, both recorded in `TASKS.md`. |
| EIP-4844's per-block blob gas cap was missing | EIP-4844 | **Fixed (`v1.58`)**, +4 tests. EIP-4844's `validate_block` requires `blob_gas_used <= MAX_BLOB_GAS_PER_BLOCK` (786,432 = 6 blobs) accumulated over the *whole block*, and this node had no such check, so a block carrying 7 or 9 blobs was admitted. It is **cumulative**, so it cannot be a per-transaction condition — a 4-blob transaction followed by a 3-blob one is an invalid block whose transactions are each valid — and the total is threaded through `eth_block:execute_transactions/6` into the validation context. It is threaded as an **argument**, not through `Block#block.blob_gas_used`, because on an imported payload that field holds the block's **declared** header value: writing an executed total into it would put a recomputed number under a key named after a header field, which §4.1 exists to prevent. The cap and the `blobGasUsed` *commitment* are therefore two questions with two values, and only the first is now answered. The conformance runner hands `validation_ctx/2` a total of 0 — a state test has one transaction per block, so **it structurally cannot express the cumulative half** — which is why the accumulation is pinned by hand on the real `finalize/1` path. |
| The rejection vocabulary: the runner asked the wrong question for 1,974 entries | measurement | **Fixed (`v1.60`).** `rejection_mismatch` on the 22-file `expectException` set went 1,974 → **0**, `match` 1,784 → 3,760. **No refusal changed.** The node now refuses for exactly the reasons it did; the runner was comparing against strings that were not the corpus's. Three defects: the `node_exception/2` table's names were wrong in **ten of eleven** clauses (including one for `insufficient_funds`, a reason `eth_tx:validate/2` never throws), `exception_code/1` string-compared the whole `"A\|B"` so 31 entries were unreachable **by construction**, and the node conflated two of EIP-4844's asserts into one reason. Classified before anything was changed: **behavioural gaps 0**, vocabulary 1,943, harness 31. The corpus has exactly 18 distinct `expectException` codes and they are now printed in the table's comment with their measured counts, because a table that asserts "every code here has been asked for" is a claim that has to be derived. **That a wrong clause cannot manufacture a match is measured**: mapping EIP-7623's floor to the wrong code *loses* 76 and invents none. The committed 266-entry subset is **unchanged at 224 of 266**, because it never had a `rejection_mismatch` — the most useful single fact about how the headline figure and the corpus figure relate. |
| An EIP-2930 access-list **address** is priced and never warmed | EIP-2930 / EIP-2929 | **Fixed (`b79e584`), and found by a test written for a different EIP.** The EIP-7702 warm-resolution test warmed its delegate through an access list and the "warm" arm came out **2,400 more** than the cold one — which is the list's own price, warming nothing. `eth_evm:access_list_access/2` folded the list into `{warm_store, Addr, Slot}` entries and **never added the address to `accessed_addresses`**, so EIP-2929's warm set had only its storage kind seeded: every access-list address was charged its 2,400 of intrinsic gas (EIP-2930's `2400 * access list address count`) and then re-charged 2,600 as a cold account access on first use. `v1.46` fixed the storage-key half and the tx field; this is the same defect one level up. **This row sat in the **Open** table describing a defect that had been closed, and the Closed table never gained a row for it at all** — so the fix was in the code and in the log and in neither table, which is the same defect as a stale conformance figure: a table a reader uses as a work list, disagreeing with the tree. |
| A contract made by `CREATE`/`CREATE2` has nonce 0 | EIP-161 (a) | **Fixed (`v1.67`)**, +5 tests, 3 injections of which 2 bite. "Account creation transactions and the CREATE operation SHALL, prior to the execution of the initialisation code, increment the nonce over and above its normal starting value by one" — and the EIP's own Rationale says why the rule is one rather than zero: *"CREATE avoids zero in the nonce to avoid any suggestion of the oddity of CREATEd accounts being reaped half-way through their creation."* `eth_block:deploy/5` (the create-*transaction* path) had always set it; `eth_evm:create_with_value/9` (the opcode path) never did, so **the two ways of deploying a contract in this node disagreed and the opcode way was wrong.** The corpus found it as **84 nonce divergences and not one code divergence** in `constantinople/eip1014_create2/test_create2_return_data.json`, and the shape is the evidence: "a create that did not happen" and "a create that happened with the wrong nonce" are the *same* diff, so the absence of a code diff is what says the deployment occurred and only the nonce was wrong. **Measured: that file 36 -> 72 of 168** (and its per-fork table is the clearest result in this work — Cancun, Shanghai and Prague go 0 of 23 to 23 of 23 while Berlin, Istanbul, London and Paris stay at 0 of 23, so the residual is a *separate* 1-to-2 gas defect at pre-Cancun forks), **constantinople 57 -> 93 of 192, byzantium 144 -> 195 of 405, the committed subset 250 -> 254 of 266.** Gated on Spurious Dragon per the EIP's own "Hard fork" section, and the gate is pinned by an injection that removes it: `homestead` 82 of 82 and `frontier` 3,661 -> 3,667, both pre-SD, both unmoved-or-better. **Nothing here is a gas figure** — the whole cost of the defect is a state root, which is why the pin moved on `state_mismatch` and not on a gas number. |
| A transaction type that fell out of a `case` on the fee field | EIP-1559 / EIP-7702 | **Fixed (`v1.57`)**, +1 table-driven test over all five wire formats. `fee_ceiling_ok/4` chose the ceiling with `case tx_type(Tx) of eip1559 -> MaxFee; eip4844 -> MaxFee; _ -> GasPrice end`, and `eip7702` was absent — so a type-4 transaction, which has **no `gasPrice` field**, fell to the legacy branch and read `field/3`'s default of `0`, and against a correct base fee every type-4 transaction was refused as underpriced *by its own cap*. **72 corpus entries**: 47 `INTRINSIC_GAS_TOO_LOW`, 14 `INTRINSIC_GAS_BELOW_FLOOR_GAS_COST`, 8 `SENDER_NOT_EOA`, 3 type-4 well-formedness. `fee_fields_ok/4` had the identical clause and `v1.54` fixed it there without re-reading its neighbour. The `case` on an enum that selects a *value* is more dangerous than one that selects a *rule*: a missing rule raises, a missing value answers plausibly. |

### The originals, kept because the reasoning is the point

The two tables above are the status. These are the *arguments*, which are the part
that stops the next person re-deriving them. Nothing here is a separate claim.

| Item | Why |
|------|-----|
| `eth_kzg:blob_to_kzg_commitment/1` | Needs the `g1_lin` derivation; no local blob fixture, and the EIP-4844 vector fetch 404'd. |
| EIP-7685 `requestsHash` | The EIP does not fix the header field position, and without EIP-7251 there are no requests. **The position is pinned rather than open**: it is the last field, and that is verified against Sepolia block 11,722,100, a real Prague header whose claimed hash `0xd79af79...` is reproduced exactly by appending the field last. See §11. |
| `TERMINAL_BLOCK_HASH` (EIP-3675) | Chain-config data, not in the EIP. Carried and echoed, never checked against a post-Merge block's difficulty. |
| Per-fork gas *price* wiring | Done. One owner of every price; the interpreter's duplicate table is deleted. SSTORE included (EIP-2200, Berlin and later). |
| `eth_tx:intrinsic_gas/1` fork-awareness | Takes no fork and falls back to the operator's `ETH_FORK` pin. Correct for pool admission, where no block exists; wrong for `eth_call`/`eth_estimateGas` and block execution, which pass the block's own fork through `intrinsic_gas/2`. Do not use the one-argument form where a block is in hand. |
| EIP-150's 63/64 rule and 2300 stipend | **Both are now fork-gated** (Tangerine Whistle and later; zero before), and the pre-Whistle rule is derived rather than invented because EIP-150's own `substitute` block is the code it replaced. That gained a corpus fixture: 11 -> 12 matches. Where the stipend sits relative to the cap was **open for a long time and was refused on purpose**, because the EIP's reading made a child's allowance exceed the caller's remaining and that could not be settled from the text. It is now settled from the specification's *source* rather than the EIP, and the recorded worry turned out not to apply: the stipend is a gift the caller does not pay for, so the child holding more than the parent has left is correct. `v1.47`; +6 fixtures. See TASKS.md. |
| The code-deposit cost | `G_codedeposit` = 200 per byte of returned code, at every fork, from `eth_fork_schedule:code_deposit_cost/1`; a create that cannot pay it fails and its whole forwarded allowance goes (EIP-2 item 3). It was charged **nowhere**, and the EIP-170 cap was a bare guard rather than a price. `max_code_size/1` answers `infinity` below Spurious Dragon. See TASKS.md. |
| EIP-2929's cold `SSTORE` term | `sstore_cost/4` is only half of EIP-2929's SSTORE clause. The other half — "charge an **additional** `COLD_SLOAD_COST`" for a pair not in `accessed_storage_keys` — is `sstore_cold_cost/2`, and omitting it under-charges the *first* touch of a slot by 2,100 while leaving every second touch right. That asymmetry is invisible to any test that writes a slot twice. |
| EIP-2929's transaction-start warm set | `eth_evm:initial_access/2`, gated on Berlin, seeds `accessed_addresses` with `tx.sender`, `tx.to` (or the address being created) and `eth_fork_schedule:precompile_addresses/1` — which **asks** `precompile_at/2` rather than keeping a second list, bounded by a pin that keeps the bound and the layout's catch-all clause the same statement. It was absent, so every precompile and both of those addresses cost `COLD_ACCOUNT_ACCESS_COST` on first touch. |
| A `CALL` the caller cannot afford | The spec's `call`: on `sender_balance < value` it pushes 0, **empties the return data**, and adds `sub_call` back. This module consumed the forwarded allowance instead, and `check_call_value/5` had no `callcode` clause at all, so `CALLCODE` moved no value and read no balance. `+45,247` on six corpus fixtures. The stipend's *field* — `cost` vs `sub_call` — is still open; see TASKS.md. |
| Pre-Berlin SSTORE | **Priced, except at Constantinople.** The flat rule (the yellow paper's, which Petersburg restored) with EIP-2200's own inherited figures, and `SLOAD_GAS` fork-selected 50/200/800 by EIP-150 and EIP-1884. Constantinople is the *only* fork still refused, because EIP-1283 replaced the rule and Petersburg reverted it — and it is unreachable by block number on mainnet anyway, since it and Petersburg share block 7,280,000. `SLOAD` itself was also a flat 200 at every fork, right for one span of three. See §3 "Fork awareness" and TASKS.md. |

## 10a. The traps this repository has now paid for

**No count, deliberately.** The heading said "Three traps" while sixty-one were listed
below, which is the §3 defect in miniature: a number in a section a reader uses as a
measure of scale, that no longer describes the tree. Every entry here was a real
outage, so the list only grows.

- **A key is written through one normaliser and read through another.**
  (`v1.39-see-the-storage-writes`, 2026-09-28.) `eth_state:new/2`
  rewrites every `{store, A, S}` key of an overlay through `eth_state:slot_key/1`; a
  read path that does not go through the same normaliser sees nothing. It cost 21 of
  266 fixtures, and it presented as a *node* defect — `test_eip1559_tx_validity` was
  read as "this node does not execute a valid EIP-1559 transaction" when the node
  finished it at `charged0=26006`, the chain's own figure. **When a write and a read of
  the same map disagree, suspect the key before the value.**
- **A function that takes a name may be handed a label.** `base_fee_for/1` took the
  fixture's fork *name*, which `fork_of_key/1`'s binary capture makes a **binary**,
  where `eth_fork_schedule:at_least/2` wanted an atom. An unrecognised fork ranks as
  ancient, so it answered `undefined` for every fork — correct before London, wrong
  from it, which is why two thirds of the corpus never noticed. The fix asks
  `current_fork/4'` about the *block* rather than translating the name, so there is no
  second list to fall out of step; and `schedule_fork_at/3` asks about **mainnet**,
  because `fork_point/1`'s activation numbers are mainnet's and asking the configured
  network answers a different question.
- **A byte width in a hand-written probe is a silent wrong answer.** `<<1:512, 2:512>>`
  is two **64-byte** fields, not two 32-byte coordinates, so the node read it as the
  points `(1,0)` and `(2,0)` -- both off the curve -- and I concluded a correct ECADD was
  broken. Three probes in one session were wrong this way: `16#62` for PUSH2 (it is
  PUSH3), a 17-byte address, and now a 64-byte field element. A probe is a test with
  the assertions removed and it fails the same way; the tell is that it disagrees with
  a derivation you can do on paper.
- **A test that asserts a defect and argues for it is worse than no test.**
  `unspent_gas_comes_back_at_the_effective_price_test` set `maxFee = 1000` against
  `baseFee + priority = 11`, asserted that the sender pays
  `gasLimit * maxFee - unused * effective`, and closed with "this is the whole reason
  1559 sends people away with a high cap, and it is not a bug". It was the only test
  exercising `maxFee > baseFee + maxPriority` -- the single case where the ceiling and
  the effective price differ -- and it pinned the bug. EIP-1559 charges
  `gas_limit * effective_gas_price` and refunds at the same price, so the cap appears in
  neither line; and the burn is `gas_used * base_fee` on gas that *was* used, so there
  is no burn at all on unused gas. Corrected rather than deleted. Same shape as the SSZ
  `withdrawalsRoot` test `v1.7` replaced.
- **A default of zero is not the same as an absent field.** `eth_block:effective_gas_price/4`
  was handed a legacy transaction's `maxFeePerGas` and `maxPriorityFeePerGas` with a
  default of `0` and guarded on `is_integer/1`, so "has no such field" and "asks for a
  zero fee" were the same value. The answer was `min(0, baseFee + 0) = 0`, and since
  `buy_gas/4` charges `gasLimit * gasPrice` while `settle_gas/8` refunds `GasLeft * 0`,
  **every legacy transaction in a London-or-later block was billed its whole gas
  limit** -- 111 conformance fixtures, and it presented as "26 EIP-196 fixtures are
  wrong". Two existing tests covered the 1559 clause with a base fee and nothing covered
  the other combination, so both covered cases were correct and the third was not.
  The same function was wrong the other way for a 1559 transaction in a block with **no**
  base fee: it answered `gasPrice`, and a typed transaction carries no `gasPrice` field,
  so that read as 0 and the sender paid nothing. `opt_uint/1` now preserves the
  distinction.
- **A result nobody writes is whatever was there before.** `finish_call/8` does not set
  `retdata` -- for an account `CALL` that is `handle_child/9`'s job -- and the precompile
  path had no such job, so `RETURNDATASIZE` after a *precompile* call reported the
  previous call's length. It read as `-19,900 x24`, which is `SSTORE_SET_GAS` minus
  `SLOAD_GAS`: a delta that decomposes onto two neighbouring constants is a wrong
  *value* feeding a right price, not a mispriced opcode. Three traps in one fix: a
  grep for `finish_call(` **misses the successful `CREATE`**, which pushes the address
  itself; the older reading of EIP-211 (the created address, left-padded, left in the
  buffer) is **wrong** for the current spec, which says the stack gets the address and
  the buffer gets `b""`; and a test for the **depth-limit** branches cannot be written
  cheaply, because a frame at depth 1024 cannot have populated the buffer. That test
  passed with the fix deleted and was deleted rather than kept.
- **A two-byte immediate written with `16#62` is a `PUSH3`.** `0x61` is `PUSH2`.
  `PUSH3` swallows the *next* opcode as its third byte -- in a probe that next byte was
  the `CREATE` under test -- so the program never created anything and reported a
  buffer nobody had touched, which reads as a node defect and is not one. Four
  hand-written probes were wrong in that one hex digit at once. A probe is a test with
  the assertions removed, and it fails the same way.
- **A gas figure read off a balance difference can be a fee bug.** `+517,958` is
  `(gasLimit - gasUsed) * price`. It looks like a pricing bug and is arithmetic about
  the *price*, and an instrumented run is what separated them: `charged0` was already
  exactly the chain's number. Print the receipt before believing a delta.
- **A map carrying both `data` and `input` is ambiguous, and the precedence is part of
  the contract.** `data` is JSON-RPC's spelling and `input` is this node's internal one;
  a caller supplying `data` means it. `eth_tx:calldata/1` states the rule because getting
  it wrong makes a test that *adds* `data` to a map already carrying an empty `input`
  fail for a reason that is not the one under test.

- **A macro whose body is an expression is not atomic, and `band` binds tighter than
  `-`.** `eth_word`'s `?MASK` is `16#FFFF…FF` -- a single token, with no operators for
  precedence to reorder. Written the obvious way, as `(1 bsl 256) - 1`, then
  `X band ?MASK` parses as `(X band (1 bsl 256)) - 1`, because `band` is a tighter-binding
  word operator than `-`. For any word below 2^256 that is **`-1`**. Nine of `eth_word`'s
  functions use `?MASK` exactly this way (`add/2`, `sub/2`, `mul/2`, `mask/1`, `shl/2`,
  `unsigned/1`, `exp/2`, `signextend/2`), so "simplifying" that one line to arithmetic
  corrupts all of them at once, and `shl(1, 0)` answering 0 reads as an off-by-one in the
  shift rather than as a macro. An injection doing precisely that rewrite fails **23 of the
  40 `eth_word` properties**.
  This repository then made the identical mistake in a *test* module's `?MASK`, and the
  symptom is the part worth keeping: the failure reported `want => -1, got => 22657,
  as => 22657, mask => 2^256-1` -- a "want" that **cannot be derived from the inputs by any
  arithmetic**. Run by hand, the property *passed*. So the rule that actually diagnosed it
  was not "check the numbers" but **"a result no arithmetic can produce means the
  expression is not what you think it is."** That is the `PROBE` trap again, one level up:
  a plausible wrong answer to a question about your own code.
  The general form: **wrap an expression macro's whole body in parentheses, or write it as a
  single token.** `?MASK` is not the only thing that can go wrong this way -- any macro used
  beside a word operator is suspect.

- **A comparison between two paths can be exactly zero for a reason that is not the one
  under test, and the tell is in the forks.** Fixing EIP-150's stipend took three
  attempts at one measurement. The first compared a *successful* value-bearing `CALL`
  with an *unsuccessful* one and got **0** at every fork -- which reads as "the stipend
  does not matter here", and the actual reason is that a callee consisting of a single
  `STOP` hands the stipend back on **both** paths, so the two cancel. The second gave
  the callee eleven gas of pure computation and got **11** at every fork -- the callee's
  own consumption, still not the stipend. The measurement that worked asserts an
  **absolute**: `spent = pushes + call_cost - stipend`, which holds at every fork
  including Tangerine Whistle, where it comes out **negative** because there is no
  EIP-161 9,000 there to absorb the gift.
  The tell that the first attempt was measuring nothing: **the number was the same at
  Tangerine Whistle as at Cancun**, and Tangerine Whistle predates both the 9,000 and
  the fork at which the 63/64 cap exists. A figure that does not move across a boundary
  where the terms around it change is measuring the wrapper, not the thing.
  Related, and the reason the third attempt was needed at all: **there are two
  saturation regimes and they are different tests.** With a large frame the *request*
  decides the child's allowance; with a small one the 63/64 *cap* does, and only then
  does the stipend's position show up at all. "Assert the frame" is worth doing --
  `?assert(Request > Cap)` -- because a test that quietly stops saturating goes on
  passing for the wrong reason.

- **`DATA_DIR` is not pid-scoped, and two runs of the corpus tool will corrupt each
  other's MPT.** `eth_test_util:tmp_dir/0` scopes the *test* directories by pid, and
  §5 says so, and it is easy to read that as covering everything a run touches. It does
  not. `eth_mpt` opens `mpt_state.dets` in the configured data dir, `DATA_DIR` defaults
  to `./data`, and **nothing scopes it**. Six concurrent `eest_report` workers -- which
  is how one would sensibly shard a 235-file run across six cores -- all opened the same
  DETS file, and every worker but the one that won the race died at boot with
  `{badmatch, {error, {needs_repair, "./data/mpt_state.dets"}}}`, with a
  `CRASH REPORT` for `eth_mpt:ensure_dets/0` and **no conformance output at all**.
  The failure looks like a corpus or harness problem and is neither: give each worker
  its own `DATA_DIR` and it is a non-issue. The general form is the one in §5: a
  resource shared by two processes needs to be scoped by something that differs between
  them, and "the tests are pid-scoped" is a statement about the tests.

- **The committed conformance subset is the smallest file in each suite, so it is the
  easiest 2% of the corpus, and quoting it as "the conformance figure" overstates the
  node by roughly 40 points.** Measured: 226 of 266 entries on the committed subset
  (85.0%, `v1.62`), **6,786 of 15,660 on the 229 non-`static` files** (43.3%, pre-`v1.55`
  and not re-run), one fork per fresh VM. Both are true; they are different measurements. The subset is a **regression
  gate** -- it is small, pinned, and has a clean per-entry attribution -- and it is good
  at that. It is not a quality claim, and §5's "the committed subset is what CI runs"
  should be read as *what CI gates on*, not *how good the node is*. The `unpriced` claim
  is the sharpest illustration: 0 on the subset, **86** on the corpus, written as "nothing
  is executed that this node cannot price". A property measured on 266 entries and
  stated without its scope is a claim about the node that the node does not support.

- **A progress interval expressed in files is silent on any corpus smaller than it.**
  `eest_state_tests:survey/2` reports every 25 files, which is right for 2,681 and useless
  for a fork with six: `istanbul` ran for **45 minutes of CPU** across five
  `test_blake2b*` gas-limit sweeps and emitted **nothing**, so it was indistinguishable
  from a hung worker. The tell that it was not hung was `ps` showing CPU time climbing at
  104%. Report on a *time* interval as well as a count -- a long-running unit that cannot
  be observed is indistinguishable from a dead one.

- **An error is a value, and a list of the right length is not a list of the right
  things.** `eth_config_settings:ip4/1` checked four octets by building
  `[octet(X) || X <- [A, B, C, D]]` and matching `[N1, N2, N3, N4]`, with `octet/1`
  answering the atom `not_an_octet` on failure. That is **wrong for every bad address**:
  `[1, not_an_octet, 1, 1]` is a four-element list, so it matched with the error atom
  bound to `N2`, the `_ -> error` clause was unreachable, and `ip4("1.999.1.1")` answered
  `{ok, {1, not_an_octet, 1, 1}}` -- a tuple with an **atom where an octet belongs**,
  which the caller destructured into `{A, B, C, D}` and returned as a bind address. The
  right arity is not a check on the right *types*, which is exactly what an untagged
  element in the list defeats, and nothing warns about it: the pattern `[N1, N2, N3, N4]`
  really does match, so the `_ ->` clause is statically dead rather than statically
  unreachable and the compiler has nothing to say. The tell was a probe that disagreed
  with a derivation doable on paper. Hence `{ok, N} | error` and an explicit
  `lists:all/2`.

- **`re:run/3` returns the first match, not all of them.** Measured here: a subject with
  three quoted tokens gives `[<<"AAA">>]` by default and `[[<<"AAA">>], [<<"BBB">>],
  [<<"CCC">>]]` with the `global` option, which is the opposite of what the default
  suggests at a glance. A test written to check "every environment variable `eth_config`
  reads is in the validation table" scanned the source with `re:run/3` and found **one**
  variable out of thirty-one -- so the assertion "nothing is unchecked" was satisfied by
  a scan that had checked almost nothing. It is the worst shape of a passing test: the
  property is a universal claim, the measurement was one example, and the failure mode is
  silence. Split on the delimiter and take the odd-indexed tokens instead, and assert the
  scan found a plausible *number* of things, so a scan that finds nothing cannot pass.

- **A test that calls `start/2` to observe a gate decision boots the node.** To find out
  whether the new configuration gate lets a *legal* configuration through, the first
  version called `etherlang_app:start/2` -- which opened `eth_mpt` under the un-scoped
  `DATA_DIR` (so `./data/mpt_state.dets`), generated a JWT secret into `./data`, and
  bound 8545 and 8551. The test passed. It was the AGENTS.md §10a `DATA_DIR` trap, hit
  by a test that meant to observe a decision. The refusal test alone does not catch this,
  because it returns before anything starts, and a negative test is satisfied by a gate
  that refuses everything. So the answer has its own function: `check_config/0` is the
  decision, `start/2` is the work, and both directions of the gate are tested against
  the first. The control for the negative case is then a **filesystem** observation --
  `jwt.hex` does not exist afterwards -- because that is what distinguishes "refused"
  from "refused after starting".

- **A function that draws its own key will happily sign with a key the test did not
  fund the account for, and the symptom is a balance that never moves.** `eth_4844_tests:
  sign/1` drew a fresh `eth_secp256k1:generate_key/0` on every call. Five settlement
  tests funded `addr_of(Priv)` and then signed with `sign/1`, so the transaction's
  recovered sender was a *different* account from the one under test. Nothing crashed
  and nothing looked wrong: the receipt was right, the gas was right, the block was
  built -- and the balance asserted on came back **exactly as it started**, because it
  was an account nobody transacted from. A delta of zero reads as "the node charged
  nothing", which is exactly the bug under test, so the test was arguing with itself.
  `sign/2` exists so a test that owns a key can sign with it. The general form: **a
  fixture's identity has to come from the test, not from the helper**, and a helper
  that generates one is a helper that can disagree with the fixture without saying so.
  Compare §10a's `base_source` rule -- a resource shared by two things needs to be
  scoped by something that differs between them.

- **A 20-nibble hex literal in a 1-byte segment is 1 byte, silently.** Three of the
  five tests wrote `<<16#1000000000000000000000000000000000000001>>` for a destination
  address. A hex constant too wide for the segment's default 8-bit width is truncated,
  so all three produced `<<1>>`. The node accepted that as a destination and
  `eth_state:address/1'` then pushed a 1-byte binary onto its *second* clause -- the one
  for `0x...` strings -- and ran `hex_to_bin/1` over it, which raised
  `function_clause` from `hv/1`, four frames away, naming neither the literal nor the
  field. The same literal at `<<16#c0de:160>>` is fine. It is §10a's byte-width trap
  again, in a form that compiles and runs: nothing is malformed, the number is just
  wrong, and the failure is somewhere the reader is not looking. The tell is the
  *distance* between the literal and the error.

- **Two state diffs of the same size are one defect, and the second one is the first
  one read back.** The 1,408 `state_mismatch` entries in
  `cancun/eip4844_blobs/test_sufficient_balance_blob_tx` and
  `test_blob_gas_subtraction_tx` diverged on the sender's balance *and* on two storage
  slots, all three by exactly 786,432, and it read as a gas problem and a state problem.
  The fixture's code is `0x3231600055...` -- `ORIGIN BALANCE PUSH1 0 SSTORE` -- so slot 0
  *is* the sender's balance as the frame saw it. The node never deducted EIP-4844's
  blob fee, and a contract that stores `BALANCE` stored the pre-deduction number. The
  general form: **when several diffs share a magnitude, they share a cause**, and
  decoding the fixture's bytecode is cheaper than modelling the EVM. The 786,432 also
  decomposes exactly: six versioned hashes at `GAS_PER_BLOB` = 131,072.

- **A report's histogram with a range cannot report the biggest cluster in the corpus.**
  `add_gas_delta/4` buckets `abs(Delta) =< 100000`, and every entry in the blob-fee
  cluster reported `no_comparable_gas` -- these fixtures set
  `maxPriorityFeePerGas = 0` against `currentBaseFee = 7`, so the effective price is the
  base fee, the sender's net is `gasUsed * (price - baseFee) = 0`, and the
  balance-inversion method that recovers a gas figure from a balance difference has
  nothing to divide. The section printed `(none in range)` for 1,408 entries: not "no
  gas defects", but "no gas defects *this instrument can see*". A bounded histogram
  that prints nothing is indistinguishable from a bounded histogram over an empty set,
  and §5's claim that an unobservable long-running unit is a dead one is the same
  shape. The diffs were always printed; it was the summary that was quiet.

- **A fabricated check hides the real ones behind it, and its victims are all
  attributed to it.** `eth_tx:valid_versioned_hashes/1` required a blob versioned
  hash's 31-byte remainder to be non-zero, "a zero hash would commit to nothing".
  EIP-4844 says no such thing, and the execution layer cannot answer the question
  anyway — the remainder is `sha256(commitment)[1:]` over a 48-byte commitment the
  transaction does not carry. The clause answered `bad_blob_hashes` for **1,827**
  corpus branches: the 288 blob-balance entries, all 34 check-ordering entries, and
  the 4 underbid-blob-fee entries. So **322 entries were refused for a reason that
  does not exist, and every one of them was a case of a rule the node genuinely
  lacked** — the missing `max_total_fee` blob term and the unreachable
  `maxFeePerBlobGas` floor were both real, and neither was visible, because a rule
  further down `check_blobs/2` had already answered. The general form: **a check
  that fires early and wrongly does not merely add noise, it deletes the
  information about everything behind it.** When three rules are wrong in the same
  place, ask which one fires first, because that is the one that has been hiding the
  other two — and the one to fix first is the *fabricated* one, even though fixing
  it exposes the others as outright failures. That is the trade: 322 wrong reasons
  become 322 right reasons and 4 refusals disappear, and the 4 are then named rather
  than masked.

- **A rule that reads a value nobody passes is not a lenient rule, it is a dead
  one — and its own comment says so without noticing.** `check_blobs/2` documented
  "when the caller cannot supply it the floor is not checked rather than guessed",
  and the sentence was read as prudence. The fact was that *no caller could supply
  it*: `eth_block:validation_ctx/4' had no `blob_base_fee` key and neither did the
  conformance runner, so `maps:get(blob_base_fee, Ctx, undefined)` took the
  `undefined` branch on every call in the program and the `ensure/2` below it never
  executed. The comment described a design decision; the code had an omission. This
  is the EIP-3607 lesson from §10's own table, and the shape is worth stating as a
  general rule: **when a function is careful about a missing input, check whether
  anything supplies it** — a careful clause is very often a disclaimer written
  around a hole. The test that finds it is not a unit test of the function, which
  passes perfectly, but a test through the *production* caller, because only that
  caller shows the omission. A negative test on its own is worse than none here: it
  is satisfied by a caller that refuses everything, so `v1.56`'s
  `the_block_admission_path_enforces_the_blob_base_fee_test` asserts the refusal
  **and** that the same block is accepted when the sender bids the block's price.

- **A missing clause in a `case` that selects a *value* is a wrong number, and it is
  indistinguishable from an ordering bug by its symptom.** `fee_ceiling_ok/4` picked
  the fee ceiling with `case tx_type(Tx) of eip1559 -> MaxFee; eip4844 -> MaxFee; _ ->
  GasPrice end`, and `eip7702` was not in it. A type-4 transaction has **no `gasPrice`
  field at all**, so the `_` branch read `field/3`'s default of `0`, and against a
  correct base fee of 7 every type-4 transaction was refused as underpriced *by its own
  cap of 7*. That is **72 corpus entries** — 47 `INTRINSIC_GAS_TOO_LOW`, 14
  `INTRINSIC_GAS_BELOW_FLOOR_GAS_COST`, 8 `SENDER_NOT_EOA`, 3 type-4 well-formedness —
  and not one of them was about fees.
  - `fee_fields_ok/4` had the **identical** missing clause, and `v1.54` fixed it there
    with a comment explaining that a fall-through clause turns "not mentioned" into "no
    rules at all". The neighbouring function was not re-read. `v1.57` adds
    `every_transaction_type_bids_its_own_fee_field_test`, which is **table-driven over
    all five wire formats** and asks each at exactly the base fee and one wei below —
    so a sixth type added later fails there instead of inheriting the legacy branch.
  - **The symptom said "ordering".** `fee_ceiling_ok/4` does run *before* the
    intrinsic-gas check, which is not the reference implementation's order, and the
    corpus's reason histogram said `INTRINSIC_GAS_TOO_LOW -> fee_too_low` for twelve
    entries. A note was written recording this as a **check-ordering** defect with a
    "−9 matches, measured, not landed" experiment attached — and that note was wrong.
    The measurement was sound; the diagnosis was not, and it was recorded with the same
    authority as the number. With the clause added, supplying the fixture's stated base
    fee is **exactly neutral** (matches 1,784, `state_mismatch` 122,
    `rejection_mismatch` 1,974 either way) and the ordering question has no evidence
    behind it at all.
  - So the general form is two rules, and they compound. First: **a fee check that
    fires on a wrong value looks exactly like a fee check that fires too early**, and
    the difference is visible only by asking *what value it compared*, not *when*.
    Second: **a rejected experiment's diagnosis has to be re-tested when the code it
    blamed changes.** This is the second time this repository has written a
    reproducible number next to an uncheckable story — the other is §10a's fabricated
    non-zero clause, pinned by a test that argued for it. A `case` on an enum that
    selects a *value* deserves more suspicion than one that selects a *rule*, because
    the first produces a plausible answer and the second produces an error.

- **A bounded histogram that prints nothing is indistinguishable from a bounded
  histogram over an empty set, and the difference hid this repository's largest
  divergence.** `add_gas_delta/3` kept only `abs(Delta) =< 100,000` and discarded
  everything else, and `eest_report:print_gas/1` printed `(none in range)` when the
  map was empty. That is what it printed over `cancun/eip4844_blobs/
  test_sufficient_balance_blob_tx` and `test_blob_gas_subtraction_tx` — **1,408
  entries**, every one of them the sender's balance wrong by exactly `6 *
  GAS_PER_BLOB`, the largest single divergence this node has produced. All 1,408
  reported `no_comparable_gas`, because those fixtures set `maxPriorityFeePerGas = 0`
  against a base fee of 7, so the effective price *is* the base fee, the sender's net
  gas cost is zero, and the balance-inversion method that recovers a gas figure has
  nothing to divide. A delta between two unknowns is a third unknown, and the section
  dropped it.
  - Fixed in `v1.59`: the accumulator keeps `buckets` (unchanged), `over`/`over_max`
    for deltas beyond the range, and `unseen` — a count **per reason a figure could
    not be computed**. The report prints all three, and the rule it now follows is one
    line: **a section that prints nothing must say what it did not look at.** The
    `unseen` block prints whether or not the in-range table is full, because a full
    table of computable deltas says nothing about the entries that have none.
  - It worked immediately, and found two things that had been invisible: **71** entries
    on the 22-file set whose diff carries *no balance for the sender at all* — a
    category that previously did not exist as a number, because the absence of a gas
    story and the absence of a balance diff printed alike — and **258** deltas beyond
    100,000 on `cancun/eip4844_blobs`, **largest 4,919,046**.
  - The general form, and it generalises past histograms: **an instrument that
    filters its input is a measurement of the filter, and the filter is chosen for
    legibility.** The range was chosen so the constants would be visible, which was
    right; the drop was silent, which was not. A dropped value and a zero value print
    the same way, and only one of them means "nothing is wrong". Same shape as §5's "an
    unobservable long-running unit is indistinguishable from a dead one" and as
    `fork_unreachable`: **absence of evidence, printed as evidence of absence.**

- **A tally is not a work list, and an instrument built around one quantity cannot make
  it one.** `state_mismatch` is the corpus's largest cluster and its least useful
  number, and this file said so for a long time: "the tally says `state_mismatch` 249
  times, which is not a work list." The obvious instrument to reach for is a gas
  histogram, and that is the wrong one — **a divergence in a storage slot or a nonce
  has no gas figure to recover**, so the entries the gas section cannot size are exactly
  the entries that most need classifying. On the 22-file set that is **71 of 122**, and
  they were invisible in both directions: no gas number and no category.
  - `v1.61` counts the **shape of the diff**, in the vocabulary the comparison already
    builds them in — `{addr, A, {balance|nonce|code, W, G}}` and `{store, A, Slot, W, G}`
    — so it adds no new parse. Storage is split because two unrelated defects produce
    the same `{store, ...}` diff: *the fixture says zero* is a write the node did **not**
    make, and *wrong value* is a write of the wrong number. A missing effect and a wrong
    effect have nothing in common beyond both being a slot.
  - It separated two clusters that had been sharing one number. The 22-file validity set
    is **1,005 nonce and 1,002 code with zero storage** — CREATE lifecycle: code not
    deployed, nonces not bumped, not one storage write. `cancun/eip4844_blobs` is
    **1,063 wrong-value storage and zero code** — execution and settlement. Same
    outcome name, opposite owners, and nothing but the shapes said so.
  - The general form: **an instrument built around one quantity classifies only what
    that quantity can measure.** A gas histogram around `abs(Delta) =< 100,000` cannot
    tell a balance problem from a nonce problem, so the fix is not a wider bucket — it is
    a second question asked of the same data. The shape is not a summary of the diff,
    it is a projection onto a different axis, and the axis is what makes it a work list.
  - And the arithmetic trap in writing it: `Diffs` is a **list**, and `maps:fold/3` over
    it raises `badarg` with the entire diff list as the first argument — so the crash
    message is a readable dump of one entry's divergence. That is an accident, and it is
    also the second time in two commits that the cheapest way to see the data was a
    malformed call (the other was `re:run/3` returning the first match).

- **A table-driven test's rows can each be failing for the wrong reason, and only one
  of them will be.** The fee-field table above needed five hand-written signing
  preimages, and the `eip7702` row's recovered a *different address from the key that
  signed it* — so the table could not distinguish a wrong fee rule from a wrong
  preimage, and four rows were passing for the wrong reason. The `eip4844` row failed
  first, on a versioned hash written as `0x01...` in the preimage where the node signs
  the raw 32 bytes: a 66-byte RLP string instead of a 32-byte one, so a different
  digest. It is now derived from `eth_tx:to_rlp/1` by splitting the last three RLP
  items, which is the identity `blob_tx_sighash_excludes_signature_test` already
  asserts, applied to all four typed formats. **The legacy format is the one exception
  and must be written out** — EIP-155 puts the chain id in `v`, so the legacy preimage
  and the legacy encoding disagree in their last three *slots*. The general form: **a
  fixture's identity must come from the system under test, not from a second copy of
  it written beside the test.** A hand-written preimage is a reimplementation of
  `eth_tx:sighash/1`, and the two will differ quietly, at the rate at which the two
  differ at all — which is to say, rarely enough to look like it works.

- **A row's precondition borrowed from a sibling row is a row that fails for the wrong
  reason.** The same table used 21,000 gas for every type, which is exactly the
  intrinsic cost of a plain call and **below** the floor for a type-4 transaction, whose
  intrinsic includes EIP-7702's 25,000 per authorization. The `eip7702` row therefore
  failed with `{error, intrinsic_gas}` — a correct answer to a correct rule that was
  not the one under test. It is worth stating plainly because the failure is a *valid*
  result: a test that reports a real rule is not obviously wrong, and the only thing
  that catches it is noticing that the number in the assertion was copied from
  somewhere else. Where a table's rows differ in their preconditions, the precondition
  belongs in the row.

- **A comment documenting a trap does not immunise the code beneath it.** The
  byte-width trap -- a hex literal wider than its segment's default 8-bit integer
  width truncates silently -- is written out in full in `eth_7702_tests.erl`,
  immediately above a `-define(MINER, <<16#c0de:160>>)` that gets it right, and
  **two lines below it `?TO`, `?DELEGATE` and `?OTHER` were all written the wrong
  way.** Five instances in one commit, three of them in the file that explains it:
  a 32-byte key literal became `<<1>>` and raised `function_clause` in
  `eth_secp256k1:node_id/1`; three 20-byte addresses became `<<1>>` and raised in
  `eth_state:hv/1` four frames away; and -- the sharpest one -- a *program*
  literal `<<16#6000, 16#6000, 16#fd>>` became `<<0,0,253>>`, silently deleting
  both `PUSH1` opcodes, so a test named "survives a reverting transaction" was
  running `STOP; STOP; REVERT` and **succeeding**. The general form: **a
  documented trap is still a trap, and the comment's presence is not evidence
  about the code under it.** The only thing that caught these was a probe whose
  answer disagreed with `byte_size/1` arithmetic doable on paper -- and the fix
  that sticks is to *assert the length*, because `<<16#6000, 16#6000, 16#fd>>`
  compiles, runs, and is three bytes.

- **A test for rule N is only about rule N if every other rule passes.**
  `an_authorization_whose_nonce_is_too_large_is_skipped_test` names EIP-7702's
  step 2, `Verify the nonce is less than 2**64 - 1`. The injection that deleted
  the check **failed nothing**, because the fixture's authority sat at nonce 0
  while its tuple claimed `2**64 - 1` -- so the tuple was skipped by step 5, the
  nonce *match*, one rule later. The test was real, it was green, and it was
  about a different rule than its name. Its control was wrong in the mirror image:
  the same authority at 0, signing at `2**64 - 2`, is *also* skipped, for the
  same reason, so neither half of the boundary pair could see the limit. The fix
  is two fixtures one nonce apart in which **the account holds the nonce its
  tuple names**, so the limit is the only thing that differs. This is §10a's "a
  row's precondition borrowed from a sibling row" with a sharper edge: there, a
  row failed for the wrong reason and said so; here, *both* rows did, and the
  injection is what noticed.

- **A specification rewritten into a nesting is a specification you have not read, and
  the rewrite is always in the direction that makes the rule look more complete.**
  EIP-2200 meters `SSTORE` over **three values** — the slot's *original* value (at the
  start of the transaction), its *current* value, and the *new* value being written —
  and its rule is a **flat partition into three cases**, asked in this order:

      current == new ?                       -> no-op, SLOAD_GAS
      current != new, original == current ?  -> clean write: SSTORE_SET_GAS when
                                               original is 0, else SSTORE_RESET_GAS
      current != new, original != current ?  -> dirty write: SLOAD_GAS plus refund
                                               adjustments

  Only the **first** case is one condition wide, and the other two are unreachable
  while it holds. `current == new` is a **no-op** — no write happens, so there is
  nothing for `original` to qualify.

  A note in `TASKS.md` restated this as `if current_value == new_value:` wrapping
  `if original_value == current_value:` wrapping `if original_value == 0:` --
  **the second and third tests pulled inside the first case**, ending in
  `SSTORE_SET_GAS`. Every clause it names exists in EIP-2200, and not one of them
  applies under the no-op. The rewrite read as a *correction* and was presented as a
  quotation.

  EIP-2200 settles it against the rewrite three times independently:
  - **The specification text** is the flat partition above, quoted whole.
  - **The Appendix's proof**, for this case -- `original = 0`, so state A: "We always
    start at state A. The first SSTORE can: **Go to state A: 200 gas is deducted.**
    We satisfy Case I because 200 * N == 200 * 1", where Case I is "If the final
    value ends up still being 0, we want to charge 200 * N gases, **because no disk
    write is needed**." A no-op write of zero needs no disk write, so it is metered
    as one.
  - **The EIP's own test-case table**: the `original = 0` row
    (`0x60006000556000600055`, writing 0 into 0) is **the cheapest row in the table**
    at 1,612 gas, against 5,812 for the same program with `original = 1`. 20,000
    cannot appear in 1,612.

  **What the rewrite cost:** 19,900 gas on every write of zero into a slot that was
  already zero, and it was a *consensus* defect, not a conformance figure. Three tests
  failed and the committed subset went 255 -> 236, and the change was defended with a
  measurement table whose EIP column was computed from the invented nesting -- so
  the table agreed with the change and disagreed with the EIP, and the table is the
  thing a reader trusts.

  - The general form: **a rule whose rewritten form is *more elaborate* than the
    original is the one to re-read, because elaboration is what a misreading looks
    like.** This repository had already paid for the same shape twice -- a fork
    *name* read as a rank, and `s <= n/2` explained by malleability when recovery maps
    a signature to an *account*. In all three the wrong reading made the rule sound
    optional or the defect sound worth fixing.
  - And the cheap guard is the one §4.2 already asks for, applied to prose: **quote
    the clause whole enough that its shape is visible.** A quotation that renders a
    flat list as a tree has already changed something, and the change is the claim.

- **"Malleable, therefore harmless" is a wrong reading of a signature rule.**
  EIP-2's `s =< n/2` is usually explained as malleability, and the natural gloss
  -- "`n - s` recovers to the same address" -- is **false**. Measured on this
  node: for a key whose low-`s` form recovers to `0x5050a4f4...`, the `n - s` form
  recovers to a *different* public key, for either parity, because recovery
  returns `-Q`. So the rule is not there to stop two signatures for one message;
  it is there because **recovery maps a signature to an account**, and without it
  the same authorization -- same chain, address and nonce -- would designate a
  different account depending only on which equivalent signature relayed it. The
  general form: **a security property inherits the wrong justification when the
  mechanism is described rather than derived**, and here the wrong justification
  is the one that makes the rule sound optional. It also went straight into a
  code comment, and had to be taken back out.

- **A destination with no code cannot revert, so a test that needs a revert must
  put code there.** `the_delegation_survives_a_reverting_transaction_test` sent
  `PUSH1 0 PUSH1 0 REVERT` as *calldata* to an account with no code. A call to a
  codeless account returns success without executing anything, so the calldata
  never ran and the transaction **succeeded** -- the assertion `status == 0`
  failed by accident rather than for a reason. This is worse than a wrong
  precondition, because a test whose *name* and *precondition* disagree cannot be
  trusted at all: nothing about it says which one is lying. The control beside it
  now differs in exactly one byte (`STOP` vs `REVERT`) at the same destination,
  with code, so the two runs are the same fixture with one opcode changed.

- **The verdict classifier in an injection harness is part of the experiment.**
  Nine correct injections were reported as `BUILD-BROKEN (proves nothing)`
  because the script keyed "build failed" on the string `"Compiling"`, which
  `rebar3` prints on *every* run. The counts underneath were right and the
  verdict was a lie, in the one direction that hides evidence. A harness that
  reports its own conclusions needs the same scepticism as the code it
  interrogates, and the cheap check is to read one line of its own output
  against one known-good run before believing the other thirteen.

- **A regex over a file that repeats its own vocabulary deletes call sites.**
  Rewriting a block of `-define`s, the script used `(?=set_code_tx)` as its
  end-of-block lookahead -- and `set_code_tx(` appears in *every test body*, so
  the lookahead matched the first call site rather than the definition, with
  `re.search` taking the first of the several identical anchors. The edit removed
  the entire test section of a new test module, and the compiler reported it as
  twelve "function unused" warnings, which read like a different problem
  entirely. The general form: **a lookahead that is satisfied by a call is not a
  lookahead on a definition**, and the same sentence is a general form of "a
  filter is a measurement of the filter".

- **A "nothing happened" assertion cannot tell "the rule did not apply" from
  "no code ran", and the second reading is free whenever a fixture is broken.**
  `a_delegation_pointing_at_a_delegation_stops_after_one_hop_test` asserted the
  storage slot was 0, on a `call_code/2` helper built with `lists:flatten/1` -- which
  flattens a list of *binaries* into a flat list of **integers**, so the account held
  a list where code belongs, the interpreter raised, `run_frame/5`'s `catch` turned it
  into "the frame consumed everything", and `gasUsed` came back as exactly the
  transaction's gas **limit**. The tell was not that the test passed -- it passed --
  but that two *other* gas figures in the same module were both 1,000,000: a gas
  **difference** of zero is a measurement, and a gas figure pinned to the ceiling is
  a frame that never returned. The first version of the loop test put a *real
  writer* one hop past the delegation, so only a recursive resolver reaches it, and
  asserted both the slot **and** that the frame halted.
- **A rule with no behavioural consequence can still have a gas one, and the test
  has to be the gas one.** "A delegation to a precompile is empty code" is
  **unobservable through the function that resolves it**: a precompile address has no
  code, so "the retrieved code is empty" and "read the target's code" are the same
  `<<>>`. The only thing that function can get wrong observably is the *account
  access* it charges, and the injection that dropped it failed nothing until a test
  compared the gas of a `CALL` to a precompile-delegated account against a `CALL` to
  a codeless one. **A rule that cannot change the answer can still change the bill**,
  and "the return value is the same" is not an argument for leaving the price
  unpinned.
- **A difference between two runs is not the component of it, and a *saving* is not
  a *difference*.** The warm-resolution test predicted "-100" for the difference
  between a warm and a cold delegate, on the reasoning "the resolution saved 2,500".
  It measured **+105**, and every part of that is accounted for: the warm arm pays
  2,600 to warm the delegate in the first place, 100 for the resolution, and 5 for
  the two extra opcodes the cold arm does not have (`PUSH20` is 3, `POP` is 2). A
  saving is a statement about one term; a difference is a statement about the sum,
  and only the second is observable.
- **The same rule, one level up: a resolution that is correct for a *transaction's*
  destination must not be charged like one for a `CALL`.** Predicting the same -100
  for the transaction path was wrong for a second reason: a transaction's own
  destination is in the warm set from the start, so resolving it costs **nothing**,
  and the only consequence is that the *delegate* becomes warm -- a difference of
  2,500. Charging 2,600 per delegated transaction would have been a consensus
  divergence in the other direction, and the test as first written demanded it.
- **A control arm must differ from the tested arm in the thing under test and in
  nothing else.** The "is a precompile delegation still charged" test gave its
  control account the *same code the delegate would have run*, on the theory that
  made the two arms comparable. They differed by **22,006**, because the control was
  doing an `SSTORE` the delegated arm deliberately does not. A control that differs
  in a second dimension is a second experiment wearing a control's clothes, and the
  number it produces is a difference nobody asked for.
- **A test that writes its own fixture's identity can be wrong in a way the
  compiler catches only sometimes.** The 3607 fixture built the indicator with a
  helper that points at a *contract* rather than at the precompile under test, and
  the only symptom was a warning for an unused variable. Where a wrong fixture is
  dead code the build says so; where it is live code the build says nothing, and
  only a value that could not have been intended gives it away.

- **An accidentally-empty `old` in `str.replace` inserts the replacement between
  every character, and the file is still "edited successfully".** Rewriting a section
  by slicing it out -- `old = s[s.index(A):s.index(B)]`, `s.replace(old, new)` -- the
  two markers were in the **wrong order** in that file, so the slice was empty,
  and `''` is what Python's `replace/2` inserts between every character when asked.
  A design document went from **38 KB to 98.7 MB in one edit** and 657 lines to
  1,551,752, committed, and the change reported itself as a success. Two things
  caught it and neither was the tool: `git push` warned that the file was 94 MB, and
  a line count is not a thing anyone checks.
  - The general form: **a marker-pair slice is a two-argument search, and a
    `replace/2` that "worked" has proved nothing about its arguments.** An empty
    `old` is not an error in any language; it is the most productive input the
    function has.
  - The cheap guard is one line, and it is the same instinct as §5's "assert the
    scan found a plausible *number* of things": `assert 0 < len(old) < len(s)`.
    A replacement that changed 23 lines should not have changed 1.5 million, and
    `git diff --stat` is that measurement for free.
  - **And a byte size is a measurement worth having.** A repository whose
    documentation is tens of kilobytes has a file in the megabytes, and the
    question "which edit did that" is answerable from the log in one command. The
    shape here is §10a's own: *a section that prints nothing must say what it did
    not look at* -- and a file that grew a thousandfold and said so in the push
    warning is an instrument that worked.

- **A `catch` clause cannot see the variables bound in the `try` body, and a
  `try` used as "any step may fail" throws away everything the failed step had
  already computed.** `apply_authorization/3` validated EIP-7702's seven steps inside
  a `try`, which is the natural way to write "if any step above fails, immediately
  stop processing the tuple" in one line. Steps 5 and 6 were signalled by
  `true = (...)`, so a **refused** tuple raised a `badmatch` and went to the
  `catch` -- and `Authority`, bound by step 3, was out of scope there. The visible
  effect was that only *applied* tuples warmed their authority, which is the
  tidier-looking rule and the wrong one: EIP-7702 step 4 comes **before** the code
  and nonce checks, so a refused tuple still leaves its account warm.
  - The general form: **`try` is a scope boundary, and using it to mean "any of these
    may fail" discards the values the successful prefix produced.** The steps are
    now three predicates and an action, with the authority in scope throughout, and
    the code is *longer* and says more.
  - The tell was a test whose two arms came back **identical** at 48,605 -- the cold
    figure twice, where the warm figure was 46,105. Two arms that agree on a figure
    they were built to differ on is either a rule that does nothing or a rule that
    always fires; here it was a rule that fired only in the case the test was not
    exercising.

- **The authority is the account that *signed*; the tuple's `address` is the
  delegation *target*.** They are different addresses, and a control that varies the
  wrong one is not a control. The step-4 test's first control signed both tuples with
  the same key, so both recovered to the same account, both arms warmed it, and both
  came back at the **warm** figure -- 46,105 -- with the difference reading 0. An
  implementation that warmed the tuple's `address` field instead of the signer would
  have passed that test. The second control signs with a different key, and the
  comment says why, because "the field step 4 does not read" is not a thing the
  fixture can say about itself.

- **`%%/*` opens a block comment, and the comment swallows the rest of the file.**
  A line of `%%` documentation that happened to begin `%%/*` was parsed as the start
  of a `/* ... */` comment, which ran on until a stray `*/` somewhere later in the
  module. The compiler then reported **two unrelated functions as undefined** --
  `buy_blob_gas/3` and `apply_authorization/3` -- naming neither the comment, nor
  the line, nor the fact that the text they were in had been consumed. Erlang has
  both comment forms and the `%%` one does **not** win. `AGENTS.md` §5 lists `band`
  binding tighter than `-`; this is the same family, and the same lesson: the error
  names the token you can see rather than the structure you cannot.

- **Cross-implementation reading finds what fixtures cannot.** Every EIP-7702 defect
  in the last two commits was found by the corpus, by an injection, or by me
  reasoning -- and the one that survived all three was EIP-7702 **step 4**, one line
  of `execution-specs`' `validate_authorization`, which no fixture in this repository
  exercises and which two of my own tests had walked past. The corpus is a
  *sampling* of the specification; another client's source is a *reading* of it, and
  the two fail differently. A sampling tool cannot tell you about the part of the
  corpus you do not have, and a third implementation is a second opinion about the
  part you do.

- **A control that crosses a difference the subject does not have in common measures
  the difference.** The step-4 test's second control compared a **type-2**
  transaction (no authorization list) against a **type-4** one, and asserted a
  2,500 gap. It measured **-22,500**: the two types differ by EIP-7702's 25,000
  authorization price, which is 90% of the answer. The control is now an *absolute*
  figure with its decomposition written out -- 21,000 + 3 + 2,600 + 2 = 23,605 --
  which pins "cold" without comparing across transaction types at all. The 2,500
  comparison belongs to the first test, where both arms are type-4.

- **A gas figure that is exactly the intrinsic is a frame that did not run.** The
  step-4 helper inherited its `to` from a shared fixture builder, which defaults to a
  codeless account, so both arms came back at **46,000** -- 21,000 plus the 25,000
  authorization price, and *nothing else*, with `status = 1`. The frame executed no
  code, and the difference read as a confident 0. The signature is the number: a
  figure that lands exactly on a sum you can name from the transaction's own fields
  is not a measurement of anything the frame did.

- **A number rendered in a notation you have not read is a number you have not
  measured.** The EIP-3860 divergences printed as `gas delta -10#200w`, and I read
  that as **-1,048,576** -- a power of two, which looked like a real finding about
  initcode sizing. `~+w` renders an integer in Erlang's `10#<digits>w` form, so it
  is **-200**. One `erl -eval` printing `-199`, `-1048576` and `-524287` through the
  same format would have said so immediately. The tell was available the whole time
  and I used arithmetic on a string: the two sample deltas differed by exactly 1,
  which is implausible for a 49,152-byte initcode and obvious for two adjacent
  integers. **Two values in a set that differ by 1 are adjacent integers, whatever
  their magnitude suggests** -- and the general form is §10a's "a value no
  arithmetic can produce means the expression is not what you think it is", applied
  to output rather than to source.

- **A hypothesis that fits every number except one is not a diagnosis.** The best
  current explanation of the EIP-3860 create-gas divergence is that the node charges
  `G_codedeposit` for one byte fewer than it deploys: it fits the -200 entries
  exactly, a 2-byte deployment costs 400, and the node returns 200 more gas than the
  fixture does. It does not fit the -199 entries, and 199 is not a multiple of any
  deposit. Recorded in `TASKS.md` item 6g **as a measurement with a suspect**, with
  the one measurement that would close or kill it written down, and with no code
  changed. A consensus constant is the last place in this repository where "it fits"
  is allowed to stand in for "it is".

- **A test whose fixture produces no refund cannot see a refund rule, and it fails
  by looking correct.** The EIP-3529 cap test swept the calldata length from 1 to
  1,800 bytes and got `gasUsed` differences of *exactly* `4 * K` at every point --
  which reads as "the cap's base does not depend on the calldata", the exact wrong
  answer, and would have been recorded as a refutation of the fix. The fixture
  wrote **0 into slots that were already 0**, and EIP-2200 gives no refund for that
  at all: original 0, current 0, new 0 is the no-op arm. So the raw refund was zero
  and both arms were identical whatever the cap said. **The assertion to write
  first is that the thing under test happens at all** -- here `?assert(A > B)`,
  "the frame refunds", one line, and without it every other claim is about zero.
- **Two arms whose difference is an exact identity are a warning, not a result.**
  `diff = 4 * K` for nine values of `K` is not a measurement; it is the shape two
  arms have when they differ by exactly the one thing you told them to differ by.
  The same signature appeared twice in one test: 46,000 in both arms (a frame that
  never ran) and 0 in both arms (a refund that never happened). An exact linear
  relationship across a sweep is the tell.
- **A test that does not set `base_source` can reach the network, and the trace
  points four frames below the opcode.** The cap test builds a state by hand and
  calls `eth_evm:run/6` directly, so nothing set the process-wide base. The first
  `SSTORE` read a slot nothing had declared, the read fell through to the upstream
  RPC, and the test sat in `eth_rpc_client:do_call/4` until it timed out -- the
  trace naming the RPC client, not the transaction that triggered it. `with_ctx/1`
  is not ceremony around a test that touches state; it is the only thing standing
  between a unit test and a live fetch.

- **"The corpus does not exercise it" is a claim about a *named* corpus, and this
  commit is the proof.** EIP-3529's cap base (`v1.65-refund-cap-base`, 2026-09-30) moved
  the committed subset 226 -> 249 of 266 and moved the 22-file set **not at all** --
  3,831 of 3,884 before and after. Both are true. The 22 files are
  transaction-*validity* fixtures with almost
  no refundable work; the committed subset is the smallest file per suite and is
  gas-execution heavy by accident. Three corpora are now in regular use here and
  they disagree, so a sentence about "the corpus" names nothing. Write the
  directory.

- **A default can be the right answer, and the mirror image of
  `eth_tx:intrinsic_gas/1` is not a hazard.** `eth_evm:run/5` is a bare frame with
  no enclosing transaction, so its refund cap's base is the frame's own gas, and it
  passes 0. An `eth_call` and a system call both charge no intrinsic to anyone, so
  there the frame's gas *is* the transaction's gas used. The hazard in this
  repository's own tables is a parameter whose default is **wrong** and whose
  correct form has other callers; this is a parameter whose default is right for
  most callers and which the one remaining caller overrides explicitly. The test
  that tells them apart is one line, and without it the default was unpinned --
  the injection that gave `run/5` a hard-coded 21,000 changed nothing, because no
  fixture in the suite runs a *refunding* frame through the bare entry point.

- **An injection can refute the *reason* a fix is written where it is, and the
  comment usually keeps the refuted reason.** The EIP-161 nonce belongs where EELS puts
  it — `process_create_message/1` calls `increment_nonce` *before* `process_message`,
  and takes a `copy_tx_state` snapshot so an exceptional halt rolls it back. The fix
  therefore wrote it on the state handed to the init code, and the comment said that
  was **load-bearing**: all four failure branches of `create_with_value/9' return
  `State1'` and so discard it. Then the injection moved the write to the obvious
  tidier place — the success arm, beside `set_code/3'` — and **every test passed**.
  Both placements agree on every reachable state, because the failure branches return
  the state from *before* the write either way.
  - The general form: **"this is where the specification puts it" and "this is where
    you can tell the difference" are two different sentences**, and writing the second
    when you have only established the first is the §4.3 failure in its quiet form. A
    placement can be correct by fidelity to the spec and untestable here, and both
    facts belong in the comment — the second especially, because the next person will
    otherwise assume a test is holding it in place and move it.
  - It was found only because the injection was aimed at the *reason* rather than at
    the code. "Delete the line" tests presence; "delete it and put it somewhere else
    that also satisfies every test" tests the claim.

- **A program with no jump runs into whatever bytes follow it, and `RETURN` versus
  `REVERT` in those bytes decides whether the *outer* frame succeeds.** Every fixture
  for a `CREATE` here is a driver followed by the init code it `CODECOPY`s, and the
  driver ends with `SSTORE` — so the outer frame carried straight on into the init
  code. The deploying arm still reported success, because `RETURN` is a successful
  halt and `run_t` answers `{ok, Out, ...}' for it; the reverting arm made the
  **outer** frame revert. The test was asserting an absent account in a state whose
  outer frame had never finished, and no branch under test was being taken.
  - The tell was the revert **payload**: 32 zero bytes, for a `MSTORE` of 42 that had
    just run. Memory the frame itself wrote cannot be zero.
  - The fix is a `STOP` fence between driver and init code, and the driver lengths
    (**18** bytes for `CREATE`, **20** for `CREATE2`) are *matched*, not assumed.

- **A frame's memory is scratch, and its code is not in it.** `eth_evm` keeps the code
  in `#e.code` and zero-extends `#e.mem` in `charge_mem/2`. `CREATE` reads its init
  code with `read(E, Off, Len)`, which is `binary:part(E#e.mem, ...)` — so an init code
  that is merely *present in the program text* reads back as zeros. That is correct
  behaviour and not a node defect: a real contract puts init code in memory with
  `CODECOPY` or `CALLDATACOPY`, which is what the corpus does.
  - The failure is silent and looks like a working create. `CREATE` pushed a real
    address, the account existed, the nonce was 1 — and the deployed code was `<<>>`.
    **Every pre-existing create test in `eth_evm_tests` passes `Len = 0'**, so nothing
    in the module had ever noticed.
  - The general form: **an absent assertion is not a passing test.** "The create
    worked" was inferred from a real address and a live account, and both were true of
    a create that deployed nothing. Assert the code before the nonce, always — the
    deployment is the thing the other assertions are about.

- **A helper that reconstructs a value carries a precondition nobody checks.**
  `would_create/1` rebuilds the create address as `keccak(rlp([sender, nonce]))` with
  the nonce *before* the increment, so it is valid **only on a state whose sender nonce
  has been rolled back**. An injection that made the deposit-failure branch keep the
  child's state — no longer rolled back — left the helper naming a different address,
  and the test asserting *no account exists there* passed, because it was checking an
  account that had never existed.
  - The general form: **an assertion of absence passes for the wrong reason whenever
    the thing reconstructed could be wrong**, and a reconstructor is a second
    implementation with an unwritten precondition. Two of these were written in this
    session; one was deleted, and the survivor's precondition is now stated at the
    definition rather than at the call.

- **A fork *name* read as "old" is a rank asked for by a name.** The pre-Spurious-Dragon
  arm of the EIP-161 fork test used `byzantium`, and failed correctly:
  `fork_rank(spurious_dragon)` is **4** and `fork_rank(byzantium)` is **5**, so
  Byzantium is two forks *after* the rule. The pre-SD forks are `frontier`,
  `homestead`, `dao` and `tangerine_whistle` at ranks 0 to 3. This is §10a's
  "a function that takes a name may be handed a label" again — and the schedule's own
  comment records that it had the same bug once, when `byzantium` was rank 0 and
  `at_least(frontier, byzantium)` was true.

- **A per-fork table cannot tell "this fork's rule is refused" from "one suite in
  this fork is broken", and a number attached to the first reading is a guess with a
  decimal point.** This repository carried "**constantinople at 29.7%** is where
  EIP-1283's `SSTORE` is refused" in `TASKS.md` for a commit. The per-suite
  instrument says `eip1014_create2` is **131 of Constantinople's 135** divergences and
  `eip145_bitwise_shift` is 3, and that the only two entries the directory runs at a
  Constantinople fork are `ConstantinopleFix` — which is *Petersburg*, where the rule
  is the reverted flat one, not EIP-1283's. **EIP-1283 is worth zero entries there.**
  - The general form: **a rate is not a cause**, and the axis you happen to have is
    usually the wrong one. Fork is the axis the corpus is *keyed* by, which is a
    reason it is easy to measure and no reason it is where the answer lives. This is
    `v1.61`'s "a tally is not a work list" reached from the other side: there the
    instrument measured the wrong quantity, here it measured the right quantity on
    the wrong axis.

- **An oracle answers the question you ask it, and the question is the easy part to get
  wrong. Install one before you edit, not after.** `geth` 1.17.7 came from the Homebrew
  `ethereum` bottle — which ships **`evm` as well as `geth`**, so `evm run` and `evm t8n`
  are both there — and one invocation settled in a minute what four rounds of reading had
  got backwards. `PUSH1 2, PUSH1 3, EXP` returns **9**, not 8: `push/1` conses, so the
  operand pushed *last* is what `EXP` pops first, and that is the base. A program computing
  `Base ** Exponent` therefore pushes the exponent **first**, which is the opposite of what
  the handler's own variable names invite a reader to assume. Eight programs agree, and the
  pair that actually separates the two readings is `PUSH1 5, PUSH1 0, EXP -> 0` against
  `PUSH1 0, PUSH1 5, EXP -> 1` — a two-byte program, no gas figures, no large operands.
  - **And the "confirmation" was circular.** The Yellow Paper was misremembered as
    `mu_s[0]` being the exponent, the pops were swapped, and the swap was then verified by
    a probe — **run against the tree I had just edited**, so it measured my own change.
    The general form is already in this section as "a test that asserts a defect and argues
    for it", and it has a sharper twin: **a measurement taken against a tree you have just
    changed is a measurement of your change.** A probe is only evidence about the code that
    was there before you touched it.
  - **The rule that follows is about ordering, not about care:** for anything a second
    implementation can answer, **ask it before editing**. The cost of asking is one command
    and the cost of not asking here was a regression introduced into correct code, defended
    by a measurement that agreed with it.

- **A wrong EIP citation is a defect that hides behind its own plausibility, and it is the
  cheapest defect in this repository to ship.** `EXP`'s gas comment cited **EIP-2565**, which
  is MODEXP's repricing — opcode 0xf0, a different instruction whose cost genuinely *is* a
  product of a base's and an exponent's widths. The code read `max(byte_size(base),
  byte_size(exponent))`. EIP named a product of two widths, the code took a product of two
  widths, and **nothing in the file invited the question.** The real rule is **EIP-160**,
  which measures the exponent and says nothing about the base: *"increase the gas cost of
  EXP from 10 + 10 per byte in the exponent to 10 + 50 per byte in the exponent."* A 32-byte
  base with an exponent of 0 was being charged 1,550 gas for nothing.
  - The general form: **a citation is an assertion about where a rule came from, and a
    plausible-looking rule under a plausible-looking citation needs no further reading.**
    Compare "a specification rewritten into a nesting", where the rewrite was *more
    elaborate* than the original. Here the rewrite is not more elaborate — it is exactly as
    elaborate as a real rule in a neighbouring opcode, which is why it survived review and
    review again.
  - **The cheap guard is to fetch the cited EIP, not the correct one.** Asking "is EIP-2565
    really this?" is one web fetch and settles it. Asking "which EIP is this?" from memory
    is what produced the defect in the first place.

- **A fork boundary is not "an old fork and a new fork", and a sample that straddles
  nothing looks exactly like a rule that does nothing.** Spurious Dragon is block 2,675,000
  and Byzantium is 4,370,000, so **Byzantium is after it** and already costs EIP-160's
  post-SD price. The first fork sweep was `byzantium` against `cancun`: both arms 66, and a
  working gate looked broken. The pair that straddles the rule is **Tangerine Whistle and
  Spurious Dragon** — 26 against 66, a difference of exactly 40, which is the whole of the
  EIP. This is "a figure that does not move across a boundary is measuring the wrapper"
  reached from the fixture side: **the sample has to be chosen from the rule's own
  activation numbers, and `eth_fork_schedule' holds them, so the choice is derivable rather
  than guessed.**

- **Four different fixture defects, one symptom: empty output.** `evm t8n` never ran, and it
  is worth listing because *every* failure printed the same thing.
  - It requires a **signed** transaction — a bare `{from, to, gas, …}` is rejected with
    `missing required field 'r'`.
  - The signature's preimage named a **different `to`** than the emitted transaction, so
    geth recovered a *different sender* than the one that had been funded.
  - `"v": "0x37"` written with `~p` (decimal 37) in a **hex** field, so the chain id came out
    as 10 and the message was `invalid chain id for signer: have 10 want 1`.
  - The **code was on the sender**, which geth refuses with `sender not an eoa`.
  - A **mixed-case** alloc key is a different account to the trie, so a funded address read
    as unfunded.
  - **The general form is §5's "a test must never perform a lazy upstream fetch" with the
    sign flipped: a broken fixture and an absent measurement are the same output.** And the
    asymmetry is the trap — *a working fixture that finds nothing* is reported, and *a
    broken fixture that finds nothing* is silently believed. When an instrument returns
    empty on a rule you have just written, **the instrument is the suspect before the rule
    is**, and the way to tell them apart is to make it return non-empty on something known.
    A harness that cannot produce a positive result cannot produce a negative one either.
  - And `evm run` needs **no signature at all** and answered the operand-order question in
    the first attempt. **Reach for the tool that needs no fixture before the one that needs
    a correct one** — `evm run <code>` prints the returned word and `evm t8n` prints a gas
    figure, so the cheap one covers the semantics and only the expensive one needs the
    signature to be right.

- **A figure is laundered by the figure next to it, and this repository hit that three
  times in one afternoon.** A test that checks "is this number attributable?" passed on all
  three stale conformance figures until the *unit of attribution* was fixed. The failures were
  not clever and each was a plain instance of the same shape:
  - a **table row** is one block, so `v1.49-full-corpus-measured` — written to date the
    full-corpus figure *in the same cell* — vouched for the committed-subset figure beside it.
    Putting `250 of 266` where the pin belonged passed, because a version tag 40 characters
    away said so.
  - a **whole markdown section** is one block if it has no blank lines between its items.
    TASKS.md's "Phase 8: Testing & Verification" is **68 lines and 8,505 characters** with no
    blank line between list items, and carries a `v1.N` belonging to a different item.
  - a **single date** in a block was accepted as attribution at all, and `2026-10-03`
    belonging to one figure vouched for `250 of 266 now` beside it.
  - **The general form: attribution is a property of a claim, and a claim is one item.**
    So the block boundary is a markdown item — a table row, a list item, a heading, a
    paragraph — not a paragraph and not a line. And **a date is not a measurement**: "when"
    is not "which measurement", so only a version tag counts.
  - **And a residual, stated rather than hidden:** the longest item in those three files is
    **322 lines**, and a `v1.N` anywhere in 322 lines still vouches for a stale figure
    anywhere else in them. Per-*sentence* attribution is not mechanical in markdown. What
    bounds it is that the item splitter is asserted to split at all.

- **A splitter that silently does not split still returns a plausible list, and a count is
  the only thing that notices.** The block splitter existed in **two copies**, and the first
  version of the fix put the *starter* line into the output list instead of into the new
  accumulator — so nothing after it was ever accumulated. **README's 1,306 lines produced 5
  blocks** that way, against 370 with the one-line correction, and the function returned a
  list of lists at every step and crashed at none. The tell was not the failure; the tests
  passed. The tell was `?assert(length(Blocks) >= N)`, which exists only because
  `string:lexemes/2` had already made the same class of bug visible once. **A count is a
  measurement of the thing that produces the list, not of the list.**

- **An injection that breaks the build reads as "no effect", because it produces no output —
  and the classifier that is supposed to prevent that reading was itself wrong three times.**
  Rewriting `starts_item(Line)' to `starts_item(_Line)' and leaving the body left `Line'
  unbound; `warnings_as_errors` turned it into a compile failure; the harness grepped for
  test names and printed **nothing at all**. Nothing is the same shape as "the injection did
  not bite", and reading it that way would have retired a working injection. AGENTS.md
  already says an injection that orphans a helper proves nothing about the test — this is
  the harness half of that sentence: **a build failure must be reported as
  `BUILD-BROKEN`, not as silence**, and the cheap check is the one this repository has
  already been bitten by, *"read one line of the harness's own output against one known-good
  run before believing the other six."*
  - **Three later attempts at the classifier, and every one of them wrong in the direction
    that hides evidence.** The second recognised a build failure by grepping for `error:`
    — and eunit's own failure line is `**error:{assertEqual, ...}', so **every red test was
    reported `BUILD-BROKEN`**, which is the verdict that proves nothing. **A pattern that
    matches more than it means is a measurement of the pattern**, and this is the third time
    in this file that sentence has applied (`re:run/3`'s first match, `pairs\(' inside
    `parse_pairs(').
  - The third was a `case $V in red) ... green)` over upper-case verdicts. `case` is
    case-sensitive, so **all five injections reported `MISMATCH` — including the two that
    were `RED` and the three that were `GREEN`.** A harness that reports disagreement for
    the right reason on every row is worse than one that reports agreement, because it looks
    like the harness is working.
  - **The general form: a verdict classifier is part of the experiment, and it gets the same
    scepticism as the code it interrogates.** All three were found the same way — by reading
    one line of real output against the classifier — and none would have been found by
    re-reading the classifier.

- **`printf '%% the old ...'` writes one percent sign, because `printf` collapses `%%` into a
  format escape -- and a single `%` is not a comment in Erlang.** An injection was meant to
  add a *comment* mentioning `hex_to_bin(` and prove the guard ignores comments. It appended
  `% the old hex_to_bin( and hexval( ...`, the guard went red, and for several minutes the
  guard looked like it had a false positive. It had not: the injected line was not a comment,
  it was **a syntax error that happened to be lexically legal**, and `strip_comment/2`
  requires *two* percent signs precisely because one means nothing in Erlang.
  - **The general form is the one above, one level down: the instrument was right and the
    probe was malformed, and the way they are told apart is to read what the probe actually
    wrote.** `tail -2` on the file answers it in one command, and it took three probe modules
    and an `erl_crash.dump` to ask. The one thing that would have answered it immediately is
    the one AGENTS.md already asks for after any probe: **check the shape of the thing you
    just wrote against arithmetic you can do on paper** -- one line, `%%`, versus the one that
    arrived.

- **A restore path that is wrong makes every injection stack, and three agreeing verdicts
  are not three results.** An injection harness stored its pristine copies as
  `$DIR/eth_chain.erl.pristine` and restored from `$DIR/src/eth_chain.erl.pristine`. Every
  `cp` failed, so injection 2 was applied on top of injection 1 and injection 3 on top of
  that, and the run reported **three `BUILD-BROKEN` verdicts that were really one missing
  file three times**. What caught it was `diff` against the pristine copy — which is
  AGENTS.md's rule after a killed script — except that the script's own end-of-run
  verification used **the same wrong path** and so could not have caught it either.
  - **The general form is a filter is a measurement of the filter, applied to the harness's
    own plumbing**: a verification step that shares its path expression with the step it
    verifies checks nothing, and three identical answers are the signature of one fault
    rather than of three findings.

- **`$\|` is a perfectly legal Erlang character literal — it is the pipe — so a clause that
  means `%` compiles, returns, and does nothing.** A comment-stripping helper for the hex
  ownership guard was written
  `strip_comment([$%, $\|Rest], N) -> ...`, and it truncated only where a `%` was
  immediately followed by a literal `|`, which is not a comment. So it stripped **nothing**,
  and the guard then reported the four comments written to record the deletion as four
  offenders. `erlc` had no opinion, because `$\|` is a valid `char()`.
  - **Three other versions of that one line were wrong too**, and all four compiled and
    returned: `binary:part/3` on a *string*, a nested list handed to `re:run/3`, and a
    dropped newline that let `;hex_to_bin(' form across a line boundary. **The count was the
    only thing that showed any of them**, which is why the guard asserts the number of files
    it scanned and asserts the offender count *before* the offender list — eunit truncates
    the list, and a truncated list reads as a whole one.
  - **The general form is `~/T(...)` and `band`-binds-tighter-than-`-`, one level down: the
    error names the token you can see and never the structure you cannot.** Here nothing
    named anything, which is why the guard was the only instrument that could.

- **An unreachable defensive branch is proved by an injection, not by a plausible test.**
  `eth_chain:verify_blocks/4` picks a block's parent from two candidates and lets the
  block's own `parentHash' choose. Deleting that comparison **passes the whole suite**. The
  first response was to write a test for it — a batch that skips a block the store already
  holds — and it failed with `{missing_parent, _}`. That is the answer: a batch starting
  below the head rewinds to the common ancestor and drops everything above it, so the second
  block of a batch can only ever link to the first, and `do_append/2`'s `missing_parent`
  catches a gap before the validator is reached. **The test was asserting a shape the store
  cannot be given**, so it was deleted and the unreachability written at the check, naming
  the injection as the evidence.
  - This is AGENTS.md's EIP-161 nonce placement again: *correct by fidelity to the
    specification and untestable here are two different sentences, and both belong in the
    comment.* The specific trap here is that **a plausible test for an unreachable branch
    will usually be written, will usually fail, and the failure will usually look like the
    node being wrong** rather than the fixture being impossible.

- **A fixture column that nothing reads, and a test that asserted on the wrong element
  because of it.** `eth_rpc_extra_tests:chain_blocks/2` took the first entry of its list as
  a *seed* and recursed on the rest, so it never built genesis: a three-entry fixture
  returned two blocks. Every later block's base fee was then derived whatever the list said,
  so the `0` that spells "this block has no `baseFeePerGas` field, it is pre-EIP-1559" was
  discarded — the parameter was named `_BaseFee`. And `a_pre_eip_1559_block_reports_a_zero_
  base_fee_test` asserts on `lists:nth(2, Blocks)` with a comment saying "**Block 1** of the
  fixture", so it believed the list was `[0, 1, 2]`. It was `[1, 2]`, the assertion was
  checking block 2, and **it had been failing for as long as the base fee moved** — which is
  why it was filed as a base-fee bug and was not one.
  - **The general form is AGENTS.md's "a key written through one normaliser and read through
    another", where the normaliser is an argument.** Nothing reads an argument named
    `_BaseFee`, so the compiler is silent and the fixture is quietly a different fixture
    from the one its comment describes.
  - **And the tell was a comment disagreeing with an index.** "Block 1" beside `nth(2)` is a
    shape that can be checked by reading, and nobody read it because the test was failing for
    a reason that had nothing to do with it. A comment that names an *element position* is a
    claim about the data, not about the code, and it decays like any other published figure.

- **Seven injections, and the first version of the test passed four of them — including all
  three stale figures it was written to catch.** `RELEASE-GATE.md`'s own header says what
  happens next: *"a gate that reports `PASS` for something nobody runs is worse than no
  gate: it stops the checking."* A gate that has never been made to fail is not a gate, it
  is a comment with assertions in it. The three that passed were caught only by narrowing
  the block unit, and each narrowing was a **real improvement to the documentation** rather
  than a concession to the test: every conformance figure is now stated next to the
  measurement it belongs to, which is what the gate asked for in the first place.

- **A message blaming one side of a comparison is a claim about the instrument, and
  this one was wrong.** Every entry of `stTimeConsuming` reports `no_comparable_gas`
  with the reason *"one side produced a gas figure and the other did not"*. The node's
  receipt **does** carry a `gasUsed`. The harness reaches the node's figure by
  *inverting the balance difference*, which is impossible when the difference is not
  divisible by the price, so the correct reason is "the node's figure could not be
  recovered", and the message as written says the *fixture* produced nothing — which
  is true of these fixtures (their `post` keys are `['hash','logs','txbytes',
  'indexes','state']`, with no `gasUsed`) and is **not** the reason for the failure.
  - The general form: **an instrument that reports a cause should be able to name
    which side it is talking about, and a message that always names the same side is
    a message that has been read once and copied.**

## 11. Known dead code

- `eth_state_management` and `eth_block_hash_oracle` were **deleted** 2026-10-03, and
  the two facts that made them a hazard rather than merely dead are worth keeping.
  Neither was ever a child of `etherlang_sup`, and `eth_state_management` had **zero**
  callers in `src/`. `eth_block_hash_oracle` looked less dead -- it has five call sites --
  but every one of them is inside `eth_state_management`, so it was unreachable for the
  same reason. **A dead cluster is not two dead modules**, and a grep for one qualified
  name would have called the second one live.
  - The part that made deleting them better than documenting them: three of their
    functions **reported work they did not do**. `prune_recent/1` computed `_KeepFrom`,
    carried the comment `%% Prune blocks older than KeepFrom`, and returned
    `{ok, pruned}`. `expire_state/1` computed `_ExpireAt`, carried `%% Expire state
    older than ExpireAt`, and returned `{ok, {expired, _ExpireAt}}`. Neither touched a
    store. Documenting that would not have helped, because the next reader's problem is
    not knowing the modules exist -- it is seeing `{ok, pruned}` and concluding state
    pruning is implemented.
  - **Three of seven Phase 4 checkboxes in `TASKS.md` were marked `[x]` on the strength
    of these two modules**, and are now `[ ]` again: state pruning, state expiration and
    the block hash oracle. That is the same defect §11 already records for
    `eth_block_builder` and `eth_engine`, in a third place, and it is the reason the
    ledger was the thing to fix rather than the code. The other four Phase 4 items are
    honest -- `eth_chain` really keeps a hash and transaction index, `eth_mpt` really
    persists to DETS, and `snapshot/0`'s own comment says plainly that it is a dump of
    the in-memory maps and not a persistent trie.
  - They were also listed in `etherlang.app.src`'s `registered`, which claimed 16
    processes and named 14. **A `registered` list is a claim a reader will check**, and
    it was the one place in the tree where the claim was wrong in the direction of
    making the node look more complete than it is.

- `eth_block_builder` **is now started** and issues `payloadId`s. It was rewritten
  rather than switched on: the dead version assembled a block as a map with its own
  header constants, three of which were wrong in ways already found and fixed in
  `eth_block` (a 24-byte nonce, the empty trie root standing in for the uncle hash,
  the same substitution for the transactions and receipts roots) and it discarded
  every `payloadAttributes` field. It builds through `eth_block:new/3` now.
- `eth_block:to_rlp/1` and `eth_block:hash/1` are **gone**, and this section listed
  them as "unused in `src/`, tests only" — which a grep showed was true of neither.
  `to_rlp/1` was a *second* header encoder that emitted nineteen fields
  unconditionally: the fifteen of Frontier, then `baseFeePerGas`, then
  `withdrawalsRoot`, then EIP-4844's two blob fields. So it was wrong at every fork,
  and at Cancun it was short and long at once because EIP-4788's
  `parentBeaconBlockRoot` had no term in it. The live encoder is
  `payload_header_rlp/4`, selected by the fork the payload describes and pinned
  against three real Sepolia blocks. **Deleting the pair is the fix, not a
  fork-aware rewrite of it** — a rewrite would have been a third encoder to keep in
  step with the other two, which is the `eth_evm:base_cost/1` mistake again with a
  block hash instead of a gas table.
- `eth_block:header/1` **is** used — by `to_payload/1`, on the `engine_getPayload`
  path — so it was not deleted. A grep for `eth_block:header` missed it because the
  call is unqualified and intra-module; grep for the *definition's callers*, not for
  its qualified name. It used to report `baseFeePerGas` as `0x0` on a header with no
  such field, and a zero there is a value a consensus client reads as an answer.
  Absent fields are now absent.
- `eth_header:header_fields/0` lists `requestsHash` **last**, which is correct and was
  nearly "fixed" into a regression. EIP-7685 does not state where the field sits in the
  RLP list, so I removed it and made `eth_header:hash/1` refuse a block carrying it —
  on the reasoning that appending was an invented position. The real Sepolia header
  already committed in `eth_header_tests:sepolia_block/0` is a Prague block, carries
  the field, and claims the real hash; appending last reproduces it exactly, so the
  refusal would have left this node unable to hash a real Prague block it had been
  getting right. Two further mistakes in the same reasoning: I read the field's value
  `0xe3b0c442...` as SHA-256 of nothing and therefore hand-entered, when it is what
  the network reports (with EIP-7251 there are no requests to commit to) and
  `eth_getBlockByNumber` returns it verbatim; and I read the fixture's timestamp as
  pre-Prague, when 1,789,629,872 is long past Sepolia's Prague activation.
  The rule this follows is §4.2's — a value that cannot be derived is pinned by a test
  against real data — and the point is that the pin already existed and I read past
  it. `requestsHash` was never "inert because upstream JSONs do not carry it": upstream
  JSONs **do** carry it, from Prague on.
- **A price the node does not charge is worse than one it charges wrongly.**
  `G_codedeposit` was absent from the execution path entirely, so a `CREATE` deployed
  code of any size for free. The corpus found it as a −918,145 gas delta on seven
  fixtures of one file, and the giveaway was the *size* of the number: a gas bug that
  large is not a mispriced opcode, it is a missing term. Read the histogram for
  magnitude, not just for repetition — a −2,100 repeated 40 times and a −918,145
  repeated 7 times are the same kind of evidence and they point at different things.
- **EIP-2929's `SSTORE` clause has two halves and they are separable.** Rewriting
  EIP-2200's `SLOAD_GAS` and `SSTORE_RESET_GAS` is a change to `sstore_cost/4`; charging
  the additional `COLD_SLOAD_COST` for a cold slot is a *separate* term. Implementing
  the first and not the second is a coherent-looking table that is wrong on every first
  access, and it is wrong in a way a test repeating an access cannot see.
- **A gas assertion needs a control that could have been different.** The first version
  of the return-data test ran one failing `CALL` and asserted `RETURNDATASIZE == 0`. It
  passed with the `evm.return_data = b""` line **deleted**, because nothing had ever
  set the register. The injection was the only thing that found it. Put the successful
  call in front of the failing one, and assert the control's value too.
- **`f([A, B]) -> ...` is `f/1`.** Not `f/2`. Every probe in this repository's history
  that exported `main/2` for a `main([Dir, Needle])` head failed with "function main/2
  undefined, did you mean main/1?" and it cost real time twice, because the error reads
  like the compiler being wrong about the arity of its own export. It is not.
- **A seeded set is not a seeded set until the key matches.** `precompile_addresses/1`
  first built one-byte binaries, because `precompile_at/2` is keyed on the address's last
  byte. Every seed was then a key no 160-bit address could equal, and the corpus did
  not move at all — an access list that is present, correctly shaped, and inert is
  indistinguishable from one that was never seeded. Twenty-byte is a length, and lengths
  are where this goes wrong.
- **Read a histogram in full.** Concluding that `+56665`/`+56668` had "dissolved" from
  `head -30` of `h5`'s output, which cut them off, was an unsound observation that
  happened to be right. The verification came later, untruncated, and by then the
  conclusion had been in TASKS.md for a commit.
- **`unsupported` is not one thing.** `eth_evm_precompiles:precompile/3` has three
  answers: `{ok, Output, GasCost}`, `{failed, Why}` (the EVM's answer is that the call
  fails — nothing returned, forwarded gas consumed, caller carries on), and
  `unsupported` (this node cannot run this at all, and `eth_block:run_transaction/5`
  refuses the block). It had two, and they were conflated in both directions: blake2f
  and the pairing check reported *rejected input* as `unsupported`, which the block
  layer reads as a missing implementation, so seven `eip152_blake2` fixtures — whose
  DELEGATECALLs carry zero-length calldata, where the call should simply fail —
  refused the whole block. `ECADD` and `ECMUL` still conflate them; named in TASKS.md.
- `eth_rpc_server:start_engine_api/2` **no longer** swallows a listener failure. It
  logged the error, returned `ok`, and `init/1` ignored the answer anyway, so a node
  whose Engine API port was taken came up reporting success with the Engine API
  silently absent. It is now `{stop, {engine_api, Reason}}`, like every other listener
  failure in that `case`. The no-JWT-secret case is unchanged and still starts the
  node: that is a 503 from the *handler*, and refusing to boot would be a much worse
  answer to a scheme whose point is refusing to serve.
- `eth_block:run_transaction/5` is exported for the conformance runner. It is not
  test-only -- `finalize_against/5` is its production caller -- but note that
  `finalize/1` **cannot** serve a caller holding its own pre-state, because it
  resolves the parent's state root through `eth_chain` and then requires the local
  MPT to *hold* that root. A state test is the opposite case.

## 12. Next up, in order

The authoritative version of this list is the "What to do next, in order" section at
the top of `TASKS.md`, which also records the Engine API work that is deliberately
**later** and why. Kept here only as a pointer, because this file is read more often.

1. Run the EEST fixtures and record what fails. Nothing in this repository has
   been checked against `execution-specs`, and that is the only remaining
   precondition for trusting any state-root claim this node makes.

Done, and no longer listed:

- Per-fork gas *pricing*, including SSTORE. `eth_fork_schedule` is the execution
  path's only source of prices, `eth_evm:base_cost/1` is deleted, and every rule
  above is fork-selected. Getting there found live bugs rather than confirming
  the schedule: a no-op `SSTORE` was overcharged by 2700 gas net, a dirty write
  was priced as a clean one, `ADDRESS` cost 3, and EIP-161's terms were gated on
  the wrong fork. See §3 "Fork awareness".

- Per-fork opcode *availability*. `eth_fork_schedule:opcode_exists/2` answers
  whether a fork has an instruction, and `eth_evm` halts on one it does not. Every
  clause in `do_op/3` used to be unconditional, so PUSH0 ran in a Paris block and
  TSTORE ran anywhere before Cancun, each returning successfully. The fork reaches
  the interpreter through a **required** `fork` key in the Env; do not give it a
  default. `fork_rank/1` also had to stop collapsing Frontier-through-Petersburg
  into one rank, because with `byzantium` at rank 0 `at_least(frontier,
  byzantium)` was true and the gate was inexpressible. Muir Glacier still shares
  Istanbul's rank on purpose.
- Payload-decoder work, committed and tagged `v1.10-versioned-engine`.
- `eth_block_builder` started and `payloadAttributes` acted on, so `forkchoiceUpdated`
  returns a `payloadId` and `getPayload` returns a real block. Its state root will not
  match the network's until the gas table is wired — that is item 1 above.
- The eight "missing" RPC methods. They were not missing so much as unexamined: a
  catch-all clause proxied every unknown method, so all eight answered — with another
  node's view. Seven now answer from this node's own state, in `eth_rpc_projection`,
  and each says what it is derived from. `eth_createAccessList` is the one that is
  genuinely absent.
- `with_ctx/1` + `store_parent/1` + the rest of the execution context, extracted
  into `eth_test_util`.
- Engine V2/V3, `forkchoiceUpdatedV3`, `getPayloadV3`, the `-32602` / `-38005` /
  `-38003` gates, and the `newPayloadV3` blob-hash check.

Later, recorded in `TASKS.md` with reasons: `engine_getPayloadBodiesBy*V1` (blocked
on raw transaction bytes the chain store does not retain), `engine_notifyHeaders`
(no clause found in `execution-apis`), V4/V5, and `engine_getBlobsV1`.

---

**Unverified claim, do not restate as fact:** "the gas schedule is the single
reason state roots diverge." It cannot be checked end-to-end without real
prestate.
