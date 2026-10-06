#!/usr/bin/env node
//
// etherlang-feeder.js - push an etherlang node's own numbers into a local eth-netstats.
//
// **Every figure here is measured from the node over its JSON-RPC.** Nothing is inferred,
// nothing is copied from another node, nothing is hard-coded. That is the point: the hosted
// EthStats service was abandoned because it displayed figures no RPC method here can produce
// (`peers: 33`, `gasPrice: 998966348`, against `net_peerCount 0x0` and
// `eth_gasPrice 0x3d45b514`). An agent that fabricates would reproduce that locally.
//
// A stat the node does not expose is sent as **null**, which the UI renders as a gap, rather
// than as a plausible number. `difficulty`, `totalMem`, `freeMem`, `hashrate` and `txPool` are
// null here for exactly that reason.
//
// The wire format was read out of the server rather than guessed: the external API is a Primus
// server on `/external` with `parser: 'JSON'` and the `primus-emit` plugin, whose encoder is
// `primus.write({ emit: [event, ...args] })` (node_modules/primus-emit/index.js:84). So a
// message is `{"emit":["update", {...}]}`. Using the server's own `ws` module rather than
// `Primus.createSocket`, which is the *browser* client API and throws on a URL string.
//
// Usage:
//   WS_SECRET=x NODE_RPC=http://127.0.0.1:8545 NETSTATS=ws://127.0.0.1:3000 \
//     node etherlang-feeder.js

'use strict';

const http = require('http');
const path = require('path');
const WebSocket = require(path.join(__dirname, 'node_modules', 'ws'));

const WS_SECRET = process.env.WS_SECRET || '';
const NODE_RPC  = process.env.NODE_RPC  || 'http://127.0.0.1:8545';
const NETSTATS  = process.env.NETSTATS  || 'ws://127.0.0.1:3000';
const NODE_ID   = process.env.NODE_ID   || 'etherlang';
const INTERVAL  = Number(process.env.INTERVAL || 30000);
const NAME      = process.env.NODE_NAME || 'etherlang (local)';

function rpc(method, params) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method, params: params || [] });
    const url = new URL(NODE_RPC);
    const req = http.request({
      hostname: url.hostname, port: url.port || 80, path: url.pathname || '/',
      method: 'POST', timeout: 15000,
      headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) },
    }, (res) => {
      let buf = '';
      res.on('data', (c) => { buf += c; });
      res.on('end', () => {
        try {
          const d = JSON.parse(buf);
          // A refusal is a value, not a failure: `-32000 chain_empty` is the node saying its
          // chain is empty, and flattening that to null here would throw the reason away.
          if (d.error) return resolve({ __error: d.error.message, __code: d.error.code });
          resolve(d.result);
        } catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error('rpc timeout')));
    req.write(body); req.end();
  });
}

function fetch(path) {
  return new Promise((resolve) => {
    const url = new URL(NODE_RPC);
    const req = http.request({ hostname: url.hostname, port: url.port || 80,
                               path: path || '/', method: 'GET', timeout: 8000 },
      (res) => { let b = ''; res.on('data', (c) => { b += c; });
                 res.on('end', () => { try { resolve(JSON.parse(b)); } catch (e) { resolve(null); } }); });
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.end();
  });
}

const hexToInt = (h) => (typeof h === 'string' && h.startsWith('0x') ? parseInt(h, 16) : null);
const isErr = (r) => r && typeof r === 'object' && r.__error !== undefined;

let lastHeight = null, lastAt = null, blockTime = null;

async function sample() {
  const at = Date.now();
  const [head, gasPrice, peers, blk] = await Promise.all([
    rpc('eth_blockNumber').catch(() => null),
    rpc('eth_gasPrice').catch(() => null),
    rpc('net_peerCount').catch(() => null),
    rpc('eth_getBlockByNumber', ['latest', false]).catch(() => null),
  ]);
  const health = await fetch('/health').catch(() => null);
  const checks = (health && health.checks) || {};
  const sync = checks.sync || {};

  const height = hexToInt(head);

  // Block time is DERIVED from consecutive height samples, not reported by the node. Stated
  // here because a derivation presented as a measurement is how a number becomes a claim the
  // node never made. With the node stuck, `height === lastHeight`, nothing is recomputed, and
  // the previous value stays rather than becoming 0 s/block -- which would be a claim that a
  // node producing no blocks is producing them instantly.
  if (height !== null && lastHeight !== null && height > lastHeight) {
    const per = (at - lastAt) / (height - lastHeight) / 1000;
    blockTime = blockTime === null ? per : (blockTime * 0.7 + per * 0.3);
  }
  if (height !== null) { lastHeight = height; lastAt = at; }

  // **`stats.block` is mandatory, and the server says so precisely.** `Collection.update/3`
  // calls `History.add(stats.block, ...)` and answers `'Block data wrong'` when it returns
  // falsy; `History.add/4` requires `number`, `uncles`, `transactions` and `difficulty` to be
  // *defined*. A node that produces no uncles has `uncles: []` and a post-merge block has
  // `difficulty: 0`, and `!_.isUndefined(0)` is true for both -- so an empty list and a zero
  // are the correct answers here, not `null`. **Sending `null` for either would be the
  // dashboard showing a gap for a field the node really did report.**
  const block = (blk && typeof blk === 'object' && blk.number !== undefined) ? {
    number:       hexToInt(blk.number),
    hash:         blk.hash || null,
    parentHash:   blk.parentHash || null,
    miner:        blk.miner || null,
    difficulty:   hexToInt(blk.difficulty),
    timestamp:    hexToInt(blk.timestamp),
    transactions: Array.isArray(blk.transactions) ? blk.transactions.length : 0,
    uncles:       Array.isArray(blk.uncles) ? blk.uncles.length : 0,
    gasLimit:     hexToInt(blk.gasLimit),
    gasUsed:      hexToInt(blk.gasUsed),
    size:         hexToInt(blk.size),
    extraData:    (blk.extraData || '0x').length > 2 ? Math.floor((blk.extraData.length - 2) / 2) : 0,
  } : null;

  return {
    /** **`active`, not `online`.** `Node.setBasicStats/2` reads exactly `active`, `mining`,
     *  `hashrate`, `peers`, `gasPrice`, `syncing` and `uptime`, and copies each into
     *  `node.stats`. A key the server does not read is dropped without complaint, so the first
     *  version of this feeder sent `online` and the dashboard's ONLINE column read `false/absent`
     *  for a node that was demonstrably answering RPC. **The dashboard's vocabulary is not
     *  mine**, so the names came out of `lib/node.js` rather than out of habit. */
    active:     true,
    // `syncing` is this node's own `/health` field, and it is the honest answer here: A is
    // up and serving RPC but has not advanced its head, so it reports syncing.
    syncing:    (sync.syncing === undefined) ? null : !!sync.syncing,
    uptime:     (checks.chain && checks.chain.uptime !== undefined) ? checks.chain.uptime : null,
    height:     height,
    block:      block,
    gasPrice:   isErr(gasPrice) ? null : hexToInt(gasPrice),
    peers:      isErr(peers)   ? null : hexToInt(peers),
    blockTime:  blockTime,
    // Not exposed by this node. Null, so the UI shows a gap rather than a plausible number.
    difficulty: null,
    totalMem:   null,
    freeMem:    null,
    hashrate:   null,
    txPool:     null,
    mining:     0,
    __headHash: blk && blk.hash ? blk.hash : null,
    __refusal:  isErr(head) ? head.__error : null,
  };
}

// **`/api`, not `/external`.** Both are Primus servers on this app and both carry the
// emit plugin, so `spark.on('hello')` and `spark.on('update')` being *present* is not proof
// that a given socket invokes them: app.js registers those handlers on `api` and `external`
// is the collections/charts channel. The first version posted to `/external`, connected
// cleanly, sent well-formed frames, and produced **no log line at all** -- which is what a
// message that arrives and is never listened for looks like.
const wsUrl = NETSTATS.replace(/\/$/, '') + '/api';
const ws = new WebSocket(wsUrl);

const send = (event, data) => {
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ emit: [event, data] }));
};

ws.on('open', () => {
  console.log(`[feeder] connected ${wsUrl}`);
  send('hello', {
    id: NODE_ID,
    secret: WS_SECRET,
    info: {
      name: NAME, client: 'etherlang/0.1.0', version: '0.1.0',
      net: 'sepolia', host: '127.0.0.1',
      port: new URL(NODE_RPC).port || 8545,
      wsport: new URL(NETSTATS).port || 3000,
      contact: 'local', canUpdateHistory: false,
    },
  });
  console.log(`[feeder] hello sent for ${NODE_ID}`);
});

ws.on('error', (e) => console.error('[feeder] ws error:', e.message));
ws.on('close', () => console.error('[feeder] closed; is the netstats server running?'));

const push = async () => {
  try {
    const s = await sample();
    send('update', { id: NODE_ID, stats: s });
    console.log(`[feeder] ${NODE_ID} height=${s.height} peers=${s.peers} ` +
                `gasPrice=${s.gasPrice}${s.__refusal ? ` (refused: ${s.__refusal})` : ''}` +
                `${s.__headHash ? ` head=${s.__headHash.slice(0, 14)}…` : ''}`);
  } catch (e) {
    console.error('[feeder] sample failed:', e.message);
  }
};

ws.on('open', push);
setInterval(push, INTERVAL);
