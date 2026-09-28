SHELL := /bin/bash
REBAR := $(shell command -v rebar3 2>/dev/null)

.PHONY: all compile test eunit docs clean docker-build docker-test docker-run compose-up compose-down compose-logs bench

all: compile

## Compile (local rebar3, if available)
compile:
	@if [ -n "$(REBAR)" ]; then $(REBAR) as prod compile; \
	else echo "rebar3 not installed locally; use 'make docker-test' or 'make docker-build'"; fi

test: eunit
eunit:
	@if [ -n "$(REBAR)" ]; then $(REBAR) eunit; \
	else echo "rebar3 not installed locally; use 'make docker-test'"; exit 1; fi

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