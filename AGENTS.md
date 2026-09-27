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
`docs/YELLOW_PAPER.md` describes the target architecture.

### Read these before claiming anything works

| File | What it is |
|------|------------|
| `README.md` | Feature status, honesty notes, config, layout. ~930 lines. |
| `TASKS.md` | The 81-task / 9-phase list. Every unchecked box is a real gap. |
| `docs/YELLOW_PAPER.md` | The design document for the v1.0 target. |

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

Erlang/OTP 29 (pinned in `mise.toml`). No CT suites exist; CI's
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

`eth_fork_schedule:current_fork/3,4` selects the fork. The gas *table*
(`gas_cost/3,4`) is fork-parameterized and unit-tested, but **nothing in the
execution path calls it** — the EVM applies one flat Cancun-era table. Wiring it
in is a refactor, not a substitution. It is a known, documented, unticked item.

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

## 10. Deliberately not done

Do not "fix" these by guessing. Each is listed in `TASKS.md`.

| Item | Why |
|------|-----|
| `eth_kzg:blob_to_kzg_commitment/1` | Needs the `g1_lin` derivation; no local blob fixture, and the EIP-4844 vector fetch 404'd. |
| EIP-7685 `requestsHash` | Hashing rule sourced, but the EIP does not fix the header field position, and without EIP-7251 there are no requests. |
| `TERMINAL_BLOCK_HASH` (EIP-3675) | Chain-config data, not in the EIP. Carried and echoed, never checked against a post-Merge block's difficulty. |
| Per-fork gas table wiring | A refactor, not a substitution. |
| `eth_block:to_rlp/1` fork-awareness | It unconditionally includes the Cancun trailing fields, so it is only correct for Cancun-or-later headers. Pre-existing, documented, unfixed. |

## 11. Known dead code

- `eth_block_builder` **is now started** and issues `payloadId`s. It was rewritten
  rather than switched on: the dead version assembled a block as a map with its own
  header constants, three of which were wrong in ways already found and fixed in
  `eth_block` (a 24-byte nonce, the empty trie root standing in for the uncle hash,
  the same substitution for the transactions and receipts roots) and it discarded
  every `payloadAttributes` field. It builds through `eth_block:new/3` now.
- `eth_block:hash/1`, `eth_block:header/1`, `eth_block:to_rlp/1` — unused in
  `src/`, tests only.
- `eth_header:header_fields/0` lists `requestsHash`, which is not a header field.
  Inert, because upstream block JSONs do not carry it.
- `eth_rpc_server:start_engine_api/2` still swallows a listener failure
  (`{error, Reason} -> logger:error(...), ok`).

## 12. Next up, in order

The authoritative version of this list is the "What to do next, in order" section at
the top of `TASKS.md`, which also records the Engine API work that is deliberately
**later** and why. Kept here only as a pointer, because this file is read more often.

1. Add the missing RPC methods: `eth_estimateGas`, `eth_feeHistory`,
   `eth_getTransactionByHash`, `eth_maxPriorityFeePerGas`, `eth_createAccessList`,
   `eth_getBlockReceipts`, `eth_getProof`, `eth_accounts`.
2. Wire the per-fork gas table into the EVM — a refactor, and a precondition for
   any state-root claim, and for a block this node builds being proposable.
3. Run the EEST fixtures and record what fails.

Done, and no longer listed:

- Payload-decoder work, committed and tagged `v1.10-versioned-engine`.
- `eth_block_builder` started and `payloadAttributes` acted on, so `forkchoiceUpdated`
  returns a `payloadId` and `getPayload` returns a real block. Its state root will not
  match the network's until the gas table is wired — that is item 2 above.
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
