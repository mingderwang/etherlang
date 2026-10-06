#!/usr/bin/env bash
#
# netstats-up.sh - run a local eth-netstats and point it at this node.
#
# Why local: the hosted service is gone. `ethstats.net` has **no DNS record at all** from any
# public resolver (checked against 1.1.1.1 and 8.8.8.8, with `registry.npmjs.org` and
# publicnode resolving normally as controls), so there is nothing to connect to. And when a
# hosted instance was reachable it reported `peers: 33` and `gasPrice: 998966348` while this
# node answered `net_peerCount 0x0` and `eth_gasPrice 0x3d45b514` (1,027,850,260) -- figures
# no RPC method here can produce. **An instrument reporting numbers this node cannot produce
# is worse than no instrument**, so it reads the node directly instead.
#
# The fork at https://github.com/cubedro/eth-netstats (v0.0.9) needs **no mongo** -- its
# `lib/collection.js` keeps everything in memory -- and needs node and npm only.
#
# Usage:
#   tools/netstats/netstats-up.sh                 # install, build, start, feed, and read back
#   RPC=http://127.0.0.1:8546 tools/netstats/netstats-up.sh   # point at node B instead
#   tools/netstats/netstats-up.sh --stop
#
# Everything it reports is measured from the node's own JSON-RPC by `feeder.js`. The fields
# this node does not expose are sent as `null`, which the dashboard renders as a gap.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${NETSTATS_DIR:-/tmp/eth-netstats}"
PORT="${PORT:-3000}"
RPC="${RPC:-http://127.0.0.1:8545}"
SECRET="${WS_SECRET:-etherlang-local}"
REPO=https://github.com/cubedro/eth-netstats.git
say() { printf '  %s\n' "$*"; }

if [ "${1:-}" = "--stop" ]; then
    for f in /tmp/netstats.pid /tmp/feeder.pid; do
        [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null && rm -f "$f" && say "stopped $(basename "$f")"
    done
    pkill -f "$WORK/bin/www" 2>/dev/null && say "stopped server"
    exit 0
fi

# --- 1. fetch and build -------------------------------------------------------
if [ ! -d "$WORK" ]; then
    say "cloning $REPO into $WORK"
    git clone --depth 1 "$REPO" "$WORK" || { say "clone failed"; exit 1; }
fi
if [ ! -d "$WORK/node_modules" ]; then
    say "npm install"
    ( cd "$WORK" && npm install --no-audit --no-fund >/dev/null 2>&1 ) || { say "npm install failed"; exit 1; }
fi
if [ ! -f "$WORK/dist/js/netstats.min.js" ]; then
    say "building the dashboard (grunt)"
    ( cd "$WORK" && (npm install -g grunt-cli --no-audit --no-fund >/dev/null 2>&1 || true) && grunt >/dev/null 2>&1 ) \
        || { say "grunt build failed"; exit 1; }
fi

# --- 2. the upstream patch ----------------------------------------------------
# `Node.setStats/3` in 0.0.9 calls `callback(null, this.getStats())` and then **falls through**
# to `callback('Stats undefined', null)` -- there is no `return`. `Collection.update/3`'s
# callback tests `err !== null` first, so *every* successful update took the error branch,
# logged "Update error: Stats undefined", and never forwarded to the dashboard. The stats were
# recorded either way, so the server looked healthy and the UI showed nothing.
if ! grep -q 'callback(null, this.getStats());' "$WORK/lib/node.js"; then
    say "**lib/node.js does not look like 0.0.9** -- skipping the patch, check it yourself"
elif grep -A12 'callback(null, this.getStats());' "$WORK/lib/node.js" | grep -q 'return;'; then
    # The window is 12 lines rather than 2 because the applied patch puts an explanatory
    # comment between the callback and the `return'. The first version used -A2, so a tree
    # that already carried the fix was reported as "patch did not apply" -- which is both
    # wrong and alarming, since it says the dashboard will stay empty when it will not.
    say "patch already applied"
else
    say "applying netstats-0.0.9-missing-return.patch"
    ( cd "$WORK" && git apply --check "$ROOT/tools/netstats/netstats-0.0.9-missing-return.patch" 2>/dev/null \
      && git apply "$ROOT/tools/netstats/netstats-0.0.9-missing-return.patch" \
      && say "  applied" ) || say "  **patch did not apply** -- the dashboard will stay empty"
fi

# --- 3. the feeder, which must be copied in: it needs netstats' own node_modules ---
cp "$ROOT/tools/netstats/feeder.js" "$WORK/etherlang-feeder.js"
cp "$ROOT/tools/netstats/read.js"    "$WORK/netstats-read.js"

# --- 4. run --------------------------------------------------------------------
pkill -f "$WORK/bin/www" 2>/dev/null; sleep 2
( cd "$WORK" && NODE_ENV=development PORT="$PORT" WS_SECRET="$SECRET" node ./bin/www > /tmp/netstats.log 2>&1 ) &
echo $! > /tmp/netstats.pid
sleep 6
code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:$PORT/")"
[ "$code" = "200" ] || { say "dashboard did not come up (HTTP $code); see /tmp/netstats.log"; exit 1; }
say "dashboard: http://127.0.0.1:$PORT/"

[ -f /tmp/feeder.pid ] && kill "$(cat /tmp/feeder.pid)" 2>/dev/null
( cd "$WORK" && WS_SECRET="$SECRET" NODE_RPC="$RPC" NETSTATS="ws://127.0.0.1:$PORT" \
    NODE_ID="${NODE_ID:-etherlang}" NODE_NAME="${NODE_NAME:-etherlang (local)}" \
    INTERVAL="${INTERVAL:-15000}" node etherlang-feeder.js > /tmp/feeder.log 2>&1 ) &
echo $! > /tmp/feeder.pid
sleep 14
say "feeding from $RPC"

# --- 5. read back what the dashboard itself holds -----------------------------
# Not the feeder's own input: a feeder that reports its own input back is not a check.
( cd "$WORK" && NODE_ID="${NODE_ID:-etherlang}" NETSTATS="ws://127.0.0.1:$PORT" node netstats-read.js )
