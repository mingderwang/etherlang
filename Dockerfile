# ---- build stage -----------------------------------------------------------
FROM erlang:27 AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends rebar3 git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY rebar.config ./
COPY config ./config
COPY apps ./apps

RUN rebar3 as prod compile \
 && rebar3 as prod release

# ---- runtime stage ---------------------------------------------------------
FROM erlang:27

RUN groupadd --system ethnode \
 && useradd --system --create-home --gid ethnode --home /home/ethnode ethnode \
 && mkdir -p /data \
 && chown ethnode:ethnode /data

WORKDIR /app
COPY --from=build /src/_build/prod/rel/etherlang /app

ENV DATA_DIR=/data \
    RPC_LISTEN_PORT=8545 \
    UPSTREAM_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com \
    ETH_START_BLOCK=latest

VOLUME ["/data"]
EXPOSE 8545

USER ethnode
ENTRYPOINT ["/app/bin/etherlang"]
CMD ["foreground"]