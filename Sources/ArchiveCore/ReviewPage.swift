import Foundation

/// The single page of the review site: plain HTML, CSS and vanilla JS in one string, no external requests. All URLs are
/// relative (`api/...`), so it works at any path behind a reverse proxy. Names and messages reach the DOM only through
/// textContent, never innerHTML.
enum ReviewPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="robots" content="noindex">
<title>Merge people</title>
<style>
:root{
  --bg:#f4f4f1; --card:#ffffff; --ink:#1b1c1e; --muted:#6a6e75; --line:#e1e1dc; --accent:#1f5fd6; --accent-ink:#ffffff;
  --good:#1c7a3d; --warn:#9a5b00; --bad:#b3261e; --chip:#eceae4; --shadow:0 1px 2px rgba(0,0,0,.06),0 2px 8px rgba(0,0,0,.05);
  --imessage:#1d6fe0; --sms:#1f8a42; --messenger:#7a3fd1; --instagram:#c2306c; --groupme:#0080a8; --skype:#0078b8; --whatsapp:#128c4a; --snapchat:#a88b00; --aim:#a07a00; --telegram:#1c7fb0; --slack:#611f69;
}
@media (prefers-color-scheme: dark){
  :root{ --bg:#121315; --card:#1d1e21; --ink:#ececec; --muted:#9a9ea6; --line:#2e3034; --accent:#6ea0ff; --accent-ink:#0b1220;
    --good:#58c47d; --warn:#e0a24a; --bad:#ff8b82; --chip:#2a2b2f; --shadow:none;
    --imessage:#6aa6ff; --sms:#5fd08a; --messenger:#b997f0; --instagram:#ff86b0; --groupme:#5cd0f0; --skype:#4fc3f7; --whatsapp:#5fd98a; --snapchat:#ffe14d; --aim:#ffd24d; --telegram:#6cc5f0; --slack:#e39be6; }
}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;
  padding:env(safe-area-inset-top) env(safe-area-inset-right) calc(84px + env(safe-area-inset-bottom)) env(safe-area-inset-left)}
.wrap{max-width:1000px;margin:0 auto;padding:0 14px}
header{position:sticky;top:0;z-index:5;background:var(--bg);padding:10px 0 8px;border-bottom:1px solid var(--line)}
h1{font-size:18px;margin:0;font-weight:650}
.row{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.spread{justify-content:space-between}
.tabs{display:flex;gap:6px;margin-top:8px}
.tab{flex:1;min-width:0;white-space:nowrap;text-align:center;padding:8px 6px;border-radius:10px;background:var(--chip);color:var(--ink);border:0;font:inherit;font-size:14px;min-height:40px}
.tab[aria-selected=true]{background:var(--accent);color:var(--accent-ink);font-weight:600}
.progress{font-size:13px;color:var(--muted);margin-top:6px}
button{font:inherit;cursor:pointer}
.btn{min-height:44px;padding:0 14px;border-radius:11px;border:1px solid var(--line);background:var(--card);color:var(--ink);font-weight:550}
.btn.primary{background:var(--accent);color:var(--accent-ink);border-color:transparent}
.btn.danger{color:var(--bad)}
.btn.small{min-height:34px;padding:0 10px;font-size:14px}
.btn:disabled{opacity:.5}
.linkish{background:none;border:0;color:var(--accent);padding:6px 2px;min-height:34px;font-size:14px}
.pair{display:grid;grid-template-columns:minmax(0,1fr);gap:12px;margin-top:12px}
@media (min-width:780px){ .pair{grid-template-columns:minmax(0,5fr) minmax(0,7fr);align-items:start} .sticky{position:sticky;top:132px} }
.label{font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:var(--muted);margin:0 2px 6px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:12px 14px;box-shadow:var(--shadow)}
.cand{margin-bottom:10px;border-width:2px}
.cand.sel{border-color:var(--accent)}
.name{font-size:19px;font-weight:650;overflow-wrap:anywhere}
.alt,.meta{font-size:14px;color:var(--muted);overflow-wrap:anywhere}
.alt.weak{font-size:13px;font-style:italic;opacity:.7}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin:8px 0 4px}
.chip{font-size:12.5px;padding:2px 9px;border-radius:99px;background:var(--chip);border:1px solid var(--line);white-space:nowrap}
.chip b{font-weight:650}
.chip.imessage{color:var(--imessage)} .chip.sms{color:var(--sms)} .chip.messenger{color:var(--messenger)} .chip.instagram{color:var(--instagram)} .chip.groupme{color:var(--groupme)} .chip.skype{color:var(--skype)} .chip.whatsapp{color:var(--whatsapp)} .chip.snapchat{color:var(--snapchat)} .chip.aim{color:var(--aim)} .chip.telegram{color:var(--telegram)} .chip.slack{color:var(--slack)}
.score{font-weight:650;font-size:13px;padding:2px 9px;border-radius:99px;border:1px solid var(--line)}
.score.strong{color:var(--good)} .score.likely{color:var(--accent)} .score.possible{color:var(--warn)}
.reasons{margin:8px 0 0;padding-left:18px;font-size:14px}
.reasons li{margin:2px 0}
.peek{margin-top:8px;border-top:1px dashed var(--line);padding-top:8px;font-size:14px}
.peek .m{margin:3px 0;overflow-wrap:anywhere}
.peek .me{color:var(--muted)}
.peek .head{font-size:13px;color:var(--muted);margin:2px 0 6px}
.seg{display:inline-flex;border:1px solid var(--line);border-radius:9px;overflow:hidden;margin:2px 0 6px}
.seg button{border:0;background:var(--card);color:var(--ink);min-height:32px;padding:0 12px;font-size:13.5px}
.seg button[aria-pressed=true]{background:var(--accent);color:var(--accent-ink)}
.peek .m .d{font-size:12px;color:var(--muted);white-space:nowrap}
.ctx{margin-top:8px;font-size:14px}
.ctx div{margin:3px 0;overflow-wrap:anywhere}
.ctx .k{color:var(--muted)}
.actions{display:flex;gap:8px;margin-top:10px;flex-wrap:wrap}
.actions .btn{flex:1;min-width:110px}
.bar{position:fixed;left:0;right:0;bottom:0;background:var(--bg);border-top:1px solid var(--line);padding:8px 14px calc(8px + env(safe-area-inset-bottom));z-index:6}
.bar .in{max-width:1000px;margin:0 auto;display:flex;gap:8px}
.bar .btn{flex:1}
.empty{text-align:center;padding:48px 12px;color:var(--muted)}
.sheet{position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:20;display:flex;align-items:flex-end;justify-content:center}
.sheet .panel{background:var(--bg);width:100%;max-width:640px;max-height:88vh;overflow:auto;border-radius:16px 16px 0 0;padding:14px 14px calc(18px + env(safe-area-inset-bottom))}
@media (min-width:780px){ .sheet{align-items:center} .sheet .panel{border-radius:16px} }
input[type=search],input[type=text]{width:100%;min-height:44px;padding:0 12px;border-radius:11px;border:1px solid var(--line);background:var(--card);color:var(--ink);font:inherit;font-size:16px}
.toast{position:fixed;left:14px;right:14px;bottom:calc(76px + env(safe-area-inset-bottom));z-index:30;max-width:640px;margin:0 auto;background:var(--ink);color:var(--bg);
  border-radius:12px;padding:10px 14px;display:flex;gap:10px;align-items:center;justify-content:space-between;box-shadow:0 4px 16px rgba(0,0,0,.25)}
.toast button{background:none;border:0;color:inherit;font-weight:700;text-decoration:underline;min-height:34px}
.hist{display:flex;gap:8px;align-items:center;justify-content:space-between;padding:8px 0;border-bottom:1px solid var(--line);font-size:14px}
.hist.undone{opacity:.5;text-decoration:line-through}
.busy .btn,.busy .tab{opacity:.55;pointer-events:none}
.err{color:var(--bad);font-size:14px;margin:8px 0}
kbd{font:12px ui-monospace,monospace;background:var(--chip);border:1px solid var(--line);border-radius:5px;padding:0 5px}
.hint{display:none;font-size:12px;color:var(--muted);margin-top:10px}
@media (hover:hover) and (pointer:fine){ .hint{display:block} }
</style>
</head>
<body>
<header><div class="wrap">
  <div class="row spread"><h1>Merge people</h1>
    <div class="row"><button class="btn small" id="undoBtn">Undo</button><button class="btn small" id="histBtn">History</button><button class="btn small" id="refreshBtn">Refresh</button></div></div>
  <div class="tabs" role="tablist"><button class="tab" role="tab" id="tabCross">Messenger / Instagram</button><button class="tab" role="tab" id="tabDups">Duplicates</button><button class="tab" role="tab" id="tabWho">Who's this?</button></div>
  <div class="progress" id="progress">Loading...</div>
</div></header>
<main class="wrap" id="main"></main>
<div class="bar"><div class="in"><button class="btn" id="skipBtn">Skip</button><button class="btn danger" id="noneBtn">None of these</button><button class="btn" id="findBtn">Find a person</button></div></div>
<div id="layer"></div>
<script>
"use strict";
const HDR = {"X-Requested-With": "archive-review"};
let queue = "cross", state = null, sel = 0, busy = false, toastTimer = null;

function h(tag, props, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (k === "class") e.className = v; else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else if (v !== false && v != null) e.setAttribute(k, v === true ? "" : v);
  }
  for (const k of kids.flat()) if (k != null && k !== false) e.append(k.nodeType ? k : document.createTextNode(String(k)));
  return e;
}
const $ = s => document.querySelector(s);
const nf = n => Number(n).toLocaleString();
const fdate = ms => ms ? new Date(ms).toLocaleDateString(undefined, {month: "short", year: "numeric"}) : "?";
const fday = ms => ms ? new Date(ms).toLocaleDateString(undefined, {month: "short", day: "numeric", year: "numeric"}) : "?";

async function api(path, body) {
  const opt = body === undefined ? {headers: HDR} : {method: "POST", headers: {...HDR, "Content-Type": "application/json"}, body: JSON.stringify(body)};
  const r = await fetch(path, opt);
  let data = null;
  try { data = await r.json(); } catch (e) { /* not json */ }
  if (!r.ok) throw new Error((data && data.error) || ("HTTP " + r.status));
  return data;
}

function toast(text, undo) {
  const old = $(".toast"); if (old) old.remove();
  clearTimeout(toastTimer);
  const t = h("div", {class: "toast", role: "status"}, h("span", {}, text), undo ? h("button", {onclick: () => { t.remove(); doUndo(); }}, "Undo") : null);
  document.body.append(t);
  toastTimer = setTimeout(() => t.remove(), 7000);
}

async function load() {
  try { state = await api("api/state?queue=" + queue); sel = 0; render(); }
  catch (e) { $("#main").replaceChildren(h("div", {class: "err"}, "Could not load: " + e.message)); }
}

async function act(path, body, okText, canUndo) {
  if (busy) return; busy = true; setBusy(true);
  try {
    state = await api(path, {...body, queue});
    sel = 0; render();
    if (okText) toast(okText, canUndo);
  } catch (e) { toast("Failed: " + e.message, false); }
  finally { busy = false; setBusy(false); }
}
function setBusy(b) { document.body.classList.toggle("busy", b); }

function badge(s) { return h("span", {class: "chip " + s.key}, h("b", {}, s.label), " ", nf(s.count)); }

function personBlock(p, opts) {
  const canRename = !opts || opts.rename !== false;
  const box = h("div", {});
  const nameRow = h("div", {class: "row spread"});
  const nameEl = h("div", {class: "name"}, p.name || "(no name)");
  const edit = h("button", {class: "linkish", "aria-label": "Rename", onclick: () => startRename(p, nameRow)}, "Rename");
  nameRow.append(nameEl, canRename ? edit : "");
  box.append(nameRow);
  if (p.renamed) box.append(h("div", {class: "alt"}, "renamed by you"));
  if (p.altNames.length) box.append(h("div", {class: "alt"}, "also: " + p.altNames.join(", ")));
  if (p.usernames.length) box.append(h("div", {class: "alt"}, p.usernames.map(u => "@" + u).join("  ")));
  if (p.possibleUsernames.length) box.append(h("div", {class: "alt weak"}, p.possibleUsernames.map(u => "possible @" + u).join("  ")));
  box.append(h("div", {class: "chips"}, p.services.map(badge), p.phones.map(x => h("span", {class: "chip"}, x))));
  const bits = [nf(p.messages) + " messages", fdate(p.firstTs) + " to " + fdate(p.lastTs)];
  if (p.groups) bits.push("in " + p.groups + (p.groups === 1 ? " group" : " groups"));
  box.append(h("div", {class: "meta"}, bits.join(" · ")));
  const peekBox = h("div", {});
  const peekBtn = h("button", {class: "linkish", onclick: () => togglePeek(p, peekBox, peekBtn)}, "Peek at messages");
  box.append(peekBtn, peekBox);
  return box;
}

function startRename(p, row) {
  const input = h("input", {type: "text", value: p.name || "", "aria-label": "Name", maxlength: "120", enterkeyhint: "done"});
  const save = h("button", {class: "btn small primary", onclick: () => doRename(p, input.value)}, "Save");
  const cancel = h("button", {class: "btn small", onclick: render}, "Cancel");
  input.addEventListener("keydown", ev => { ev.stopPropagation(); if (ev.key === "Enter") doRename(p, input.value); if (ev.key === "Escape") render(); });
  row.replaceChildren(input, save, cancel);
  input.focus(); input.select();
}
function doRename(p, name) { act("api/rename", {person: p.anchor, name}, "Renamed", true); }

const PEEK_MODES = [["latest", "Latest"], ["earliest", "Earliest"], ["spread", "Spread"]];
async function togglePeek(p, box, btn) {
  if (box.childNodes.length) { box.replaceChildren(); btn.textContent = "Peek at messages"; return; }
  btn.textContent = "Hide messages";
  loadPeek(p, box, "latest");
}
async function loadPeek(p, box, mode) {
  box.replaceChildren(h("div", {class: "peek"}, "Loading..."));
  try {
    const r = await api("api/peek?person=" + p.anchor + "&mode=" + mode);
    const inner = h("div", {class: "peek"});
    inner.append(h("div", {class: "seg", role: "group", "aria-label": "Which messages"},
      PEEK_MODES.map(([k, label]) => h("button", {"aria-pressed": k === mode, onclick: () => loadPeek(p, box, k)}, label))));
    if (r.totalInThread) inner.append(h("div", {class: "head"}, nf(r.totalInThread) + " messages in the biggest thread · " + fday(r.firstTs) + " to " + fday(r.lastTs)));
    if (!r.messages.length) inner.append(h("div", {class: "meta"}, "No text messages to show."));
    for (const m of r.messages) inner.append(h("div", {class: "m" + (m.fromMe ? " me" : "")},
      h("span", {class: "d"}, fday(m.ts) + " "), h("span", {class: "chip " + m.service}, m.service), " ", h("b", {}, m.fromMe ? "You: " : "Them: "), m.text));
    box.replaceChildren(inner);
  } catch (e) { box.replaceChildren(h("div", {class: "err"}, e.message)); }
}

function ctxBlock(c, sourceLabel, candLabel) {
  if (!c || (!c.mates.length && !c.sourceThreads.length && !c.candidateThreads.length)) return null;
  const rows = [];
  if (c.mates.length) rows.push(h("div", {}, h("span", {class: "k"}, "Group-mates: "), c.mates.join(", "), c.totalMates > c.mates.length ? " +" + (c.totalMates - c.mates.length) + " more" : ""));
  if (c.sourceThreads.length) rows.push(h("div", {}, h("span", {class: "k"}, sourceLabel + ": "), c.sourceThreads.join(" · ")));
  if (c.candidateThreads.length) rows.push(h("div", {}, h("span", {class: "k"}, candLabel + ": "), c.candidateThreads.join(" · ")));
  return h("div", {class: "ctx"}, rows);
}

function cand(c, i, src) {
  const reasons = h("ul", {class: "reasons"}, c.reasons.map(r => h("li", {}, r)));
  const head = h("div", {class: "row"}, h("span", {class: "chip"}, "#" + (i + 1)),
    h("span", {class: "score " + c.label}, c.label + " · " + Math.round(c.score * 100) + "%"),
    c.sharedGroups ? h("span", {class: "chip"}, c.sharedGroups + " shared in groups") : null);
  return h("div", {class: "card cand" + (i === sel ? " sel" : ""), onclick: ev => { if (ev.target.closest("button,input")) return; sel = i; render(); }},
    head, personBlock(c.person), reasons, ctxBlock(c.context, "Their groups", "This person's groups"),
    h("div", {class: "actions"},
      h("button", {class: "btn primary", onclick: () => doMerge(src, c)}, "Merge"),
      h("button", {class: "btn", onclick: () => doReject(src, [c])}, "Not the same")));
}

function render() {
  const s = state, p = s.progress;
  $("#tabCross").setAttribute("aria-selected", queue === "cross");
  $("#tabDups").setAttribute("aria-selected", queue === "dups");
  $("#tabWho").setAttribute("aria-selected", queue === "who");
  const rem = q => (p.queues && p.queues[q]) || 0;
  const narrow = window.matchMedia("(max-width:520px)").matches;
  $("#tabCross").textContent = (narrow ? "Meta" : "Messenger / Instagram") + " (" + nf(rem("cross")) + ")";
  $("#tabDups").textContent = (narrow ? "Dups" : "Duplicates") + " (" + nf(rem("dups")) + ")";
  $("#tabWho").textContent = (narrow ? "Who?" : "Who's this?") + " (" + nf(rem("who")) + ")";
  $("#noneBtn").textContent = queue === "who" ? "No match" : "None of these";
  $("#progress").textContent = nf(p.remaining) + " left · " + nf(p.reviewed) + " reviewed this session (" + nf(p.skipped) + " skipped) · " + nf(p.merges) + " merges made · " + nf(p.rejections) + " marked not the same · " + nf(p.noMatches) + " no match";
  const undoable = s.history.find(d => d.id === s.undoableID);
  $("#undoBtn").disabled = !s.undoableID; $("#undoBtn").title = undoable ? undoable.label : "";
  const main = $("#main");
  const barBtns = ["#skipBtn", "#noneBtn"].map($);
  if (!s.card) {
    barBtns.forEach(b => b.disabled = true);
    main.replaceChildren(h("div", {class: "empty"}, h("p", {}, "Nothing left in this queue."), h("button", {class: "btn", onclick: doRefresh}, "Recompute suggestions")));
    return;
  }
  barBtns.forEach(b => b.disabled = false);
  const c = s.card;
  if (sel >= c.candidates.length) sel = 0;
  const who = queue === "who";
  const left = h("div", {class: "sticky"}, h("div", {class: "label"}, queue === "dups" ? "Person" : "Messenger / Instagram person"),
    h("div", {class: "card"}, personBlock(c.source), who ? ctxBlock(c.context, "Their groups", "") : null));
  const right = who
    ? h("div", {}, h("div", {class: "label"}, "No suggestion"), h("div", {class: "card"}, h("p", {style: "margin:0"}, "Nothing in your texts looks like this person. Use Find a person to link them to anyone, or No match so they do not come back.")))
    : h("div", {}, h("div", {class: "label"}, queue === "cross" ? "Could be the same as" : "Could be the same person as"), c.candidates.map((x, i) => cand(x, i, c.source)));
  main.replaceChildren(h("div", {class: "pair"}, left, right),
    h("div", {class: "hint"}, "Keys: ", who ? null : [h("kbd", {}, "1"), "-", h("kbd", {}, "3"), " pick · ", h("kbd", {}, "m"), " merge · "],
      h("kbd", {}, "n"), who ? " no match · " : " not the same · ",
      h("kbd", {}, "s"), " skip · ", h("kbd", {}, "u"), " undo · ", h("kbd", {}, "/"), " find a person"));
}

function nameOf(p) { return p.name || "(no name)"; }
function doMerge(src, c) { act("api/merge", {source: src.anchor, target: c.person.anchor}, "Merged " + nameOf(src) + " with " + nameOf(c.person), true); }
function doReject(src, cs) { act("api/reject", {source: src.anchor, targets: cs.map(c => c.person.anchor)}, "Marked not the same", true); }
function doSkip() { if (state && state.card) act("api/skip", {source: state.card.source.anchor}, "Skipped", false); }
function doNone() {
  if (!state || !state.card) return;
  if (queue === "who") act("api/nomatch", {source: state.card.source.anchor}, "No match for " + nameOf(state.card.source), true);
  else doReject(state.card.source, state.card.candidates);
}
function doUndo(id) { act("api/undo", id ? {id} : {}, "Undone", false); }
function doRefresh() { act("api/refresh", {}, "Suggestions recomputed", false); }

function sheet(title, body) {
  closeSheet();
  const panel = h("div", {class: "panel", role: "dialog", "aria-label": title},
    h("div", {class: "row spread"}, h("b", {}, title), h("button", {class: "btn small", "data-keep": "1", onclick: closeSheet}, "Close")), body);
  const el = h("div", {class: "sheet", onclick: ev => { if (ev.target === el) closeSheet(); }}, panel);
  $("#layer").append(el);
  return el;
}
function closeSheet() { $("#layer").replaceChildren(); }

function openFind() {
  if (!state || !state.card) return;
  const src = state.card.source;
  const input = h("input", {type: "search", placeholder: "Search by name or username", "aria-label": "Search people", autocomplete: "off", "data-keep": "1"});
  const list = h("div", {style: "margin-top:10px"});
  let timer = null, token = 0;
  input.addEventListener("keydown", ev => { ev.stopPropagation(); if (ev.key === "Escape") closeSheet(); });
  input.addEventListener("input", () => {
    clearTimeout(timer);
    timer = setTimeout(async () => {
      const my = ++token;
      if (input.value.trim().length < 2) { list.replaceChildren(); return; }
      try {
        const res = await api("api/search?q=" + encodeURIComponent(input.value) + "&exclude=" + src.anchor);
        if (my !== token) return;
        list.replaceChildren(...(res.length ? res.map(p => h("div", {class: "card", style: "margin-bottom:10px"}, personBlock(p, {rename: false}),
          h("div", {class: "actions"}, h("button", {class: "btn primary", onclick: () => { closeSheet(); act("api/merge", {source: src.anchor, target: p.anchor}, "Merged " + nameOf(src) + " with " + nameOf(p), true); }}, "Merge with " + nameOf(p))))) : [h("div", {class: "meta"}, "No one found.")]));
      } catch (e) { list.replaceChildren(h("div", {class: "err"}, e.message)); }
    }, 220);
  });
  sheet("Merge " + nameOf(src) + " with...", h("div", {style: "margin-top:10px"}, input, list));
  input.focus();
}

function openHistory() {
  const body = h("div", {});
  if (!state.history.length) body.append(h("div", {class: "meta", style: "margin-top:10px"}, "No decisions yet."));
  for (const d of state.history) body.append(h("div", {class: "hist" + (d.undone ? " undone" : "")}, h("span", {}, d.label),
    d.undone ? h("span", {class: "meta"}, "undone") : d.id === state.undoableID ? h("button", {class: "btn small", onclick: () => { closeSheet(); doUndo(d.id); }}, "Undo") : h("span", {class: "meta"}, "undo the newer ones first")));
  sheet("Last " + state.history.length + " decisions", body);
}

function setQueue(q) { if (q !== queue) { queue = q; load(); } }
$("#tabCross").addEventListener("click", () => setQueue("cross"));
$("#tabDups").addEventListener("click", () => setQueue("dups"));
$("#tabWho").addEventListener("click", () => setQueue("who"));
$("#skipBtn").addEventListener("click", doSkip);
$("#noneBtn").addEventListener("click", doNone);
$("#findBtn").addEventListener("click", openFind);
$("#undoBtn").addEventListener("click", () => doUndo());
$("#histBtn").addEventListener("click", openHistory);
$("#refreshBtn").addEventListener("click", doRefresh);

document.addEventListener("keydown", ev => {
  if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
  const t = ev.target;
  if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA")) return;
  if (ev.key === "Escape") { closeSheet(); return; }
  if ($("#layer").childNodes.length) return;
  const c = state && state.card;
  if (/^[1-9]$/.test(ev.key)) { if (c && Number(ev.key) <= c.candidates.length) { sel = Number(ev.key) - 1; render(); } }
  else if (ev.key === "m" && c && c.candidates.length) doMerge(c.source, c.candidates[sel]);
  else if (ev.key === "n" && c) { if (queue === "who") doNone(); else if (c.candidates.length) doReject(c.source, [c.candidates[sel]]); }
  else if (ev.key === "s") doSkip();
  else if (ev.key === "u") doUndo();
  else if (ev.key === "/") { ev.preventDefault(); openFind(); }
});
load();
</script>
</body>
</html>
"""#
}
