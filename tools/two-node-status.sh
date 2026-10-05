#!/usr/bin/env bash
#
# two-node-status.sh - live status for two etherlang nodes, side by side.
#
# Node A has an upstream JSON-RPC endpoint; node B has none, so it can only know what
# a peer told it. This script exists because the EthStats agent could not be used to
# watch them: it is a 2016-era web3 0.x application, and **the numbers it reported were
# not this node's** -- it showed `peers: 33` and `gasPrice: 998966348` while the node
# answered `net_peerCount = 0x0` and `eth_gasPrice = 0x3d45b514` (1,027,850,260). An
# instrument reporting figures that no method here can produce is worse than no
# instrument, so this reads the node directly.
#
# Usage:
#   tools/two-node-status.sh            # refresh every second
#   tools/two-node-status.sh --once     # one snapshot and exit
#   RPC_A=8545 RPC_B=8546 tools/two-node-status.sh
#
# ---------------------------------------------------------------------------
# What this can and cannot show
# ---------------------------------------------------------------------------
# Everything below is read from the node over HTTP, so every figure is one the node
# actually produced. Two things it cannot show, stated rather than faked:
#
#   * **The discv4 routing table.** `table_size` and `bonded` are internal to
#     `eth_discv4` and no RPC method exposes them. `net_peerCount` is *connected,
#     eth-capable* peers -- a strictly smaller and more meaningful number. So a node can
#     have peers in its routing table and still report `0x0`, and that is not a
#     contradiction.
#   * **Whether a head is advancing.** A single sample cannot tell. So each row carries
#     the delta from the previous refresh, and a node whose head is stuck shows `+0`
#     rather than a plausible-looking number that never moves.
#
# **A refused call is shown as its reason, not as a blank.** The first version printed
# `-' whenever `result' was absent, which made node B -- the one with no upstream and no
# chain -- look indistinguishable from a node that had crashed. It is the difference
# this repository exists to keep: `eth_blockNumber' on B answers `-32000 chain_empty',
# which is a refusal with a reason, and a screen that renders that as a blank has thrown
# the reason away.
#
# `/health` is asked once per node per refresh and answers `status`, the local head, the
# block count, the MPT account count, the pool, and whether sync is ok -- so it is the
# one request that carries most of what matters here.
#
# **A defect noticed while writing this, and this note was WRONG about where it lives.**
#
# `/health` reports `chain.headHash` as `0x30783230626162...`, which decodes to the ASCII
# string `"0x20bab966..."` -- 66 bytes of hash *hex text* where this codebase's convention
# everywhere else is 32 raw bytes. The first version of this note called it a `/health`
# encoding bug: the handler encoding the value a second time.
#
# **It is not, and `/health` is the one thing here that is telling the truth.** The same
# bytes come out of `eth_chain:head/0` -- `erl_call -a 'eth_chain head []'` prints
# `{11846219, #Bin<48,120,50,48,98,97,98,57,54,54,...>}`, and 48/120/50/48 is ASCII `0x20`.
# `eth_chain` gets it from `block_hash/1`, which is `maps:get(<<"hash">>, Block, <<>>)`, so
# **the chain store holds whatever representation the block map carried** and `/health`
# reports that faithfully. Fixing `/health` would hide it.
#
# Recorded rather than fixed, because it is a separate change with its own blast radius:
# `missing_parent` compares a `ParentHash` against the stored head, so if the two sides ever
# disagree about the representation the chain cannot link, and that is worth checking
# rather than assuming. Nothing here shows that happening -- this node has appended
# 11,846,219 blocks -- so it is filed as an open question, not as a defect.

set -u

RPC_A=${RPC_A:-8545}
RPC_B=${RPC_B:-8546}
INTERVAL=${INTERVAL:-1}
ONCE=${1:-}

DIM=$'\033[2m'; BOLD=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
[ -t 1 ] || { DIM=""; BOLD=""; RED=""; GRN=""; YEL=""; RST=""; }

# **The timeout is 10 s, and that number is measured rather than chosen -- but the reason
# for it has changed and the old reason was a defect that is now fixed.**
#
# Measured on this pair after `cd511da` (5 samples each, median):
#
#   method             node A (upstream)     node B (no upstream)
#   eth_blockNumber    2.3 ms                2.1 ms
#   eth_gasPrice       4.6 ms                **6007 ms**
#   net_peerCount      2.3 ms                1.3 ms
#
# `eth_gasPrice` on the node with no upstream is the only slow thing left: it falls back to
# the dead upstream, retries and all, and lands at just over 6 s. At a 6 s timeout that reads
# as `unreachable', which is a claim about the node that is simply false. So 10 s, with ~4 s
# of margin on the one method that needs it.
#
# **`net_peerCount` used to be 2091-3525 ms and this comment used to be the reason for the
# timeout.** That was `eth_peer:peers/0' calling into every peer with a 2 s timeout, and it
# was fixed in `cd511da` -- the manager answers from its own state now. Recorded here rather
# than quietly rewritten, because the number a reader would otherwise find in the git history
# is wrong and they deserve to know it was wrong rather than to wonder which measurement is
# current. `make counts`-style discipline: a published figure that expires should say so.
rpc() {  # rpc <port> <method>
    curl -s -m10 -X POST -H 'content-type: application/json' \
         -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":[]}" \
         "http://127.0.0.1:$1" 2>/dev/null
}
field() { python3 -c "
import json,sys
try: d = json.load(sys.stdin)
except Exception: print('unreachable'); raise SystemExit
if 'error' in d:
    e = d['error']
    print('err %s %s' % (e.get('code'), str(e.get('message'))[:40]))
else:
    print(d.get('result', '-'))
"; }
health_field() {  # health_field <port> <dotted.path>
    curl -s -m6 "http://127.0.0.1:$1/health" 2>/dev/null | python3 -c "
import json,sys
try: d = json.load(sys.stdin)
except Exception: print('-'); raise SystemExit
for part in '$2'.split('.'):
    if not isinstance(d, dict) or part not in d: print('-'); raise SystemExit
    d = d[part]
print(d)
"; }

dec() { python3 -c "print(int('$1',16) if '$1'.startswith('0x') else '$1')" 2>/dev/null || echo "$1"; }

# **One array, two indices.** The node's label chooses the slot (`row "A" ... 0`), so
# there is no reason for a second array and there never was -- `PREV_B` was declared,
# reset every refresh, and read by nothing.
declare -a PREV_A

row() {  # row <label> <A port> <prev-index>
    local label=$1 port=$2 idx=$3
    local head hlocal blocks accounts pending queued syncok gas peers
    head=$(rpc "$port" eth_blockNumber | field)
    hlocal=$(health_field "$port" checks.chain.head)
    blocks=$(health_field "$port" checks.chain.blocks)
    accounts=$(health_field "$port" checks.mpt.accounts)
    pending=$(health_field "$port" checks.pool.pending)
    queued=$(health_field "$port" checks.pool.queued)
    syncok=$(health_field "$port" checks.sync.ok)
    gas=$(rpc "$port" eth_gasPrice | field)
    peers=$(rpc "$port" net_peerCount | field)

    # Delta from the previous refresh. A head that has not moved is the single most
    # useful thing this screen can say, and it cannot be read off a sample.
    local delta=" "
    if [ "$head" != "-" ] && [ -n "${PREV_A[$idx]:-}" ] && [ "${PREV_A[$idx]}" != "$head" ]; then
        delta=$(python3 -c "print('%+d' % (int('$head',16) - int('${PREV_A[$idx]}',16)))" 2>/dev/null || echo "?")
    elif [ "$head" != "-" ]; then
        delta="+0"
    fi
    PREV_A[$idx]=$head

    local head_dec="-"
    [ "$head" != "-" ] && head_dec=$(dec "$head")
    printf "  %s%-22s%s %s%-22s%s %s\n" "$DIM" "$label" "$RST" "$BOLD" "$head_dec" "$RST" \
           "${DIM}head=$head  local=$hlocal  blocks=$blocks  mpt=$accounts${RST}"
    printf "  %-22s %-22s %sdyn %s  peers %s  basefee %s  pool p%s/q%s  sync %s\n" \
           "" "" "$DIM" "$delta" "$peers" "$([ "$gas" = "-" ] || echo "$gas ($(dec "$gas"))")" \
           "$pending" "$queued" \
           "$([ "$syncok" = "True" ] && echo "${GRN}ok${RST}" || echo "${YEL}${syncok}${RST}")"
}

if [ "$ONCE" = "--once" ]; then
    printf "%s%-22s %-22s %s\n" "$BOLD" "metric" "node A (:$RPC_A, upstream)" "node B (:$RPC_B, no upstream)" "$RST"
    for m in eth_blockNumber eth_gasPrice net_peerCount; do
        printf "  %-22s %-22s %s\n" "$m" "$(rpc "$RPC_A" "$m" | field)" "$(rpc "$RPC_B" "$m" | field)"
    done
    printf "  %-22s %-22s %s\n" "health.status" "$(health_field "$RPC_A" status)" "$(health_field "$RPC_B" status)"
    exit 0
fi

printf "%stwo-node status%s  ${DIM}A=:$RPC_A (has upstream)   B=:$RPC_B (no upstream)${RST}\n" "$BOLD" "$RST"

# **Seeded once, before the loop, and that placement is the whole fix.** This used to sit
# inside it, which cleared the previous sample before `row/3` could compare against it --
# so `dyn` read `+0` on every single refresh and the header's promise ("a node whose head is
# stuck shows +0") was indistinguishable from a node that had moved between two samples and
# come back. A delta needs the sample before the one being drawn, and a reset in the loop
# guarantees there is never one. The feature was not wrong, it was unreachable.
PREV_A=()

while true; do
    clear 2>/dev/null || printf '\033[H\033[J'
    printf "%stwo-node status%s  %sA=:$RPC_A (upstream)   B=:$RPC_B (no upstream)   every ${INTERVAL}s%s\n" \
           "$BOLD" "$RST" "$DIM" "$INTERVAL" "$RST"
    printf "\n%s-- node A --%s\n" "$DIM" "$RST"
    row "A" "$RPC_A" 0
    printf "\n%s-- node B --%s\n" "$DIM" "$RST"
    row "B" "$RPC_B" 1
    printf "\n%s  peers is net_peerCount: connected eth-capable peers. The discv4 routing%s\n" "$DIM" "$RST"
    printf "%s  table is not exposed by any RPC method, so it cannot be shown here.%s\n" "$DIM" "$RST"
    sleep "$INTERVAL"
done
