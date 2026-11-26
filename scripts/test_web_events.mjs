// Tests for the web page's calendar-event helpers (run: node scripts/test_web_events.mjs). The helpers are the block between the
// "BEGIN pure event helpers" and "END pure event helpers" markers in web/app.js, evaluated here without a browser.
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const src = readFileSync(new URL('../web/app.js', import.meta.url), 'utf8');
const block = src.slice(src.indexOf('// BEGIN pure event helpers'), src.indexOf('// END pure event helpers'));
assert.ok(block.length > 100, 'helper block found');
const ctx = { Intl, Date, Number, Array };
vm.createContext(ctx);
vm.runInContext(block + '\n;globalThis.H = { eventTime, mergeEventDays };', ctx);
const H0 = ctx.H;
// ICU versions differ on the space before AM/PM (U+202F or a plain space): compare with plain spaces.
const H = { ...H0, eventTime: (e, fm) => H0.eventTime(e, fm).replace(/[\u202f\u00a0]/g, ' ') };
const f = {
  local: new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit', timeZone: 'America/New_York' }),
  utc: new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit', timeZone: 'UTC' }),
};
let n = 0;
const t = (name, fn) => { fn(); n++; console.log('ok', name); };
const at = s => Date.parse(s);

t('an all-day event reads "All day"', () => {
  assert.equal(H.eventTime({ allDay: true, start: at('2024-05-03T00:00:00Z'), end: at('2024-05-03T23:59:59Z') }, f), 'All day');
});

t('a timed event shows its start and its same-day end in the viewer zone', () => {
  assert.equal(H.eventTime({ allDay: false, floating: false, start: at('2024-05-03T23:00:00Z'), end: at('2024-05-04T00:30:00Z') }, f), '7:00 PM–8:30 PM');
});

t('a floating time reads in UTC (it is wall-clock time with no zone)', () => {
  assert.equal(H.eventTime({ allDay: false, floating: true, start: at('2024-05-03T09:00:00Z'), end: null }, f), '9:00 AM');
});

t('no end, an end before the start, or a day or longer: the start alone', () => {
  const s = at('2024-05-03T13:00:00Z');
  assert.equal(H.eventTime({ allDay: false, start: s }, f), '9:00 AM');
  assert.equal(H.eventTime({ allDay: false, start: s, end: s - 1 }, f), '9:00 AM');
  assert.equal(H.eventTime({ allDay: false, start: s, end: s + 86400000 }, f), '9:00 AM');
});

t('event days merge into the map; junk entries and a missing list are ignored', () => {
  const m = new Map();
  H.mergeEventDays(m, [{ day: 20240503, events: [{ summary: 'A' }] }, { day: 'x', events: [] }, null, { day: 20240504 }]);
  assert.deepEqual([...m.keys()], [20240503]);
  H.mergeEventDays(m, undefined);
  H.mergeEventDays(m, [{ day: 20240503, events: [{ summary: 'B' }] }]);
  assert.equal(m.get(20240503)[0].summary, 'B');
});

console.log(`${n} tests passed`);
