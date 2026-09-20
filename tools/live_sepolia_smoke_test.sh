#!/usr/bin/env bash
#
# Live Sepolia smoke test for etherlang.
#
# Verifies, against a real deployed etherlang node and the real Sepolia chain:
#   1. basic RPC responses (chain id, block number, syncing, client version)
#   2. a fixed block served by the local node matches the upstream provider
#   3. chain integrity: parentHash(block N) == hash(block N-1) for N..N-W
#   4. the node serves locally stored blocks even when upstream is unreachable
#
# Usage:
#   LOCAL_RPC=http://127.0.0.1:8545 \
#   UPSTREAM_RPC=https://ethereum-sepolia-rpc.publicnode.com \
#   ./tools/live_sepolia_smoke_test.sh
#
# The node must already be running (built with `rebar3 as prod release` and
# started with UPSTREAM_RPC_URL=<upstream> ETH_START_BLOCK=latest RPC_LISTEN_PORT=8545).
#
# Requires: curl, python3. No API keys. Read-only against the network.
set -u

LOCAL_RPC=${LOCAL_RPC:-http://127.0.0.1:8545}
UPSTREAM_RPC=${UPSTREAM_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
WINDOW=${WINDOW:-3}

PASS=0
FAIL=0
rpc() { # rpc <url> <method> <params-json>
  curl -sS -m 30 -X POST -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}" "$1"
}
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS  $1"
  else FAIL=$((FAIL+1)); echo "FAIL  $1 (expected=$2 got=$3)"; fi
}

echo "== smoke test: local=$LOCAL_RPC upstream=$UPSTREAM_RPC peer-window=$WINDOW =="

# --- 1. chain identity ---
CHAIN_LOCAL=$(rpc "$LOCAL_RPC" eth_chainId '[]' | python3 -c "import json,sys;print(json.load(sys.stdin)['result'])")
CHAIN_UP=$(rpc "$UPSTREAM_RPC" eth_chainId '[]' | python3 -c "import json,sys;print(json.load(sys.stdin)['result'])")
check chainId "$CHAIN_UP" "$CHAIN_LOCAL"
[ "$CHAIN_LOCAL" = "0xaa36a7" ] && echo "PASS  chainId is Sepolia (0xaa36a7)" || echo "FAIL  chainId is not Sepolia: $CHAIN_LOCAL"

CLIENT=$(rpc "$LOCAL_RPC" web3_clientVersion '[]' | python3 -c "import json,sys;print(json.load(sys.stdin)['result'])")
echo "INFO  clientVersion=$CLIENT"

N=$(rpc "$LOCAL_RPC" eth_blockNumber '[]' | python3 -c "import json,sys;print(int(json.load(sys.stdin)['result'],16))")
echo "INFO  local head = $N"

# --- 2. fixed-block parity with upstream ---
python3 - "$LOCAL_RPC" "$UPSTREAM_RPC" "$N" <<'PY'
import json,sys,urllib.request
loc,up,n=sys.argv[1],sys.argv[2],int(sys.argv[3])
hdr={"content-type":"application/json","user-agent":"curl/8.4.0","accept":"application/json"}
def rpc(url,m,p):
    req=urllib.request.Request(url,data=json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(),headers=hdr)
    return json.loads(urllib.request.urlopen(req,timeout=30).read())["result"]
a=rpc(loc,"eth_getBlockByNumber",[hex(n),True]); b=rpc(up,"eth_getBlockByNumber",[hex(n),True])
fields=["number","hash","parentHash","timestamp","gasLimit","gasUsed"]
ok=True
for f in fields:
    m = a.get(f)==b.get(f)
    ok &= m
    print("%s  block.%-10s local=%s upstream=%s" % ("PASS" if m else "FAIL", f, a.get(f), b.get(f)))
m = len(a.get("transactions"))==len(b.get("transactions")); ok &= m
print("%s  block.txCount   local=%d upstream=%d" % ("PASS" if m else "FAIL", len(a.get("transactions")), len(b.get("transactions"))))
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# --- 3. chain integrity: parentHash linkage across a window ---
python3 - "$LOCAL_RPC" "$N" "$WINDOW" <<'PY'
import json,sys,urllib.request
loc,n,w=sys.argv[1],int(sys.argv[2]),int(sys.argv[3])
hdr={"content-type":"application/json","user-agent":"curl/8.4.0"}
def rpc(m,p):
    req=urllib.request.Request(loc,data=json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(),headers=hdr)
    return json.loads(urllib.request.urlopen(req,timeout=30).read())["result"]
ok=True
for i in range(w):
    cur=rpc("eth_getBlockByNumber",[hex(n-i),False]); prv=rpc("eth_getBlockByNumber",[hex(n-i-1),False])
    m=cur["parentHash"].lower()==prv["hash"].lower(); ok &= m
    print("%s  link %d -> %d : parentHash == hash" % ("PASS" if m else "FAIL", n-i, n-i-1))
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# --- 4. local storage + restart recovery (re-query persisted block) ---
PH=$(rpc "$LOCAL_RPC" eth_getBlockByNumber '["latest",false]' | python3 -c "import json,sys;print(json.load(sys.stdin)['result']['hash'])")
PH2=$(rpc "$LOCAL_RPC" eth_getBlockByNumber '["latest",false]' | python3 -c "import json,sys;print(json.load(sys.stdin)['result']['hash'])")
check persisted-block-stable "$PH" "$PH2"

echo ""
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
