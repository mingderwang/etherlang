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

`eest_report` prints the tally, the breakdown by fork, a histogram of the gas
deltas, and the divergences by suite. It needs `ETH_NETWORK=mainnet`, which it sets
itself: the fork schedule is mainnet's, and the fixtures declare chain id 1.

## The numbers are not reproducible, and that is stated everywhere they appear

The tally **depends on what else the test run did first**, and the reason is
specific. `eth_state:storage/3` and `balance/2` answer from the transaction overlay
and fall through to `base_source` for anything absent. The conformance run sets
`base_source` to the local MPT — which is what stops a unit test from fetching over
HTTP — and the local MPT is process-wide and shared with every other test.

A storage slot that the fixture's code reads but never declares therefore reads
whatever another test left in the store. Measured: **6** matches in a fresh VM,
**7** under eunit, and **2** on a later eunit run, same code both times.

Seeding every address the fixture mentions (`pre`, post-state, sender, destination,
coinbase) and every slot the post-state names removes most of it, and is done
anyway because it is correct regardless. It cannot remove the rest: a slot the code
reads and never writes is not knowable without executing the code.

So the tally is **reported, not asserted**, and `eest_conformance_tests` pins only
what does not move. Giving the runner an isolated state base is a task in
`TASKS.md`, not a footnote.
