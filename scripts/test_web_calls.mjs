// Tests for the web page's call-line helpers (run: node scripts/test_web_calls.mjs). The helpers are the block between the
// "BEGIN pure call helpers" and "END pure call helpers" markers in web/app.js, evaluated here without a browser.
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const src = readFileSync(new URL('../web/app.js', import.meta.url), 'utf8');
const block = src.slice(src.indexOf('// BEGIN pure call helpers'), src.indexOf('// END pure call helpers'));
assert.ok(block.length > 100, 'helper block found');
const ctx = { Number, Infinity, Map };
vm.createContext(ctx);
vm.runInContext(block + '\n;globalThis.H = { mergeCalls, callsInWindow, interleave, callCount };', ctx);
const H = ctx.H;
const L = a => [...a];   // arrays made inside the context belong to its realm: copy before deepEqual
let n = 0;
const t = (name, fn) => { fn(); n++; console.log('ok', name); };
const msg = (id, ts) => ({ id, ts });
const call = (id, ts) => ({ id, ts, label: 'c' + id });

t('calls merge into the map by id; junk and a missing list are ignored', () => {
  const m = new Map();
  H.mergeCalls(m, [call(1, 10), { id: 'x', ts: 1 }, null, { id: 2 }]);
  H.mergeCalls(m, undefined);
  H.mergeCalls(m, [call(1, 10), call(3, 30)]);   // a page that carries a call again does not double it
  assert.deepEqual([...m.keys()], [1, 3]);
});

t('the window shows calls between its first and last message, and past an end it has reached', () => {
  const m = H.mergeCalls(new Map(), [call(1, 5), call(2, 15), call(3, 20), call(4, 35), call(5, 50)]);
  const msgs = [msg(10, 10), msg(11, 20), msg(12, 30)];
  assert.deepEqual(L(H.callsInWindow(m, msgs, false, false).map(c => c.id)), [2, 3]);
  assert.deepEqual(L(H.callsInWindow(m, msgs, true, false).map(c => c.id)), [1, 2, 3]);
  assert.deepEqual(L(H.callsInWindow(m, msgs, false, true).map(c => c.id)), [2, 3, 4, 5]);
  assert.deepEqual(L(H.callsInWindow(m, [], false, false).map(c => c.id)), [1, 2, 3, 4, 5]);   // no messages: every call
});

t('calls fall between messages in time order, after messages of the same millisecond', () => {
  const rows = [msg(10, 10), msg(11, 20), msg(12, 30)];
  const out = H.interleave(rows, [call(1, 5), call(2, 20), call(3, 25), call(4, 40)]);
  assert.deepEqual(L(out.map(e => e.call ? 'c' + e.call.id : 'm' + e.id)), ['c1', 'm10', 'm11', 'c2', 'c3', 'm12', 'c4']);
  assert.deepEqual(L(H.interleave(rows, []).map(e => e.id)), [10, 11, 12]);
  assert.deepEqual(L(H.interleave([], [call(1, 5)]).map(e => e.call.id)), [1]);
});

t('the count reads "1 call" or "N calls"', () => {
  assert.equal(H.callCount(1), '1 call');
  assert.equal(H.callCount(7), '7 calls');
});

console.log(`${n} tests passed`);
