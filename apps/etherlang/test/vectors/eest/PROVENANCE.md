# `execution-spec-tests` state-test corpus (committed subset)

Third-party expected results, committed rather than fetched, for the same reason
`sepolia_*.json` is: a test that reaches for a network fails for reasons that have
nothing to do with the code under it.

## Provenance

| | |
|---|---|
| Project | [`ethereum/execution-spec-tests`](https://github.com/ethereum/execution-spec-tests) (EEST) |
| Release | `v5.4.0`, published 2025-12-06 |
| Asset | `fixtures_stable.tar.gz` (257.3 MB) |
| Suite | `state_tests/` |
| Retrieved | 2026-09-27 |
| Verify | `sha256` of the asset, and the release tag, are the handles. The fixtures carry their own `_info` block naming the `execution-specs` commit and the EIP each test came from, so a single file can be traced without this file. |

The fixtures are **unmodified**. Each is byte-identical to what the release
tarball contained, including the `_info` block, so a reader can check that claim
against the `_info.url` and `_info["reference-spec-version"]` fields inside any
committed file.

## What is committed, and why not all of it

Upstream's `state_tests` suite is **2,681 files and 503 MB**, of which 315 MB is a
single `static/` directory of legacy VMTests. Committing that is not an option, and
*claiming* to have run it would be worse than not having run it.

The committed subset is **25 files, 1.2 MB**, chosen by a rule rather than by taste:

- **one file per suite**, and there are 30 suites covering 10 forks;
- **the smallest file in each suite**, so a fixture is only as large as it needs to
  be;
- **nothing over 150 KB**, which excludes six suites whose smallest file is larger
  than that (`eip198_modexp` 1.7 MB, `eip145_bitwise_shift` 1.6 MB,
  `frontier/precompiles` 1.5 MB, `eip1014_create2` 1.0 MB, `eip3860_initcode`
  2.1 MB, `eip7610_create_collision` 363 KB). They are run by the full-corpus
  command below; they are simply not pinned here;
- `frontier/` suites are **kept** even though none of them can be executed, so the
  `fork_unreachable` path stays covered by a test.

## Running the whole corpus

The pinned subset is what CI runs. The full suite is a developer step, because it
needs the 257 MB tarball:

```sh
curl -L -o fixtures_stable.tar.gz \
  https://github.com/ethereum/execution-spec-tests/releases/download/v5.4.0/fixtures_stable.tar.gz
mkdir -p /tmp/eest && tar -xzf fixtures_stable.tar.gz -C /tmp/eest
erl -pa _build/default/lib/*/ebin -pa _build/test/lib/etherlang/test \
    -s eest_report main /tmp/eest/fixtures/state_tests
```

`eest_report` prints the tally, the breakdown by fork, a histogram of the
schedule-sized gas deltas, and a bounded sample of the divergences. It needs
`ETH_NETWORK=mainnet`, which it sets itself: the fork schedule is mainnet's, and the
fixtures declare chain id 1.

**It folds rather than collects, and that is load-bearing.** The first version
gathered every result into a list and kept every detail map alive — one per state
mismatch, each holding a diff list and a gas story. Over the full suite that is
tens of thousands of retained maps, and the run spent **over an hour at 100% CPU
inside `erts_bor`**, the garbage collector, without finishing a single fork. It was
not slow; it was not going to finish. `eest_state_tests:survey/1` folds instead:
the tally, the per-fork counts and the histogram are all folds, and only a bounded
sample of divergences is kept. Peak memory is one fixture's decoded JSON.

The non-`static` suites are the practical full run — 235 files, 188 MB, and they
cover every EIP-named suite upstream has. The `static/` directory is 315 MB of
legacy VMTests and is where the time goes.

## The numbers are reproducible, and getting there found two harness bugs

They were not at first. The tally drifted between runs of identical code — 5, 6, 7
and 2 were all observed — and one run scored *higher* than a clean VM because a
fixture was passing on an account another test had left in the store, which is worse
than flakiness because it is a wrong answer that looks right. Two independent causes:

1. **A storage read the fixture does not declare.** `eth_state:storage/3` and
   `balance/2` answer from the transaction overlay and fall through to `base_source`
   for anything absent, which under `with_local_reads` is the process-wide local MPT.
   Seeding every address and slot the fixture mentions removes most of it — and is
   done regardless, because it is correct — but it cannot remove the rest: a slot the
   code reads and never writes is not knowable without executing the code.
   `eth_state:with_base_source/2` removes the dependency instead of reducing it. The
   runner gives every state it builds the new `empty` base, so an undeclared account
   or slot reads as *does not exist*.

2. **The runner inherited `ETH_NETWORK` from its caller.** The report tool set it;
   the in-suite path did not, so it ran the corpus under Sepolia's chain id
   (11155111) against fixtures declaring chain 1. The runner now owns it and
   restores it afterwards. This one is worth reading twice: it made the validator
   *correctly reject* five EIP-1559 transactions from the wrong chain, which
   reclassified them from `expected_rejection_not_raised` — this node admits
   something invalid — to `rejection_mismatch`, which reads like the node being
   right. **The harness was suppressing the exact finding it was added to make.**

With both fixed, the tally is identical per entry from a fresh VM and from inside
the suite, and `eest_conformance_tests` pins it both exactly and as a bound.
