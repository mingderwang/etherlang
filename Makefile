SHELL := /bin/bash
REBAR := $(shell command -v rebar3 2>/dev/null)

.PHONY: all compile test eunit counts check-ledger docs rationale edoc-preview clean docker-build docker-test docker-run compose-up compose-down compose-logs bench

all: compile

## Compile (local rebar3, if available)
compile:
	@if [ -n "$(REBAR)" ]; then $(REBAR) as prod compile; \
	else echo "rebar3 not installed locally; use 'make docker-test' or 'make docker-build'"; fi

test: eunit
eunit:
	@if [ -n "$(REBAR)" ]; then $(REBAR) eunit; \
	else echo "rebar3 not installed locally; use 'make docker-test'"; exit 1; fi

## The size figures quoted in README.md, AGENTS.md and TASKS.md. **Run this and paste its
## output; do not edit the numbers by hand.** The counts drifted three times, and the
## counting was never the problem -- "lines of code" was undefined and the *procedure*
## was prose, so two derivations that both looked reasonable disagreed. The definition is
## in the script, where it can be read and re-run.
counts:
	@tools/counts.escript

  ## **A commit that changes the node must change a ledger file in the same commit.**
  ##
  ## The open-items list is a claim about the code, and a hand-maintained claim decays
  ## silently. Four entries in TASKS.md were checked against the source on 2026-10-05 and
  ## **all four were false** -- each described work that had since been done, the oldest by
  ## several commits. Nothing in the build noticed, because a sentence cannot fail.
  ##
  ## So the rule is enforced rather than stated: a commit that touches
  ## `apps/etherlang/src/` must also touch TASKS.md, README.md or AGENTS.md. That is the
  ## whole mechanism, and it is deliberately cheap -- it does not check that the ledger is
  ## *right*, only that it was *opened*. Accuracy is `eth_open_claims_tests`, which pairs
  ## each named-open item with a check that must hold today, so an item cannot be added
  ## without a passing check, and an item whose gap has been closed fails its own.
  ##
  ## **Two modes, and the second is explicit on purpose.**
  ##
  ## `make check-ledger' judges **what is about to be committed** -- `git diff --name-only
  ## HEAD', staged and unstaged together. Run before committing, that is a gate. Run after,
  ## it is a post-mortem.
  ##
  ## `make check-ledger AUDIT=<sha>' audits a commit already in the log, which is how you
  ## check history rather than the next change.
  ##
  ## **There is deliberately no automatic "tree is clean, so audit HEAD" fallback, and the
  ## first version had one and it was dead.** `.dockerignore' carries an uncommitted change
  ## that is not ours, so `git diff --name-only HEAD' is never empty and the branch could
  ## never be taken -- while its comment described it as existing. Two rules and the one
  ## that bites: **a branch you have never seen taken is a claim, not a feature**, and the
  ## cheapest test is to print which arm ran. It printed "judging the pending change" on a
  ## tree I had just called clean.
  ##
  ## An automatic fallback would also have been the wrong design: it would make the same
  ## command mean two different things depending on untracked state, and a gate whose
  ## subject changes under you is one you learn not to read.
  ##
  ## Outside a git working tree it passes rather than failing, because a source export has
  ## no history to check.
  check-ledger:
	@if ! git rev-parse --git-dir >/dev/null 2>&1; then \
	    echo "not a git working tree -- nothing to check"; exit 0; fi; \
	 if [ -n "$(AUDIT)" ]; then \
	   LABEL="`git rev-parse --short $(AUDIT) 2>/dev/null || echo $(AUDIT)`"; \
	   FILES="`git diff-tree --no-commit-id --name-only -r $(AUDIT)`"; \
	 else \
	   LABEL="the pending change"; FILES="`git diff --name-only HEAD`"; \
	   echo "ledger: judging the pending change (staged and unstaged vs HEAD)"; \
	 fi; \
	 if [ -z "$$FILES" ]; then echo "ledger: nothing to judge in $$LABEL"; exit 0; fi; \
	 echo "$$FILES" | grep -q '^apps/etherlang/src/' || { \
	  echo "ledger: ok -- $$LABEL does not change apps/etherlang/src/"; exit 0; }; \
	 echo "$$FILES" | grep -qE '^(TASKS|README|AGENTS)[.]md$$' && { \
	  echo "ledger: ok -- src/ and a ledger file change together in $$LABEL"; exit 0; }; \
	echo "ledger: FAIL"; \
	echo "  $$LABEL changes apps/etherlang/src/ and no ledger file."; \
	echo "  Update TASKS.md (the open-items list), README.md or AGENTS.md in this"; \
	echo "  commit, or say in the commit message why this change needs none."; \
	exit 1

## API reference (edoc) into doc/, which is gitignored -- it is a build artifact.
##
## **This is the signature index, not the project's documentation.** edoc-1.5 on OTP 29
## binds a comment to a function only when it carries an explicit `%% @doc' tag, and
## plain `%%' prose is dropped silently. This tree has 513 function heads with a comment
## immediately above and **zero** `@doc' tags, so all 6,035 comment lines in src are
## absent from the output. That is a property of the tool and of what these comments
## are -- EIP rationale and defect history, much of it deliberately placed *after* the
## function it explains -- not an omission here. See doc/overview.edoc, which says so in
## the generated page too.
docs:
	@if [ -n "$(REBAR)" ]; then $(REBAR) compile || true; fi
	@if [ ! -d _build/default/lib/etherlang/ebin ]; then \
	  echo "no compiled beams in _build/default/lib/etherlang/ebin -- run 'make compile' first"; \
	  exit 1; fi
	@mkdir -p doc
	@erl -noshell -pa _build/default/lib/*/ebin -eval ' \
	  edoc:application(etherlang, [ {dir, "doc"}, {preprocess, true}, \
	    {includes, ["apps/etherlang/include"]}, \
	    {source_path, ["apps/etherlang/src"]} ]), \
	  io:format("edoc -> doc/ (~p html pages)~n", [length(filelib:wildcard("doc/*.html"))]), \
	  halt(0).'
	@echo "open doc/index.html"

## The `%%' comment corpus as navigable HTML. **Not docstrings** -- see
## apps/etherlang/doc/README.md. 1,029 blocks over 6,133 comment lines.
rationale:
	@mkdir -p doc
	@tools/rationale.escript

## What `make docs` would look like IF the source carried `%% @doc' tags, built into a
## scratch copy. `apps/etherlang/src` is never written to. This exists to make the
## argument against doing that for real checkable rather than asserted: **13 of the 48
## modules cannot be documented by edoc at all**, because a `<` or an unbalanced `' in
## their comments stops its XML writer.
## Add --all to tag every block rather than only the `precedes' ones.
edoc-preview:
	@tools/edoc_preview.escript $(EDOC_PREVIEW_FLAGS)

## Run the test-suite inside Docker (source is mounted in, deps fetched at build)
docker-test:
	docker build -f Dockerfile.test -t etherlang-test .
	docker run --rm -v "$(PWD)":/src etherlang-test rebar3 eunit

## Build the node image
docker-build:
	docker build -t etherlang:latest .

## Run the node (Sepolia) with a live tail from the current head
docker-run: docker-build
	docker run --rm -it -p 8545:8545 \
	  -v etherlang-data:/data \
	  -e UPSTREAM_RPC_URL=$(UPSTREAM_RPC_URL) \
	  -e ETH_START_BLOCK=$(ETH_START_BLOCK) \
	  etherlang:latest

compose-up: docker-build
	docker compose up -d

compose-down:
	docker compose down

compose-logs:
	docker compose logs -f

## Run an eth_call load benchmark against the running node
bench:
	@NET=$$(docker network ls -q --filter name=etherlang_default | head -1); \
	if [ -z "$$NET" ]; then echo "compose network not up; run 'make compose-up' first"; exit 1; fi; \
	docker run --rm --network etherlang_default \
	  -v "$(PWD)/tools/eth_bench.escript:/eth_bench.escript:ro" \
	  etherlang-test escript /eth_bench.escript \
	    --url http://etherlang:8545 $(BENCH_ARGS)

clean:
	rm -rf _build
	docker rmi etherlang:latest etherlang-test 2>/dev/null || true