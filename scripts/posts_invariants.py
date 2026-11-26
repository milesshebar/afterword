#!/usr/bin/env python3 -I
"""Independent audit of a posts-and-comments import (archivectl posts-import) on a copy, against the archive it was copied from.

Recomputed from the SQLite files and the export HTML, not taken from the importer's own report:
  0  every row of every table that existed before is unchanged in the copy (full-row digest per table); rows only in the copy
     are listed per table, new handles one by one
  1  written rows = the ledger's "new" rows (ids, counts by type); held rows point at rows that exist; the source row is the run's
  2  every written row's time is its own: it equals the time the export prints for that record (re-read with the survey reader
     fb_saved_pages.py, not posts_read.py), and no written post is later than its first written comment
  3  no post or comment written twice: near-matches among all post rows / all comment rows (same author, same text with
     whitespace removed, times within the printed precision), each listed
  4  likes: no row whose body is a "likes this" line; no reaction rows added
  5  every written comment's post exists; no comment of a left-out post was written

usage: posts_invariants.py <ledger.tsv> <copy archive.sqlite> <before archive.sqlite> <records.jsonl>"""
import collections, datetime, hashlib, json, os, re, sqlite3, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fb_saved_pages as fsp  # noqa: E402
import posts_read as pr  # noqa: E402

TZ_2011 = None   # the 2011 export's zone, from the records file's header ("zone")


def _at4(lm):
    return int(datetime.datetime.fromisoformat(lm).replace(tzinfo=TZ_2011).timestamp() * 1000) if lm else None


def media_times_2011(paths):
    """Each 2011 album photo's and video's own printed time, by its Facebook id (the a[name] anchor that opens its block), read
    with regular expressions, independent of posts_read.py (a time found anywhere in the export
    is not this photo's time)."""
    out = {}
    for p in paths:
        raw = open(p, encoding="utf-8", errors="replace").read()
        name = os.path.basename(p)
        if name.startswith("album-"):
            for blk in raw.split('<div class="photo">')[1:]:
                m = re.search(r'<a name="(\d+)"', blk)
                t = re.search(r'<span class="time">([^<]*)</span>', blk.split('<div class="comments">')[0])
                if m and t:
                    out[m.group(1)] = _at4(fsp.dyi_time(t.group(1)))
        elif name == "videos.html":
            # an anchor precedes each video block
            for m in re.finditer(r'<a name="(\d+)"\s*/>\s*<div class="video">(.*?)(?=<a name="\d+"\s*/>\s*<div class="video">|$)', raw, re.S):
                t = re.search(r'<div class="vidinfo">.*?<span class="time">([^<]*)</span>', m.group(2), re.S)
                if t:
                    out[m.group(1)] = _at4(fsp.dyi_time(t.group(1)))
    return out


META_TIME = re.compile(r"([A-Z][a-z]{2} \d{1,2}, \d{4} \d{1,2}:\d{2}(?::\d{2})?\s?[ap]m)")
MENTION = re.compile(r"@\[\d+:\d+:([^\]]+)\]")


def meta_segments(path, offset_s):
    """A Meta (2025) page re-read with regular expressions, independent of posts_read.py: the visible text between one printed
    time and the next, keyed by that time in Unix ms (each record's footer time follows its own text). Mentions are shown as
    names, as the reader does. Returns [(ms, text with whitespace removed, raw html segment)]."""
    import html as _h
    raw = open(path, encoding="utf-8", errors="replace").read()
    i = raw.find('role="main"')
    raw = raw[i:] if i >= 0 else raw
    out, prev = [], 0
    # a record's own time is its footer: div._a72d (Facebook), div._a6-o (Instagram), or the Time cell of an Instagram comment;
    # "Updated", "Last modified" and "Taken" times inside a record are not footers
    footer = re.compile(r'(?:class="_a72d">|class="_3-94 _a6-o">|>Time</td><td class="[^"]*_a6_r">)\s*' + META_TIME.pattern)
    for m in footer.finditer(raw):
        seg = raw[prev:m.start()]
        prev = m.end()
        t = m.group(1).replace("\u202f", " ")
        for f in ("%b %d, %Y %I:%M:%S %p", "%b %d, %Y %I:%M %p"):
            try:
                d = datetime.datetime.strptime(t, f)
                break
            except ValueError:
                d = None
        if d is None:
            continue
        if isinstance(offset_s, str):                       # a named zone with DST (some newer exports)
            import zoneinfo
            tz = zoneinfo.ZoneInfo(offset_s)
        else:
            tz = datetime.timezone(datetime.timedelta(seconds=offset_s))
        ms = int(d.replace(tzinfo=tz).timestamp() * 1000)
        text = MENTION.sub(lambda x: x.group(1), _h.unescape(re.sub(r"<[^>]+>", " ", seg)))
        out.append((ms, re.sub(r"\s+", "", text).casefold(), _h.unescape(seg)))
    return out


MEDIA_ID = re.compile(r"[/_](\d{6,})\.(?:jpg|jpeg|png|gif|heic|webp|mp4|mov)\b", re.I)


def meta_ids_by_time(segs):
    """Each media id printed in a record's segment -> the footer times it is printed under (a photo without
    text is checked against its own time, by its id)."""
    out = collections.defaultdict(set)
    for ms, _text, raw in segs:
        for m in MEDIA_ID.finditer(raw):
            out[m.group(1)].add(ms)
    return out


def meta_id_time_ok(external_id, ts, by_id):
    return ts in by_id.get(str(external_id), set())


def meta_time_ok(ts, body, link, segs_by_ms):
    """The row's time is printed in the export, right after a segment holding every line of its text (or its link)."""
    for text, raw in segs_by_ms.get(ts, []):
        lines = [re.sub(r"\s+", "", l).casefold() for l in (body or "").split("\n") if l.strip()]
        if lines and all(l in text for l in lines):
            return True
        if not lines and (not link or link in raw):
            return True
    return False


def _clean(fragment):
    import html as _h
    t = _h.unescape(re.sub(r"<br\s*/?>", "\n", fragment))
    t = re.sub(r"<[^>]+>", " ", t)
    return MENTION.sub(lambda x: x.group(1), t).strip()


def meta_captions(raw, platform):
    """The caption or text a record prints, re-read from its own segment of the page with regular expressions:
    Instagram's caption heading; Facebook's photo caption, a post's text paragraph, a "Message" cell, an Instagram
    comment's text. Facebook's header line ("<owner> shared a link.") is not a caption."""
    caps = []
    if platform == "instagram":
        caps += [_clean(m) for m in re.findall(r'<(?:h2|div) class="[^"]*_a6-h[^"]*">(.*?)</(?:h2|div)>', raw, re.S)]
        caps += [_clean(m) for m in re.findall(r'>Comment<div><div>(.*?)</div>', raw, re.S)]
    else:
        caps += [_clean(m) for m in re.findall(r'<div class="_3-95">(.*?)</div>', raw, re.S) if "Group:" not in m]
        caps += [_clean(m) for m in re.findall(r'<div class="_2pin"><div>([^<]*)</div>', raw)]
        caps += [_clean(m) for m in re.findall(r'>Message</td><td class="[^"]*_a6_r">(.*?)</td>', raw, re.S)]
    return [c for c in caps if c and not re.match(r"^Updated [A-Z][a-z]{2} \d{1,2}, \d{4}", c)]


def captions_ok(body, caps):
    """A row is faithful to its page's captions: none printed, or the row's text holds one of them (whitespace and case aside)."""
    if not caps:
        return True
    # letters and digits, "<3" read as a heart: the page escapes some characters ("Presents\\:") and draws a heart as "<3"
    key = lambda x: "".join(ch for ch in (x or "").replace("<3", "\u2665").casefold() if ch.isalnum() or ch == "\u2665")
    ws = lambda x: re.sub(r"\s+", "", x or "").casefold()
    if not ws(body):
        return False
    # a caption of punctuation or emoji only ("????", ";)") is compared as printed, whitespace aside
    return any((key(c) in key(body)) if key(c) else (ws(c) in ws(body)) for c in caps)


def media_time_ok(external_id, ts, times):
    return external_id in times and times[external_id] == ts


def main():
    ledger_p, copy_p, before_p, records_p = sys.argv[1:5]
    C = sqlite3.connect(f"file:{copy_p}?immutable=1", uri=True)
    B = sqlite3.connect(f"file:{before_p}?immutable=1", uri=True)
    problems = [0]

    def bad(msg):
        problems[0] += 1
        print("  PROBLEM:", msg)


    def tables(db):
        return [r[0] for r in db.execute("select name from sqlite_master where type='table' and name not like 'sqlite_%' "
                                         "and name not like '%_fts%' order by name")]


    print("== 0 old rows unchanged")
    bt, ct = tables(B), tables(C)
    print("  tables only in the copy:", sorted(set(ct) - set(bt)), "| only before:", sorted(set(bt) - set(ct)))
    if set(bt) - set(ct):
        bad("a table disappeared")
    for t in bt:
        def dig(db):
            c = collections.Counter()
            for row in db.execute(f'select * from "{t}"'):
                c[hashlib.blake2b(repr(row).encode("utf-8", "surrogatepass"), digest_size=16).digest()] += 1
            return c
        hb, hc = dig(B), dig(C)
        missing, added = sum((hb - hc).values()), sum((hc - hb).values())
        print(f"  {t:18s} before {sum(hb.values()):9d} copy {sum(hc.values()):9d} | before-rows not identical in copy: {missing} | rows only in copy: {added}")
        if missing:
            bad(f"{t}: {missing} pre-existing rows changed or gone")
        if added and t not in ("handle", "contact_name", "source", "import_ledger", "meta", "post", "post_comment"):
            bad(f"{t}: {added} rows added to an existing table that should get none")
    mh = B.execute("select max(id) from handle").fetchone()[0]
    newh = C.execute("select id, normalized, raw, kind from handle where id > ? order by id", (mh,)).fetchall()
    print(f"  new handles: {len(newh)}")
    for h in newh:
        th = C.execute("select count(*) from thread_member where handle_id=?", (h[0],)).fetchone()[0]
        print(f"    {h[0]}\t{h[1]}\t{h[3]}\tthreads {th}")
        if th:
            bad(f"new handle {h[1]} is in a thread")

    print("== 1 written rows = ledger new rows")
    L = [l.rstrip("\n").split("\t") for l in open(ledger_p, encoding="utf-8")]
    hdr, rows = L[0], L[1:]
    ix = {k: i for i, k in enumerate(hdr)}
    recs = [json.loads(l) for l in open(records_p, encoding="utf-8")]
    head, recs = recs[0], recs[1:]
    global TZ_2011
    TZ_2011 = pr.parse_zone(head["zone"]) if head.get("zone") else None
    print(f"  records {len(recs)} | ledger rows {len(rows)}")
    if len(recs) != len(rows):
        bad("ledger rows != records")
    dec = collections.Counter((r[ix["type"]], r[ix["decision"]], r[ix["reason"]]) for r in rows)
    for k, v in sorted(dec.items()):
        print("   ", v, k)
    sid = C.execute("select id from source where kind = ? order by id desc limit 1", ("posts-" + head["export"],)).fetchone()
    sid = sid[0] if sid else None
    print("  source row:", sid)
    for typ, table in (("post", "post"), ("comment", "post_comment")):
        led = sorted(int(r[ix["written_id"]]) for r in rows if r[ix["type"]] == typ and r[ix["decision"]] == "new")
        have = sorted(x[0] for x in C.execute(f"select id from {table} where source_id = ?", (sid,))) if sid else []
        print(f"  {table}: ledger new {len(led)} | rows with this source {len(have)} | equal id sets: {led == have}")
        if led != have:
            bad(f"{table}: written ids differ from the ledger")
        held = [int(r[ix["existing_id"]]) for r in rows if r[ix["type"]] == typ and r[ix["decision"]] == "held"]
        for h in held:
            if not C.execute(f"select 1 from {table} where id = ? and source_id != ?", (h, sid)).fetchone():
                bad(f"held {typ} points at {h}, which is not an earlier row")
        print(f"  {table}: held {len(held)} (each an earlier row)")

    print("== 2 times are the export's own")
    fmt = lambda ms: datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    ws = lambda s: re.sub(r"\s+", "", (s or "")).casefold()
    printed = collections.defaultdict(list)   # (kind, author fold, ws text) -> [ms]
    meta = head["export"] in ("fb-2025",) or head["export"].startswith(("ig-", "fb-2026"))
    segs = collections.defaultdict(list)
    ids_by_time = collections.defaultdict(set)
    for f in head["files"]:
        if meta:
            off_s = f.get("zone") or f.get("offset_s", 8 * 3600 if head["platform"] == "facebook" else -8 * 3600)
            fsegs = meta_segments(f["path"], off_s)
            for ms_, text, raw in fsegs:
                segs[ms_].append((text, raw))
            for k, v in meta_ids_by_time(fsegs).items():
                ids_by_time[k] |= v
            continue
        p = f["path"]
        if head["export"] == "fb-dyi-2011":
            page = fsp.read_page(p)
            root, _ = fsp.parse_html(open(p, encoding="utf-8", errors="replace").read())
            at4 = _at4
            for r in page["records"]:
                if r["kind"] in ("post", "comment"):
                    printed[(r["kind"], fsp.norm_text((r.get("author") or {}).get("name")), ws(r["text"]))].append(at4(r.get("local_minute")))
            # album photos and videos: every "time" span in the file, by its comment text or caption, re-read with a regex
            for m in re.finditer(r'<span class="profile">([^<]*)</span>((?:(?!<span class="profile">).)*?)<br/><span class="time">([^<]*)</span>', open(p, encoding="utf-8", errors="replace").read(), re.S):
                printed[("comment", fsp.norm_text(m.group(1)), ws(fsp.text_of(fsp.parse_html(m.group(2))[0])))].append(at4(fsp.dyi_time(m.group(3))))
        else:
            page = fsp.read_page(p, os.path.getmtime(p))
            for r in page["records"]:
                if r["kind"] in ("post", "comment"):
                    printed[(r["kind"], fsp.norm_text((r.get("author") or {}).get("name")), ws(r["text"]))].append(r.get("ts_ms"))
    media_times = media_times_2011([f["path"] for f in head["files"]]) if head["export"] == "fb-dyi-2011" else {}
    me = fsp.norm_text(head.get("me", ""))
    capfail = [0]
    off = 0
    checked = 0
    for table, kind in (("post", "post"), ("post_comment", "comment")):
        q = f"select id, by_me, author_name, body, ts_ms, ts_precision{', kind, external_id' if table == 'post' else ''} from {table} where source_id = ?"
        for row in C.execute(q, (sid,)):
            rid, by_me, name, body, ts = row[:5]
            author = me if by_me else fsp.norm_text(name)
            times = printed.get((kind, author, ws(body)), [])
            if meta:
                link, ext, ctx = C.execute("select link, external_id, context from post where id = ?", (rid,)).fetchone() if table == "post" \
                    else (None, None, C.execute("select context from post_comment where id = ?", (rid,)).fetchone()[0])
                if ext and str(ext) in ids_by_time:        # a photo or video: its own id under this very time, and its text if any
                    ok = meta_id_time_ok(ext, ts, ids_by_time) and (not body or meta_time_ok(ts, body, None, segs))
                    mine_segs = [raw for _t, raw in segs.get(ts, []) if str(ext) in raw]
                else:
                    mine_segs = [raw for _t, raw in segs.get(ts, [])]
                # the caption the page prints for this record, re-read and compared, also when the row has no text
                if not any(captions_ok(body, meta_captions(raw, head["platform"])) for raw in mine_segs):
                    capfail[0] += 1
                    if capfail[0] <= 20:
                        bad(f"{table} {rid}: the page prints a caption this row does not hold")
                if ext and str(ext) in ids_by_time:
                    pass
                elif body or link:
                    ok = meta_time_ok(ts, body, link, segs)
                else:                                      # nothing but the header line: it must be printed under this time
                    hdr = re.sub(r"\s+", "", (ctx or "").split(" | ")[0]).casefold()
                    ok = bool(hdr) and any(hdr in text for text, _raw in segs.get(ts, []))
            elif table == "post" and row[6] in ("album-photo", "video"):
                ok = media_time_ok(row[7], ts, media_times)   # this photo's (video's) own printed time, by its Facebook id
            else:
                ok = ts in times
            checked += 1
            if not ok:
                off += 1
                if off <= 20:
                    bad(f"{table} {rid} at {fmt(ts)}: the export prints no such record at that time ({len(times)} candidates)")
    print(f"  rows checked {checked} | time not found in the export: {off}" + (f" | caption not held: {capfail[0]}" if meta else ""))
    late = C.execute("""select p.id, p.ts_ms, min(c.ts_ms) from post p join post_comment c on c.post_id = p.id
                        where p.source_id = ? group by p.id having p.ts_ms > min(c.ts_ms)""", (sid,)).fetchall()
    print(f"  written posts later than their first comment: {len(late)}", late[:10])
    for x in late:
        bad(f"post {x[0]} printed after its first comment")

    print("== 3 near-matches (written twice?)")
    for table in ("post", "post_comment"):
        groups = collections.defaultdict(list)
        for rid, src, by_me, ah, body, ts, prec in C.execute(f"select id, source_id, by_me, author_handle_id, body, ts_ms, ts_precision from {table}"):
            k = ws(body)
            if len(k) < 2:
                continue
            groups[(by_me, ah, k)].append((ts, prec, rid, src))
        near = []
        for k, v in groups.items():
            v.sort()
            for a, b in zip(v, v[1:]):
                wa = 60000 if a[1] == "minute" else 1000
                if b[0] - a[0] < max(wa, 60000):
                    near.append((a[2], a[3], b[2], b[3], (b[0] - a[0]) // 1000, k[2][:40]))
        print(f"  {table}: same author, same text (whitespace removed), within a minute: {len(near)}")
        for n in near:
            print(f"    rows {n[0]} (source {n[1]}) and {n[2]} (source {n[3]}), {n[4]} s apart, text {n[5]!r}")

    print("== 3b across exports: same author, overlapping minute, one text the other's beginning (word for word)")
    def words(x):
        return re.findall(r"\w+", (x or "").casefold())
    for table in ("post", "post_comment"):
        mine = C.execute(f"select id, ts_ms, ts_precision, by_me, author_handle_id, body from {table} where source_id = ?", (sid,)).fetchall()
        n = 0
        for i, ts, prec, by_me, ah, body in mine:
            w = 60000 if prec == "minute" else 1000
            for j, ots, oprec, ob in C.execute(f"select id, ts_ms, ts_precision, body from {table} where source_id != ? and by_me = ? and author_handle_id is ? and ts_ms between ? and ?",
                                               (sid, by_me, ah, ts - 60000, ts + w)):
                ow = 60000 if oprec == "minute" else 1000
                a, b = words(body), words(ob)
                if not (ots < ts + w and ts < ots + ow) or not a or not b:
                    continue
                k = min(len(a), len(b))
                if a[:k] == b[:k]:
                    n += 1
                    if n <= 30:
                        print(f"    {table} {i} (this export) and {j} (earlier), {(ts - ots) // 1000} s, {len(a)} and {len(b)} words")
        print(f"  {table}: {n}")

    print("== 4 likes")
    for table in ("post", "post_comment"):
        # the 2011 export's like lines: "2 people like this", "Ann Bee likes this", "Ann Bee and Bo Sea like this"
        like = re.compile(r"^(?:\d+ (?:people|person) likes? this|(?:[A-Z][\w'.-]* ){1,4}(?:and (?:\d+ others|(?:[A-Z][\w'.-]* ){1,4}))?likes? this)\.?$")
        n = sum(1 for (b,) in C.execute(f"select body from {table} where body like '%like%this%'") if like.match((b or "").strip()))
        print(f"  {table} rows whose body is a likes line: {n}")
        if n:
            bad("likes line written")
    rb = B.execute("select count(*) from reaction").fetchone()[0]
    rc = C.execute("select count(*) from reaction").fetchone()[0]
    print(f"  reaction rows before {rb} copy {rc}")
    if rb != rc:
        bad("reaction rows changed")
    print("  post_reaction table exists:", bool(C.execute("select 1 from sqlite_master where name='post_reaction'").fetchone()))

    print("== 5 comments and their posts")
    orph = C.execute("select count(*) from post_comment c where c.source_id = ? and c.post_id is not null and not exists (select 1 from post p where p.id = c.post_id)", (sid,)).fetchone()[0]
    nopost = C.execute("select count(*) from post_comment where source_id = ? and post_id is null", (sid,)).fetchone()[0]
    print(f"  written comments whose post row is missing: {orph} | written comments with no post (the export names none): {nopost}")
    if orph:
        bad("comment points at a missing post")
    left = {r[ix["rid"]] for r in rows if r[ix["type"]] in ("post", "skip") and r[ix["decision"]] == "left-out"}
    written_under_left = [r[ix["rid"]] for r in rows if r[ix["type"]] == "comment" and r[ix["decision"]] == "new"
                          and next((x.get("parent") for x in recs if x["rid"] == r[ix["rid"]]), None) in left]
    print(f"  comments written under a left-out post: {len(written_under_left)}")
    if written_under_left:
        bad("comment of a left-out post written")
    fts_b = 0
    fts_c = C.execute("select count(*) from post_fts").fetchone()[0]
    withbody = C.execute("select (select count(*) from post where coalesce(body,'') != '') + (select count(*) from post_comment where coalesce(body,'') != '')").fetchone()[0]
    print(f"  post_fts rows {fts_c} = rows with a body {withbody}: {fts_c == withbody}")
    if fts_c != withbody:
        bad("full-text index out of step")
    print("RESULT:", "OK" if problems[0] == 0 else f"{problems[0]} problem(s)")


if __name__ == "__main__":
    main()
