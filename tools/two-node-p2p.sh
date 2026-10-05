#!/usr/bin/env bash
#
# two-node-p2p.sh - run two etherlang nodes and make them find each other over p2p.
#
# Node A has an upstream JSON-RPC endpoint and serves the chain. Node B has **no
# upstream** -- its UPSTREAM_RPC_URL points at a syntactically valid URL that nothing
# listens on -- so anything B knows, it learned from A over devp2p.
#
# Usage:
#   tools/two-node-p2p.sh start      # build (if needed), start A then B
#   tools/two-node-p2p.sh status     # heads, discv4, peers for both
#   tools/two-node-p2p.sh stop
#   tools/two-node-p2p.sh logs A|B
#
# ---------------------------------------------------------------------------
# Four things in here are not guesses. Each cost a wrong turn first, so each is
# written down with the measurement that settled it.
#
# 1. **Build into `_build/prod`, and run that tree.**
#    `rebar3 as prod release` writes `_build/prod/rel/etherlang`.
#    `tools/etherlangctl` points node A at `_build/default/rel/etherlang`, which is a
#    *different, older* tree. Measured: `eth_config.beam` there was dated 09-22 and its
#    abstract code had **no `discv4_enabled/0` at all** -- so p2p never started, the node
#    answered RPC from a stale 636 MB chain store, and looked completely healthy. A
#    silently-old node that still serves requests is worse than one that is down.
#
# 2. **discv4 and RLPx must share one port number.**
#    `eth_discv4:parse_enode/1` builds `#{udp => Port, tcp => Port}` from the single port
#    in an enode, but `eth_config` lets `DISCV4_PORT` and `RLPX_PORT` differ. Any config
#    where they differ is **unreachable via bootnode**: the bootnode ping goes to UDP on
#    the RLPx port, where nothing listens. Measured: `pending => 1` forever, `table_size
#    => 0`. The node only warns when the two are *equal*.
#
# 3. **B needs a distinct `-sname`.** Two `etherlang@host` nodes cannot both register
#    with epmd, and the second refuses to boot.
#
# 4. **`RPC_LISTEN_IP=0.0.0.0` is needed only for the EthStats dashboard**, because the
#    agents run in containers. Measured on this machine:
#      bind 127.0.0.1  -> container cannot reach it (it cannot see host loopback)
#      bind <LAN IP>   -> host itself gets 000; macOS firewall drops that interface
#      bind 0.0.0.0    -> container reaches it, and the **LAN still cannot** (000)
#    So `0.0.0.0` exposes the docker/colima bridge and not the LAN. It does reverse the
#    v0.3.2 "bind loopback by default" hardening, so pass `RPC_LISTEN_IP=127.0.0.1` if
#    you are not starting the dashboard.
# ---------------------------------------------------------------------------

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REBAR="${REBAR:-/Users/mingderwang/.bin/rebar3}"

A_TREE="$ROOT/_build/prod/rel/etherlang"
B_TREE="$ROOT/_build/node2/rel/etherlang"

A_RPC=${A_RPC:-8545};  A_ENGINE=${A_ENGINE:-8551};  A_P2P=${A_P2P:-30303}
B_RPC=${B_RPC:-8546};  B_ENGINE=${B_ENGINE:-8552};  B_P2P=${B_P2P:-30313}
LISTEN_IP=${RPC_LISTEN_IP:-0.0.0.0}
UPSTREAM_A=${UPSTREAM_A:-https://ethereum-sepolia-rpc.publicnode.com}
# Nothing listens on port 9 (discard). This is "no upstream": `eth_config_settings`
# validates UPSTREAM_RPC_URL as an absolute URL, so an *empty* string is rejected at boot
# with {error,{invalid_configuration,_}} -- a dead endpoint is the only way to say it.
UPSTREAM_B=${UPSTREAM_B:-http://127.0.0.1:9}
STATE_DIR="${TMPDIR:-/tmp}/etherlang-two-node"
mkdir -p "$STATE_DIR"

say() { printf '  %s\n' "$*"; }

boot_id() {
    # The epmd port is the only reliable handle: `bin/<rel> ping` matches by OTP node
    # name and both nodes answer to names that differ only by an OTP node name clash.
    epmd -names 2>/dev/null | awk -v n="name $1 at port" '$0 ~ n {print $5}'
}

stop_one() {
    local Otp=$1 Tree=$2
    local P; P="$(boot_id "$Otp")"
    if [ -n "$P" ]; then
        erl_call -address "127.0.0.1:$P" -a 'init stop []' >/dev/null 2>&1
        say "stopped $Otp (dist port $P)"
    else
        say "$Otp not running"
    fi
}

# The enode needs the *node id*, and `eth_peer:status/0` reports it as a `#Bin<...>>`
# that Erlang truncates for display (30 of 64 bytes). So read the persisted key instead:
# `eth_nodekey` writes 32 **raw** bytes (not hex text) to $DATA_DIR/nodekey.
#
# **Those 32 bytes are the private key, and the enode wants the 64-byte public key.** So
# this derives it, and the derivation is checked against the node's own log rather than
# assumed: A logs `rlpx listening on tcp 30303 id=0EB87AAFD7CAF95B`, and
# `eth_ecies:pubkey/1` over that nodekey produces 64 bytes whose hex begins
# `0eb87aafd7caf95b` -- the same 8 bytes. The first version of this helper hexdumpped the
# nodekey and used it as the id, which is the private key's bytes wearing the public key's
# name; the peer still connected, because a bootnode enode's id is not what the dialer
# matches on -- it dials host:port and learns the real id from the Hello -- so the wrong
# value was invisible in exactly the way a wrong value here usually is.
#
# The previous helper called `erl -s nid main`, and **there is no `nid` module in this
# repository.** So it returned nothing and `start` exited 1 at the guard below, which means
# `start` had never run to completion through this script.
node_id_of() {
    local Tree=$1
    erl -noshell -pa "$ROOT/_build/test/lib/etherlang/ebin" -eval "
        {ok, K} = file:read_file(\"$Tree/data/nodekey\"),
        Pub = eth_ecies:pubkey(K),
        io:format(\"~s~n\", [binary_to_list(binary:encode_hex(Pub, lowercase))]),
        halt(0)." 2>/dev/null | tail -1
}

# **The newest rotation, never `erlang.log.1` by name.** `eth_peer_conn` rotates on size,
# so `erlang.log.1` is whichever file the *current* run happens to be in only until it grows
# past the limit -- and then it is a file that stopped receiving events. Reading it produces
# answers that are true and about the past, which is the worst combination: this repository
# spent an hour concluding "node A has no inbound connection at all" from a rotation whose
# last line was 28 minutes old, while the live file held 175 lines naming the peer exactly.
# A missing file is reported as missing, not silently substituted.
newest_log() {
    ls -t "$1"/log/erlang.log.* 2>/dev/null | head -1
}

# `net_peerCount` with its latency. The latency is not decoration: it is what separated the
# two defects this pair has had. `eth_peer:peers/0` used to call into every peer with a 2 s
# timeout and answer 2091-3525 ms, and every sample of it timed out while the connection was
# alive (fixed in cd511da -- it is now ~2 ms). A count and a count's cost are different
# questions and only the second one said anything about the connection.
peer_count() {
    local Out; Out="$(curl -s -m10 -o /dev/null -w '%{time_total}' \
        -X POST -H 'content-type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"net_peerCount","params":[]}' \
        "http://127.0.0.1:$1" 2>/dev/null)"
    local V; V="$(curl -s -m10 -X POST -H 'content-type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"net_peerCount","params":[]}' \
        "http://127.0.0.1:$1" 2>/dev/null)"
    # One decimal, because `%d' printed `0' for every sample and **a rounded-to-zero
    # latency is not a smaller latency** -- it is an instrument that cannot distinguish
    # "fast" from "unmeasured". `eth_peer:peers/0' is a map lookup now, so sub-millisecond
    # on loopback is the honest reading; it will also read 0.1 on a slow sample, which is
    # the point.
    printf '%s (%.1f ms)' "$(printf '%s' "$V" | sed 's/.*"result":"\([^"]*\)".*/\1/')" \
        "$(printf '%s' "$Out" | awk '{printf "%.1f", $1*1000}')"
}

rpc_head() { curl -s -m8 -X POST -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
    "http://127.0.0.1:$1" 2>/dev/null; }

local_head() {
    local P; P="$(boot_id "$1")"
    [ -z "$P" ] && { echo "not running"; return; }
    erl_call -address "127.0.0.1:$P" -a 'eth_chain head []' 2>/dev/null | head -1
}

d4() {
    local P; P="$(boot_id "$1")"
    [ -z "$P" ] && { echo "not running"; return; }
    erl_call -address "127.0.0.1:$P" -a 'eth_discv4 status []' 2>/dev/null \
        | grep -oE '(pending|bonded|table_size) => [0-9]+' | tr '\n' ' '
}

peers() {
    local P; P="$(boot_id "$1")"
    [ -z "$P" ] && { echo "not running"; return; }
    erl_call -address "127.0.0.1:$P" -a 'eth_peer status []' 2>/dev/null \
        | grep -oE '(peers|dialing|target) => [0-9]+' | tr '\n' ' '
}

start() {
    command -v erl_call >/dev/null || { echo "erl_call not on PATH (need OTP bin)"; exit 1; }

    if [ ! -x "$A_TREE/bin/etherlang" ]; then
        say "building release into _build/prod (see note 1 -- not _build/default)"
        "$REBAR" as prod release >/dev/null 2>&1 || { say "release build failed"; exit 1; }
    fi
    if [ ! -x "$B_TREE/bin/etherlang" ]; then
        say "copying the tree for node B"
        rm -rf "$B_TREE"; mkdir -p "$(dirname "$B_TREE")"
        rsync -a "$A_TREE" "$B_TREE"
        # note 3: B needs its own OTP node name
        sed -i '' 's/^-sname etherlang$/-sname etherlang2/' "$B_TREE"/releases/*/vm.args
    fi

    stop_one etherlang "$A_TREE" >/dev/null
    stop_one etherlang2 "$B_TREE" >/dev/null
    sleep 5

    say "starting A on :$A_RPC (upstream = $UPSTREAM_A, p2p $A_P2P)"
    ( cd "$A_TREE" && env \
        UPSTREAM_RPC_URL="$UPSTREAM_A" \
        RPC_LISTEN_IP="$LISTEN_IP" RPC_LISTEN_PORT="$A_RPC" ENGINE_PORT="$A_ENGINE" \
        DATA_DIR="$A_TREE/data" ETH_START_BLOCK=latest \
        DISCV4_ENABLED=true DISCV4_PORT="$A_P2P" RLPX_ENABLED=true RLPX_PORT="$A_P2P" \
        PEER_TARGET=2 POLL_INTERVAL_MS=3000 \
        ./bin/etherlang daemon >/dev/null 2>&1 & )
    sleep 25

    local NID ENODE
    NID="$(node_id_of "$A_TREE")"
    if [ -z "$NID" ]; then say "could not read A's node id from $A_TREE/data/nodekey"; exit 1; fi
    ENODE="enode://$NID@127.0.0.1:$A_P2P"
    echo "$ENODE" > "$STATE_DIR/A.enode"
    say "A's enode: $ENODE"
    say "  (cross-check: A's startup log prints the first 8 bytes of this id)"

    say "starting B on :$B_RPC (NO upstream -> $UPSTREAM_B, bootnode = A)"
    ( cd "$B_TREE" && env \
        UPSTREAM_RPC_URL="$UPSTREAM_B" \
        RPC_LISTEN_IP="$LISTEN_IP" RPC_LISTEN_PORT="$B_RPC" ENGINE_PORT="$B_ENGINE" \
        DATA_DIR="$B_TREE/data" ETH_START_BLOCK=latest \
        DISCV4_ENABLED=true DISCV4_PORT="$B_P2P" RLPX_ENABLED=true RLPX_PORT="$B_P2P" \
        DISCV4_BOOTNODES="$ENODE" \
        PEER_TARGET=2 POLL_INTERVAL_MS=3000 \
        ./bin/etherlang daemon >/dev/null 2>&1 & )
    sleep 40
    status
}

status() {
    echo "== node A (has upstream) =="
    say "rpc head   : $(rpc_head "$A_RPC")"
    say "local head : $(local_head etherlang)"
    say "net_peers  : $(peer_count "$A_RPC")"
    say "discv4     : $(d4 etherlang)"
    say "eth_peer   : $(peers etherlang)"
    echo "== node B (no upstream) =="
    say "rpc head   : $(rpc_head "$B_RPC")"
    say "local head : $(local_head etherlang2)"
    say "net_peers  : $(peer_count "$B_RPC")"
    say "discv4     : $(d4 etherlang2)"
    say "eth_peer   : $(peers etherlang2)"
    echo "== known state =="
    say "Both nodes are expected to report net_peerCount 0x1, and both do. The two paths"
    say "are not interchangeable: B dialled A, so B's entry is built by the dial path, and"
    say "A accepted B, so A's is built by the accept path. Until e598fee the accept path"
    say "replaced the entry peer_up had just filled in, so A reported 0x0 while holding a"
    say "live eth peer."
    say ""
    say "B is expected to sit at chain_empty, and the reason is recorded, not guessed:"
    say "eth_sync:walk_back/5's gen_server:call({get_headers, ...}, 20000) exceeds its own"
    say "budget on both nodes. See TASKS.md, section 'The next blocker: eth_sync cannot get"
    say "a single header across' -- it records what was measured, what was refuted (the"
    say "framing-desync hypothesis: zero bad_header_mac in either log), and the one"
    say "measurement that would settle what is left."
    say ""
    say "NOT true, and it was printed here until now: that the peer connection dies ~33s"
    say "after peer_up with enotconn on poll while lsof shows the socket ESTABLISHED."
    say "e823649 measured that on a fresh pair and it does not happen: peer_up = 1, conn"
    say "terminating = 0, per-second diagnostics rising. What was read as a death was"
    say "eth_peer:peer_status/1 answering {error, down} -- and the socket was ESTABLISHED"
    say "precisely because nothing had closed it."
    say ""
    say "Also NOT true: 'See the repo README section Two local nodes'. There is no such"
    say "section in README.md, so that pointer led nowhere. The measurement it meant to"
    say "point at is in TASKS.md and is attributed to a commit, not to a version tag."
}

case "${1:-status}" in
    start)  start ;;
    status) status ;;
    stop)   stop_one etherlang "$A_TREE"; stop_one etherlang2 "$B_TREE" ;;
    logs)   tail -f "$(newest_log "$([ "${2:-A}" = B ] && echo "$B_TREE" || echo "$A_TREE")")" ;;
    *)      echo "usage: $0 start|status|stop|logs A|B"; exit 1 ;;
esac
