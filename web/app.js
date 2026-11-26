/* The read-only web app. Plain JS, no dependencies. Hash routes: #/ (people), #/p/<id> (a person's
   merged timeline), #/t/<id> (a group thread), either with ?at=<message id> or ?svc=sms,imessage, #/posts/<person id> (a person's
   Facebook and Instagram posts and comments), #/recordings (every voicemail, voice memo and recorded meeting by date,
   ?kind=voicemail|memo|meeting, ?q= to search their transcripts), and #/search?q=... (&in=posts for posts and comments; a message
   whose voice message's machine transcript matches is a hit, marked as such). A voice message on a thread shows its machine
   transcript under its player. A timeline shows each day's
   calendar events as a line under the day header (the messages pages carry them when asked with the viewer's zone), each call
   (phone, FaceTime, WhatsApp, Skype) as a line at its time (the messages pages carry the calls of their span), and each voicemail
   its person left as a card with a player and its machine transcript at its time (the same pages carry them). */
'use strict';

const SERVICES = ['imessage', 'sms', 'messenger', 'instagram', 'groupme', 'skype', 'whatsapp', 'snapchat', 'aim', 'telegram', 'slack'];
const SERVICE_LABEL = { imessage: 'iMessage', sms: 'SMS', messenger: 'Messenger', instagram: 'Instagram', groupme: 'GroupMe', skype: 'Skype', whatsapp: 'WhatsApp', snapchat: 'Snapchat', aim: 'AIM', telegram: 'Telegram', slack: 'Slack' };
const SERVICE_SHORT = { imessage: 'iMsg', sms: 'SMS', messenger: 'FB', instagram: 'IG', groupme: 'GM', skype: 'SK', whatsapp: 'WA', snapchat: 'SC', aim: 'AIM', telegram: 'TG', slack: 'SL' };
const PAGE = 60, FIRST_PAGE = 40, SIDE = 30, MAX_WINDOW = 360, EDGE_PX = 700;

const app = document.getElementById('app');
// The product's name is the page's own <title> (web/index.html), so a rename touches only that file and the manifest.
const APP_NAME = document.title;
const fmt = {
  day: new Intl.DateTimeFormat(undefined, { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' }),
  time: new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' }),
  short: new Intl.DateTimeFormat(undefined, { year: '2-digit', month: 'numeric', day: 'numeric' }),
  weekday: new Intl.DateTimeFormat(undefined, { weekday: 'long' }),
  month: new Intl.DateTimeFormat(undefined, { year: 'numeric', month: 'long' }),
  full: new Intl.DateTimeFormat(undefined, { dateStyle: 'full', timeStyle: 'short' }),
};
// BEGIN pure event helpers (no DOM; tested by scripts/test_web_events.mjs)
// A calendar event's time under a day header: "All day", or its start (a floating time has no zone and reads in UTC), and
// its end when it ends the same day.
const EVENT_TIME = { local: new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' }), utc: new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit', timeZone: 'UTC' }) };
function eventTime(e, f = EVENT_TIME) {
  if (e.allDay) return 'All day';
  const t = e.floating ? f.utc : f.local;
  const start = t.format(new Date(e.start));
  if (!e.end || e.end <= e.start || e.end - e.start >= 86400000) return start;
  return start + '–' + t.format(new Date(e.end));
}
// The events a page of messages brought (one entry per day that has any) into the timeline's day -> events map.
function mergeEventDays(map, days) { for (const d of days || []) if (d && Number.isInteger(d.day) && Array.isArray(d.events)) map.set(d.day, d.events); return map; }
// END pure event helpers
// BEGIN pure call helpers (no DOM; tested by scripts/test_web_calls.mjs)
// The calls a page of messages brought into the timeline's id -> call map.
function mergeCalls(map, calls) { for (const c of calls || []) if (c && Number.isInteger(c.id) && Number.isFinite(c.ts)) map.set(c.id, c); return map; }
// The calls the loaded window shows: between its first and last message, and beyond an end of the conversation it has reached.
function callsInWindow(map, msgs, reachedStart, reachedEnd) {
  const lo = msgs.length && !reachedStart ? msgs[0].ts : -Infinity, hi = msgs.length && !reachedEnd ? msgs[msgs.length - 1].ts : Infinity;
  return [...map.values()].filter(c => c.ts >= lo && c.ts <= hi).sort((a, b) => a.ts - b.ts || a.id - b.id);
}
// Messages and calls in time order (a call after the messages of the same millisecond); a call entry is { call }.
function interleave(rows, calls) {
  const out = []; let i = 0;
  for (const r of rows) { while (i < calls.length && calls[i].ts < r.ts) out.push({ call: calls[i++] }); out.push(r); }
  while (i < calls.length) out.push({ call: calls[i++] });
  return out;
}
const callCount = n => n === 1 ? '1 call' : n.toLocaleString() + ' calls';
// END pure call helpers
// BEGIN pure recording helpers (no DOM; tested by scripts/test_web_recordings.mjs)
// The voicemails a page of messages brought into the timeline's id -> voicemail map (only ones with a time can sit in a timeline).
function mergeRecordings(map, list) { for (const r of list || []) if (r && Number.isInteger(r.id) && Number.isFinite(r.ts)) map.set(r.id, r); return map; }
// Calls and voicemails of the loaded window as one list in time order; a voicemail entry is { ts, id, vm }.
function timelineExtras(calls, vms) {
  return calls.concat(vms.map(v => ({ ts: v.ts, id: v.id, vm: v }))).sort((a, b) => a.ts - b.ts || (a.vm ? 1 : 0) - (b.vm ? 1 : 0) || a.id - b.id);
}
// 0:07, 3:42, 1:02:05
function recClock(seconds) {
  const s = Math.max(0, Math.round(Number(seconds) || 0)), p = n => String(n).padStart(2, '0');
  return s >= 3600 ? Math.floor(s / 3600) + ':' + p(Math.floor(s % 3600 / 60)) + ':' + p(s % 60) : Math.floor(s / 60) + ':' + p(s % 60);
}
const voicemailCount = n => n === 1 ? '1 voicemail' : n.toLocaleString() + ' voicemails';
const RECORDING_KINDS = ['voicemail', 'memo', 'meeting'];
// The recordings list's subtitle: what it holds and how long (a kind the archive has none of is left out, except voicemails and memos).
function recordingsSummary(page) {
  const parts = [voicemailCount(page.voicemails || 0), (page.memos || 0).toLocaleString() + ' voice memos'];
  if (page.meetings) parts.push(page.meetings === 1 ? '1 recorded meeting' : page.meetings.toLocaleString() + ' recorded meetings');
  return parts.join(' \u00b7 ') + ' \u00b7 ' + Math.round((page.seconds || 0) / 3600).toLocaleString() + ' h';
}
// The quiet line under a recording's title: its length and what the source says about it. Nothing is claimed that the source does not say.
function recFacts(r) {
  const out = [recClock(r.duration)];
  if (r.kind === 'voicemail') { if (r.heard === true) out.push('heard'); else if (r.heard === false) out.push('not heard'); }
  if (r.deleted === true) out.push(r.kind === 'voicemail' ? 'in the phone\u2019s deleted list' : 'in Recently Deleted');
  if (r.content === 'music') out.push('music'); else if (r.content === 'noise') out.push('noise, no speech'); else if (r.content === 'no-speech') out.push('no words transcribed');
  return out;
}
// When it was recorded. A time that is only when a file was exported or written is said to be that, never shown as the recording's own.
function recWhen(r, format) {
  if (!Number.isFinite(r.ts)) return 'No date in the source';
  const d = format(new Date(r.ts));
  if (r.timeIsOwn) return d;
  return (r.datedBy === 'export-time' ? 'Saved ' : 'File dated ') + d + (r.kind === 'voicemail' ? ' (left earlier; the source has no time for it)' : ' (the recording has no time of its own)');
}
// What a transcript is, said every time it is shown: a machine transcript, never anyone's verified words.
function transcriptLabel(t) {
  if (t.origin === 'apple') return 'The phone\u2019s own voicemail transcription \u00b7 a machine transcript, not verified';
  const m = String(t.model || '').split('/').pop();
  return 'Machine transcript' + (m ? ' (' + m + ')' : '') + ' \u00b7 made on the Mac, not verified';
}
// The segment being spoken at time t (seconds), or -1: the last one that has started.
function segmentAt(segments, t) {
  let at = -1;
  for (let i = 0; i < (segments || []).length; i++) { if (segments[i].start <= t + 0.05) at = i; else break; }
  return at;
}
// The recordings list's request: search when there are words, else the list page after `next`.
function recordingsRequest(state) {
  const kind = RECORDING_KINDS.includes(state.kind) ? state.kind : '';
  if (state.q && state.q.trim()) return { path: 'api/recordings/search', params: { q: state.q.trim(), kind, limit: 50, offset: state.offset || 0, order: state.order === 'newest' || state.order === 'oldest' ? state.order : 'best' } };
  return { path: 'api/recordings', params: { kind, limit: 50, ts: state.next ? state.next.ts : '', id: state.next ? state.next.id : '' } };
}
// END pure recording helpers
const dayKey = ms => { const d = new Date(ms); return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate(); };
function listDate(ms) {
  const d = new Date(ms), now = new Date();
  if (d.toDateString() === now.toDateString()) return fmt.time.format(d);
  const y = new Date(now); y.setDate(now.getDate() - 1);
  if (d.toDateString() === y.toDateString()) return 'Yesterday';
  if (now - d < 6 * 86400000) return fmt.weekday.format(d);
  return fmt.short.format(d);
}
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const initials = name => { const w = String(name || '').split(/\s+/).filter(x => /\p{L}/u.test(x)); return w.length ? (w[0][0] + (w[1] ? w[1][0] : '')).toUpperCase() : '#'; };
const bytes = n => n < 1024 ? n + ' B' : n < 1048576 ? (n / 1024).toFixed(0) + ' KB' : (n / 1048576).toFixed(1) + ' MB';
const h = (tag, attrs = {}, ...kids) => {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') el.className = v; else if (k === 'html') el.innerHTML = v; else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (v !== null && v !== undefined && v !== false) el.setAttribute(k, v === true ? '' : v);
  }
  for (const k of kids.flat()) if (k !== null && k !== undefined && k !== false) el.append(k.nodeType ? k : document.createTextNode(String(k)));
  return el;
};
const ICON = {
  back: '<svg viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7"/></svg>',
  search: '<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/></svg>',
  calendar: '<svg viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/></svg>',
  close: '<svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg>',
  play: '<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z" fill="currentColor"/></svg>',
  posts: '<svg viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16" rx="2"/><path d="M8 9h8M8 13h8M8 17h5"/></svg>',
  mic: '<svg viewBox="0 0 24 24"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg>',
};

let toastTimer;
function toast(msg) {
  const t = document.getElementById('toast');
  t.textContent = msg; t.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.hidden = true; }, 3500);
}

async function api(path, params = {}) {
  const u = new URL(path, location.href);
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null && v !== '') u.searchParams.set(k, v);
  const r = await fetch(u, { headers: { 'X-Requested-With': 'archive-web' }, credentials: 'same-origin' });
  if (!r.ok) { let m = r.status + ''; try { m = (await r.json()).error || m; } catch (_) {} throw new Error(m); }
  return r.json();
}

// ---- state and routing ----
const cache = { people: null, peopleAt: 0 };
let current = null;   // the active view object (has .destroy())

function route() {
  const hash = location.hash.replace(/^#\/?/, '');
  const [path, qs] = hash.split('?');
  const q = new URLSearchParams(qs || '');
  const seg = path.split('/').filter(Boolean);
  if (current && current.destroy) current.destroy();
  current = null;
  app.replaceChildren();
  if (seg[0] === 'p' && seg[1]) current = timelineView({ person: seg[1] }, q);
  else if (seg[0] === 't' && seg[1]) current = timelineView({ thread: seg[1] }, q);
  else if (seg[0] === 'posts' && seg[1]) current = postsView(seg[1]);
  else if (seg[0] === 'recordings') current = recordingsView(q);
  else if (seg[0] === 'search') current = searchView(q);
  else current = peopleView(q);
}
window.addEventListener('hashchange', route);

function go(hash) { location.hash = hash; }
function back(fallback) { if (history.length > 1 && document.referrer !== '' || history.state) history.back(); else go(fallback || '#/'); }

// ---- people list ----
async function loadPeople(force) {
  if (!force && cache.people && Date.now() - cache.peopleAt < 60000) return cache.people;
  cache.people = await api('api/people'); cache.peopleAt = Date.now();
  return cache.people;
}

function peopleView(q) {
  const state = { tab: q.get('tab') === 'groups' ? 'groups' : 'people', filter: q.get('f') || '', svc: q.get('svc') || '', hidden: q.get('hidden') === '1' };
  const list = h('ul', { class: 'rows' });
  const scroll = h('div', { class: 'scroll' }, list);
  const input = h('input', { type: 'search', placeholder: 'Filter by name', value: state.filter, autocomplete: 'off', autocapitalize: 'off',
    oninput: e => { state.filter = e.target.value; render(); } });
  const seg = h('div', { class: 'seg' },
    h('button', { class: state.tab === 'people' ? 'on' : '', onclick: () => { state.tab = 'people'; render(); } }, 'People'),
    h('button', { class: state.tab === 'groups' ? 'on' : '', onclick: () => { state.tab = 'groups'; render(); } }, 'Groups'));
  const chips = h('div', { class: 'chips' });
  const title = h('h1', {}, 'Messages');
  const recBtn = h('button', { class: 'btn', style: 'visibility:hidden', title: 'Voicemails and voice memos', html: ICON.mic, onclick: () => go('#/recordings') });
  api('api/overview').then(o => { if (o.recordings) { recBtn.style.visibility = ''; recBtn.title = o.recordings.toLocaleString() + ' voicemails and voice memos'; } }).catch(() => {});
  app.append(
    h('div', { class: 'bar' }, recBtn, title,
      h('button', { class: 'btn', title: 'Search everything', html: ICON.search, onclick: () => go('#/search') })),
    h('div', { class: 'search-row' }, input, seg),
    chips, scroll);
  let data;
  function render() {
    if (!data) return;
    seg.children[0].classList.toggle('on', state.tab === 'people'); seg.children[1].classList.toggle('on', state.tab === 'groups');
    chips.replaceChildren(...SERVICES.map(s => h('button', { class: 'chip svc-' + s + (state.svc === s ? ' on' : ''), onclick: () => { state.svc = state.svc === s ? '' : s; render(); } },
      h('span', { class: 'dot' }), SERVICE_LABEL[s])),
      h('button', { class: 'chip' + (state.hidden ? ' on' : ''), onclick: () => { state.hidden = !state.hidden; render(); } }, state.hidden ? 'Hiding nothing' : 'Show hidden'));
    const f = state.filter.trim().toLowerCase();
    const rows = [];
    if (state.tab === 'people') {
      for (const p of data.people) {
        if (p.hidden && !state.hidden) continue;
        if (state.svc && !p.services[state.svc]) continue;
        if (f && !(p.name.toLowerCase().includes(f) || p.usernames.some(u => u.toLowerCase().includes(f)))) continue;
        rows.push(personRow(p));
      }
    } else {
      for (const g of data.groups) {
        if (g.hidden && !state.hidden) continue;
        if (state.svc && g.service !== state.svc) continue;
        if (f && !g.title.toLowerCase().includes(f)) continue;
        rows.push(groupRow(g));
      }
    }
    title.replaceChildren('Messages', h('span', { class: 'sub' }, rows.length.toLocaleString() + (state.tab === 'people' ? ' people' : ' groups')));
    list.replaceChildren(...(rows.length ? rows : [h('li', { class: 'empty' }, 'Nothing matches')]));
    const u = new URLSearchParams(); if (state.tab === 'groups') u.set('tab', 'groups'); if (state.filter) u.set('f', state.filter); if (state.svc) u.set('svc', state.svc); if (state.hidden) u.set('hidden', '1');
    history.replaceState(null, '', '#/' + (u.toString() ? '?' + u : ''));
  }
  function personRow(p) {
    const services = SERVICES.filter(s => p.services[s]);
    return h('li', { class: 'row' + (p.hidden ? ' dim' : ''), onclick: () => go('#/p/' + p.id) },
      h('div', { class: 'avatar' }, initials(p.name)),
      h('div', { class: 'main' },
        h('div', { class: 'top' }, h('span', { class: 'name' }, p.name), h('span', { class: 'date' }, listDate(p.lastTs))),
        h('div', { class: 'preview' }, p.preview || ''),
        h('div', { class: 'meta' }, ...services.map(s => h('span', { class: 'svc-' + s, style: 'display:inline-flex;align-items:center;gap:3px' }, h('span', { class: 'dot' }), SERVICE_SHORT[s])),
          h('span', {}, '· ' + p.messages.toLocaleString() + (p.calls ? ' · ' + callCount(p.calls) : '')))));
  }
  function groupRow(g) {
    return h('li', { class: 'row' + (g.hidden ? ' dim' : ''), onclick: () => go('#/t/' + g.id) },
      h('div', { class: 'avatar' }, initials(g.title)),
      h('div', { class: 'main' },
        h('div', { class: 'top' }, h('span', { class: 'name' }, g.title), h('span', { class: 'date' }, listDate(g.lastTs))),
        h('div', { class: 'preview' }, g.preview || ''),
        h('div', { class: 'meta' }, h('span', { class: 'svc-' + g.service, style: 'display:inline-flex;align-items:center;gap:3px' }, h('span', { class: 'dot' }), SERVICE_SHORT[g.service] || g.service),
          h('span', {}, '· ' + g.members + ' people · ' + g.messages.toLocaleString()))));
  }
  list.append(h('li', { class: 'spinner' }, 'Loading…'));
  loadPeople().then(d => { data = d; render(); }).catch(e => { list.replaceChildren(h('li', { class: 'empty' }, 'Could not load: ' + e.message)); });
  return { destroy() {} };
}

// ---- timeline ----
function timelineView(scopeSpec, q) {
  const svcParam = q.get('svc') || '';
  const state = { svc: new Set(svcParam ? svcParam.split(',').filter(s => SERVICES.includes(s)) : []), msgs: [], reachedStart: false, reachedEnd: true, loading: false, armed: false, info: null, gen: 0 };
  const eventsByDay = new Map();   // dayKey -> that day's calendar events (only days that have any), filled by every page of messages
  const callsById = new Map();     // the calls the pages brought (each page carries the calls of its span); emptied when the window is replaced
  const vmsById = new Map();       // the voicemails the pages brought (the same spans as the calls)
  const isGroup = !!scopeSpec.thread;
  const scopeParams = () => ({ ...(scopeSpec.person ? { person: scopeSpec.person } : { thread: scopeSpec.thread }), services: state.svc.size ? [...state.svc].join(',') : '' });
  const pageParams = extra => ({ ...scopeParams(), zone: viewerZone(), ...extra });   // the zone brings the page's calendar events
  const hashBase = scopeSpec.person ? '#/p/' + scopeSpec.person : '#/t/' + scopeSpec.thread;
  const title = h('h1', {}, '…');
  const tl = h('div', { class: 'timeline' });
  const topEdge = h('div', { class: 'edge' }), bottomEdge = h('div', { class: 'edge' });
  const chips = h('div', { class: 'chips hidden' });
  const coverage = h('div', { class: 'coverage hidden' });
  const bar = h('div', { class: 'bar' },
    h('button', { class: 'btn', html: ICON.back, onclick: () => back('#/') }),
    title,
    h('button', { class: 'btn', html: ICON.calendar, title: 'Jump to date', onclick: pickDate }),
    h('button', { class: 'btn', html: ICON.search, title: 'Search this conversation', onclick: () => go('#/search?' + new URLSearchParams(scopeSpec.person ? { person: scopeSpec.person } : { thread: scopeSpec.thread })) }));
  const postsBtn = h('button', { class: 'btn hidden', html: ICON.posts, title: 'Posts and comments', onclick: () => go('#/posts/' + scopeSpec.person) });
  bar.insertBefore(postsBtn, bar.lastChild);
  app.append(bar, chips, coverage, tl);
  let seq = 0;

  function syncHash() {
    const u = new URLSearchParams(); if (state.svc.size) u.set('svc', [...state.svc].join(','));
    history.replaceState(null, '', hashBase + (u.toString() ? '?' + u : ''));
  }

  function renderHeader() {
    const info = state.info; if (!info) return;
    const name = info.name || info.title || '…';
    const count = (info.messages || 0).toLocaleString();
    const calls = info.calls ? ' · ' + callCount(info.calls) + (info.callSeconds >= 3600 ? ' (' + Math.round(info.callSeconds / 3600).toLocaleString() + ' h)' : '') : '';
    const vms = info.voicemails ? ' · ' + voicemailCount(info.voicemails) : '';
    title.replaceChildren(name, h('span', { class: 'sub' }, isGroup ? (info.members.length + ' people · ' + count) : count + ' messages' + calls + vms));
    document.title = name + ' · ' + APP_NAME;
    if (!isGroup) {
      const present = SERVICES.filter(s => info.services[s]);
      if (present.length > 1) {
        chips.classList.remove('hidden');
        chips.replaceChildren(...present.map(s => h('button', { class: 'chip svc-' + s + (state.svc.size === 0 || state.svc.has(s) ? ' on' : ''), onclick: () => toggleService(s, present) },
          h('span', { class: 'dot' }), SERVICE_LABEL[s] + ' ' + info.services[s].toLocaleString())));
      }
    }
    renderCoverage(info.months);
  }

  function toggleService(s, present) {
    if (state.svc.size === 0) { state.svc = new Set(present.filter(x => x !== s)); }
    else if (state.svc.has(s)) { state.svc.delete(s); if (state.svc.size === 0) state.svc = new Set(); }
    else state.svc.add(s);
    if (state.svc.size === present.length) state.svc = new Set();
    syncHash(); renderHeader();
    api('api/months', scopeParams()).then(m => renderCoverage(m)).catch(() => {});
    start({ latest: true });
  }

  function renderCoverage(months) {
    if (!months || months.length < 2) return;
    coverage.classList.remove('hidden');
    const max = Math.max(...months.map(m => m.n), 1);
    const first = months[0], last = months[months.length - 1];
    const cells = [];
    const byKey = new Map(months.map(m => [m.y * 12 + m.m - 1, m.n]));
    let lastY = null;
    for (let k = first.y * 12 + first.m - 1; k <= last.y * 12 + last.m - 1; k++) {
      const y = Math.floor(k / 12), m = k % 12 + 1, n = byKey.get(k) || 0;
      if (lastY !== null && y !== lastY) cells.push(h('span', { class: 'y' }));
      lastY = y;
      const hgt = n ? Math.max(3, Math.round(26 * Math.sqrt(n / max))) : 2;
      cells.push(h('button', { class: 'm' + (n ? '' : ' empty'), style: 'height:' + hgt + 'px', title: fmt.month.format(new Date(y, m - 1, 1)) + ': ' + n,
        onclick: () => start({ ts: new Date(y, m - 1, 1).getTime() }) }));
    }
    coverage.replaceChildren(...cells);
  }

  // messages -> DOM items (day headers, time stamps, sender runs), the same rules as the Mac app
  function buildItems(rows) {
    const out = []; let prev = null, prevDay = -1;
    const extras = timelineExtras(callsInWindow(callsById, rows, state.reachedStart, state.reachedEnd), callsInWindow(vmsById, rows, state.reachedStart, state.reachedEnd));
    for (const e of interleave(rows, extras)) {
      const r = e.call ? { ts: e.call.ts, kind: 'call', me: e.call.vm ? false : e.call.me } : e;
      const dk = dayKey(r.ts); let showTime = false;
      if (dk !== prevDay) {
        out.push(h('div', { class: 'day', 'data-day': dk }, fmt.day.format(new Date(r.ts))));
        const evs = eventsByDay.get(dk); if (evs && evs.length) out.push(eventsEl(evs));
        prevDay = dk; showTime = true;
      }
      const gap = prev ? r.ts - prev.ts : Infinity;
      if (gap > 30 * 60000) showTime = true;
      let sameRun = prev && !showTime && prev.me === r.me && prev.sender === r.sender && !r.kind && !prev.kind;
      if (sameRun && !isGroup && (prev.thread !== r.thread || prev.service !== r.service)) sameRun = false;
      const showSender = isGroup && !r.me && !sameRun && !r.kind;
      if (showTime) out.push(h('div', { class: 'time' }, fmt.time.format(new Date(r.ts))));
      out.push(e.call ? (e.call.vm ? recordingEl(e.call.vm, { inTimeline: true }) : callEl(e.call)) : messageEl(r, showSender, sameRun && gap < 120000));
      prev = r;
    }
    return out;
  }

  // a day's calendar events: one quiet line under the day header; a tap shows where and which calendar
  function eventsEl(evs) {
    const el = h('div', { class: 'events', role: 'button', tabindex: '0', title: 'Calendar: tap for details' });
    const toggle = () => el.classList.toggle('open');
    el.addEventListener('click', toggle);
    el.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); } });
    el.append(h('span', { class: 'ico', html: ICON.calendar }));
    for (const e of evs) {
      const more = [e.location, e.calendar, e.recurring ? 'repeats (first date)' : null].filter(Boolean).join(' · ');
      el.append(h('span', { class: 'ev' }, h('span', { class: 'when' }, eventTime(e)), ' ', e.summary, e.recurring ? ' ↻' : '', more ? h('span', { class: 'more' }, more) : null));
    }
    return el;
  }

  // a call from the call logs (phone, FaceTime, WhatsApp, Skype): a quiet line at its time, like Messenger's own call lines
  function callEl(c) {
    const missed = !c.me && c.outcome !== 'answered';
    return h('div', { class: 'note call' + (missed ? ' missed' : ''), 'data-ts': c.ts, title: fmt.full.format(new Date(c.ts)) }, '📞 ', c.label);
  }

  function messageEl(r, showSender, tight) {
    const body = (r.body || '').trim();
    if (r.kind && !body && !r.attachments.length) {
      return h('div', { class: 'note' + (r.kind === 'unsent' ? ' unsent' : ''), 'data-id': r.id, title: fmt.full.format(new Date(r.ts)) }, r.kind === 'call' ? '📞 ' : '', r.note || '');
    }
    const el = h('div', { class: 'msg svc-' + r.service + (r.me ? ' me' : '') + (tight ? ' tight' : ''), 'data-id': r.id, 'data-ts': r.ts });
    if (showSender) el.append(h('div', { class: 'sender' }, r.sender || 'Unknown'));
    for (const a of r.attachments) el.append(attachmentEl(a, r));
    if (body) {
      const bubble = h('div', { class: 'bubble', title: fmt.full.format(new Date(r.ts)) + (!isGroup && !scopeSpec.thread ? ' · ' + SERVICE_LABEL[r.service] : '') });
      if (r.subject && r.subject !== 'null') bubble.append(h('span', { class: 'subject' }, r.subject));
      bubble.append(linkify(body));
      const line = h('div', { class: 'line' }, bubble);
      if (!isGroup && !tight) line.append(h('span', { class: 'tag' }, SERVICE_SHORT[r.service]));   // once per run, like the Mac app's merged view
      el.append(line);
    }
    if (r.reactions.length) {
      const groups = new Map();
      for (const x of r.reactions) { const g = groups.get(x.emoji) || []; g.push(x.me ? 'You' : (x.name || 'Someone')); groups.set(x.emoji, g); }
      el.append(h('div', { class: 'reactions' }, ...[...groups.entries()].map(([e, who]) => h('span', { class: 'reaction', title: who.join(', ') }, e, who.length > 1 ? h('small', {}, who.length) : null))));
    }
    return el;
  }

  function linkify(text) {
    const frag = document.createDocumentFragment();
    const re = /https?:\/\/[^\s<>"']+/g; let i = 0, m;
    while ((m = re.exec(text))) {
      if (m.index > i) frag.append(text.slice(i, m.index));
      frag.append(h('a', { href: m[0], target: '_blank', rel: 'noopener noreferrer' }, m[0]));
      i = m.index + m[0].length;
    }
    if (i < text.length) frag.append(text.slice(i));
    return frag;
  }

  function attachmentEl(a, r) {
    const media = 'media/' + a.sha;
    if (a.kind === 'image') {
      const img = h('img', { src: 'thumb/' + a.sha + '/480', alt: a.name || 'photo', loading: 'lazy', decoding: 'async' });
      img.addEventListener('error', () => { img.replaceWith(fileChip(a)); });
      return h('div', { class: 'att', onclick: () => lightbox(a, r) }, img);
    }
    if (a.kind === 'video') return h('div', { class: 'att' }, h('video', { controls: true, preload: 'metadata', playsinline: true, src: media }));
    if (a.kind === 'audio') return voiceEl(a);
    return fileChip(a);
  }
  // an audio attachment: a player (the playable copy when the file is one browsers do not play), and a voice message's machine
  // transcript under it, labeled as one; "Show all" brings its timed sentences, which seek the player
  function voiceEl(a) {
    const audio = h('audio', { controls: true, preload: 'metadata', src: 'media/' + (a.play || a.sha) });
    const el = h('div', { class: 'att voice' }, audio);
    for (const t of a.transcripts || []) {
      const box = h('div', { class: 'rec-tr' }, h('div', { class: 'rec-tr-label' }, transcriptLabel(t)));
      const text = (t.text || '').trim();
      if (!text) { box.append(h('div', { class: 'rec-tr-text none' }, 'The transcriber heard no words in this voice message.')); el.append(box); continue; }
      const body = h('div', { class: 'rec-tr-text clamp' }, text);
      box.append(body);
      const more = h('button', { class: 'rec-more' }, 'Show all');
      more.addEventListener('click', async () => {
        more.remove(); body.classList.remove('clamp');
        try {
          const all = await api('api/voice/' + a.sha);
          const full = (all || []).find(x => x.origin === t.origin && x.model === t.model);
          if (!full || !full.segments || !full.segments.length) return;
          const spans = full.segments.map(sg => h('span', { class: 'seg-t', title: recClock(sg.start), onclick: () => { audio.currentTime = sg.start; audio.play().catch(() => {}); } }, sg.text + ' '));
          body.replaceChildren(...spans);
          audio.addEventListener('timeupdate', () => { const i = segmentAt(full.segments, audio.currentTime); spans.forEach((sp, k) => sp.classList.toggle('now', k === i)); });
        } catch (_) { /* the plain text stays */ }
      });
      if (text.length > 160) box.append(more);
      el.append(box);
    }
    return el;
  }
  function fileChip(a) {
    return h('a', { class: 'att file', href: 'media/' + a.sha, target: '_blank', rel: 'noopener' }, '📎 ' + (a.name || a.mime || 'file'), h('span', {}, bytes(a.bytes)));
  }

  function lightbox(a, r) {
    const box = h('div', { class: 'lightbox' },
      h('div', { class: 'top' }, h('button', { html: ICON.close, onclick: () => box.remove() }), h('a', { href: 'media/' + a.sha, target: '_blank', rel: 'noopener' }, 'Open original')),
      h('div', { class: 'pic', onclick: () => box.remove() }, h('img', { src: 'thumb/' + a.sha + '/1600', alt: a.name || 'photo' })),
      h('div', { class: 'cap' }, fmt.full.format(new Date(r.ts)) + (a.name ? ' · ' + a.name : '') + ' · ' + bytes(a.bytes)));
    document.body.append(box);
  }

  // window management: the DOM holds at most MAX_WINDOW messages; paging in one edge drops the far edge
  function setWindow(rows, { reachedStart, reachedEnd }) {
    state.msgs = rows; state.reachedStart = reachedStart; state.reachedEnd = reachedEnd;
    tl.replaceChildren(topEdge, ...buildItems(rows), bottomEdge);
    renderEdges();
  }
  function renderEdges() {
    topEdge.textContent = state.reachedStart ? (state.msgs.length ? 'Beginning of conversation' : 'No messages') : 'Loading…';
    bottomEdge.textContent = state.reachedEnd ? '' : 'Loading…';
  }
  function messageNode(id) { return tl.querySelector('[data-id="' + id + '"]'); }

  async function start(target) {
    const gen = ++state.gen;
    state.loading = true; state.armed = false;
    callsById.clear(); vmsById.clear();
    tl.replaceChildren(topEdge, h('div', { class: 'spinner' }, 'Loading…'), bottomEdge);
    try {
      let data, highlight = null, anchorTop = false;
      if (target.latest) {
        data = await api('api/messages', pageParams({ mode: 'latest', limit: FIRST_PAGE }));
        if (gen !== state.gen) return;
        mergeEventDays(eventsByDay, data.events); mergeCalls(callsById, data.calls); mergeRecordings(vmsById, data.voicemails);
        setWindow(data.messages, { reachedStart: data.messages.length < FIRST_PAGE, reachedEnd: true });
        tl.scrollTop = tl.scrollHeight;
      } else {
        data = await api('api/messages', pageParams({ mode: 'around', id: target.id, ts: target.ts, side: SIDE }));
        if (gen !== state.gen) return;
        mergeEventDays(eventsByDay, data.events); mergeCalls(callsById, data.calls); mergeRecordings(vmsById, data.voicemails);
        const at = data.at ?? 0;
        setWindow(data.messages, { reachedStart: at < SIDE, reachedEnd: data.messages.length - at - 1 < SIDE });
        const row = data.messages[at];
        if (row) {
          if (target.id) { highlight = row.id; }
          else anchorTop = true;
          let node = messageNode(row.id);
          if (anchorTop && node && node.previousElementSibling && node.previousElementSibling.classList.contains('time')) node = node.previousElementSibling;
          if (anchorTop && node && node.previousElementSibling && node.previousElementSibling.classList.contains('events')) node = node.previousElementSibling;
          if (anchorTop && node && node.previousElementSibling && node.previousElementSibling.classList.contains('day')) node = node.previousElementSibling;
          if (node) node.scrollIntoView({ block: anchorTop ? 'start' : 'center' });
          if (highlight) { const el = messageNode(highlight); if (el) { el.classList.add('hit'); setTimeout(() => el.classList.remove('hit'), 2600); } }
        }
      }
    } catch (e) {
      if (gen !== state.gen) return;
      tl.replaceChildren(h('div', { class: 'empty' }, 'Could not load: ' + e.message));
      return;
    }
    state.loading = false;
    setTimeout(() => { if (gen === state.gen) { state.armed = true; checkEdges(); } }, 50);   // not rAF: a background tab never paints
  }

  async function loadOlder() {
    const first = state.msgs[0]; if (!first) return;
    state.loading = true; const gen = state.gen;
    try {
      const data = await api('api/messages', pageParams({ mode: 'before', ts: first.ts, id: first.id, limit: PAGE }));
      if (gen !== state.gen) return;
      mergeEventDays(eventsByDay, data.events); mergeCalls(callsById, data.calls); mergeRecordings(vmsById, data.voicemails);
      let all = data.messages.concat(state.msgs), end = state.reachedEnd;
      if (all.length > MAX_WINDOW) { all = all.slice(0, MAX_WINDOW); end = false; }
      const before = tl.scrollHeight, top = tl.scrollTop;
      setWindow(all, { reachedStart: data.messages.length < PAGE, reachedEnd: end });
      tl.scrollTop = top + (tl.scrollHeight - before);
    } catch (e) { toast('Could not load older messages: ' + e.message); state.reachedStart = true; renderEdges(); }
    finishPaging(gen);
  }
  async function loadNewer() {
    const last = state.msgs[state.msgs.length - 1]; if (!last) return;
    state.loading = true; const gen = state.gen;
    try {
      const data = await api('api/messages', pageParams({ mode: 'after', ts: last.ts, id: last.id, limit: PAGE }));
      if (gen !== state.gen) return;
      mergeEventDays(eventsByDay, data.events); mergeCalls(callsById, data.calls); mergeRecordings(vmsById, data.voicemails);
      let all = state.msgs.concat(data.messages), startFlag = state.reachedStart;
      let dropped = 0;
      if (all.length > MAX_WINDOW) { dropped = all.length - MAX_WINDOW; all = all.slice(dropped); startFlag = false; }
      const before = tl.scrollHeight, top = tl.scrollTop;
      setWindow(all, { reachedStart: startFlag, reachedEnd: data.messages.length < PAGE });
      if (dropped) tl.scrollTop = top - (before - tl.scrollHeight);   // content above was removed: keep the view in place
    } catch (e) { toast('Could not load newer messages: ' + e.message); state.reachedEnd = true; renderEdges(); }
    finishPaging(gen);
  }
  function finishPaging(gen) {
    state.loading = false;
    setTimeout(() => { if (gen === state.gen && !state.loading) { state.armed = true; checkEdges(); } }, 200);
  }
  function checkEdges() {
    if (!state.armed || state.loading) return;
    if (!state.reachedStart && tl.scrollTop < EDGE_PX) { state.armed = false; loadOlder(); return; }
    if (!state.reachedEnd && tl.scrollHeight - tl.scrollTop - tl.clientHeight < EDGE_PX) { state.armed = false; loadNewer(); }
  }
  tl.addEventListener('scroll', checkEdges, { passive: true });

  function pickDate() {
    const info = state.info || {};
    const min = info.threads ? Math.min(...info.threads.map(t => t.firstTs).filter(Boolean)) : info.firstTs;
    const max = info.threads ? Math.max(...info.threads.map(t => t.lastTs).filter(Boolean)) : info.lastTs;
    const iso = ms => ms ? new Date(ms).toISOString().slice(0, 10) : null;
    const input = h('input', { type: 'date', min: iso(min), max: iso(max), value: iso(state.msgs[0]?.ts || max) });
    const sheet = h('div', { class: 'sheet', onclick: e => { if (e.target === sheet) sheet.remove(); } },
      h('div', { class: 'panel' }, h('div', {}, 'Jump to a date'), input,
        h('div', { class: 'actions' }, h('button', { onclick: () => sheet.remove() }, 'Cancel'),
          h('button', { class: 'primary', onclick: () => { const v = input.value; sheet.remove(); if (v) { const [y, m, d] = v.split('-').map(Number); start({ ts: new Date(y, m - 1, d).getTime() }); } } }, 'Go'))));
    document.body.append(sheet);
  }

  // load: the header info and the first window in parallel
  const at = q.get('at'), atTs = Number(q.get('ts'));
  (scopeSpec.person ? api('api/person/' + scopeSpec.person) : api('api/thread/' + scopeSpec.thread))
    .then(info => { state.info = info; renderHeader(); if (info.posts) { postsBtn.classList.remove('hidden'); postsBtn.title = info.posts.toLocaleString() + ' posts and comments'; } })
    .catch(e => { title.textContent = 'Not found'; toast(e.message); });
  start(at ? { id: at } : atTs > 0 ? { ts: atTs } : { latest: true });   // ?ts=<ms>: open at a time (a voicemail's place in the conversation)
  if (at || atTs > 0) { const u = new URLSearchParams(location.hash.split('?')[1] || ''); u.delete('at'); u.delete('ts'); history.replaceState(null, '', hashBase + (u.toString() ? '?' + u : '')); }
  return { destroy() { state.gen++; document.title = APP_NAME; } };
}

// ---- posts and comments ----
// BEGIN pure post helpers (no DOM; tested by scripts/test_web_posts.mjs)
const postEsc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
// Only http and https links are made clickable; anything else (javascript:, data:, file:) stays plain text.
function safeHref(url) {
  try { const u = new URL(String(url || '')); return (u.protocol === 'http:' || u.protocol === 'https:') ? u.href : null; } catch (_) { return null; }
}
// A post's or comment's text as HTML: every character escaped; a search snippet's U+0001/U+0002 become <mark> after escaping.
function postTextHTML(it) {
  if (it.snippet) return postEsc(it.snippet).replace(/\u0001/g, '<mark>').replace(/\u0002/g, '</mark>');
  return postEsc(it.body || it.context || it.link || '(' + it.kind + ')');
}
// "Mine" is item.byMe, never a missing author (a page's photo has no author and is not the owner's).
function postWho(it) { return it.byMe ? 'You' : (it.author || 'Someone (not named)'); }
// Posts search parameters: the person scope is passed when it is on; posts have no thread, so a thread scope is not offered.
function postsSearchParams(state, scope) {
  const p = { q: state.q, limit: 50, offset: state.offset, order: state.order === 'best' ? 'best' : state.order };
  if (scope.person && !state.everywhere) p.person = scope.person;
  return p;
}
function postsScopeOffered(scope) { return !!scope.person; }
// The viewer's zone, so the server folds albums by each row's own local day (daylight saving included).
function viewerZone() { try { return Intl.DateTimeFormat().resolvedOptions().timeZone || ''; } catch (_) { return ''; } }
// END pure post helpers
function postRow(it) {
  const who = postWho(it);
  const head = it.isComment ? (it.onMe ? who + ' commented on your post' : it.target ? who + ' commented on ' + it.target + "'s post" : who + ' commented')
                            : it.target ? who + ' → ' + it.target : who;
  const text = postTextHTML(it);
  const href = it.link && !it.isComment ? safeHref(it.link) : null;
  const meta = [it.platform === 'instagram' ? 'Instagram' : 'Facebook', it.isComment ? 'comment' : it.kind, it.targetText, fmt.full.format(new Date(it.ts)) + (it.basis === 'tagged' ? ' (when you were tagged)' : '')].filter(Boolean).join(' · ');
  return h('div', { class: 'hit-row post-row' },
    h('div', { class: 'top' }, h('b', {}, head), h('span', {}, fmt.short.format(new Date(it.ts)))),
    h('div', { class: 'snip', html: text }),
    it.isComment && it.postBody ? h('div', { class: 'post-on' }, 'on: ' + it.postBody) : null,
    href ? h('a', { class: 'post-link', href, target: '_blank', rel: 'noopener noreferrer' }, it.link) : it.link && !it.isComment ? h('div', { class: 'post-meta' }, it.link) : null,
    h('div', { class: 'post-meta' }, meta));
}
function postEntry(e) {
  if (!e.album) return postRow(e.items[0]);
  const box = h('div', { class: 'album-items hidden' });
  const head = h('button', { class: 'hit-row album-row', onclick: () => {
    if (!box.childElementCount) box.replaceChildren(...e.items.map(postRow));
    box.classList.toggle('hidden');
  } }, h('div', { class: 'top' }, h('b', {}, e.album + ': ' + e.items.length + ' photos'), h('span', {}, e.day || '')));
  return h('div', {}, head, box);
}

function postsView(personID) {
  const title = h('h1', {}, 'Posts and comments');
  const list = h('div', { class: 'rows' });
  const more = h('button', { class: 'more hidden', onclick: () => load() }, 'More');
  app.append(h('div', { class: 'bar' }, h('button', { class: 'btn', html: ICON.back, onclick: () => back('#/p/' + personID) }), title, h('span', { class: 'btn', style: 'visibility:hidden' })),
    h('div', { class: 'scroll' }, list, more));
  let next = null, gen = 0, shown = 0;
  api('api/person/' + personID).then(p => { title.replaceChildren(p.name, h('span', { class: 'sub' }, (p.posts || 0).toLocaleString() + ' posts and comments')); document.title = p.name + ' · Posts'; }).catch(() => {});
  async function load() {
    const g = ++gen;
    try {
      const page = await api('api/posts', { person: personID, limit: 100, zone: viewerZone(), tz: -new Date().getTimezoneOffset(), ts: next ? next.ts : '', id: next ? next.id : '' });
      if (g !== gen) return;
      for (const e of page.entries) { list.append(postEntry(e)); shown++; }
      if (!shown) list.replaceChildren(h('div', { class: 'empty' }, 'No posts or comments with this person'));
      next = page.nextTs ? { ts: page.nextTs, id: page.nextID } : null;
      more.classList.toggle('hidden', !next);
    } catch (e) { if (g === gen) list.append(h('div', { class: 'empty' }, 'Could not load: ' + e.message)); }
  }
  load();
  return { destroy() { gen++; document.title = APP_NAME; } };
}

// ---- voicemails and voice memos ----
// One recording as a card: what it is and when, a player, and its transcript labeled as a machine transcript. Every string from the
// archive goes in as text (textContent), a search snippet through esc() before its marks.
function recordingEl(r, opts = {}) {
  const isVM = r.kind === 'voicemail', isMeeting = r.kind === 'meeting';
  const el = h('div', { class: 'rec ' + (isVM ? 'vm' : isMeeting ? 'meeting' : 'memo') + (opts.inTimeline ? ' in-tl' : ''), 'data-rec': r.id, 'data-ts': r.ts || '' });
  el.append(h('div', { class: 'rec-head' }, h('b', {}, (isVM ? '📼 ' : isMeeting ? '👥 ' : '🎙 ') + r.title), opts.inTimeline ? null : h('span', {}, Number.isFinite(r.ts) ? fmt.short.format(new Date(r.ts)) : '')));
  if (isMeeting && r.note) el.append(h('div', { class: 'rec-meta' }, r.note));
  el.append(h('div', { class: 'rec-meta' }, recWhen(r, d => fmt.full.format(d)) + ' · ' + recFacts(r).join(' · ')));
  let audio = null;
  if (r.audio) {
    audio = h('audio', { controls: true, preload: 'none', src: 'media/' + r.audio });
    el.append(audio);
  } else {
    el.append(h('div', { class: 'rec-none' }, 'No audio: ' + (r.note || 'the source holds this recording\u2019s entry but not its sound')));
  }
  for (const t of r.transcripts || []) {
    const box = h('div', { class: 'rec-tr' });
    box.append(h('div', { class: 'rec-tr-label' }, transcriptLabel(t)));
    const text = (t.text || '').trim();
    if (!text) { box.append(h('div', { class: 'rec-tr-text none' }, 'The transcriber heard no words in this recording.')); el.append(box); continue; }
    const body = h('div', { class: 'rec-tr-text clamp' });
    if (r.snippet && t === r.transcripts[0] && r.snippet.includes('\u0001')) body.innerHTML = esc(r.snippet).replace(/\u0001/g, '<mark>').replace(/\u0002/g, '</mark>');
    else body.textContent = text;
    box.append(body);
    if (text.length > 280 || r.snippet) {
      const more = h('button', { class: 'rec-more' }, 'Show all');
      more.addEventListener('click', async () => {
        more.remove(); body.classList.remove('clamp'); body.textContent = text;
        // the timed sentences: tap one to play from there, and the one being spoken is marked while it plays
        try {
          const full = await api('api/recording/' + r.id);
          const ft = (full.transcripts || []).find(x => x.origin === t.origin && x.model === t.model);
          if (!ft || !ft.segments || !ft.segments.length || !audio) return;
          const spans = ft.segments.map(sg => h('span', { class: 'seg-t', title: recClock(sg.start), onclick: () => { audio.currentTime = sg.start; audio.play().catch(() => {}); } }, sg.text + ' '));
          body.replaceChildren(...spans);
          audio.addEventListener('timeupdate', () => { const i = segmentAt(ft.segments, audio.currentTime); spans.forEach((sp, k) => sp.classList.toggle('now', k === i)); });
        } catch (_) { /* the plain text stays */ }
      });
      box.append(more);
    }
    el.append(box);
  }
  if (r.audio && !(r.transcripts || []).length) el.append(h('div', { class: 'rec-tr' }, h('div', { class: 'rec-tr-label' }, 'No transcript')));
  if (r.chat) el.append(h('a', { class: 'rec-link', href: 'media/' + r.chat, target: '_blank', rel: 'noopener' }, 'The meeting\u2019s saved chat (Zoom\u2019s own file)'));
  if (!opts.inTimeline && isVM && (r.person || r.thread)) {
    const target = (r.person ? '#/p/' + r.person : '#/t/' + r.thread) + (Number.isFinite(r.ts) && r.timeIsOwn ? '?ts=' + r.ts : '');
    el.append(h('a', { class: 'rec-link', href: target, onclick: e => { e.preventDefault(); go(target); } }, 'Open the conversation' + (Number.isFinite(r.ts) && r.timeIsOwn ? ' at this time' : '')));
  }
  return el;
}

function recordingsView(q) {
  const state = { kind: RECORDING_KINDS.includes(q.get('kind')) ? q.get('kind') : '', q: q.get('q') || '', order: 'best', next: null, offset: 0, shown: 0 };
  const title = h('h1', {}, 'Recordings');
  const list = h('div', { class: 'rows recs' });
  const more = h('button', { class: 'more hidden', onclick: () => load(true) }, 'More');
  const input = h('input', { type: 'search', placeholder: 'Search transcripts and titles', value: state.q, autocomplete: 'off', autocapitalize: 'off', enterkeyhint: 'search' });
  const kinds = [['', 'All'], ['voicemail', 'Voicemails'], ['memo', 'Memos'], ['meeting', 'Meetings']];
  const seg = h('div', { class: 'seg' }, ...kinds.map(([k, l]) => h('button', { class: state.kind === k ? 'on' : '', onclick: () => { state.kind = k; load(); } }, l)));
  app.append(h('div', { class: 'bar' }, h('button', { class: 'btn', html: ICON.back, onclick: () => back('#/') }), title, h('span', { class: 'btn', style: 'visibility:hidden' })),
    h('div', { class: 'search-row' }, input, seg),
    h('div', { class: 'scroll' }, list, more));
  let timer, gen = 0;
  input.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => { state.q = input.value; load(); }, 350); });
  input.addEventListener('keydown', e => { if (e.key === 'Enter') { clearTimeout(timer); state.q = input.value; load(); input.blur(); } });
  async function load(append) {
    const g = ++gen;
    for (const [i, b] of [...seg.children].entries()) b.classList.toggle('on', kinds[i][0] === state.kind);
    if (!append) { state.next = null; state.offset = 0; state.shown = 0; list.replaceChildren(h('div', { class: 'spinner' }, 'Loading…')); }
    const u = new URLSearchParams(); if (state.kind) u.set('kind', state.kind); if (state.q.trim()) u.set('q', state.q.trim());
    history.replaceState(null, '', '#/recordings' + (u.toString() ? '?' + u : ''));
    const req = recordingsRequest(state), searching = req.path.endsWith('/search');
    try {
      const page = await api(req.path, req.params);
      if (g !== gen) return;
      const rows = searching ? page : page.recordings;
      if (!append) list.replaceChildren();
      for (const r of rows) { list.append(recordingEl(r)); state.shown++; }
      if (!state.shown) list.replaceChildren(h('div', { class: 'empty' }, searching ? 'No recording matches' : 'No recordings in the archive'));
      if (searching) { state.offset += rows.length; more.classList.toggle('hidden', rows.length < 50); title.replaceChildren('Recordings', h('span', { class: 'sub' }, state.shown + (rows.length === 50 ? '+' : '') + ' matching')); }
      else {
        state.next = page.nextTs !== undefined && page.nextTs !== null ? { ts: page.nextTs, id: page.nextID } : null;
        more.classList.toggle('hidden', !state.next);
        title.replaceChildren('Recordings', h('span', { class: 'sub' }, recordingsSummary(page)));
      }
    } catch (e) { if (g === gen) list.replaceChildren(h('div', { class: 'empty' }, 'Could not load: ' + e.message)); }
  }
  load();
  document.title = 'Recordings · ' + APP_NAME;
  return { destroy() { gen++; document.title = APP_NAME; for (const a of list.querySelectorAll('audio')) a.pause(); } };
}

// ---- search ----
function searchView(q) {
  const scope = q.get('person') ? { person: q.get('person') } : q.get('thread') ? { thread: q.get('thread') } : {};
  const state = { q: q.get('q') || '', order: q.get('order') || 'best', offset: 0, hits: [], scopeName: null, everywhere: !scope.person && !scope.thread, posts: q.get('in') === 'posts' };
  const input = h('input', { type: 'search', placeholder: 'Search messages', value: state.q, autocomplete: 'off', autocapitalize: 'off', enterkeyhint: 'search' });
  const list = h('div', { class: 'rows' });
  const scroll = h('div', { class: 'scroll' }, list);
  const title = h('h1', {}, 'Search');
  const orderSeg = h('div', { class: 'seg' }, ...[['best', 'Best'], ['newest', 'Newest'], ['oldest', 'Oldest']].map(([k, l]) => h('button', { class: state.order === k ? 'on' : '', onclick: () => { state.order = k; run(); } }, l)));
  const scopeChip = h('button', { class: 'chip' + (state.everywhere ? '' : ' on'), onclick: () => { if (scope.person || scope.thread) { state.everywhere = !state.everywhere; run(); } } }, '…');
  const kindChip = h('button', { class: 'chip' + (state.posts ? ' on' : ''), onclick: () => { state.posts = !state.posts; kindChip.classList.toggle('on', state.posts); kindChip.textContent = state.posts ? 'Posts and comments · tap for messages' : 'Messages · tap for posts and comments'; renderScope(); run(); } },
    state.posts ? 'Posts and comments · tap for messages' : 'Messages · tap for posts and comments');
  app.append(
    h('div', { class: 'bar' }, h('button', { class: 'btn', html: ICON.back, onclick: () => back(scope.person ? '#/p/' + scope.person : scope.thread ? '#/t/' + scope.thread : '#/') }), title, h('span', { class: 'btn', style: 'visibility:hidden' })),
    h('div', { class: 'search-row' }, input, orderSeg),
    h('div', { class: 'chips' }, kindChip, scopeChip,
      h('button', { class: 'chip', title: 'Voicemails and voice memos have their own search', onclick: () => go('#/recordings' + (state.q.trim() ? '?q=' + encodeURIComponent(state.q.trim()) : '')) }, 'Recordings →')), scroll);
  let timer;
  input.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => { state.q = input.value; run(); }, 350); });
  input.addEventListener('keydown', e => { if (e.key === 'Enter') { clearTimeout(timer); state.q = input.value; run(); input.blur(); } });
  if (scope.person) api('api/person/' + scope.person).then(p => { state.scopeName = p.name; renderScope(); }).catch(() => {});
  else if (scope.thread) api('api/thread/' + scope.thread).then(t => { state.scopeName = t.title; renderScope(); }).catch(() => {});
  function renderScope() {
    const name = state.scopeName || 'this conversation';
    scopeChip.textContent = state.everywhere ? 'Everywhere' + (scope.person || scope.thread ? ' · tap for ' + name : '') : 'In ' + name + ' · tap for everywhere';
    scopeChip.classList.toggle('on', !state.everywhere);
    // posts have no conversation: in Posts mode a thread scope is not shown (and not pretended), a person scope is applied
    scopeChip.classList.toggle('hidden', state.posts ? !postsScopeOffered(scope) : false);
  }
  renderScope();
  let gen = 0;
  async function run(more) {
    const g = ++gen;
    for (const [i, b] of [...orderSeg.children].entries()) b.classList.toggle('on', ['best', 'newest', 'oldest'][i] === state.order);
    if (!more) { state.offset = 0; state.hits = []; }
    const u = new URLSearchParams(); if (state.q) u.set('q', state.q); if (state.order !== 'best') u.set('order', state.order); if (scope.person) u.set('person', scope.person); if (scope.thread) u.set('thread', scope.thread); if (state.posts) u.set('in', 'posts');
    history.replaceState(null, '', '#/search' + (u.toString() ? '?' + u : ''));
    if (!state.q.trim()) { list.replaceChildren(h('div', { class: 'empty' }, 'Type to search every message' + (state.everywhere ? '' : ' in this conversation'))); return; }
    if (!more) list.replaceChildren(h('div', { class: 'spinner' }, 'Searching…'));
    if (state.posts) {
      try {
        const hits = await api('api/posts/search', postsSearchParams(state, scope));
        if (g !== gen) return;
        state.hits = state.hits.concat(hits); state.offset += hits.length;
        list.replaceChildren(...(state.hits.length ? state.hits.map(postRow) : [h('div', { class: 'empty' }, 'No posts or comments match')]));
        title.replaceChildren('Search', h('span', { class: 'sub' }, state.hits.length + (hits.length === 50 ? '+' : '') + ' posts and comments'));
        if (hits.length === 50) list.append(h('button', { class: 'more', onclick: () => run(true) }, 'More results'));
      } catch (e) { if (g === gen) list.replaceChildren(h('div', { class: 'empty' }, 'Search failed: ' + e.message)); }
      return;
    }
    try {
      const params = { q: state.q, order: state.order, limit: 50, offset: state.offset };
      if (!state.everywhere) Object.assign(params, scope);
      const hits = await api('api/search', params);
      if (g !== gen) return;
      state.hits = state.hits.concat(hits); state.offset += hits.length;
      list.replaceChildren(...(state.hits.length ? state.hits.map(hitRow) : [h('div', { class: 'empty' }, 'No matches')]));
      title.replaceChildren('Search', h('span', { class: 'sub' }, state.hits.length + (hits.length === 50 ? '+' : '') + ' results'));
      if (hits.length === 50) list.append(h('button', { class: 'more', onclick: () => run(true) }, 'More results'));
    } catch (e) { if (g === gen) list.replaceChildren(h('div', { class: 'empty' }, 'Search failed: ' + e.message)); }
  }
  function hitRow(x) {
    const snip = esc(x.snippet).replace(/\u0001/g, '<mark>').replace(/\u0002/g, '</mark>');
    const target = x.person ? '#/p/' + x.person + '?at=' + x.id : '#/t/' + x.thread + '?at=' + x.id;
    return h('a', { class: 'hit-row', href: target, onclick: e => { e.preventDefault(); go(target); } },
      h('div', { class: 'top' }, h('b', {}, x.where + (x.sender ? ' · ' + x.sender : x.me ? ' · You' : '')), h('span', {}, fmt.short.format(new Date(x.ts))), h('span', { class: 'svc-' + x.service }, SERVICE_SHORT[x.service] || x.service)),
      x.voice ? h('div', { class: 'voice-tag' }, '🎤 Voice message \u00b7 machine transcript, not verified') : null,
      h('div', { class: 'snip', html: snip }));
  }
  run();
  if (!state.q) setTimeout(() => input.focus(), 50);
  return { destroy() { gen++; } };
}

route();
