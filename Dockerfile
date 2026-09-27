# ---- build stage -----------------------------------------------------------
FROM erlang:29.1 AS build

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
FROM erlang:29.1

RUN groupadd --system ethnode \
 && useradd --system --create-home --gid ethnode --home /home/ethnode ethnode \
 && mkdir -p /data \
 && chown ethnode:ethnode /data

WORKDIR /app
COPY --from=build /src/_build/prod/rel/etherlang /app

# The build stage and this stage are the same tag, so a mismatch here means the tag
# was edited in one place and not the other. Assert it rather than trust it: the
# project pins its toolchain in mise.toml, and the image was on `erlang:27` for the
# whole life of the Dockerfile while every test and every measurement in this
# repository ran on OTP 29. That made `make docker-test` -- the container path CI
# uses -- a test of a runtime nothing else here ever ran, and a mismatch in the other
# direction is a `badmatch' or an undefined function at release time rather than at
# build time. Pinning both to `29.1' makes the versions identical by construction;
# this check is here so the next bump of one without the other fails loudly.
RUN erl -noshell -eval \
        Expected = "29", \
        Actual = erlang:system_info(otp_release), \
        case lists:prefix(Expected, Actual) of \
            true -> halt(0); \
            false -> io:format(standard_error, \
                      "OTP ~s, expected ~s~n", [Actual, Expected]), halt(1) \
        end.

ENV DATA_DIR=/data \
    RPC_LISTEN_PORT=8545 \
    UPSTREAM_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com \
    ETH_START_BLOCK=latest

VOLUME ["/data"]
EXPOSE 8545

USER ethnode
ENTRYPOINT ["/app/bin/etherlang"]
CMD ["foreground"]