# etherlang v1.0 — status ledger

**What is true now. How it was found is in [`apps/etherlang/doc/MEASUREMENTS.md`](apps/etherlang/doc/MEASUREMENTS.md).**

The measurement journal moved out of this file. It was lines 30–1393 of the previous
`TASKS.md` — the full-corpus re-measurement, the `stTimeConsuming` investigation, the
instrument history, and the write-ups of items 1–6 below, all completed. Leaving it
here meant a reader opening this file to find out what to do next read 960 lines of
finished work first, with the queue at line 986 and a header whose numbers disagreed
with the file it sat above.

> **Specification conformance is measured, not assumed.** The committed
> `execution-spec-tests` `state_tests` subset — 25 files, 266 entries — runs on every
> `rebar3 eunit` and its outcome is asserted by `eest_conformance_tests`. The figure is
> **255 of 266 (95.9%)**: `state_mismatch` 8, `fork_unreachable` 3, every other
> outcome 0. It stood at 226 of 266 (85.0%) up to `v1.68`, 2026-09-30 -- for several
> commits after the number itself had stopped being true --
> true; the pin and this header now agree, and the changelog that got them there is in
> the module comment of `eest_conformance_tests.erl`.
>
> **The subset is the smallest file in each suite, so it is the easiest ~2% of the
> corpus** — see `PROVENANCE.md` for the selection rule and AGENTS.md §10a for the
> measurement: 255 of 266 here against 6,786 of 15,660 (43.3%), measured at `v1.49-full-corpus-measured`, 2026-09-29, and **not re-run since**, on the 229 non-`static` files.
> Both are true and they are different measurements. **Quote the directory, never
> "the corpus".** The full run is a developer step (`eest_report`).
>
> The unper-fork detail that a conformance figure hides: Berlin 22/22, Byzantium
> 15/15, ConstantinopleFix 17/17, Homestead 3/3, Istanbul 18/18, London 22/22, Paris
> 22/22, Cancun 39/42, Prague 52/56, Shanghai 35/36, Frontier 0/2 (unreachable by
> block number in this node's schedule, not wrongly executed). Worst suite by
> divergence is **`eip6780_selfdestruct` at 0 of 5** — every entry, and it is named
> in the open findings below. Three suites present on disk execute **zero** entries:
> `eip7702_set_code_tx`, `eip7516_blobgasfee`, `eip4844_blobs`.

**Build and test.** `make counts` is the authority for the architecture numbers; do not
edit them by hand. `rebar.config` sets `warnings_as_errors`, so any warning fails the
build. OTP 29.1. Current: **49 src modules / 14,765 code lines, 65 test modules /
15,120 code lines, 1077 eunit tests, all passing.**

**82 tasks across 9 phases — 46 done, 36 remaining.** Counted, not asserted; re-derive
them with the procedure below rather than editing this sentence.

**This said 49 done and 33 remaining, and both were wrong by three.** The total, 82, was
right: every phase heading's own count matches the number of checkboxes under it, 14 + 12 +
7 + 8 + 13 + 3 + 7 + 8 + 10. The split was not, and the direction of the error is the
interesting part — **three boxes had been re-opened and the sentence was never updated**,
so the file claimed more finished work than it contained and correspondingly less
remaining. §11 records the re-opening: `eth_state_management` and `eth_block_hash_oracle`
were deleted and three Phase 4 checkboxes went from `[x]` back to `[ ]`.

The derivation, which is the part worth keeping:

    grep -cE '^[[:space:]]*[-*][[:space:]]+\[x\]' TASKS.md      # 46
    grep -cE '^[[:space:]]*[-*][[:space:]]+\[ \]' TASKS.md      # 36

and per phase, attributed to a heading rather than to the file as a whole, so a phase
cannot be inflated by another's boxes. **The first version of this measurement reported
`[ ]` = 0** — a Python `re.M` pattern with `\s*` under `^`, which is the AGENTS.md
`string:lexemes/2` failure again: a count that is 0 because the pattern matched nothing is
indistinguishable from a count that is 0 because there is nothing. `grep -c` is the
authority here for the reason `make counts` is: it is a procedure, not a claim.


## Verified findings not yet in any task list

Found by reading the tree and measuring it, on 2026-10-02. **None of these appears in
the 9 phases, in `AGENTS.md` §10's two tables, or in `AGENTS.md` §11's dead-code list**
— which is why they are here rather than appended to a phase. Each is stated with the
evidence that establishes it, because a gap with a measurement is a work item and a gap
without one is an opinion.

Ordered by what unblocks the most, not by severity.

| # | Finding | Evidence | Why it matters |
|---|---|---|---|
| **F1** | **Block-level header validity is not checked at all.** No timestamp > parent, no number = parent + 1, no EIP-1559 ±1024 gas-limit band, no `baseFee == calc_base_fee(parent)`, no `difficulty == 0`, no nonce width. | `grep -rn 'parent_timestamp\|number =< Parent\|calc_base_fee(parent\|difficulty =/= 0' apps/etherlang/src` → **0 hits**. `eth_chain:verify_blocks/2:344-355` only recomputes the header hash. `VERIFY_HEADERS` (`eth_config.erl:39`) is that recomputation and nothing else — the name overstates it. | A payload with any of these wrong is accepted. This is the largest single gap between "follows an upstream node" and "validates blocks independently", and it is first because it needs no external oracle to establish or fix. |
| **F2** | ~~**`withdrawalsRoot` is never verified.**~~ **WITHDRAWN 2026-10-03 — the premise is false, and so is the consequence.** | There is **no declared `withdrawalsRoot` at the boundary where a payload is decoded.** `ExecutionPayloadV3` in `execution-apis` lists `parentHash`, `feeRecipient`, `stateRoot`, `receiptsRoot`, `logsBloom`, `prevRandao`, `blockNumber`, `gasLimit`, `gasUsed`, `timestamp`, `extraData`, `baseFeePerGas`, `blockHash`, `transactions`, `withdrawals`, `blobGasUsed`, `excessBlobGas` -- and not `withdrawalsRoot`. EIP-4895's "Execution payload validity" section is one line, `assert execution_payload_header.withdrawals_root == compute_trie_root_from_indexed_data(execution_payload.withdrawals)`, and it is **correct but not expressible there**, because the value it names is not in the payload. The node's own comment said exactly this -- "Both are recomputed here from those lists rather than read from anywhere" -- and was right to. | **Two checks exist that this entry did not credit.** *Structural:* the computed root enters the header, the header is hashed, and that hash is compared against the payload's own `blockHash`, which the consensus layer derived from the network's real header, real `withdrawalsRoot` included. A payload whose withdrawals did not produce the network's root fails on the block hash. *Against real data:* `payload_withdrawals_root_matches_the_network_test` compares the computed root against the `withdrawalsRoot` published in real Shanghai and Cancun Sepolia payloads, and they agree. The rule is enforced twice, once against the network's own number. What is missing is a **named verdict** in the `Verification` map, and adding one would mean stamping `{verified, _}` for a value derived from the same list it would be compared against -- the circular `verified` §4.1 exists to forbid. **This is the same shape as the snappy withdrawal and the `eth_block_builder` entries: a claim recorded with the same authority as a number, where the number was right and the story was not.** The generator was a field list recalled rather than looked up, which is why AGENTS.md §1 now carries the canonical URL for it. |
| **F3** | ~~**A payload with more than 16 withdrawals is neither rejected nor refused.**~~ **CLOSED 2026-10-03** — refused at both decode entry points. | `eth_fork_schedule:withdrawals_root/1` truncated at `?MAX_WITHDRAWALS_PER_PAYLOAD`, and its own comment said a caller must reject the payload rather than accept the truncated commitment. **No caller did.** A 17-withdrawal payload was given a root over 16 of its withdrawals -- a root that is not the root of the payload's own list, so the header stopped committing to what the payload carried and nothing said so. | **One predicate, both entry points** (`withdrawals_within_bound/1`). The first version put the check only in `payload_roots/2`, so `from_payload/1` accepted the payload while `payload_block_hash/1` refused it -- two answers to one question, which is the worst shape a validation rule can have, and what caught it was that the test was written against `from_payload/1` rather than the convenient one. | **The bound is recorded, not derived, and its provenance comment was wrong.** The macro said "EIP-4895 allows at most 16 withdrawals per payload"; EIP-4895 names no limit and says the bound is "enforced by the consensus layer", and `execution-apis` states no number either. The comment now says so, and the figure is read through `eth_fork_schedule:max_withdrawals_per_payload/0` rather than duplicated as a macro in `eth_block` -- one owner per constant, the same rule §3 states for the gas table. | **Both tests use the committed Shanghai payload, which carries exactly sixteen** -- the cap itself -- so the accepted arm changes nothing at all and the refused arm is that payload plus one duplicated entry, with the other seventeen header fields still the ones the network published. |
| **F4** | **EIP-7691's blob schedule is not modelled.** `?TARGET_BLOB_GAS_PER_BLOCK = 393216` (3 blobs) and `?MAX_BLOB_GAS_PER_BLOCK = 6 * 131072` (6 blobs) are EIP-4844's Cancun figures. Prague raises them to 6 and 9. | `eth_fork_schedule.erl:798,804`. The same table carries `{time, 1741159776, prague}` for Sepolia and `{time, 1746612311, prague}` for mainnet. `max_blob_gas_per_block()` returns 786432. | Legal 7–9-blob blocks are refused, and `excess_blob_gas` diverges for any block whose parent used 3–6 blobs — changing the blob fee, the sender's balance, and therefore the state root. `max_code_size/1` and `initcode_word_cost/1` already take a fork argument; these two do not. |
| **F5** | **Any block containing an EIP-7702 transaction gets the empty receipts root.** | `eth_receipt.erl:91-100` maps `<<"0x4">>` to `unsupported`; `to_wire/1:78-80` does `{ok, Enc} = to_rlp(R)` and cannot match; `receipt_root/1:66-74` catches it into `{error, bad_receipt}`; `eth_block:receipts_root/1` falls back to `eth_trie:root([])`. | EIP-7702 is live on mainnet. On the import path it reports a mismatch; on the build path `check_commitment(_, ?EMPTY_ROOT, Computed) -> {verified, Computed}` stamps it and calls it verified — the node would propose a block whose `receiptsRoot` commits to nothing. No test finalises a block with a type-4 transaction: `eth_7702_tests` calls `run_transaction/5`, which never reaches `commitments/1`. |
| **F6** | ~~**`blockValue` is always 0.**~~ **CLOSED 2026-10-03** — the builder now sums the receipts it produced. | `eth_block_builder:block_value/1` read `maps:get(receipts, Verification, undefined)`, and `Verification` holds only `state_root`, `transactions_root`, `receipts_root` and `gas_used` — **there is no `receipts` key**. The lookup always answered `undefined`, the branch reserved for "not knowable" was taken every time, and `getPayload` reported `blockValue: 0` for every block this node built. The arithmetic below it was correct throughout and never ran once on a real block. | **Why it survived: the tests agreed with it.** Eight assertions exist on this function and every one passed the map shape `#{receipts => [...]}` -- exactly the shape `finalize/1` never produces. So the tip arithmetic was pinned correctly against a fixture **no production call could supply**. *A test that pins the arithmetic and the call shape at once will happily pin a call shape that never happens*, and that is the more general form of the fixture lesson: agreement between a test and a bug is not evidence. The eight now pass a receipt list, and a ninth asserts the guard -- a `Verification` map is refused loudly instead of answered 0, because **the bug's failure mode was a plausible number**. Reverting the call site fails **18** tests. | **The gap this row does not close, named:** no test exercises `getPayload` on a block that contains a transaction. That needs a funded state in the parent's trie, a signed transaction in a running pool, and a head carrying that state root, and `store_head/0` builds a header with no state. The wire test's `blockValue == 0x0` is **correct for an empty block**, which is exactly why it never noticed. |
| **F7** | **The EVM never enforces the 1024-item stack limit.** `push/2` has no bound. | `eth_evm.erl:431`. `grep 1024` in `src/` finds only the two *frame depth* checks. | A contract pushing 1025 items runs on and returns a different post-state. The cheapest real consensus divergence on this list: one guard, no fixture needed. |
| **F8** | ~~**`EXP` was priced on `max(base, exponent)`.**~~ **CLOSED 2026-10-04** -- and it was the smallest of four defects in the same handler. | `eth_evm.erl`'s `do_op(16#0A, ...)`: `Cost = 10 + 50 * max(byte_size(base), byte_size(exp))`. Four separate things, found together by installing geth and using `evm run` as an oracle. **(1)** the base's width was priced, and EIP-160 measures only the exponent -- "increase the gas cost of EXP from 10 + 10 per byte in the exponent to 10 + 50 per byte in the exponent", Spurious Dragon, so **(2)** the coefficient was 50 at every fork where it is 10 before Spurious Dragon, and **(3)** the literal `10 +` double-charged a flat cost the loop already takes from `constant_cost/2 -> base_gas_cost(16#0A, _, _) -> 10`. **(4)** The comment cited **EIP-2565**, which is MODEXP's repricing -- opcode 0xf0, and its cost really does involve both a base and an exponent, which is exactly why `max(base, exponent)` read as deliberate rather than wrong. | **A wrong citation is not only an attribution error; it is a defect that hides behind its own plausibility.** The EIP named a product of two widths, the code took a product of two widths, and no reader -- or writer -- would look further. | **The operand order was right and it was broken here, then restored.** `push/1` conses, so the operand pushed last is the one EXP pops first, and that is the base; a program computing `Base ** Exponent` therefore pushes the exponent **first**. geth agrees on all eight programs measured, with `PUSH1 5, PUSH1 0, EXP -> 0` and `PUSH1 0, PUSH1 5, EXP -> 1` separating the two readings on a two-byte program. The Yellow Paper was misremembered, the pops were swapped, and the swap was verified by a probe **run against the edited tree** -- measuring the edit. This is §4.3's quiet form and AGENTS.md's fixture rule together: **a measurement taken against a tree you have just changed is a measurement of your change.** The oracle was one command away throughout. | **The fork boundary is Tangerine Whistle / Spurious Dragon, and sampling Byzantium against Cancun straddles nothing** -- Spurious Dragon is block 2,675,000 and Byzantium 4,370,000, so both already cost 50. The first sample was exactly that pair, both arms came back 66, and the gate looked broken. **A number that does not move across a boundary is measuring the wrong side of it.** | **`evm t8n` never ran, and the four reasons all printed the same empty output.** It requires a signed transaction; a preimage naming a different `to` than the emitted transaction, `"v": "0x37"` written with `~p` in a hex field, code on the sender, and a mixed-case alloc key are four different defects with one symptom. **A missing measurement is what a broken fixture looks like**, which is the same shape as the bounded histogram that printed nothing. The cross-fork gas figures are pinned against EIP-160's text and by test instead; the differential harness this needs is D-13. |
| **F9** | **WITHDRAWN — the snappy claim was wrong.** It said snappy was enabled while never advertised, so every frame after the Hello failed against a real peer. Three separate checks say otherwise, and the first was the claim itself: **the devp2p specification makes compression unconditional after Hello at protocol version 5** ("All messages following Hello are compressed using the Snappy algorithm", EIP-706), and `?P2P_VERSION` is 5, so `snappy = true` is *correct*. `snappy` is not a capability -- geth keys it off `snappyProtocolVersion = 5` and `"snappy"` appears **0 times** in its capability lists -- so not advertising it is also correct. And `frame-size` carries the compressed length (`eth_rlpx.erl:317`), as the spec requires. **"Interoperability is broken" was never established**; it was inferred from a misreading, and no client is installed here to test against. What survives is small and is not an interop defect: `eth_snappy:compress/1` is literal-only, so it **expands** every body — measured +2 bytes on a Ping, +9 on a 400-byte one, and round-trip is correct on all nine payloads probed. Compression is safe and useless. |
| **F10** | ~~**The txpool has no replacement rule, so two transactions with the same `(sender, nonce)` both live in the pool.**~~ **CLOSED 2026-10-03** — `insert/3` holds at most one per `(sender, nonce)`, and a strictly higher price replaces it. | `eth_txpool.erl` keyed on the transaction **hash** alone, so two transactions differing only in `gasPrice` were both admitted and both lived in the pool. **Measured over 12 runs** with a 1 gwei and a 2 gwei transaction at the same `(sender, nonce)`: the 2 gwei one won 8, the 1 gwei one won 4, **and the 2 gwei one won in exactly the 8 runs where its own hash was the larger of the two — twelve of twelve.** The fee was therefore not a weak tiebreaker, it was never consulted. `sender_pending/2` sorted on `nonce` with a `=<` comparator, true both ways for equal nonces, so the order came from `by_sender/1`'s prepending accumulator over a flatmap visited in key order — and the key is the hash. `cap_sender/2` evicted the *highest* nonce and so never resolved the conflict, and the old eviction fixture gave every transaction a fresh key, so no test could see it. A user bumping the price on a stuck transaction had a coin flip on being ignored, and the loser still occupied a per-sender and a global slot. **No price-bump threshold, deliberately:** no EIP specifies one and nothing here derives it; geth's ~10% is a mempool policy, and importing a peer's policy as a rule is what §4.2 exists to prevent. The cost of omitting it is that anyone can churn a slot by bidding one wei more, bounded by `per_sender`/`max`, and this node authors no blocks so there is nothing to gain. Three tests, each shown to bite: no replacement at all fails the two replacement tests and leaves the different-nonces control green; any price replacing fails the same two; making the rule ignore `nonce` fails all three, which is what proves the control is not vacuous. |
| **F11** | ~~**`eth_state_management` and `eth_block_hash_oracle` are dead code and are not listed as such.**~~ **CLOSED 2026-10-03** — deleted, de-registered, and **three Phase 4 checkboxes re-opened**, which was the larger half of this and not what the entry said. | `grep -rn 'eth_state_management:start_link\|eth_block_hash_oracle:start('` → **0 hits**; neither was a child in `etherlang_sup.erl`. **That grep was also wrong in a way that mattered:** `eth_block_hash_oracle` has five call sites, which reads as live, but every one is inside `eth_state_management`, so the two are a **dead cluster** and searching one qualified name would have called the other live. | **The three functions that reported work they did not do, and why the modules were deleted rather than documented:** `prune_recent/1` computed `_KeepFrom`, carried `%% Prune blocks older than KeepFrom`, returned `{ok, pruned}` and pruned nothing; `expire_state/1` computed `_ExpireAt`, carried `%% Expire state older than ExpireAt`, returned `{ok, {expired, _ExpireAt}}` and expired nothing. Three RPC callers would have been told the work was done. **And `TASKS.md` had marked state pruning, state expiration and the block hash oracle `[x]` ✅ on the strength of exactly these functions** — so the ledger, not the code, was the thing that had to change. This is §11's `eth_block_builder` / `eth_engine` shape in a third place. No test referenced either module, so nothing caught it. The other four Phase 4 items are honest and remain `[x]`. |

| **F12** | **PARTIALLY CLOSED 2026-10-03 — one of three terms.** ~~**`SELFDESTRUCT` charges a flat 5,000** — no cold-access term, no new-account term, no refund.~~ EIP-2929's beneficiary access term is implemented and gated on Berlin; the other two are **named, not guessed**. | `eth_fork_schedule:selfdestruct_access_cost/2` is the new term; the base 5,000 is unchanged and still charged by the machine loop. The warm case is **0**, per the EIP's explicit "does not charge a `WARM_STORAGE_READ_COST` in case the recipient is already warm, which differs from how the other call-variants work". **Still absent:** the new-account term for an empty beneficiary, and EIP-3529's pre-London 24,000 refund. Neither is derivable from anything in this tree, and §4.2 forbids inventing one. | **The corpus corroborates nothing here, and the entry previously said it did.** It claimed `eip6780_selfdestruct` at 0 of 5 "independently confirms" the defect. The tally is pinned exactly and **did not move** with this fix. That suite's committed fixture is a revert-semantics test whose transaction is a `CALL` into a pre-existing contract, so its divergence is in EIP-6780's deletion rules or in storage clearing — **not** in the price. This is §10a's "a rejected experiment's diagnosis has to be re-tested when the code it blamed changes", reached from the other side: here the *number* was right and the *story attached to it* was not, and both were recorded with the same authority. |
| **F13** | ~~**A remote UDP sender can terminate the node.**~~ **CLOSED 2026-10-03** — one boundary per remote packet in `eth_discv4:handle_packet/4`; the malformed case is dropped and logged, and the node survives. Was: `handle_findnode/5` calls `table_closest(Tab, to_bin(Target), K)`, and `to_bin/1` answers `<<>>` for anything that is not a binary or integer — which is what a **two-element** FindNode target decodes to. `table_closest/3:190` then calls `distance(Target, Id)` unguarded, and `distance/2` is `crypto:exor/2`, which requires equal sizes. | **Proven end to end**, not inferred: with one node in the table, `table_closest(Tab, <<0:512>>, 16)` returns that node and `table_closest(Tab, <<>>, 16)` raises `badarg`; the empty table with the same bad target returns `0 node(s)`, so the table being non-empty is the whole precondition. It reaches the raise from `handle_info` at `:262` with no `try`, the child is `restart => permanent`, and the supervisor is `one_for_one` with `intensity => 5, period => 10` — so **about six packets in ten seconds take the whole application down**. Packet signature is verified before this point, which is why it survived reading: `decode_packet/1` checks the keccak of the signature, and the attacker can satisfy that cheaply. |
| **F14** | ~~**One inbound TCP connection stalls the whole peer manager for ten seconds.**~~ **CLOSED 2026-10-03** — and it was **two** defects, of which the second was the more serious because nothing had to be attacking the node for it to bite. (i) `handle_info(accept, S)` called `eth_peer_conn:start_recipient_unlinked/3` inline, and `gen_server:start/3` does not return until `init/1` acks or exits, where `init/1` for an inbound connection is the blocking `eth_rlpx:recipient/3` with a 10-second timeout. (ii) `gen_tcp:accept(S#st.lsock, 1000)` ran inside the same callback, so the manager was inside a one-second blocking call **permanently**. Fixed by `accept/2` with a zero timeout plus a `?ACCEPT_POLL_MS` re-poll, and by spawning the handshake the way `auto_dial/2` already did. | **Both halves measured, not inferred.** (i) unreachable at t=2.2, 4.4, 6.6 and 8.8 s, answering only after `rlpx inbound handshake failed (timeout)` at t≈11 s. (ii) **20 idle `status` calls: 798 ms min, 1001 ms median, 1004 ms max — with no connection anywhere**, against **1 µs / 2 µs / 67 µs** after. Both callers are production paths, not tests: `eth_sync.erl:454` and `eth_statesync.erl:109` each poll `eth_peer:peers/1`. Each of the two new tests fails on its own half and passes on the other's, checked by injecting one change at a time. Two measurements worth keeping for whoever touches this next: **`gen_tcp:recv/3` does not require the calling process to own the socket** (only setting `{active, ...}` does), which is why the handshake can run before the `controlling_process/2` transfer exactly as it always did; and **`{active, once}` on a *listening* socket delivers nothing** — `{tcp_passive, _}` is the re-arm message for an established socket, measured on OTP 29 for `once`, `1` and `true` alike. The idle poll is a deliberate trade against a dedicated acceptor process, and the reason is ownership: `gen_tcp:controlling_process/2` may only be called by the current owner, so an acceptor cannot pass a socket to a `gen_server:start/3` that has not returned. |
| **F15** | **One `NewPooledTransactionHashes` announcement stalls its own connection for ten seconds — and only its own, which is the whole of the severity.** | `handle_msg/3`'s `Base + 8` arm calls `handle_pooled_hashes/2`, which asks for the transactions with `Base + 9` and then blocks in `await_pooled/2` on a `eth_rlpx:recv/3` with a **ten-second** timeout — on the connection's own process, inside `handle_info(poll, S)'s dispatch. The `#st.fetching` flag keeps the poll loop out of the way of a *local* fetch; nothing keeps a *remote-initiated* fetch out of the way. | **Measured**: the peer answered code 25 (`GetPooledTransactions`, so the path definitely ran), a `status` call timed out at 1500 ms, and a second was answered **8497 ms** later. **This is D-15's shape one layer down, and it is deliberately not given D-15's severity.** D-14/D-15 blocked `eth_peer` — one process shared by every peer — so one connection took `eth_peer:peers/0` down for everybody (`eth_sync.erl:454`, `eth_statesync.erl:109`). Here the blocked process is **per-connection**, so a peer can stall only its own; the manager stays answerable throughout. Pinned by `a_pooled_hash_announcement_stalls_only_its_own_connection_test`, which asserts the blast radius *and* that the connection recovers — an unbounded wedge would be a much worse finding and nothing else in the suite would notice it. **Left open deliberately.** The two ways to remove the stall both cost something real: not fetching on an announcement drops an inbound path by which a peer chooses what enters the pool, and a shorter deadline is an invented constant, which §4.2 forbids. Deferred until the fork-model decision in TASKS.md item 6 lands, since a resolver that watches peers changes whether this fetch is wanted at all. |
| **F16** | ~~**`eth_peer_conn`'s message dispatch has no error boundary, and that is where D-14's shape would be.**~~ **CLOSED 2026-10-03 — investigated, and it is not a defect.** 49 hostile payloads across all seven dispatched codes: the connection stayed up and answered a status call after every one. No boundary was added, because one would be defence in depth against a crash this repository cannot reproduce. | Seven `try`s, none at the dispatch point — the mirror image of `eth_discv4` before D-14. The surface is genuinely guarded in four places that are easy to miss: `eth_snappy:decompress/1` is total (`get_varint/3` answers the atom `error`, every `decode/3` arm ends in `{error,_}`, `do_copy/5` range-checks the offset before `append_copy/4` indexes with it); the `eth_eth:decode_*_bin/1` decoders each wrap `eth_rlp:decode/1` **and** validate the decoded shape — `wellformed_pooled/1` is what stops a peer handing `ingest_pooled/2` an RLP integer, which its two-clause `case` cannot handle; `eth_rlpx`'s frame layer answers `bad_header_mac` / `bad_frame_mac` / `frame_too_large` / `short_header` / `bad_rlp`, and `to_int/1` has a catch-all; and `eth_eth:walk/6` guards `Num >= 0' so an arbitrary `Skip` walks off the end instead of looping. | Now pinned by `eth_peer_conn_tests` (new file, 3 tests), so a future change that removes one of those four guards fails there instead of in production. Shown to bite by two injections — a raise at the top of `serve_headers_req/2`, and one on `handle_msg/3`'s dispatch arm — both of which kill the connection and are caught. **Coverage boundary, stated because the sweep reports only "0 crashes":** every payload goes out through `eth_rlpx:send/4`, which compresses correctly and unconditionally, so **a malformed snappy stream cannot be produced by this harness**, and injecting a raise into `eth_snappy:get_varint/3`'s catch-all changes nothing. That is the input every remote message passes through *first*. `send_frame/4` is not exported and `send/4` always compresses, so reaching it means reimplementing the AES-CTR framing — a second copy of the code under test, which is worse than the gap. `eth_snappy:decompress/1`'s totality rests on reading it, not on the test. |
| **F17** | **Every inbound p2p handshake performs a live upstream JSON-RPC fetch, and waits for it.** | `eth_peer_conn:maybe_eth/3` calls `eth_eth:status_data/1`, whose `total_difficulty/0` is `eth_rpc_client:call(<<"eth_getBlockByNumber">>, [<<"latest">>, false])` — an uncached upstream call, on the handshake path, with whatever timeout and retry count the operator configured. | **Measured**: 6059 ms and 6004 ms on two consecutive `rebar3 eunit` runs of a loopback peer, because under eunit the application is started and `eth_rpc_client` points at a reachable endpoint. The same code outside eunit returns instantly, because the client is uninitialised and the call exits `noproc` at once — so **the cost of this is invisible to every test that does not start the application**, which is most of them. The consequence is that one unavailable upstream delays *every* inbound handshake by the full timeout, and there is no cache. This is also the mechanism behind an unrelated trap: a test harness that builds a real peer pair times out at 5 s for this reason alone, and the symptom (`{error,timeout}` on the first frame after Hello) points at the framing rather than at the fetch. `?FALLBACK_TD` is what makes it *correct* rather than fatal, so this is a latency and availability finding, not a correctness one. Recorded, not fixed: the right answer depends on whether this node is meant to compute total difficulty itself (see TASKS.md item 6), and caching it wrongly is worse than being slow. |
| **F18** | **The EVM never enforced the Yellow Paper's 1024-item stack limit, and the absence was a memory vector rather than a tidiness gap.** | `eth_evm:push/2` was `E#e{stack = [mask(V) | E#e.stack]}` with no bound, and the frame carried no depth. | **Measured, not argued:** 10,000,000 `PUSH1` on a 30M gas limit -- which the gas limit permits, at 3 each -- ran to completion in **3,281 ms** with a **942 MB** peak RSS, roughly 89 bytes per stack item. The frame reached 9,765 times the specified depth, and one transaction's calldata bought one transaction's worth of a gigabyte. After the fix: **55 ms**, **99 MB**, and the same program ends in an exceptional halt. A gas limit is not a memory limit, and nothing else in the frame bounded this. | Two design choices, both of which were the whole difficulty. **(i) Where the check lives:** `push/2`, not `push_n/3` and `dup_n/3`, because those are not the only callers and a second site is a second thing to forget. **(ii) `depth` is a counter, not `length(stack)`** -- there are exactly four sites that write `stack` (`push/2` +1, `pop/1` -1, `popn/2` -N, `swap_n/4` 0), and `length/1` per push would walk 1024 cells on a program that pushes ten million times. That makes drift the defect to fear, so `emptying_the_stack_lets_it_be_refilled_to_the_limit_test` pushes to the limit, empties it, and refills it; an injection that removes `pop/1`'s decrement fails **only** that test. | **The load-bearing part is that it is a halt and not a crash.** `eth_block:execute_transactions/6` answers any `{error, _}` from `run_transaction/5` by refusing the whole block, so an overflow raised as an `evm_crash` would let one transaction that pushes 1025 items invalidate a block whose every other transaction is valid -- strictly worse than the defect being fixed. `{error, stack_overflow}` consumes the frame's allowance and fails one transaction. **This also says something about the pinned `stack_underflow_test`, which asserts underflow is an `evm_crash`: by the same argument an underflow refuses a block. Not changed here, because it is a separate behavioural change against a deliberately pinned test -- but it is the next thing to look at. |
| **F19** | **Twelve hand-written hex decoders in `src/`, and they did not agree.** `eth_hex` has owned hex decoding since it was written; seven modules carried their own and two more reached one of them by a qualified call. `eth_block`'s two-clause version returned a bare binary **undecoded** while `eth_rpc_handler`'s and `eth_statesync`'s decoded it. `eth_header`'s and `eth_state`'s turned an **odd** number of hex characters into one byte each, so `"0x123"` decoded to `<<0x12, 0x03>>`. `eth_eth`'s answered `<<>>` for a value it could not read, which on a 32-byte hash means the empty binary compares *unequal* to every real hash rather than reporting that it could not be read. | **CLOSED 2026-10-04** — one owner, `eth_hex`, plus `must_decode_bytes/1` for the eight call sites that already know the value is DATA. Three behaviours were load-bearing and are kept **at the call site and named**: `find_by_hash/2` must stay lenient because a stored hash that will not decode means "not this block" and it walks the numbers; `eth_state`/`eth_header` must still accept an integer; `eth_statesync` was already returning `{ok, _}` and swapping the function made it `{ok, {ok, _}}`, which raised `badarg` on a tuple three frames later. **`eth_hex_owners_tests` forbids the definition** and its scan strips comments first — an earlier version counted the comments written to record the deletion as four offenders, and the only way to have made it green was to delete the comments. **It found a defect rather than confirming one:** `eth_test_util:header/3` put a **QUANTITY** (`"0x0"`) in the DATA field `extraData`, the lenient decoder turned it into `<<0>>`, and the header was hashed over bytes no conformant payload can carry. 144 tests failed on that single value when the decoder was made strict. |
| **F20** | **The EIP-1559 base fee was computed against the wrong target and floored at an invented number.** The target was two thirds of the gas limit; EIP-1559 says `gas_target = gas_limit // ELASTICITY_MULTIPLIER` with the multiplier 2, so it is half. The floor was 7 wei and EIP-1559 has no minimum. | **CLOSED 2026-10-04.** **The two targets agree for an empty parent** — the delta is `parent // 8` either way — which is why this survived: the only case anyone had compared is the one where it cannot be seen. They differ, **in opposite directions**, for a block whose `gasUsed` lies between half and two thirds of the limit. **The floor was unpinnable rather than merely wrong:** `F -> F - F div 8` has a fixed point at every `F < 8`, so `max(0, ...)`, no floor and `max(7, ...)` all answer 7 after 400 steps, which means nothing was holding the number in place either. Six tests were written against the old figures and three argued for the defects in their comments. |

**These are carried as `D-1`…`D-18` in [`RELEASE-GATE.md`](RELEASE-GATE.md)**, with
`D-14`/`D-15` being F13/F14 and **`D-1` having been closed by the header-validity work
that F19 and F20 sat inside** — one pass, three separate commits, because the three were
entangled in the tree and separating them into three *green* states needed three more full
suite runs. **F16** is the answer to the question D-14 raised
about the *other* dispatch point, and **F15**/**F17** were found by that
investigation rather than by reading. `D-9` is a **withdrawn** claim kept in both files
rather than deleted, because the way it was wrong is the point: three
independent checks — the specification text, geth's actual capability lists, and
the `frame-size` clause — each refuted it, and none was consulted before it was
written down. `D-13` is the three missing harnesses. The gate is where to look for *what is accepted and why*; this table is where to look for *what was found and how it was established*. Two views of one list, meant to be read together: a deviation with no finding behind it is an excuse, and a finding with no deviation behind it is a task nobody triaged.

**Not findings, recorded because they were suspected and are not:** `eth_block:from_json/1`'s
24-byte nonce default is real but that function has **no caller in `src/`** — dead, not
live. `CALLCODE` does not transfer value: `eth_evm.erl:1370` sets
`callcode -> {CurAddr, CurAddr, Value}`, so the transfer nets to zero. The listen socket
has no `send_timeout` while the outbound connect does, so the exposure is inbound-only.



## What the two-node run found, and what is still open

Running two etherlang nodes against each other on one host (2026-10-05) produced a list
of findings that no test and no document held. All of these are measured; the
measurement is named so it can be repeated.

### Fixed in `9dc6c4a`'s successor: three methods the node refused

`net_version`, `eth_gasPrice` and `net_peerCount` had **no clause in
`eth_rpc_handler:dispatch/3'**, so they were answered `-32601`. That is the correct
behaviour for a method the node does not implement -- the catch-all policy is
deliberate -- and it still left the node unwatchable by any stock Ethereum status tool.

**What the absence looked like from outside was misleading.** web3 0.x turned the
`-32601' into `Error: invalid argument 0: hex string without 0x prefix', naming a
*formatting* fault in this node's block responses. A scan of all 27 string fields of
`eth_getBlockByNumber', and of every field of a transaction object inside it, found
nothing missing the prefix. **The hex complaint was three layers downstream of an
unsupported method.** Adding the three methods did **not** fix the dashboard, which is
the second half of that sentence and the part worth keeping.

`eth_gasPrice` reads the base fee of the block *after* the head, through
`eth_rpc_projection:next_base_fee_for_head/1`. **That function asks `eth_chain:head/1'
rather than going through `resolve_block_number/2'`**, because the latter answers
`max(head_num(Chain), 0)' -- so an empty store and a head at block zero are the same
answer, and `next_base_fee/1' on the resulting `#{}' returns `0`, the figure the
specification prescribes for a pre-EIP-1559 block. The empty-store case would have
reported a **gas price of zero**: a claim about the chain's next block derived from a
fact about this node's storage. Measured on the node with no upstream and an empty
chain, where every other read answers `-32000 chain_empty'.

`net_peerCount` counts connected **eth-capable** peers via `eth_peer:eth_peer_count/0`,
using `eth_peer:eth_ready_peer/1's predicate verbatim. `eth_peer:status/0' would be
cheaper -- it is a map size -- and it is the wrong number: it counts conns that have not
finished handshaking and conns that are dead. Measured on two live nodes, `status/0'
said `peers => 1' while `peers/0' said `{error, down}' for that one entry.

### The blocker, found: a peer that is invisible exactly while it is working

**Two deadlines, and they disagree by 7.5x.**

```
eth_peer_conn:fetch_request/6    deadline  15,000 ms    blocks the whole conn
eth_peer:peer_status/1           gives up   2,000 ms    on that same process
```

`eth_peer_conn:handle_call({get_headers, ...})` calls `fetch_request/6`, which sends the
request and then owns `recv` until the response arrives or **15 seconds** pass. A
`gen_server` handles one message at a time, so for that entire window the process **cannot
answer `gen_server:call(Pid, status, 2000)`** -- and `peer_status/1` abandons it and
answers `{error, down}` from a bare `catch _:_`.

**A peer that is only visible while idle cannot be used for work, because starting the
work hides it.** That is the whole defect, and it is self-referential: the fetch that
makes the peer useful is the fetch that makes it invisible.

### Every symptom, and which part of it this explains

| Measured | Mechanism |
|---|---|
| `eth_peer:peers/0` answers `{error, down}` for a conn that is provably alive | mid-fetch; the 2 s call gives up |
| `net_peerCount` alternates `0x1` / `0x0` on a stable connection | the sample lands in a gap between fetches, or inside one |
| 22 `status` calls logged against 40 `net_peerCount` samples | roughly half the calls were never processed, because the conn was inside `handle_call` |
| `net_peerCount` costs **2.1-3.5 s** | each stuck conn consumes the full 2 s |
| `eth_ready_peer/1` answers `no_eth_peers` and `eth_sync` never starts | that is the gate `eth_sync` uses |
| the conn diagnostic shows `handle_ms=0`, `q=0`, idle | it is not inside `handle_msg`; it is inside `handle_call` |
| `peer_up` = 1, `conn terminating` = 0, diagnostic ticks rising steadily | **the connection never dies at all** |

### The connection does not die. An earlier claim that it did was wrong.

`91e7741`'s entry in this file, and several earlier ones, describe a peer connection dying
about 33 seconds after `peer_up` with `{error, enotconn}' out of `poll`, while `lsof`
still listed the socket as ESTABLISHED. **On the tree as it stands now that does not
reproduce**: over 60 seconds and across a fresh pair, `peer_up` = 1, `conn terminating` = 0,
and the per-second diagnostic ticks rise monotonically on both nodes. What was being
observed as a death was `peer_status/1` reporting `{error, down}' -- and the socket was
ESTABLISHED precisely *because* nothing had closed it.

**`eth_peer_conn` now logs its own socket state on a non-normal terminate, so a real death
would say whether the port still believed it was connected.** That question was what the
whole search was for, and it is answered by the log line rather than by an observer:
`erlang:port_info(Sock, connected)` at the moment of closing, which distinguishes a handle
that is still a connected socket, one that is not, and one that is gone.

### Two hypotheses killed by measurement, recorded because both would have broken working code

1. *"The eth message-id table is wrong."* Wrong. Against go-ethereum's
   `eth/protocols/eth/protocol.go`: `GetBlockHeaders = 0x03`, `GetBlockBodies = 0x05`,
   `GetReceipts = 0x0f`, `NewPooledTransactionHashes = 0x08` -- every offset in
   `eth_eth:msg_*/1` matches exactly.
2. *"`handle_call(status, ...)` passes the wrong thing to `eth_rlpx:remote_id/1`."* Wrong.
   `remote_id(#sess{remote = R}) -> R.` (eth_rlpx.erl:65) wants the session record, which
   is what it is given. The `maps:get(node_id, Opts)` at eth_rlpx.erl:231 is inside
   `recipient/3`, a different function; reading one line of a large file as the definition
   of a name used elsewhere in it is what produced the claim. The diagnostic line was
   "fixed" on that basis and the fix has been reverted.

### And five instruments that were wrong before any of that

Each was discarded against a control, which is the only reason any of them was caught:

| Instrument | Why it was wrong |
|---|---|
| `strings` on a release beam, looking for a log format string | the release beam carries no readable literals -- **the control was the pre-existing log line, which was also absent** |
| `beam_lib:chunks(B, [atoms])` looking for a function name | the atoms chunk does not list private functions -- **the control was `await_status/4`, which was also absent** |
| calling `eth_peer_conn:port_connected/1` from outside | it is **private**; a private function answers `undef` by definition |
| `erlang:function_exported/3` for the same | answers `false` for anything unexported |
| `init stop` as a way to trigger the terminate log | the reason is `shutdown`, and `terminate/2` deliberately does not log that branch |

**Five of the six instruments used in this search were mine and four of those five were
broken.** The two that worked were reading the abstract code and reading the log, and both
were reached only after the failures.

### Fixed: `peers/0` answers from the manager, and never calls the peer

`handle_call(peers, ...)` was `[{Pid, peer_status(Pid)}]` -- one
`gen_server:call(Pid, status, 2000)` per peer. It is now a map lookup, and `peer_up` carries
the negotiated `eth` value so the manager never has to ask.

**Measured on the pair in `tools/two-node-p2p.sh`, 20 samples each, after the fix:**

| | before | after |
|---|---|---|
| node B `net_peerCount` | `0x1` and `0x0` alternating | **`0x1` in 20 of 20** |
| `net_peerCount` latency | **2091-3525 ms** median | **2.0 ms** median (min 0.9, max 9.1) |
| node A `net_peerCount` | unreadable -- each sample timed out | **`0x0` in 20 of 20**, max 27 ms |

The median latency figure is the one that decides it: **2.0 ms is inside the 2000 ms window
the old call gave up in**, so even the old shape would now usually have returned. The fix is
not that the deadline was tight. It is that a value the manager already holds was being
re-read from a process that cannot answer while it is doing the work this node wants.

**The test is the defect, stated as an assertion, and it does not depend on timing.**
`sys:suspend/1` makes the peer provably unable to answer *any* message, and the answer must
not change: `peers/0` still reports it eth-ready, `eth_peer_count/1` still says 1. Injecting
the `gen_server:call` back turns it red with `{badmap,{error,down}}`.

**Two things that were wrong inside the fix and were caught before it was committed**, both
recorded because both would have shipped a peer-counting rule that is the opposite of the
one intended:

1. The first version put the **raw** `S1#st.eth` in `peer_up`. That value is `undefined`
   when no `eth` capability was shared, and the consumers test
   `maps:get(eth, Info, false) =/= false` -- so `undefined` **passes**, and a peer with no
   `eth` capability would have counted as eth-ready. `eth_ready/1` is the one definition of
   "eth-capable" and it answers `false`, so it is what travels.
2. `eth_ready_peer/1` is **private**, so the test could not call it; the assertion was
   rewritten against `eth_peer_count/1`, which uses that predicate verbatim. Adding an
   export for a test would have been the second copy of the rule.

**`eth_ready(S1)` and `S1#st.eth` cannot differ on any path that exists today** -- the
`peer_up` send is inside `maybe_eth`'s `{ok, S1}' branch -- so nothing pins that choice, and
the comment at the call site says so rather than implying otherwise. It is "correct by the
specification and unobservable here", which are two different sentences.

### Two things this measurement settled that were open questions

**The RPC does report A's local head, and that is worth having checked.** A's chain is stuck
at 11,846,219 and `eth_blockNumber` returns `0xb4c24b`, which **is** 11,846,219. So the
projection is not answering from `base_source` here; it answers from the chain store, and it
answers with the number it actually holds. (This was misread once during the measurement as
"it had got past the blocker", and the arithmetic -- not the code -- was what was wrong.)

**A has an inbound connection, and reading that cost an hour of the wrong file.**
`eth_peer_conn` rotates its log, so `erlang.log.1` is a **stale rotation** -- it stopped
being written at 01:05 while the node was still running and writing `erlang.log.4`. Every
measurement of "A has no inbound connection" was taken from that file: no `rlpx conn diag`
line, no crash report, no mention of B's port. All three are absences of evidence in a file
that had stopped receiving events. Against the current rotation: **175 diag lines, remote
exactly B's discovery id**, no crashes. The claim "A never accepted a peer" was an
instrument pointed at a dead file, which is the same shape as every other time in this file's
history that an absence was reported as a result.

### Fixed: the accept path was deleting the peer entry it had just been told about

With both nodes finally talking, `net_peerCount` was **asymmetric on identical code**: node
B, which *dialled* A, reported `0x1`; node A, which *accepted* B, reported `0x0`. The two
paths build the peer entry differently, and one of them threw the answer away.

`handle_info({accepted, Ref, Res}, ...)` wrote `Pid => #{ref => MRef}` -- a **replacement**,
not an update. And the message order guarantees the information was already there: the
spawned acceptor calls `start_recipient_unlinked/3`, which runs the whole handshake and
sends `peer_up` (carrying `remote`, `hello` and `eth`) to the manager, and only *then* sends
`{accepted, Ref, Res}`. So `peer_up` was handled first and `accepted` overwrote it with a
bare `#{ref => ...}`.

The result: a live, eth-capable, fully handshaken inbound connection whose entry held no
`eth` at all, so `eth_ready_peer/1` rejected it. `handle_call({dial, ...})` had the same
replacement and is fixed with it; both now go through `put_ref/3`, which merges.

**`ensure_peer/2` already knew this ordering** -- its comment says "peer_up may arrive before
dial_result" -- and the accept clause was simply never given it. That is the shape worth
noticing: the fix for a race existed one function away, with the race written in its comment,
applied to one of the three sites that create an entry.

**Measured, 20 samples per side:**

| | before | after |
|---|---|---|
| A (`net_peerCount`, the accept side) | `0x0` in 20 of 20 | **`0x1` in 20 of 20** |
| B (`net_peerCount`, the dialing side) | `0x1` in 20 of 20 | `0x1` in 20 of 20 |
| latency, either side | 1.4-1.6 ms median | unchanged -- `peers/0` reads the manager's own state on both paths |

The test is `eth_peer_tests:autodial/0`, whose `peer_ad_b` has `target => 0` so it **never
dials**: its only entry comes from the accept path. It asserts `wait_eth_peer(peer_ad_b, ...)`
succeeds and that `eth_peer_count/1` is 1 on **both** managers. Restoring the replacement
turns it red with `autodial_timeout` -- the accept-side peer can never be reported, because
by the time anyone looks, its entry says nothing about it.

**That assertion is what closes the `eth_open_claims_tests` gap** which recorded that a
non-zero `net_peerCount` was indistinguishable from a hardcoded `0x0`. The gap entry's own
diagnosis was wrong twice over -- it blamed the connection dying, which `e823649` disproved,
and it blamed the 2 s `peers/0` call, which `cd511da` removed -- and both of those were real
blockers that had to be cleared before the assertion could be written at all. The entry is
gone and the reason is recorded in that module, including **why no static replacement was
built**: three attempts read `eth_peer_tests`'s beam, and one iterated the module's top-level
forms (where the functions are, not the calls), and two read a stale beam because a
`--module=` run of one test module does not rebuild another. A check that reads a sibling
test's compiled form to confirm the sibling test says something is a check about the build.

1028 eunit tests, down one: the closed gap was a `_test/0` function and deleting it is the
point.

### The next blocker: `eth_sync` cannot get a single header across

**Measured on the running pair.** With both sides now counting their peers, B still sits at
`chain_empty` while reporting `0x1` peer, for 20 minutes of sampling. Both nodes' logs carry
the same error, on both sides:

```
ERROR REPORT: sync tick crashed (exit:{timeout, {gen_server,call,
  [<0.705.0>, {get_headers, {hash, <<32,186,185,102,240,97,35,140,...>>}, 192, 0, true}, 20000]}})
  [{eth_sync,walk_back,5, eth_sync.erl,494},
   {eth_sync,peer_catchup,3, eth_sync.erl,474},
   {eth_sync,try_peers,2, eth_sync.erl,466},
   {eth_sync,run_once,1, ...}]
```

The hash in the request is **A's own head hash**, so B is asking A for the 192 headers below
A's tip, and the call exceeds its own 20,000 ms budget. B has crashed 11 times this way and A
13, over roughly forty minutes of uptime -- so it is not a tight per-tick loop, and
**"every tick" in the log message is the message's wording, not the measured rate.**

**What is *not* the cause, because it was measured.** Two readings were wrong on the way
here and both are worth keeping:

* *"`handle_ms` is 0, so the connection is idle and the fault is elsewhere."* `handle_ms`
  measures `handle_msg/3` only. A `gen_server` inside `handle_call/3` prints nothing, so this
  number says nothing about the path that is failing. It was read as if it covered both.
* *"`q` is growing without bound, so messages are never consumed."* Over eight consecutive
  one-second samples it read 10, 10, 12, 12, 14, 15, 15, 17; over a further thirty seconds it
  **plateaued at 19-23**. It is a stable backlog, not a leak. The first reading was taken over
  exactly the window in which the number rises.

### The defect this points at: a partial frame read is thrown away

`eth_rlpx:recv_frame/3` reads a frame in **two sequential `gen_tcp:recv` calls that share one
`Timeout`** -- 32 bytes of header, then `RSize + 16` of body. Two things follow, and the
second is the problem:

1. `recv_frame_header/6` advances `Sess#sess{ingress, dec}` -- the MAC chain and the AES
   counter -- **before the body has been read**. That is correct, because the header must be
   authenticated before the body is trusted.
2. **If the body read times out, those 32 header bytes are already gone from the socket and
   the caller is given the *old* session back.** `fetch_wait/5` in `eth_peer_conn` recurses
   with the state it started from, so the advanced MAC counter is discarded along with the
   frame. The stream is now **32 bytes out of step**, permanently.

The next `recv_frame/3` reads the first 32 bytes of what was frame 1's *body* and treats them
as a header. `mac_header/2` fails, the connection answers `{error, bad_header_mac}`, and
**no frame sent after one slow frame can ever be read again** -- because each attempt
consumes another 32 bytes and misinterprets them.

**This hypothesis was tested and it is WRONG.** The discriminator named below was run:
`bad_header_mac`, `bad_frame_mac`, `short_header`, `frame_too_large` and `bad_rlp` were
counted in both nodes' logs, and there are **zero of all five**. Every one of the 38 crash
records is `exit:{timeout`.

That refutes it on its own terms. A stream 32 bytes out of step cannot produce a *timeout* as
its next symptom: the misread header fails `mac_header/2`, so the very next read answers
`{error, bad_header_mac}` and `fetch_wait/5` returns that error rather than a deadline. Zero
framing errors across ~40 minutes of two nodes hammering each other is not what a desynced
stream looks like.

**So the mechanism above is real code and a latent bug -- a partial read still discards 32
bytes and the advanced MAC counter -- but it is not what is stopping these two nodes**, and
recording it as the cause would have been the wrong claim to build the next change on. It
stays here because the byte-level test for it is still missing and the defect is real; it is
demoted from "the blocker" to "uncovered, not currently firing".

What the timeout *is* is the reading below, and the arithmetic is why: the numbers line up
with no free parameter.

**There is no test for it, and that is the larger fact.** `eth_rlpx_tests` exercises the
handshake, the Hello exchange, Ping/Pong and MAC tampering -- and **`recv_frame/3` is never
called by any test in the repository.** The receive path of the framing layer, which is the
one place a byte-level slip becomes permanent, is the only part of it with no coverage.

The test that would bite needs the frame split across two TCP segments, which a plain loopback
pair cannot produce because `send_frame/4` writes header and body in one `gen_tcp:send`. The
way to do it without reimplementing the framing is a **transparent byte relay** between the
two sockets that forwards the first 32 bytes, waits, then forwards the rest. Writing the
crypto by hand in the test would be a second implementation of `send_frame/4`, which is the
fixture-identity trap.

### The other reading of the same evidence, not yet excluded

`eth_peer_conn:handle_info(poll, ...)` calls `eth_rlpx:recv(Sess, Sock, ?POLL_MS)` with
`?POLL_MS = 1000`, **inside a `handle_info` callback**. A `gen_server` processes its mailbox
FIFO, so every message behind a poll waits up to a second. A stable backlog of ~20 messages
would then put a `'$gen_call'` at the back of ~20 seconds of polls -- which is exactly the
observed 20,000 ms budget, arrived at from the other direction.

**Both readings predicted the same number**, and that is why the one-line experiment was worth
naming in advance: 20 messages x 1,000 ms = the timeout, with nothing left to fit. The
partial-read reading predicted `bad_header_mac` in the logs; the queue reading predicted none.
**The logs have none, so the queue reading survives and the other is refuted.**

**Still unmeasured, and it is the thing to measure next:** that the latency scales with the
backlog. Nothing outside the process can observe it now -- `net_peerCount` answers from the
manager and no longer calls the conn, which was the point of `cd511da`, so the one method
that used to time a conn call is deliberately gone. The measurement has to be a test: put `N`
messages in a live conn's mailbox and time a `handle_call` to it, with `N = 1, 3, 10`, and
check the answer is about `N` seconds. If it is, the fix is to stop blocking for
`?POLL_MS` inside `handle_info/2` -- and the reason `cd511da` is worth stating here is that
it removed a symptom without touching this, so a green `net_peerCount` and a stuck `eth_sync`
are not in conflict.

### Two operational scripts, tracked now, and four of their statements were false

`tools/two-node-p2p.sh` and `tools/two-node-status.sh` are how this pair is run and how it
is watched. Both were **untracked**, so none of this was in the repository, and **four
statements in them were wrong** -- two of them about things this file had already measured
and corrected. Every one of the four was found by reading the script while fixing another
thing, and none would have been found by a test.

| What the script said | What is true |
|---|---|
| "the peer conn completes the eth handshake and then dies ~33s later with enotconn on poll while lsof still shows the socket ESTABLISHED" | **Does not happen.** `e823649` measured a fresh pair over 60 s: `peer_up` = 1, `conn terminating` = 0, diagnostics rising. `peer_status/1` answering `{error, down}` is what read as a death -- and the socket was ESTABLISHED *because* nothing had closed it. |
| "See the repo README section 'Two local nodes' for the measurement." | **There is no such section in `README.md`.** A pointer to a place that does not exist is worse than none: a reader either finds nothing and stops, or believes a section was removed. The measurement is here, attributed to a commit. |
| `logs A\|B` tails `erlang.log.1` | **That is whichever rotation the current run is in, until it grows.** `eth_peer_conn` rotates on size, so `erlang.log.1` becomes a file that stopped receiving events. It is now `ls -t | head -1`, and a missing file is reported missing rather than substituted. |
| the 10 s RPC timeout exists because `net_peerCount` measured 2091-3525 ms | **That is fixed** (`cd511da`; it is now ~1-2 ms). The timeout is still right, and now for the reason that is actually true: `eth_gasPrice` on the node with **no upstream** falls back to a dead endpoint and lands at **6007 ms** (5 samples, min 6006.3, max 6014.6). |

**The `logs` defect is the one that cost an hour**, and it is the same defect committed in
prose one commit earlier: reading a stale log rotation and reporting what it does not contain
as a fact about the running node. This repository concluded "node A has no inbound connection
at all" from a rotation whose last line was 28 minutes old, while the live file held 175
lines naming the peer exactly. The script had the bug that produced the mistake.

#### And two that were not statements but mechanisms that had never run

* **`two-node-status.sh`'s live mode had never worked.** Line 141 printed `$RPCA` and
  `$RPCB`; the variables are `RPC_A` and `RPC_B`, so under `set -u` the script died on the
  first refresh with `RPCA: unbound variable`, exit 1. Its `--once` mode worked, **so the
  one path that got exercised was the one that happened to work.** The live mode is now
  verified end to end.
* **The `dyn` column always read `+0`,** and the header promises the opposite. `PREV_A=()`
  sat *inside* the `while true` loop, so the previous sample was cleared before `row/3`
  could compare against it. A delta needs the sample before the one being drawn.

**Verified with a stub, not against the live pair** -- and that distinction is the point.
Both real nodes are stuck at their head, so `dyn +0` is the correct reading there and cannot
distinguish a working delta from a broken one. Against a stub that advances its head by 7
per request, with both node variables pointed at it: **`+0, +0, +14, +14`** -- the first two
are each slot's first sample, then 14 per refresh, which is 7 x 2 requests. With the reset
put back inside the loop the same stub reads `+0` forever. **A stuck subject and a broken
feature produce the same output, and the subject here was stuck by an unrelated bug.**

#### `start` could not have worked either

`node_id_of/1` ran `erl -s nid main`. **There is no `nid` module in this repository**, so it
printed nothing and the guard on line 149 would have exited 1. It derives the id properly
now: `eth_ecies:pubkey/1` over the 32 raw bytes of `data/nodekey`, which are the *private*
key, giving the 64-byte public key an enode wants. Checked against the node's own log rather
than assumed -- A logs `id=0EB87AAFD7CAF95B` and the derivation produces `0eb87aafd7caf95b...`.

The first version hexdumpped the nodekey and used those bytes as the id, which is the private
key wearing the public key's name. **It worked anyway**, because a bootnode enode's id is not
what the dialer matches on: it dials host:port and learns the real id from the Hello. So the
wrong value was invisible in exactly the way a wrong value here usually is -- and I made it
by hand earlier in this same investigation before checking.

**`start` now completes, measured rather than inferred: 80 s wall clock, both nodes up,
`net_peerCount 0x1` on both.** That is the fix verified, not the code reading that motivated
it.

**And one observation does not fit that explanation, recorded because a tidy account that
swallows a loose end is how the next reader gets misled.** The first attempt to run the fixed
`start` **timed out after 30 minutes having printed nothing at all** -- not "could not read A's
node id", not even the first `say` at line 122. Everything observed since is consistent with
the code reading: `stop` returns in under a second, `start` finishes in 80 s, and no
`erl -noshell` is left behind. None of that explains a run with no output whatsoever. So
either the hang was in `stop_one`/`epmd` at that moment, or there is a second fault in this
script that has not been reproduced. **Not reproduced is not the same as absent**, and it is
written down here rather than dropped because the alternative is a claim that everything is
understood.

### Open question, newly found by fixing the script: the chain store holds hashes as hex text

`/health` reports `chain.headHash` as `0x30783230626162...`, which decodes to the ASCII
string `"0x20bab966..."` -- 66 bytes of hash **hex text**, where this codebase's convention
is 32 raw bytes. `tools/two-node-status.sh` had this filed as a **`/health` encoding bug**:
the handler encoding the value a second time.

**It is not, and `/health` is the one thing here that is telling the truth.** The same bytes
come out of the store: `erl_call -a 'eth_chain head []'` prints
`{11846219, #Bin<48,120,50,48,98,97,98,57,54,54,...>}`, and 48/120/50/48 is ASCII `0x20`.
`eth_chain:block_hash/1` is `maps:get(<<"hash">>, Block, <<>>)`, so the store holds whatever
representation the block map carried, and `/health` reports that faithfully. Fixing `/health`
would have hidden it -- the same shape as a fabricated check hiding the real ones behind it.

**Not shown to cause anything, and that is stated rather than implied.** `missing_parent`
compares a block's `ParentHash` against the stored head, so if the two representations ever
disagree the chain cannot link. This node has appended 11,846,219 blocks, so on the path it
took they evidently agree. **Which path that was is the open question**: blocks that arrive
over p2p are decoded by `eth_eth`, and blocks that arrive from upstream JSON-RPC are decoded
by the projection, and there is no test asserting that the two put the same bytes in a
`<<"hash">>` field. Filed as a question, not a defect.

### Fixed, and it is NOT the sync blocker: a frame could block for twice its budget

`eth_rlpx:recv_frame/3` read a frame in **two `gen_tcp:recv` calls handed the same
`Timeout`** -- 32 bytes of header, then `RSize + 16` of body -- so a frame could block for
twice what it was given: the header read takes `Timeout`, and if it succeeds on the last
millisecond the body read takes `Timeout` again. `eth_peer_conn:fetch_wait/5` re-derives the
remaining time *between* iterations of its loop and this function re-derived nothing *within*
one, so the two together spent the budget twice and nothing checked.

One absolute deadline now runs through both reads (`recv_frame_until/3`), and the guard is
`max(1, Deadline - now)` because **`gen_tcp:recv/3` reads a timeout of 0 as *wait forever*** --
so an exhausted budget would have become exactly the thing the deadline exists to prevent.

**This is the first test in the repository that calls `recv_frame/3` at all.** It needs a byte
relay, because a plain loopback pair cannot produce the shape: `send_frame/4` writes header
and body in one `gen_tcp:send', so a frame is always whole by the time a socket sees it.
Writing the framing by hand in the test would be a second implementation of `send_frame/4`,
which is the fixture-identity trap -- a hand-written preimage agrees with the code by
construction and disagrees with it silently. The relay holds a write for 800 ms, forwards only
the first 32 bytes and parks the rest; `recv/3` is given 1000 ms and the assertion is at
1400 ms, which is 400 ms above the correct answer and 400 ms below the old one. Restoring the
double spend turns it red.

**And the measurement did not move, which is the result.** Re-running the pair after the fix:

| | before the fix | after |
|---|---|---|
| diagnostic gap, median | 4-5 s | **19.01 s** |
| diagnostic gap, max | 19.03 s | **54.15 s** |
| `sync tick crashed`, B | 11 in ~40 min | 12 in ~4 min |
| B | `chain_empty` | `chain_empty` |

**So this is a real defect, with a test that bites, and it is not what is stopping the sync.**
It is committed because it is a defect -- a deadline that is spent twice is a deadline that is
not a deadline -- and recorded here because the reasoning that produced it was wrong in a way
worth keeping.

### What the ~19 s actually is, and the four things that are now ruled out

**The method that located it, because it is the transferable part.** `?DIAG_MS` is 1000, so a
gap in the diagnostic **is** the length of the block: a `gen_server` cannot process a message
while it is inside `handle_call/3`, so the tick's absence is the measurement. Intervals of
19.01 s and 19.03 s on two independent processes are a shared timer rather than a coincidence.

**What that method cannot do, which I asserted it could.** I read "24 samples, none with
`fetching = true`" as *the conn is never inside a fetch*. **That is backwards: the diagnostic
cannot observe the state it is in**, because observing it is what being blocked prevents. It
went into the first version of this entry as evidence.

Measured, on this pair, and each one ruled out:

| Candidate | Measured | Verdict |
|---|---|---|
| RLP decode of the 192-header payload | **4 ms** (157,636 bytes, 821-byte headers) | out |
| `eth_eth:verify_chain/3` on 192 linked headers | **289 ms**, returns `ok` | out |
| `eth_keccak:hash/1` | **3 ms** per 821-byte header | out |
| the frame's double-spent `Timeout` (above) | fixed, test bites | **out** |

**Request-side work is therefore about 0.3 s, against a 15,000 ms fetch deadline and a
20,000 ms call budget.** So roughly 3.7 s of the ~19 s is still unattributed, and 15 s of it is
inside `fetch_request` -- which means either the deadline is still being overrun by something
this measurement cannot see, or the block is not one `get_headers` call.

**That last one is the fork, and it is not resolvable from the outside.** `eth_sync:walk_back/5`
may issue two calls back to back; a `'$gen_call'` queued behind another one is served only
after the first returns, so a block can be two 15 s fetches with the diagnostic tick invisible
across both. Distinguishing that needs the number **from inside the handler**: elapsed time of
each `handle_call({get_headers, ...})', and the fetch's own result beside it. That is one log
line and it is not written yet.

Two mistakes of mine are recorded because they cost the time and would cost it again:
`binary:copy(<<I:256>>, 32)` is 1024 bytes, not 32 -- my first header template was 14,157
bytes and every measurement taken through it was of a header 20x too large; and
`verify_chain/3` **returns on the first broken link**, so an unlinked fixture measures nothing
at all while looking like a fast success. Both were caught by printing the encoded size and
the return value instead of believing the timing.

### Fixed: a conn that is fetching no longer stops answering peers

`handle_info(poll, #st{fetching = true}, S)` does not read the socket at all while a fetch
owns it, and `fetch_wait/5` **discarded** any frame that was not the awaited response. So for
the whole 15,000 ms of a fetch this process answered nobody -- and when both peers fetch from
each other, neither one ever sees the other's request. That is not a slow peer; it is a deaf
one, and the two look identical from the caller's side.

**Measured, on the pair in `tools/two-node-p2p.sh`, before the fix.** Both nodes logged

```
get_headers n=0 ms=15002 -> {error, timeout}
get_headers n=1 ms=15002 -> {error, timeout}
get_headers n=2 ms=15003 -> {error, timeout}
get_headers n=3 ms=15006 -> {error, timeout}
get_headers n=4 ms=13    -> {ok, ...}          <-- the only success, in thirteen
```

**Every failure lands on the millisecond of the 15,000 ms fetch deadline**, and the single
success is the only moment either side was not inside a fetch. A `get_headers` call that
returns `{error, timeout}` at exactly the deadline is a peer that answered nothing, and the
one that returned in 13 ms is the same code path on the same second.

**After the fix, same pair:**

```
B: n=2 ms=14 -> {ok, ...}   n=3 ms=12 -> {ok, ...}   n=4 ms=11 -> {ok, ...}
A: `fetch_wait served an unrequested frame' logged 9 times
```

**The test is the same shape and reproduces the same numbers.** `eth_peer_tests:autodial/0`
asks one side for a block the peer does not have -- and `eth_eth:serve_headers/5`'s
`{error, _}' branch sends **no frame at all**, so the fetch waits out its full deadline
without a network or a timer -- and then has the *other* side ask for something that does
exist. Injecting the discard back:

```
peer fetch test: served in 15002 ms -> {error,timeout}
```

which is the live measurement, in a unit test, to the millisecond. There is no timing race
here: the blocking fetch is 15,000 ms long by construction.

`fetch_wait/5` now calls `handle_msg/3` on the frame it did not expect. The Ping clause two
cases above already replied inline, so this is that same treatment extended to every code --
which is what a devp2p peer must do: serving a peer while fetching is normal, not an
exception. **This is the structural change `TASKS.md` had recorded as "correct and much
larger, and it touches framing state"**; it turned out to be two lines, because `fetch_wait`
already read the frame and already knew how to handle it.

**A diagnostic that earned its place.** `handle_call({get_headers, ...})` now logs the elapsed
time, the call's ordinal within the process, and the shape of the reply:

```
etherlang: get_headers n=4 ms=11 want={hash,<<...>>} max=192 skip=0 rev=true -> {ok, 1}
```

The ordinal is the part that matters. **The gap in the per-second diagnostic cannot tell
"one call overran" from "two calls back to back"**, because a `'$gen_call'` queued behind
another is served only after the first returns and the tick is invisible across both; the
ordinal can. And `want=` prints the hash's first 4 bytes rather than all 32, because the full
form wrapped the line and put the result on a continuation, where one grep cannot see it.

### And the reason B still does not sync: A has one block in its store

With the deafness gone, B's requests succeed -- and return **`{ok, 1}`**. One header, not the
192 asked for. `eth_eth:walk/6` is correct (`Rev = true` steps `Num - 1`); it stops because
`eth_chain:get_by_number/2` finds nothing one below the head.

**A's `/health` reports `chain.blocks = 1`.** Its `eth_getBlockByNumber` answers for the head
*and its parent* -- but those answers come from the upstream RPC, because `base_source` is
`upstream` on A. The chain store holds the head and nothing else.

**So the `excess_blob_gas_mismatch` at 11,846,220 is not "A cannot advance". It is "A has no
chain to serve",** and B cannot sync from a peer with one block no matter how well the two
nodes talk. That reorders the remaining work: the blob-gas rule is now the blocker for p2p
sync, not a separate consensus defect.

### A build that failed for several cycles, and what I concluded from it

**The `fetch_wait/5` fix referenced `S1` where the parameter is `S`, so it did not compile**,
and neither did an instrument inserted into `serve_headers_req/2` with a stray `;`. Two
consequences, both mine:

* `rebar3 as prod release` output went to `/dev/null` in the rebuild loop, so a **failed build
  produced no evidence and the old release kept running.** I then measured the pair, concluded
  "the fix does not help", and wrote that down -- three rebuild cycles against a tree that had
  never contained the change. The tell was available the whole time and I did not look for it:
  `grep base=` in the running node's log returned **nothing**, which is not what a successful
  rebuild looks like.
* AGENTS.md's rule is that `warnings_as_errors` makes any warning a failure. It does not say a
  *compile error* is loud, because a release build redirects it away. **A verification step
  that shares its plumbing with the step it verifies checks nothing** -- `>/dev/null` on a
  rebuild is the same mistake as the `cp` from the wrong path.

And one more, in the same family: `io:format/1` inside a test is how the `{acceptor_hello, _}`
versus `{acceptor_hello, ...}` mix-up was found at all -- a receive that never matches and a
receive that matches nothing print the same until you look at what is actually in the mailbox.

### Fixed: the validator read the header's `blob_gas_used` where EIP-4844 says the parent's

EIP-4844's update rule is

```
excess_blob_gas(parent) = max(parent.excess_blob_gas + parent.blob_gas_used
                             - TARGET_BLOB_GAS_PER_BLOCK, 0)
```

`eth_block_validator:excess_blob_gas_mismatch/3` passed `num(Header, <<"blobGasUsed">>)` --
**the header's own** value. `eth_fork_schedule:excess_blob_gas/3`'s parameters are named
`ParentExcessBlobGas, ParentBlobGasUsed`, so the call site was contradicting the function it
calls.

**Every validator fixture had `blobGasUsed = 0` in *both* parent and child**, so the two
readings agreed and no test could tell them apart. Not a missing test -- a fixture whose two
arms are the same number. The new test gives the parent 9 blobs and the child none.

```erlang
%% before the fix:  {excess_blob_gas_mismatch, 786432, 0}
%% after:           ok
```
and injecting the old field back turns it red with that exact value.

**The control is the more informative half.** A child using 9 blobs with an
`excessBlobGas` of 0 is **valid**, and the first version of that test asserted a mismatch. It
failed with `{value, ok}` after the fix, and it was wrong to assert a refusal: the header's own
`blob_gas_used` does not appear in the expression at all, so nine blobs there can neither
create nor excuse a mismatch. Corrected to assert `ok`, and renamed to say what it holds.

### The blocker is NOT closed, and the residual is unexplained

A still refuses to sync, and the log says so on every attempt:

```
append failed ({invalid_header, 11846220,
                {invalid_header, {excess_blob_gas_mismatch, 210359169, 208961068}}})
```

The computed value moved from **208436780 to 208961068**, so the fix is live in the running
build. What has **not** been established is where the remaining difference comes from, and
three of my attempts to infer it were all wrong, which is the part worth recording:

1. I assumed the target was Cancun's 393216 and reverse-solved the chain's own numbers for it.
   **The reverse-solved "target" came out as 14, 7.33, 12, 4, 14, 8.67, 5.33, 14, 6, 3.33**
   across sixteen consecutive blocks. A consensus constant cannot do that, so the model -- not
   the chain -- was wrong.
2. I called `eth_fork_schedule:excess_blob_gas(cancun, ...)` to find out what the code
   computes, and it returned 210,402,860, which is **neither** number in the log. The node was
   using **1835008 (14 blobs)**, i.e. a later fork the schedule does have. I had probed the
   wrong fork and treated the answer as the code's behaviour. Using the right fork, the *old*
   code reproduces its own logged number exactly: `210140716 + 131072 - 1835008 = 208436780`.
   **So `target_blob_gas_per_block/1` is not missing a BPO fork** -- that claim in this entry
   was wrong before it was written.
3. I compared A's stored head against upstream field by field, expecting the divergence to be
   in the decode path. **All eight fields match**, including `excessBlobGas = 0xc867e2c` and
   `blobGasUsed = 0xa0000`. That hypothesis is dead too.

**What is left is 1,398,101, and no consistent model reproduces it.** The obvious next
instrument is one line inside `excess_blob_gas_mismatch/3` printing `PEG`, `HEG`, `PBGU`, the
resolved `Fork` and `target_blob_gas_per_block(Fork)` -- the node's own inputs, rather than an
inference from a remote endpoint. That is not written. **Three wrong inferences in a row is the
signal that the remaining work is measurement, not reasoning.**

### Amsterdam activated on 2026-10-06 and the node cannot certify a block past it

**This is now, not eventually.** Sepolia's `amsterdamTime` is **1791294816 =
2026-10-06T13:53:36Z**, read from go-ethereum's `params/chainspecs/sepolia.json`, and the
node's own schedule already carries `{time, 1791294816, amsterdam}` -- so the fork *is* named
and *is* scheduled. What it does not have is the **rules**.

`eth_fork_schedule:past_modelled_range/3` takes the frontier from `last_activation/1` of the
network's schedule, so **the newest modelled fork becoming active is by definition "past the
modelled range"**. The function's own comment says this is intended -- "Sepolia's modelled
range ends at Amsterdam, 2026-10-06. On that day this function starts answering `true' for its
head" -- and the refusal is **correct behaviour**: a block past the range would be executed
under rules the node does not have, and a wrong figure is worse than a declined
certification. The design is working; the node is behind.

### The modelled-range frontier was the wrong question, and it stopped the node twice

`past_modelled_range/4` took **the schedule's newest activation** as its frontier and
answered "therefore the node is one fork behind". That is only a valid inference while the
node lacks that fork's rules, and it stopped being one twice:

* **2026-10-06, Amsterdam.** Sepolia activated it and `eth_tx_validity_tests` went red
  (a fixture carrying the wall clock), then the node stopped accepting blocks entirely.
* **The frontier now asks the other question**: the newest fork the node has **no rules
  for**. Amsterdam's rules are present -- `slotNumber`, `SLOTNUM`, and EIP-7928, whose gas
  table is EIP-2929's unchanged -- so no schedule has an unmodelled fork and the answer is
  `false` everywhere.

**The guard moved from a date to a test, and that is strictly better.** With every named
fork modelled the runtime check *cannot fire*, which is stated rather than left looking
armed. `every_fork_this_module_names_is_modelled_test` and
`no_scheduled_fork_is_left_unmodelled_test` assert the relation directly, so a fork added
to a schedule without rules fails at the moment it is added -- naming the fork -- where
the old form only moved a frontier nobody reads.

**My first `modelled_forks/0` had six names and omitted every pre-merge fork and the whole
BPO series.** `bpo2` was then the newest *unmodelled* entry, the frontier moved **earlier**
than before, and the node would have refused everything after BPO2: a larger outage than
the one being fixed, introduced by the fix. The completeness test caught it on its first
run, which is the only reason it was not shipped.

**`past_modelled_range` is now unreachable and is named as such.**
`eth_block_validator:unreachable_rule_names/0` lists it and the coverage test asserts that
set, so the rule stays in the log vocabulary. Fabricating a schedule entry to keep a
fixture would have made the coverage test pass by *asserting* the rule rather than
exercising it.

### The payload encoder spelled three header shapes and needed five

`payload_header_rlp/4` handled `paris`, `shanghai` and `cancun`. **A Prague payload was
encoded as a 20-field Cancun header** -- EIP-7685's `requestsHash` missing -- and an
Amsterdam one as the same 20 fields, missing `requestsHash`, `blockAccessListHash` and
`slotNumber`. `payload_block_hash/1` answered a hash that is not the block's, which
`newPayload` reports to the client as `INVALID_BLOCK_HASH` on a perfectly valid payload.
`eth_block_payload_tests` pinned Paris, Shanghai and Cancun and had **no Prague case**,
which is the whole reason this survived; that is the same shape as the earlier
`requestsHash` omission and the fixture that would have caught it.

Fixed: `payload_header_fork/1` now tells Prague and Amsterdam apart by the fields the
payload carries -- `ExecutionPayloadV4` "has the syntax of ExecutionPayloadV3 and appends
the new field: `blockAccessList`", and its listing carries `blockAccessList` and
`slotNumber` -- and the encoder emits 21 and 23 fields.

**The block access list's commitment is now checked, which is the item this file recorded
as unverifiable.** `block_access_list_hash = keccak256(rlp(block_access_list))`, and
`ExecutionPayloadV4` carries `blockAccessList` as the RLP bytes themselves -- so **the hash
is over those bytes directly** and the BAL's internal structure never has to be decoded.
The earlier note was true of the public JSON-RPC this node syncs from (`eth_getBlockByNumber`
returns only the hash; `debug_getBlockAccessList` does not exist there) and false of the
Engine API, which is where a proposer actually sends it. The empty case is pinned three
ways: EIP-7928's stated `keccak256(rlp([]))`, this repository's `empty_uncle_hash()`, and
the computation -- all `0x1dcc4de8...`.

**`requestsHash` is computed, not refused -- and my reason for refusing it was wrong.**
`eth_fork_schedule:requests_hash/1` implements EIP-7685's `compute_requests_hash`, and
`engine_newPayloadV5`'s **fourth parameter is `executionRequests`** (execution-apis
src/engine/amsterdam.md), so the value is a pure function of what the client sends. The header
term is derived from it whenever the payload does not carry the field.

**The note this replaces asserted that `requestsHash` "lives in the beacon roots contract's
storage", and that is false.** EIP-7251 is about consolidation requests and defines no such
slot -- its constants are a queue at a predeploy address. **The right source was the newPayload
parameter list, one document from the one I had read.** A comment written from a
half-remembering became a refusal, and the refusal read as careful rather than as a gap in what
I had actually checked.

**It is `sha256`, not keccak**, and this is the only non-keccak commitment in the module --
worth stating because `eth_keccak:hash/1` is the reflex here and it is the wrong one. Three
rules, and the second is the one a plain loop gets wrong: items with empty `request_data` are
**excluded**; items are **sorted by `request_type` ascending**; and the outer hash is over the
**concatenated inner digests**.

**The empty case is the chain's value.** `sha256("")` = `0xe3b0c442...`, which is exactly what
real Sepolia Prague block 11,722,100 carries -- the value this repository once read as "SHA-256
of nothing, therefore invented" and hand-entered.

**Where the sort leaves a choice, it is recorded as one.** EIP-7685 says only "ordered by
`request_type` ascending" and nothing about two requests sharing a type. `lists:sort/2` is
stable, so the caller's order survives, and the test asserts that the two orders hash
*differently*. My first version asserted they hash alike, which would have demanded an ordering
the specification does not define -- and a node that invented one would disagree with every other
client exactly where nobody can check it.

**The coverage gap is closed, and it took two rounds because the first attempt was removed
un-green rather than committed failing.** The tests above prove only that the new terms
*participate* -- two payloads differing hash differently -- and three injections satisfied
that: BAL bytes returned un-hashed, `requestsHash` appended twice, `slotNumber` before
`blockAccessListHash`.

The tests that close them rebuild the header through **`eth_header:hash/1`, a second encoder
with its own field list**, and compare hashes -- the technique that pinned `requestsHash` when
it was added. **One per shape, and Prague was not redundant:** after the 23-field test landed,
"append `requestsHash` twice" was *still green*, because it is the Prague branch and Prague had
no cross-check. **A test that pins one shape says nothing about its sibling.** Five injections,
five red.

**Two bugs the instrumentation had, both worth the space.**

* **`binary:encode_unsigned/2` raises `badarg` on every value on this OTP** -- verified
  directly, 6,985,356 included. Two attempts blamed zero and then negative integers, and
  neither was true. The error names neither the value nor the field, which sent me looking
  for the wrong thing twice: **a helper that cannot report its input turns a one-line mistake
  into a hunt.** `erlang:integer_to_binary/2` is the replacement, and the quantity helper now
  names the field in its own failure.
* **`eth_hex:decode/1` answers an integer and raises on non-hex; it is not a byte decoder.**
  Used for the BAL on the first attempt, which produced a `try_clause` with no clause to
  report, because the value was an integer and the guard wanted a binary.

### EIP-7918 was missing, and it is what stopped the node syncing

**This was the sync blocker and it is now fixed.** The node refused Sepolia 11,846,220
with `{excess_blob_gas_mismatch, 210359169, 208961068}` and retried it forever, so its
head sat at 11,846,219 and `net_peerCount` was 0 because there was nothing to serve.

**EIP-7918 adds a second branch to `calc_excess_blob_gas`, and this node had only the
first.** Quoted whole from `eip-7918.md`:

    if BLOB_BASE_COST * parent.base_fee_per_gas >
       GAS_PER_BLOB * get_base_fee_per_blob_gas(parent):
        return parent.excess_blob_gas
             + parent.blob_gas_used * (max - target) // max
    else:
        return parent.excess_blob_gas + parent.blob_gas_used - target_blob_gas

**The second figure is exactly the one the node logged as `computed`.** The defect is a
consensus one and not a stale fee: the two branches disagree on the committed
`excessBlobGas` header field, so the node computed a header no other client produces and
then rejected the chain's. Measured on 20 consecutive Sepolia transitions: **14 take the
EIP-7918 branch and 6 the original, and the union reproduces all 20 exactly.** The two
never both match, so no single formula explains the chain -- which is why seven attempts
to infer a target from the chain's own numbers all failed before the EIP was read.

**Three readings of the EIP were each wrong first, and all three would have shipped:**

* **The scaled term is a ratio, `used * (max - target) / max`, not `used - target`.** For
  Sepolia at BPO2 (target 14, max 21) the ratio is **exactly 1/3** -- which is where the
  "thirds of a blob" reading of the chain came from. It was never a fraction of a blob.
  The difference is visible in one line: five blobs raise the counter by 218453 under
  EIP-7918 and *lower* it by 1179648 under EIP-4844.
* **`blob_price` is a function of the parent's _excess blob gas_, not of the parent's blob
  gas used.** I passed the latter, which makes the price the 1 wei floor and the reserve
  test **vacuously true**, so the branch selection was wrong on **6 of the 20** transitions
  -- which is what made a rule that fits 14 of 20 look like it fit all 20 and leave the
  other 6 unexplained. This is the second time in this work that a wrong argument produced
  a plausible number rather than an error.
* **The schedule is the current block's, not the parent's** -- "the *new*
  `blobSchedule.max` and `blobSchedule.target` must be used". Only visible in the EIP's
  prose, not in geth's `calcExcessBlobGas`, which resolves the config by head timestamp
  and so cannot be read as though it were the parent's.

**`excess_blob_gas/3` became `/4` rather than gaining a sibling.** The parent's base fee
enters the comparison, so leaving `/3` in place would have been two answers to one
question -- the shape this repository treats as the worst one for a validation rule.

**Two of the new tests existed to close holes the first attempts left open**, and both
holes were found by injections that came back green:

* A fork-gate test using the pinned block's inputs at `prague` **stayed green with the gate
  deleted**, because Prague's update fraction makes the blob price `e^41.9` there, far above
  the reserve, so both branches agree by coincidence. **A gate test whose inputs make the
  gated path irrelevant is not a gate test.** The replacement uses an excess of 50,000,000,
  which puts the price under the reserve and the two branches 699,050 apart.
* Injecting `num(Header, <<"baseFeePerGas">>)` in place of `num(Parent, ...)` **left the
  whole validator module green**, because every fixture had the same base fee in parent and
  child. Getting them onto opposite sides of the 1,034,202,240 threshold needed EIP-1559
  to *lower* the child's fee (parent `gasUsed` at 12,000,000), which is the only
  arrangement in which the two readings differ.

**Untested, and named rather than hidden:** the comparison is strict `>`, and
`>=` was injected with the suite green. Reaching it needs
`BLOB_BASE_COST * baseFee == GAS_PER_BLOB * fake_exponential(...)` exactly, which is
`baseFee == 16 * price`, and no real chain produces it. The strictness is stated in the
EIP's own `if` and copied verbatim rather than pinned by a test.

**Amsterdam is two EIPs, not one, and the second one was found by hashing a block.**

| What | EIP | State |
|------|-----|-------|
| header field `slotNumber`, opcode `SLOTNUM` (`0x4b`, gas **2**) | EIP-7843 | header field, opcode, payload decode and Env wiring **all done** |
| header field `blockAccessListHash`, and the block access list itself | EIP-7928 | header field **done**, in this commit; the BAL **not** |
| `ExecutionPayloadV4` / `PayloadAttributesV4`, `engine_newPayloadV5`, `engine_getPayloadV6`, `engine_forkchoiceUpdatedV4` | both | **not** |

**I had this as one EIP and named `forkchoiceUpdatedV5`.** EIP-7843's own text says
`engine_forkchoiceUpdatedV4`, and the header carries a second field I had never heard of.
Both errors came from the same place: writing down what the EIP said about the *opcode* and
assuming the fork was only that. The field list came from geth's `core/types/block.go`, which
is a **reading** of the fork rather than of one document:

    RequestsHash        *common.Hash `json:"requestsHash" rlp:"optional"`
    BlockAccessListHash *common.Hash `json:"blockAccessListHash" rlp:"optional"`
    SlotNumber          *uint64      `json:"slotNumber" rlp:"optional"`

**And the second field was found by a failing hash, not by reading that list** -- I fetched a
real Amsterdam header, put `slotNumber` last, and `eth_header:hash/1` answered something that
was not the block's hash. That is the ordinary way a missing field announces itself, and the
schedule entry that named the fork had said nothing about either field.

**Amsterdam headers are 23 fields, and the node now hashes them correctly.** Sepolia block
**11,856,337** (timestamp 1791294816, which is precisely `amsterdamTime`, so the first
Amsterdam block on Sepolia) hashes to its claimed
`0xa03f956aeb69d3fa234d9894c4309f4bb089cca9b6440cb45066c9ba39222588` with
`blockAccessListHash` then `slotNumber` appended last. Block **11,856,336**, immediately
before it, has neither field and still hashes to its own claim -- which is what makes the
fields *optional* rather than a 23-field default, and a fixed-width encoding would change the
hash of every pre-Amsterdam block on every network.

**Both fields are `optional` and that is not a detail.** `0xe6048b5d...` and the integer
`0xe6048b5d...` have the **same RLP encoding**, because an RLP integer is minimal big-endian
and this value has no leading zero byte to strip. Every hash in the fixture starts with a
non-zero byte -- which is what a uniform 32-byte field usually looks like -- so **no fixture
made of real hashes can tell `opt_data` from `opt_qty`.** An injection switching
`blockAccessListHash` to `opt_qty` was green until a fixture with a deliberately zeroed first
byte was added, and that test is now the one that protects *every* hash field in the header,
not only the two new ones.

**`SLOTNUM` is implemented, and it is the only opcode in the interpreter that does not
default.** `0x4b`, gas **2**, `introduced_by` Amsterdam, and every neighbour is
`s_env(Key, Ctx, 0)` -- which answers 0 for an Env that does not carry the key. **Slot 0 is
the genesis slot and a real value**, so that default would let a block with no slot number
report one. `do_op/3` uses `maps:find/2` and refuses with
`{unsupported, {slot_number, absent}}` instead, and `block_env/2` builds the key
*conditionally* rather than seeding it.

**Gas 2 is against the family it sits numerically inside, and that needed measuring rather
than recalling.** `constant_cost/2` answers **2** for all of `0x41..0x46` and **5** for
`0x47` SELFBALANCE, **20** for `0x48`/`0x49`/`0x4A`; the EVM adds the address family's
extra on top, which is why `basefee_costs_20_test` exists. So the obvious move -- widening
the `0x41..0x46` guard to `0x4B` -- would have silently repriced **four** existing
instructions to fix one, and it is the kind of edit that compiles, passes nothing, and
ships. EIP-7843 says 2 and geth charges `GasQuickStep`.

**`base_gas_cost/3` is not fork-gated and that is by design**, which cost me an injection
before I read it: availability is `opcode_exists/2`'s job, and
`no_opcode_is_silently_unpriced_test` asserts the priced set at Cancun *exactly*. Adding
`0x4b` without adding it to the price table failed that test with
`{unexpected_prices, [16#4B]}` -- the table-driven test doing the one job it was built for.

**Both items this section listed as missing are now closed**, and the paragraph that listed
them is corrected here rather than left to rot:

* **`payload_header_rlp/4` built 20 fields for an Amsterdam payload.** It now spells 21
  (Prague) and 23 (Amsterdam), pinned against real Sepolia blocks by a second encoder.
* **The v4 payload objects did not exist.** `engine_newPayloadV4`, `engine_newPayloadV5`,
  `engine_getPayloadV4`, `engine_getPayloadV6`, `engine_forkchoiceUpdatedV4` and
  `PayloadAttributesV4` are all present.

**What genuinely remains is one thing, and it is not a code gap.** The block access list's
*contents* cannot be checked from this node's upstream: `eth_getBlockByNumber` returns only
`blockAccessListHash` and `debug_getBlockAccessList` does not exist there. On the Engine API
path it **is** checked -- `ExecutionPayloadV4` carries the RLP bytes and
`block_access_list_hash = keccak256(rlp(block_access_list))`. EIP-7928 changes **no execution
cost** (its gas table is EIP-2929's), so Amsterdam blocks execute correctly either way.

### A calendar-dependent fixture turned into a time bomb, and the refusal was the correct part

`eth_tx_validity_tests:child_block/3` built its blocks through `eth_block:new/2`, which stamps
`erlang:system_time(second)` (`eth_block.erl:130`). `eth_block:finalize/1` then validates that
timestamp, so **from 2026-10-07 every block the module built was refused** for being past the
modelled range, and `valid_nonce_is_required_test` failed in a suite that had been green at
1031.

**It fails with or without this session's other changes** -- verified by stashing them and
re-running -- which is the only way to tell a date from a regression.

The fixture now pins the timestamp to `1000001`, the parent's `1000` plus a second: after the
parent, as `timestamp_not_after_parent` requires, and decades inside every activation the
node models. **A test that depends on today's date is a test with an expiry date**, and this
one had one nobody wrote down.

**Production was never affected**, and the reason is worth recording: `eth_block_builder`
overrides the field with the CL's `payloadAttributes.timestamp` (`eth_block_builder.erl:258`)
and only falls back to `eth_block:new`'s default when the CL omits one. That fallback is the
same latent bug, on a path where the CL *can* trigger it.

### A local eth-netstats, and why the hosted one is not an option

`tools/netstats/` runs https://github.com/cubedro/eth-netstats (0.0.9) locally against a node.
That fork needs **no mongo**, and only node and npm.

**`ethstats.net` has no DNS record at all** from any public resolver -- checked against 1.1.1.1
and 8.8.8.8, with `registry.npmjs.org` and publicnode resolving as controls -- so there is
nothing to connect to, and no client package on npm any more (`eth-net-intelligence-api` and
`ethstats-client` both 404).

**Every figure on that dashboard is measured from the node's own JSON-RPC.** Fields the node
does not expose are sent as `null` so the UI shows a gap rather than a plausible number,
because the hosted service's failure was exactly that: it showed `peers: 33` and
`gasPrice: 998966348` while the node answered `net_peerCount 0x0` and
`eth_gasPrice 0x3d45b514`. `blockTime` is **derived** from consecutive height samples and says
so at the sampler, because a derivation presented as a measurement is how a number becomes a
claim the node never made.

**Upstream 0.0.9 has a silent bug that this repository had to patch to see anything at all.**
`Node.setStats/3` calls `callback(null, this.getStats())` and then **falls through** to
`callback('Stats undefined', null)` -- no `return`. `Collection.update/3`'s callback tests
`err !== null` first, so every *successful* update took the error branch, logged
"Update error: Stats undefined", and never forwarded to the dashboard. The stats were
recorded (`setBlock`, `setBasicStats` and `setPending` had all run), so **the server looked
healthy and the UI showed nothing** -- the same failure as the hosted service, by a different
cause. One line, kept as `netstats-0.0.9-missing-return.patch`.

Three more things cost real time and are in the script's comments: `/api` is the socket that
carries `hello`/`update` and `/external` is the collections channel, so a message posted to
the wrong one **connects cleanly and produces no log line at all**; the dashboard socket sends
nothing until the client says `ready`; and the dashboard's vocabulary is its own --
`Node.setBasicStats/2` reads `active`, not `online`, and ignores a top-level `height` entirely
in favour of `stats.block.number`.

### Also found, also open

| Item | Evidence |
|---|---|
| **A cannot advance the chain.** `append failed ({invalid_header,11846220,{invalid_header,{excess_blob_gas_mismatch,210359169,208436780}}})`, repeated ~150 times, leaving the local head at 11,846,219 while Sepolia was at 11,846,760. An earlier run hit the same class at 11,772,398 and *did* get past it, so it is not simply a wrong constant -- it is unexplained. | A's log |
| **`/health` double-encodes `headHash`.** `0x30783230626162...` decodes to the ASCII string `"0x20bab966..."` -- the hash's hex text encoded a second time. Every other hash in this tree is the raw 32 bytes. | `curl :8545/health` |
| **`DISCV4_PORT` and `RLPX_PORT` must be equal or the node is unreachable by bootnode.** `eth_discv4:parse_enode/1' builds `#{udp => Port, tcp => Port}` from the single port in an enode, but `eth_config` lets the two differ. Measured: `pending => 1` forever, `table_size => 0`. The node only warns when they are *equal*. | two-node run |
| **`tools/etherlangctl` points at a tree the build does not produce.** It uses `_build/default/rel/etherlang`; `rebar3 as prod release` writes `_build/prod/rel/etherlang`. The `default` tree's `eth_config.beam` was dated 09-22 and its abstract code had **no `discv4_enabled/0` at all** -- so p2p never started and the node answered RPC from a stale 636 MB chain store looking completely healthy. | `lsof`, `beam_lib` |
| **`etherlang_sup:90-91` is stale.** It says "RLPx only speaks p2p Hello/Ping/Pong (no eth capability / peer fetch yet); RPC sync is unchanged", which `eth_eth` and `eth_sync:445` contradict. | reading |
| **`net_peerCount` costs 2.1-3.5 s.** `eth_peer:peers/1` calls into every peer with a 2 s timeout and the stuck connections each consume it. | two-node run |
| **A positive `net_peerCount` has no test.** The negative case is covered; the only fixture with a live eth peer has one that dies within a second, so a non-zero count would be a race rather than a test. Recorded in `eth_open_claims_tests`. | injections |

### The EthStats stack, and why it was abandoned

`docker compose --profile ethstats up` runs, the dashboard serves on `:3001`, and both
agents register (`etherlangLocal`, `etherlang2Local`). **It reports numbers this node
does not produce**: `peers: 33` and `peers: 35` while `net_peerCount` answers `0x0`, and
`gasPrice: 998966348` while `eth_gasPrice` answers `0x3d45b514` (1,027,850,260). Its
agent is a 2016-era web3 0.x application. `tools/two-node-status.sh` reads the nodes
directly instead, and says on its face what it cannot show (the discv4 routing table is
exposed by no RPC method, and a single sample cannot show whether a head is advancing,
so each row carries a delta).

**What a current geth uses instead:** `--metrics` exposes Prometheus-format metrics on
`:6060` (`--metrics.addr`, `--metrics.port`, `--metrics.influxdb`), which Prometheus
scrapes and Grafana renders. **etherlang has no metrics endpoint at all**, and that is
the real gap rather than anything about ethstats.

## Standing rule: a change to the node opens the ledger in the same commit

**A commit that touches `apps/etherlang/src/` must also touch `TASKS.md`, `README.md` or
`AGENTS.md`. Enforced by `make check-ledger`, not stated here and hoped for.**

This exists because the rule was broken four times in one pass and nobody noticed. Checked
against the source on 2026-10-05, **four entries in this file were false** -- each said
something was missing that had since been implemented:

| entry said | actually |
|---|---|
| "ECADD and ECMUL still conflate a rejected input with an absent implementation" | three distinct answers: `{ok, _, _}`, `{failed, {ecadd, not_on_curve}}`, `{failed, {ecadd, {coordinate_not_in_field, p}}}` |
| "Not done: KZG commitment verification" | `eth_kzg:verify/4` is the verification and is exported |
| "The catch-all `base_cost(_) -> 3` remains a fallback" | `eth_evm:base_cost/1` was deleted; the only four hits for the name are comments saying so |
| "What is still missing is EIP-150's 63/64 rule and the 2300 stipend" | `eth_evm:child_gas/4` implements both, clamp on the pre-stipend figure |

**A sentence cannot fail.** That is the whole reason a stale conformance figure survives, a
stale architecture count survives, and a stale open-items list survives -- and the first two
of those had already been given mechanical defences in this repository (`make counts`, and
`eth_published_figures_tests`). The list had none.

**Two halves, and the second is the one that keeps this file true.**

`make check-ledger` is cheap and mechanical: `src/` changed without a ledger file is a
failure. It does not check that this file is *right*, only that it was *opened*. Run against
the real history -- `make check-ledger AUDIT=<sha>` -- it flags four of this pass's own
commits: `93513c2`, `f74787b`, `1342660` and `5de6e08`, the last being the blob-schedule
work, whose absence from this ledger was a real omission and not a formality.

**Two modes, and the second exists because the first version was a gate that arrived one
commit late.** It read `git diff-tree HEAD`, so run *before* committing -- which is when a
gate is worth running -- it verified the **previous** commit and passed while the pending one
violated the rule. An instrument pointed at the wrong object reports honestly about the wrong
thing. It now judges `git diff --name-only HEAD`, staged and unstaged together, which is what
the next commit will contain.

**The version after that had a branch that could never be taken, and its comment described it
as existing.** An automatic "the tree is clean, so audit HEAD" fallback looked obviously
right. `.dockerignore` carries an uncommitted change that is not ours, so
`git diff --name-only HEAD` is **never** empty and the fallback was dead -- and I had written
a paragraph about it. The tell was printing which arm ran: it said "judging the pending
change" on a tree I had just called clean. **A branch you have never seen taken is a claim,
not a feature.** The fallback is gone and auditing a commit is explicit (`AUDIT=<sha>`),
which is also the better design: it stops one command meaning two different things
depending on untracked state, and a gate whose subject shifts under you is one you learn to
skip.

`eth_open_claims_tests` is what makes the file *accurate*. Each genuinely-open item is paired
with a check that must hold today, so **an item cannot be added without a passing check, and
an item whose gap has been closed fails its own and has to come out.** That is a ratchet, not
a list, and it is the only arrangement in which such a file stays true. Four items are in it:
Constantinople's SSTORE refused while every other pre-Berlin fork is priced; `eth_kzg`'s two
derivation functions absent while the verification is exported; `eth_evm:base_cost/1` gone;
and the interpreter's EIP-3860 charge still a second, un-gated copy of the schedule's figure.

**And the same decay was found inside `src/`, not only here.** `eth_state.erl` carried a
comment saying "`hex_to_bin/1` is still exported" for several commits after the function was
renamed, and `eth_evm:do_create/3` carried one blaming "this module has no fork" after
`eth_evm:run/5` began requiring a `fork` key -- **a real gap described by a reason that is
not**, which is why a reader who checks the reason leaves it alone.

## Three things settled, and how each was established

### p2p is on the critical path — settled by the operator, 2026-10-04

**This is a decision, not a measurement**, and it is the answer to a question this file had
carried unresolved across several passes: whether the peer transport is load-bearing for a
release or whether this node is a verifier taking state from a provider. It is load-bearing.

**What it changes, concretely.** Two carried findings stop being Tier 3 and become release
blockers, because both are on the peer path and a release that cannot hold a connection
cannot sync:

| Finding | Where it lives | Why the decision makes it blocking |
|---|---|---|
| One `NewPooledTransactionHashes` announcement stalls **its own connection for ten seconds** | `eth_peer_conn:handle_msg/3` | the peer path is the critical path, so a ten-second stall on a gossip class is a liveness defect and not a throughput note |
| **Every inbound p2p handshake performs a live upstream JSON-RPC fetch, and waits for it** | `eth_peer_conn:maybe_eth/3` → `eth_eth` | an inbound connection from an untrusted peer reaches an outbound dependency synchronously. This is F17, and it is the same shape as the one already closed for the peer manager (F14) |

And it makes **Phase 7 the load-bearing phase: 0 of its 7 tasks are done.** Seven consensus
clients, none integrated, plus the local docker-compose harness and mainnet readiness. With
p2p critical, a node that has never spoken to a Lighthouse, Prysm, Nimbus, Teku or Lodestar
has no evidence of the property the decision asserts.

**What it does not change.** Nothing about the code. No line moves for this; what moves is
which items gate a release, and a gate that has been reclassified is a gate whose cell has
to be re-measured rather than re-labelled.

**`RELEASE-GATE.md` is suspended and was not used to record any of this.** The operator's
instruction is to leave it alone, so the decision is recorded here instead — which is the
right home for it under AGENTS.md §12 anyway, since that names this section as the
authoritative work list. Where this file and `RELEASE-GATE.md` disagree about the status of
a finding, **this file is the one that was updated and the other is stale**, and that
inversion is the reason to be careful reading either.

### The version scheme, derived from the tags rather than believed

All three schemes in the tree were checked against `git tag` and **all three are wrong**.
The tag inventory is the evidence, and it is 97 tags:

| Shape | Count | Range |
|---|---|---|
| `vX.Y.Z` semantic | **22** | `v0.1.0` .. `v0.7.4` |
| `v1.N-<slug>` | **72** | `v1.0-block-production` .. `v1.66-7702-refund` |
| neither | **3** | `v1.63.1-access-list-address`, `v1.67`, `v1.68` |

So the semantic scheme in one file describes **only the v0 era**, which stopped being used
at `v0.7.4` on 2026-09-25 — twenty tags and the entire pre-1.0 history. The `v1.N-<slug>`
scheme in the other file describes the v1 era and holds for 72 of 75, with three exceptions
that are individually enumerable:

- **`v1.0` carries six tags** — `block-production`, `dev`, `engine-api`, `mpt`,
  `state-management`, `tasks`. **`v1.5` carries two** — `gas-tables`, `merge-detection`.
  So **`v1.N` does not identify a commit** for eight of the 72.
- **`v1.53` does not exist.** The series runs `v1.52-word-properties` → `v1.54-admission-rules`.
- **`v1.67` and `v1.68` have no slug**, and `v1.63.1-access-list-address` is a patch-level
  tag sitting inside the `v1.N` series beside `v1.63-7702-follow-delegation`.

**The consequence is the part that matters, and it is not cosmetic.** An attribution rule
that accepts a bare `v1.N` as sufficient is satisfied by `v1.0` and cannot say which of six
commits it means. Anywhere a figure is attributed to `v1.0` or `v1.5`, the attribution is
ambiguous by construction, and **an ambiguous attribution is the same failure as a missing
one** — a reader who trusts it is worse off than one who sees none.

**And 28 commits carried no tag at all** — the window since `v1.68` on 2026-09-30. Ten of
those are completed passes whose figures are recorded in this file and in `README.md`; under
a rule that requires a version tag, **every one of those figures was unattributable**, and
they were the most recent ones.

**Closed 2026-10-04: the window is tagged, `v1.69` .. `v1.97`, one tag per commit.** No pass
boundaries were guessed — this repository's convention is one behavioural change per commit
and the message states what the node now does, so every commit in the window is a completed
change. Numbering continues upward, and the script asserts that each `v1.N` is unused before
creating it, because **the historical `v1.0` and `v1.5` collisions are exactly what
reusing a number looks like.**

**The count in that paragraph was 28 when written and the tree then made it 29**, by one
commit — this file's own claim expiring the moment the work it describes landed. It is the
defect this section is about, and it happened inside the section.

**The rule that survives all of this:** a `git rev-parse --short HEAD` hash, which is unique
by construction, over any `v1.N`. A tag is a name a human chose and can be reused, renamed
or omitted, and this inventory is the proof of all three.

### Nothing above was taken on trust

Every number in this section was produced by a command in this repository, and two of the
three measurements contradicted the file they were replacing. That is the second time in one
session that a count written by this repository's own hand was wrong in a direction that
made the tree look better than it is: `README.md` carried three stale conformance figures
until a test was written to catch them (F-row Tier 0.4), and the task split above was wrong
by three in the flattering direction until it was counted per phase.

**The general form is the one AGENTS.md already has for published figures, extended to
counts of work:** a hand-written tally of what is finished is a claim about the work, it
decays silently, and nothing in the build notices. The three defences that have actually
caught something here are all mechanical — `make counts`, an eunit assertion, and `grep -c`.

## The one decision that is actually open, and what has already been settled about it

**Settled by measurement, so it is not part of the decision: `bpo3`, `bpo4` and `bpo5` can
never be the current fork.** No activation table in `eth_fork_schedule` mentions them —
mainnet's ends at `bpo2` and Sepolia's at `amsterdam` — and `current_fork/4` swept over every
timestamp either schedule contains, and a long way past them, answers `bpo2` and then
`amsterdam`. They are **names with no schedule**.

**And that is worse than dead, because the module contradicts itself about them.**
`bpo3`, `bpo4` and `bpo5` appear in exactly two places in `src/` — two `lists:member/2` gates
that mean "at Cancun and later" and "at Prague and later" — and neither has a `fork_rank/1`
clause. So a name the module *lists as post-Cancun* ranks **0**, which is Frontier, and
`at_least(bpo3, cancun)` answers **false** while `at_least(bpo1, cancun)` answers **true**.
The `fork_rank(_) -> 0` fallback is documented as "the safe direction, since a rule wrong
inactive is a rule the node declines to apply", and for an atom nobody has heard of that is
right. For these three it is not: they are not unknown, they are *known and unreachable*.

### The decision: what is the fork after Prague on mainnet, and is it in this node at all

**`fusaka` appears zero times in `src/`.** Not in the rank table, not in either activation
schedule, not in `eth_config`'s name list. And `amsterdam` — which *is* present, at rank 21,
with a Sepolia timestamp of 1,791,294,816 — is a **later** mainnet fork than the one that
follows Prague.

So the tree currently says the post-Prague mainnet fork is called `amsterdam`, and the
network's name for the fork that follows Prague is not in the tree at all. **Which of these
is intended cannot be derived from anything in this repository**, and the two possibilities
have opposite consequences:

- **If `amsterdam` is right**, then `bpo3`–`bpo5` are speculative and should be deleted from
  the two gates, and the open work is D-4: EIP-7691's blob schedule, where the parameters
  Osaka raises and each BPO revision changes again.
- **If the fork is `fusaka`**, then naming it `amsterdam` is a **consensus defect with a
  reachable symptom**: every mainnet block at or after that timestamp is priced, gated and
  hashed under another fork's rules, and the naming error is invisible because nothing in
  the tree holds both names to compare.

**What is not part of the question.** Whether the node refuses an unpriceable block — it
does, and that check is why a mis-named fork is a wrong answer rather than a crash. Whether
the conformance corpus would catch it — it would not, since a fixture's fork comes from its
own directory name and the corpus has no post-Prague suite. And whether `fork_rank/1`'s
fallback is safe — for genuinely unknown atoms it is, and that part of its comment is right.

**What would settle it, and it is not more reading here.** The activation timestamps and the
parameter changes for the fork after Prague are in `ethereum/execution-specs` and in the
client release notes, neither of which is in this repository (see §1 of `AGENTS.md`). One
fetch of either settles the name, the block or timestamp, and the parameter deltas — and
that is a smaller piece of work than the guessing it replaces.

## What to do next, in order

1. **The divergence fingerprints**  *(next, and these are concrete)*. The tally says
   `state_mismatch` 249 times, which is not a work list. `eest_report`'s gas-delta
   histogram is: a delta of a few thousand gas repeats because it is one missing
   schedule term, and a delta in the millions means a frame consumed its whole
   allowance where the fixture's did not. Of 229 comparable deltas:
   - ~~**The histogram's own blind spot.**~~  **Fixed in `v1.59`.** `add_gas_delta/3`
     kept only `abs(Delta) =< 100,000` and discarded the rest, and the report printed
     `(none in range)` when the map was empty — which is what it printed over the
     1,408-entry cluster in `apps/etherlang/doc/MEASUREMENTS.md`'s item 6a, all of them `no_comparable_gas`. The accumulator
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
     decompose the largest cluster, and this item has said "the tally says
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
     - ~~**ECADD and ECMUL conflate a rejected input with an absent implementation.**~~
       **CLOSED — the code was already fixed and this entry was not.** `bn128_add/2` and
       `bn128_mul/2` answer **three** distinct things, measured against the precompiles
       directly rather than read out of a comment:

       | input | answer |
       |---|---|
       | `(0,0) + (0,0)`, `(1,2) + (0,0)` | `{ok, 64, 500}` |
       | `(1,3) + (0,0)` — off the curve | `{failed, {ecadd, not_on_curve}}` |
       | `(p,0) + (0,0)` — coordinate ≥ p | `{failed, {ecadd, {coordinate_not_in_field, p}}}` |

       `unsupported` is reachable for `ecadd` only **below Byzantium**, where the precompile
       does not exist yet, and for the precompiles this node genuinely does not implement.
       EIP-196 lists the two invalidity conditions separately — "does not lie on the curve
       **or** any of the field elements is equal or larger than the field modulus p" — so
       they are told apart rather than both answered the same way.
       **The stated reason for not doing it was that a change here "could move the
       `byzantium/eip196_ec_add_mul` fixtures in a direction I had not measured". They did
       not move: that fixture is one entry of the committed subset and the subset's tally is
       asserted, so this is measured rather than assumed. **The entry was the thing that was
       wrong** — a note reading "named, not done" outlived the change that did it, and I
       repeated it in a status report before checking the code.
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
2. **Block-level conformance**  *(next after that)*. The corpus above is state transitions.
   EEST's `blockchain_tests` and the Ethereum Foundation's own `ethereum/tests`
   exercise what a state test cannot: state roots, receipts roots, logs blooms and
   block headers, over multi-block forks and transitions. Two thirds of the current
   divergences are `state_mismatch`, so fixing those comes first -- but a node that
   cannot produce a block another client would accept has not been measured at all,
   and that is the measurement Lighthouse actually cares about.

### Two local nodes: the handshake works, and the cold-start sync path does not exist

**Measured on a live pair, A synced to the Sepolia tip (11,875,097) and B given no upstream:**

| what | result |
|---|---|
| A `net_peerCount` / B `net_peerCount` | `0x1` / `0x1` -- **handshake works both ways** |
| B's view of A's head | present, 32 bytes, via the `eth/69` status forkid |
| `get_headers n=192 rev=true` from A | `{ok, 192}` in ~1.0 s, repeatedly |
| B's `eth_blockNumber` | `chain_empty` |
| B's `eth_sync status` | **times out** |

**So the p2p plumbing is sound and the defect is in `eth_sync`'s cold start.** Three things,
all measured or read:

1. **`?PEER_WALK_CAP` is 2048 headers.** `peer_catchup/3` walks back from the peer's head
   until it finds a local anchor, capped at 2048. From A's tip that reaches 11,873,049, and an
   empty store has no anchor there. **A cold node cannot bridge to genesis this way at all**:
   genesis is 11.87M headers back, i.e. ~61,900 `get_headers` calls. devp2p's `eth/68`
   `getBlockHeaders` also serves **forward** by number (`reverse=0` with a start number), and
   this node never asks that way -- which is the request a cold sync actually needs.
2. **`peer_fill/3` answers `{mode = follow, synced = true}` when it has nothing to append.**
   That is a node with an empty chain declaring itself synced. It is the same shape as the
   defects this file records elsewhere: **a status this node has not earned.**
3. **The walk runs inside the `eth_sync` gen_server**, so a tick longer than the caller's
   timeout makes `eth_sync:status/0` time out -- the node cannot report its own state while it
   is syncing. The walk needs to be bounded in *iterations* and yield between them, not bounded
   only in headers.

**Fixed here: the script, which is why none of this was measurable before.**
`tools/two-node-p2p.sh` did B's `-sname` rename **inside the tree-copy branch**, so once
`_build/node2/rel/etherlang` existed the `sed` never ran, B's `vm.args` kept
`-sname etherlang`, and B died at boot with `the name etherlang@HOST seems to be in use`.
`daemon` redirects to `/dev/null`, so a B that refuses to start is indistinguishable from a B
that was never started, and `status` said "not running" for both. **B had never started in any
measurement taken before this** -- which is the answer to why Phase 7 read 0 of 7 with nothing
obviously wrong. The rename is now unconditional and **verified**, because a step that can
silently do nothing has to be checked rather than assumed.

### The commit gate, and the failure that produced it

**`d47f57e` changed `apps/etherlang/src/` and committed with `make check-ledger` red. That
was this agent's error, not a rule that was unclear and not anybody else's.** The check
printed its verdict, the verdict disagreed with the commit, and the commit went anyway --
because the check is a *judgement* rather than a build failure, and nothing was running it.
TASKS.md was wrong until `1ede3b3` corrected it.

**The mechanism, because a note is not one.** `tools/git-hooks/pre-commit` refuses a `src/`
change with no ledger change, and refuses when `make check-ledger` fails.
`tools/install-hooks.sh` points git at it; `tools/check-gate.sh` **verifies the gate is
armed**, and `make check-gate` runs that.

**`core.hooksPath` pointing at a missing directory makes git skip every hook, silently.**
`git reset --hard` removed `tools/git-hooks/` while the configuration still named it, and
`git config --get core.hooksPath` printed a correct-looking value while enforcing nothing --
**found by committing through it**, which is the only way it would have been found. **A gate
that has quietly stopped existing is worse than no gate**, because the next red commit is then
a surprise instead of a reminder. Hence the third check in `check-gate.sh`: it commits a
`src/`-only change and requires it to be refused.

**Two things it deliberately does not do.** It does not run `rebar3 eunit` -- a four-minute
gate on every commit gets bypassed, and `warnings_as_errors` already makes a broken build fail
loudly. And it does not inspect the message. `--no-verify` still exists, because anything
bypassable can be bypassed; the point is that bypassing becomes a flag in the command line
rather than the default outcome of forgetting.

### Three version axes in one module, and they do not line up

`structure_for_version/2` is keyed on the **payload structure**, `frame_admission/2` on the
**fork**, and the **method number** on neither:

| method | payload structure | fork frame |
|---|---|---|
| `newPayloadV4` | `cancun` (V3-shaped) | `prague` |
| `newPayloadV5` | `amsterdam` (V4-shaped) | `amsterdam` |
| `forkchoiceUpdatedV4` | -- | `amsterdam` |
| `getPayloadV4` | `cancun` | `prague` |
| `getPayloadV6` | `amsterdam` | `amsterdam` |

**There is no `getPayloadV5`.** prague.md names `getPayloadV4` and amsterdam.md names
`getPayloadV6`, so version 5 has **no clause on purpose** -- an unmapped version is refused
rather than answered with a neighbour's structure. Forwarding the method version straight into
`frame_admission/2` raised `function_clause` on the first V6 attributes object; it asks
`in_fork_frame/2` directly now.

**`targetGasLimit` is in `PayloadAttributesV4` and in no EIP this fork is built from.** Not in
EIP-7843, not in EIP-7928, not in any header field this node encodes -- it is a *target*, and
nothing in the header commits to it. The structure check requires the object to carry a field
**this node has no rule for**, recorded at `required_attributes/1` rather than papered over: a
`gasLimit` other than the one the block's own header carries would change the block, and
nothing says which target wins.

**`attributes_frame_check/2` returned a boolean, and `attributes_admission/2` matches only `ok`
and `{error, Code, Message}`.** Every pre-fork attributes object therefore matched neither and
fell through to `ok`: **a refusal that reads as an acceptance**, and the most dangerous shape in
this work. Only a test that asks for the pre-Amsterdam case directly could see it.

**One test was checking the wrong object.** The `PayloadAttributesV4` assertion first passed
the *payload* fixture to `attributes_admission/2`, which checks a different structure
(`required_attributes/1` against `appended_attribute_keys/0`) -- so it would have passed on a
node that checked nothing at all.


### Deliberately later: the rest of the Engine API

These are real gaps, not low-priority decoration, but they are not on the critical
path to a node a consensus layer can drive — items 1 and 2 above are (they were
items 7 and 8 before `apps/etherlang/doc/MEASUREMENTS.md` took items 1–6). Left here so
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
- ~~**Engine API V4/V5** (Osaka, Amsterdam)~~ — **done**: `newPayloadV4`/`V5`,
  `getPayloadV4`/`V6`, `forkchoiceUpdatedV4` and `PayloadAttributesV4` all exist.
  `targetGasLimit` is required by the attributes structure and is in no EIP this
  fork is built from, which is recorded at `required_attributes/1`.
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
  **The block it builds is still not the block the network would build.** Its state root does not match the network's, for the reasons in item 7 — the same gas-schedule divergences that hold the conformance tally at 255 of 266 (2026-10-04) rather than all of it. So the item is closed as *wiring* and the divergence is tracked where it can be seen, not here.

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
- [ ] **State pruning** — implement archive, recent, and pruning modes.
  **Re-opened 2026-10-03.** This was marked done and the only implementation was
  `eth_state_management:prune_recent/1`, which computed `_KeepFrom`, carried the
  comment `%% Prune blocks older than KeepFrom`, and returned `{ok, pruned}`. It
  pruned nothing, and the module was never a child of `etherlang_sup` and had no
  caller in `src/`. The module has been deleted rather than left in place, because
  a `{ok, pruned}` that pruned nothing is a trap: it reads as the finished article.
    - Archive mode: keep all historical states — **nothing implements this**
    - Pruned mode: keep only recent states, prune old ones — **nothing implements this**
    - Full mode: keep all states, prune old state tries but keep history — `prune_full/1`
      returned `{ok, {archive, Num}}`, which is at least honest about keeping everything
  - Archive mode: keep all historical states ✅
  - Pruned mode: keep only recent states, prune old ones ✅
  - Full mode: keep all states, prune old state tries but keep history ✅
- [ ] **State expiration** — expire state older than `STATE_HISTORY` blocks
  (EIP-4444 client-side enforcement). **Re-opened 2026-10-03.** The only
  implementation was `eth_state_management:expire_state/1`, which computed
  `_ExpireAt`, carried the comment `%% Expire state older than ExpireAt`, and
  returned `{ok, {expired, _ExpireAt}}`. It expired nothing. Deleted with the
  module.
- [x] **History indices** — maintain history index for block hashes and receipts ✅
- [ ] **Full state sync** — download full state from peers using snap sync protocol
  - Snap code (EIP-1189) — download account/storage ranges
  - Boundary proof verification
  - Parallel range downloads
  - State trie reconstruction from snap data
- [ ] **Block hash oracle** — maintain block hash list for `eth_getBlockByHash`
  and consensus. **Re-opened 2026-10-03.** `eth_block_hash_oracle` was a real
  implementation and a dead one: it is called from five places, all of them
  inside `eth_state_management`, which nothing calls. Deleted with the module.
  Note that `eth_chain` keeps a genuine hash and transaction index
  (`index_txs/4`, `unindex_txs/2`, and the hash table `eth_getBlockByHash`
  reads), so the *lookup* works — what never existed is the oracle as a
  separate list maintained alongside the chain.
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
  - ~~**What is still missing is the part a price table cannot express at all: EIP-150's
      63/64 gas-retention rule and the 2300 stipend.**~~ **Both are implemented, and the
      entry is the residue of the work that did them.** `eth_evm:child_gas/4` asks
      `eth_fork_schedule:all_but_one_64th(Fork)`, and when it is true computes
      `Call = min(GasReq, Avail - Avail div 64)` and hands the child `Call + Stipend`, with
      `Stipend` from `eth_fork_schedule:call_stipend(Fork)` and zero when the value is zero.
      The clamp is on the **pre-stipend** figure, which is the position EIP-150's own
      `MessageCallGas` and `sub_call` give it -- `min(gas + extra_gas, gas + call_stipend)`
      is a different function and is wrong whenever the cap binds. `eth_evm_tests` pins the
      boundary and the saturation case separately.
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
  - ~~**Not done: KZG *commitment* verification.**~~ **Wrong when written, and closed by
      measuring the module rather than the note.** `eth_kzg:verify/4` exists and is the
      verification: it computes `PY = Cpt + [G]·(r − y)` and `XMZ = G2 + [G2]·(r − z)` and
      answers `e(−G2, PY) · e(XMZ, Ppt) == 1` in Fq12, which is the KZG verification
      equation. It is exported, it is built on `g1_mul/2`, `g2_mul/2`, `pairing/2` and
      `fq12_eql/2`, and it answers `false` on an exception rather than raising. The entry
      said the module "has `g1_mul/2`, the pairing check and `versioned_hash/1`, but no
      commitment verification" -- the pairing check **is** half of that verification and the
      note read the list of exports as the list of gaps.
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
  - ~~**The catch-all `base_cost(_) -> 3` remains a fallback.**~~ **Gone, and the entry is
      the residue of the deletion.** `grep -rn 'base_cost' apps/etherlang/src` returns four
      hits and **every one is a comment** -- two of them in `eth_block_validator` and one in
      `eth_block` saying the function was deleted for being a second copy of the schedule.
      There is no catch-all because there is no `eth_evm:base_cost/1`: `eth_fork_schedule`
      is the only price table, and the interpreter asks it for the fork in hand.
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
  (`execution-spec-tests`, 6,786 of 15,660 (43.3%), measured at `v1.49-full-corpus-measured`, 2026-09-29, and **not re-run since**) does more for EVM correctness than any of
  them; this covers the arithmetic the corpus reaches only indirectly.
- [ ] **Fuzz testing** — fuzz the EVM interpreter for edge cases
- [ ] **Differential testing** — run same block through etherlang and geth, compare outputs
- [ ] **Performance benchmarks** — block processing speed, state access latency
- [x] **Conformance tests** — `eest_state_tests.erl` runs the `execution-spec-tests`
  `state_tests` corpus. **Started, and the first measurement is about 2%**
  (78 of 266 committed entries at the first measurement, 2026-10-03, and
  **255 of 266** as of 2026-10-04; see "What
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
