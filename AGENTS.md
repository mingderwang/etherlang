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
§"Current Status" and `TASKS.md` are the authority on what is and is not done;
`docs/YELLOW_PAPER.md` describes the system model, the trust assumptions, and
the boundary between what the node does and what it is becoming.

### Read these before claiming anything works

| File | What it is |
|------|------------|
| `README.md` | Feature status, honesty notes, config, layout. |
| `TASKS.md` | The 86-task / 9-phase list. Every unchecked box is a real gap. |
| `docs/YELLOW_PAPER.md` | The design document: system model, trust assumptions, and the boundary between what the node does and what it is becoming. §1.3 is the list of things it deliberately does *not* claim. |

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

47 modules in `apps/etherlang/src`, 44 test modules in `apps/etherlang/test`.
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

  **The tally is not asserted and must not be.** It drifts between runs of the same
  code, because a storage read a fixture's code performs but does not declare falls
  through `base_source` to the local MPT, which is process-wide and shared with the
  rest of the suite. Seeding everything the fixture mentions removes most of it; the
  rest needs an isolated state base, and until that exists a pinned number is a test
  that flips.

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
- Tag each completed pass: `v1.N-<short-slug>`. Existing:
  `v1.9-engine-honesty`, `v1.8-admission-validation`, `v1.7-initcode-gas`,
  `v1.6-point-evaluation`, `v1.5-gas-tables`.
- Update the test count in `README.md` and `TASKS.md` with the same change that
  moves it.

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
| `TERMINAL_BLOCK_HASH` | EIP-3675 | Chain-config data, not in the EIP. Carried and echoed, **never checked** against a post-Merge block's difficulty. |
| Pre-Berlin `SSTORE` **at Constantinople** | EIP-1283 | The only fork still refused. EIP-1283 replaced the rule and Petersburg reverted it, so a single figure would be right for two spans and wrong at the third -- and wrong *only* at Constantinople is never noticed. Unreachable by block number on mainnet. |
| A warm-set entry keyed on a value the frame cannot name | EIP-2929/3651 | `initial_access/3` warms `coinbase` from the **Env** with `maps:get/3`, so an Env that omits it warms nothing. `maps:get/2` would have warmed `undefined`. `v1.45`. |
| EIP-7702's state transition | EIP-7702 | A type-4 transaction is priced, validated and executed as though it carried **no** authorizations. Decode, sender recovery and both validity rules are done. |
| `eth_createAccessList` | — | The one genuinely absent JSON-RPC method. |
| `eth_tx:intrinsic_gas/1` takes no fork | — | Falls back to the operator's `ETH_FORK` pin. Correct for pool admission, where no block exists; **wrong** for `eth_call`, `estimateGas` and block execution, which must use `intrinsic_gas/2`. Not a gap so much as a hazard: it is a one-argument function that answers correctly in the one place nobody calls it wrongly. |

### Closed by a decision, or fixed. Do not "re-open" these.

| Item | Which EIP | Where it ended |
|------|-----------|----------------|
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

## 10a. Three traps this repository has now paid for

- **A key is written through one normaliser and read through another.** `eth_state:new/2`
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

## 11. Known dead code

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
