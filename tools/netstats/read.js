#!/usr/bin/env node
//
// netstats-read.js - read what eth-netstats itself reports about a node.
//
// This exists so the answer to "is the node's height right and is it online" comes from the
// **dashboard's own state** rather than from the JSON-RPC the feeder read. A feeder that
// reports its own input back at you is not a check; going through the dashboard is.
//
// The client socket is `/primus` and, like `/api`, carries the emit plugin, so a server
// message arrives as `{"emit":[event, args]}`. On connect netstats pushes its whole state.

'use strict';
const path = require('path');
const WebSocket = require(path.join(__dirname, 'node_modules', 'ws'));

const NETSTATS = process.env.NETSTATS || 'ws://127.0.0.1:3000';
const NODE_ID  = process.env.NODE_ID  || 'etherlang-A';

const ws = new WebSocket(NETSTATS.replace(/\/$/, '') + '/primus');
let done = false;

ws.on('open', () => {
  // **The dashboard socket sends nothing until the client says `ready`.** app.js:372 wires
  // `clientSpark.on('ready', ...)` and only inside it emits `init` with the node list, so a
  // reader that only listens receives silence and times out -- which looks like "no nodes"
  // rather than "you never introduced yourself".
  ws.send(JSON.stringify({ emit: ['ready', { serverTime: Date.now() }] }));
  console.log('[read] ready sent');
});

ws.on('message', (raw) => {
  let m; try { m = JSON.parse(raw.toString()); } catch (e) { return; }
  const ev = m && m.emit && m.emit[0];
  const arg = m && m.emit && m.emit[1];
  if (ev !== 'init' && ev !== 'check' && ev !== 'update' && ev !== 'data') return;

  // netstats wraps the payload as {action, data} in some paths and as the array directly in
  // others; handle both rather than assuming one, because guessing wrong yields "no nodes"
  // rather than an error.
  let payload = arg;
  if (arg && arg.data !== undefined) payload = arg.data;
  if (!payload) return;

  const nodes = payload.nodes || (Array.isArray(payload) ? null : null);
  const list = nodes || (payload && payload.nodes) || [];
  const n = list.find((x) => x && (x.id === NODE_ID || (x.info && x.info.name) === NODE_ID));
  const target = n || list[0];

  if (!target) {
    if (!done) { console.log('[read] dashboard reported no nodes yet'); done = true; }
    return;
  }
  done = true;
  const s = target.stats || {};
  const b = s.block || {};
  console.log('  --- what eth-netstats reports ---');
  console.log(`  node id            : ${target.id}`);
  console.log(`  name               : ${target.info && target.info.name}`);
  console.log(`  net                : ${target.info && target.info.net}`);
  console.log(`  active (netstats)  : ${target.stats && target.stats.active}`);
  console.log(`  syncing (from node): ${target.stats && target.stats.syncing}`);
  console.log(`  height (netstats)  : ${s.height}`);
  console.log(`  height (in block)  : ${b.number}`);
  console.log(`  block hash         : ${b.hash}`);
  console.log(`  peers (netstats)   : ${s.peers}`);
  console.log(`  gasPrice           : ${s.gasPrice}`);
  console.log(`  transactions/uncles: ${b.transactions}/${b.uncles}`);
  console.log(`  difficulty         : ${b.difficulty}`);
  console.log(`  last block arrived : ${b.arrived ? new Date(b.arrived).toISOString() : 'n/a'}`);
  ws.close();
  process.exit(0);
});

ws.on('error', (e) => { console.error('[read] error:', e.message); process.exit(1); });
setTimeout(() => { console.log('[read] timed out waiting for dashboard state'); process.exit(2); }, 20000);
