// Tests for the web page's voicemail and voice-memo helpers (run: node scripts/test_web_recordings.mjs). The helpers are the block
// between the "BEGIN pure recording helpers" and "END pure recording helpers" markers in web/app.js, evaluated here without a browser.
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const src = readFileSync(new URL('../web/app.js', import.meta.url), 'utf8');
const block = src.slice(src.indexOf('// BEGIN pure recording helpers'), src.indexOf('// END pure recording helpers'));
assert.ok(block.length > 100, 'helper block found');
const ctx = { Number, Math, String, Map };
vm.createContext(ctx);
vm.runInContext(block + '\n;globalThis.H = { mergeRecordings, timelineExtras, recClock, voicemailCount, recFacts, recWhen, transcriptLabel, segmentAt, recordingsRequest, recordingsSummary };', ctx);
const H = ctx.H;
const L = a => JSON.parse(JSON.stringify(a));   // values made inside the context belong to its realm: copy before deepEqual
let n = 0;
const t = (name, fn) => { fn(); n++; console.log('ok', name); };
const fmt = d => 'D' + d.getTime();

t('voicemails merge into the map by id; one with no time cannot sit in a timeline', () => {
  const m = new Map();
  H.mergeRecordings(m, [{ id: 1, ts: 10 }, { id: 2, ts: null }, null, { id: 'x', ts: 5 }]);
  H.mergeRecordings(m, undefined);
  H.mergeRecordings(m, [{ id: 1, ts: 10 }, { id: 3, ts: 30 }]);
  assert.deepEqual([...m.keys()], [1, 3]);
});

t('calls and voicemails share one time order; a voicemail follows the call of the same instant', () => {
  const out = H.timelineExtras([{ id: 7, ts: 20, label: 'missed' }, { id: 8, ts: 5 }], [{ id: 1, ts: 20 }, { id: 2, ts: 1 }]);
  assert.deepEqual(L(out.map(e => (e.vm ? 'v' : 'c') + e.id)), ['v2', 'c8', 'c7', 'v1']);
});

t('lengths read as a clock', () => {
  assert.equal(H.recClock(7.4), '0:07');
  assert.equal(H.recClock(222), '3:42');
  assert.equal(H.recClock(3725), '1:02:05');
  assert.equal(H.recClock(undefined), '0:00');
  assert.equal(H.voicemailCount(1), '1 voicemail');
  assert.equal(H.voicemailCount(1200), (1200).toLocaleString() + ' voicemails');
});

t('the facts line says only what the source says', () => {
  assert.deepEqual(L(H.recFacts({ kind: 'voicemail', duration: 21, heard: true, deleted: false })), ['0:21', 'heard']);
  assert.deepEqual(L(H.recFacts({ kind: 'voicemail', duration: 4, heard: false, deleted: true, content: 'no-speech' })), ['0:04', 'not heard', 'in the phone’s deleted list', 'no words transcribed']);
  assert.deepEqual(L(H.recFacts({ kind: 'voicemail', duration: 9 })), ['0:09']);                      // an export: heard or not is unknown, so unsaid
  assert.deepEqual(L(H.recFacts({ kind: 'memo', duration: 62.5, heard: true, content: 'music' })), ['1:03', 'music']);   // "heard" is not a memo's fact
});

t('a time that is only an export or file time is never shown as the recording’s own', () => {
  assert.equal(H.recWhen({ ts: 1000, timeIsOwn: true, kind: 'memo' }, fmt), 'D1000');
  assert.match(H.recWhen({ ts: 1000, timeIsOwn: false, datedBy: 'export-time', kind: 'voicemail' }, fmt), /^Saved D1000 \(left earlier/);
  assert.match(H.recWhen({ ts: 1000, timeIsOwn: false, datedBy: 'file-time', kind: 'memo' }, fmt), /^File dated D1000 \(the recording has no time/);
  assert.equal(H.recWhen({ ts: null, kind: 'memo' }, fmt), 'No date in the source');
});

t('a transcript is always labeled a machine transcript', () => {
  assert.equal(H.transcriptLabel({ origin: 'machine', model: 'mlx-community/parakeet-tdt-0.6b-v3' }), 'Machine transcript (parakeet-tdt-0.6b-v3) · made on the Mac, not verified');
  assert.match(H.transcriptLabel({ origin: 'apple', model: 'apple-voicemail' }), /machine transcript, not verified$/);
  assert.match(H.transcriptLabel({ origin: 'machine' }), /^Machine transcript ·/);
});

t('the sentence being spoken is the last one that has started', () => {
  const s = [{ start: 0, end: 2 }, { start: 2.5, end: 4 }, { start: 9, end: 10 }];
  assert.equal(H.segmentAt(s, 0), 0);
  assert.equal(H.segmentAt(s, 2.2), 0);
  assert.equal(H.segmentAt(s, 2.5), 1);
  assert.equal(H.segmentAt(s, 60), 2);
  assert.equal(H.segmentAt([{ start: 3, end: 4 }], 1), -1);
  assert.equal(H.segmentAt(undefined, 1), -1);
});

t('words search the transcripts; no words page the list by the last row', () => {
  assert.deepEqual(L(H.recordingsRequest({ kind: '', q: '  ', next: null })), { path: 'api/recordings', params: { kind: '', limit: 50, ts: '', id: '' } });
  assert.deepEqual(L(H.recordingsRequest({ kind: 'memo', q: '', next: { ts: 5, id: 9 } })), { path: 'api/recordings', params: { kind: 'memo', limit: 50, ts: 5, id: 9 } });
  assert.deepEqual(L(H.recordingsRequest({ kind: 'bogus', q: ' fern ', offset: 50, order: 'newest' })), { path: 'api/recordings/search', params: { q: 'fern', kind: '', limit: 50, offset: 50, order: 'newest' } });
  assert.equal(H.recordingsRequest({ q: 'x', order: 'weird' }).params.order, 'best');
  assert.equal(H.recordingsRequest({ kind: 'meeting', q: '' }).params.kind, 'meeting');
});


t('the list subtitle names recorded meetings only when there are some', () => {
  assert.equal(H.recordingsSummary({ voicemails: 530, memos: 297, seconds: 3600 * 19.4 }), '530 voicemails \u00b7 297 voice memos \u00b7 19 h');
  assert.equal(H.recordingsSummary({ voicemails: 1, memos: 2, meetings: 2, seconds: 7200 }), '1 voicemail \u00b7 2 voice memos \u00b7 2 recorded meetings \u00b7 2 h');
  assert.equal(H.recordingsSummary({ voicemails: 0, memos: 0, meetings: 1, seconds: 0 }), '0 voicemails \u00b7 0 voice memos \u00b7 1 recorded meeting \u00b7 0 h');
});
console.log(n + ' tests passed');
