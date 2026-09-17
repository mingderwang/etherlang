SHELL := /bin/bash
REBAR := $(shell command -v rebar3 2>/dev/null)

.PHONY: all compile test eunit docker-build docker-test docker-run compose-up compose-down compose-logs bench clean

all: compile

## Compile (local rebar3, if available)
compile:
	@if [ -n "$(REBAR)" ]; then $(REBAR) as prod compile; \
	else echo "rebar3 not installed locally; use 'make docker-test' or 'make docker-build'"; fi

test: eunit
eunit:
	@if [ -n "$(REBAR)" ]; then $(REBAR) eunit; \
	else echo "rebar3 not installed locally; use 'make docker-test'"; exit 1; fi

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