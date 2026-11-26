#!/usr/bin/env python3 -I
"""Readers for Facebook and Instagram posts and comments.

Each reader turns one export into a *records file* (JSON lines) that `archivectl posts-import` writes into the archive's
post tables. The reader decides what a record is and when it happened; the importer decides people, overlaps and rows.

  line 1   {"export", "platform", "account", "me", "time_rule", "reader", "files": [{"path", "origin", "sha256", "bytes"}]}
  then     {"rid", "type": "post" | "comment" | "skip", ...}

  post     kind, author, author_ns, by_me, target, target_ns, target_text, ts_ms, precision, basis, body, context, link,
           place, external_id, dkey
  comment  parent (a post rid of this file, or null), reply (bool), author, author_ns, by_me, on, on_ns, ts_ms, precision,
           body, context, dkey
  skip     what, reason, parent, author, ts_ms (a record that is counted and ledgered but never written: a like line, an
           empty record, a record whose printed time is not its own, a comment whose post was left out)

author_ns / target_ns / on_ns: "fb-name" (a Facebook display name -> fb:<folded name>), "ig-user" (an Instagram username ->
the ig: handle whose high-confidence username it is, else ig:@<username>), "ig-name" (an Instagram display name -> ig:<folded>).
by_me: the record is the export owner's own (the importer stores no author handle for it).

Times (each proven on real exports): saved pages carry Unix seconds (data-utime,
feedback_params.content_timestamp); the 2011 export prints wall-clock minutes with no zone, read in --zone (required for fb2011: an
IANA name, or a fixed offset such as UTC-04:00, which matched the one export checked better than its named zone). A post whose printed
time is later than its first comment's does not carry its own time: it is skipped ("time-not-own"), and so are its comments
("parent-left-out"); nothing is written at a guessed time.

Usage (records go to stdout; nothing is ever written next to the input):
  posts_read.py saved-pages --me NAME [--account ID] [--origin PATH=LABEL]... <page.html>...
  posts_read.py fb2011 --me NAME --zone IANA|UTC±hh:mm [--account ID] [--origin LABEL] <export root holding html/>
  posts_read.py fb2025 --me NAME [--account ID] [--origin LABEL] [--zone IANA] [--export NAME] <export root holding your_facebook_activity/>
                    (an export whose header offset is not the one its times are printed in: --zone America/New_York --export fb-2026-11;
                    the importer keeps one time rule per export name)
  posts_read.py instagram [--me NAME] [--separate] [--origin LABEL] <account username> <export root holding your_instagram_activity/>

--me NAME     the export owner's display name exactly as Facebook prints it ("<NAME> shared a link."); required for Facebook
--account ID  the export's account as stored in the archive (default facebook:me)
--separate    an Instagram account that is not the owner's own (a project or shared account): its posts get its own handle,
              never by_me
"""
import collections, datetime, glob, hashlib, json, os, re, sys, unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fb_saved_pages as fsp  # noqa: E402

READER = "posts_read.py 5"
ME = ""                     # the export owner's display name (--me)
FB_ACCOUNT = "facebook:me"  # --account
ZONE_2011 = None            # --zone for the 2011 export: a tzinfo


def parse_zone(text):
    """An IANA zone name, or a fixed offset written UTC, UTC-04:00, UTC+5:30."""
    m = re.fullmatch(r"UTC(?:([+-])(\d{1,2})(?::(\d{2}))?)?", text.strip(), re.I)
    if m:
        if not m.group(1):
            return datetime.timezone.utc
        delta = datetime.timedelta(hours=int(m.group(2)), minutes=int(m.group(3) or 0))
        return datetime.timezone(-delta if m.group(1) == "-" else delta)
    import zoneinfo
    return zoneinfo.ZoneInfo(text.strip())


def zone_text(tz):
    return tz.tzname(None) if isinstance(tz, datetime.timezone) else str(tz)


def zone_label(tz):
    return f"fixed {tz.tzname(None).replace('UTC', 'UTC')}" if isinstance(tz, datetime.timezone) else f"named zone {tz} with DST"


def read_text(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def fold(s):
    return " ".join(unicodedata.normalize("NFC", s or "").casefold().split())


def an_key(s):
    """Letters and digits, case-folded, "<3" read as a heart: the three-way text rule's second key."""
    s = unicodedata.normalize("NFC", (s or "").replace("<3", "♥")).casefold()
    return "".join(ch for ch in s if ch.isalnum() or ch == "♥")


def text_hash(s):
    """The identity hash in a content key: the exact text, normalized only for line endings, so texts that differ at all get
    different keys (the matching rules elsewhere stay three-way)."""
    t = (s or "").replace("\r\n", "\n").replace("\r", "\n")
    return hashlib.sha1(t.encode("utf-8")).hexdigest()[:16]


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest(), os.path.getsize(p)


class Out:
    """Collects records; gives every dkey that repeats inside one file an ordinal (#2, #3), so two identical records stay two."""

    def __init__(self):
        self.recs, self.seen, self.by_dkey = [], {}, {}

    def add_unique(self, rec):
        """For a dkey that is the record's own id (a Facebook post or comment id): a second record with it is the same record,
        ledgered as a repeat of the first, never given an ordinal. Returns the rid that holds it."""
        k = rec["dkey"]
        if k in self.by_dkey:
            first = self.by_dkey[k]
            self.recs.append({"rid": rec["rid"], "file": rec["file"], "type": "skip", "what": rec["type"], "reason": "repeat-in-export",
                              "same_as": first, "note": "the same Facebook id is in an earlier page", "author": rec.get("author"),
                              "ts_ms": rec.get("ts_ms")})
            return first
        self.by_dkey[k] = rec["rid"]
        self.recs.append(rec)
        return rec["rid"]

    def add(self, rec):
        if rec.get("dkey"):
            n = self.seen.get(rec["dkey"], 0) + 1
            self.seen[rec["dkey"]] = n
            if n > 1:
                rec["dkey"] = f"{rec['dkey']}#{n}"
        self.recs.append(rec)
        return rec


def is_me(name):
    return fold(name) == fold(ME)


def person_fields(prefix, name):
    me = bool(name) and is_me(name)
    return {prefix: None if me else (name or None), prefix + "_ns": "fb-name", **({"by_me": me} if prefix == "author" else {})}


# ---------------- saved pages (2013-2018) ----------------

def read_saved_pages(paths, origins):
    out = Out()
    files = []
    canon = {}                                              # a post's Facebook id -> the rid that holds it
    for fi, p in enumerate(paths):
        sha, size = sha256_file(p)
        files.append({"path": p, "origin": origins.get(p, p), "sha256": sha, "bytes": size})
        page = fsp.read_page(p, os.path.getmtime(p))
        title = re.sub(r"^\(\d+\)\s*", "", page["meta"].get("title") or "").strip()
        recs = [r for r in page["records"] if r["kind"] in ("post", "comment")]
        posts = {r["id"]: r for r in recs if r["kind"] == "post"}
        first_comment = {}
        for r in recs:
            if r["kind"] == "comment" and r.get("ts_ms"):
                first_comment[r["parent"]] = min(first_comment.get(r["parent"], r["ts_ms"]), r["ts_ms"])
        bad_posts = set()
        for pid, r in posts.items():
            rid = f"p{fi}:post:{pid}"
            name = (r.get("author") or {}).get("name")
            if not r.get("ts_ms"):
                bad_posts.add(pid)
                out.add({"rid": rid, "file": fi, "type": "skip", "what": "post", "reason": "no-time", "author": name})
                continue
            if pid in first_comment and r["ts_ms"] > first_comment[pid]:
                bad_posts.add(pid)
                out.add({"rid": rid, "file": fi, "type": "skip", "what": "post", "reason": "time-not-own", "author": name,
                         "ts_ms": r["ts_ms"], "note": f"printed after its first comment ({first_comment[pid]})"})
                continue
            to = [t.get("name") for t in (r.get("to") or []) if t.get("name")]
            kind = {"group-post": "group-post", "photo-with-comments": "photo", "timeline": "wall-post"}.get(page["meta"]["kind"], "post")
            canon[pid] = (out.add_unique if pid and pid != "None" else out.add)({"rid": rid, "file": fi, "type": "post", "kind": kind, **person_fields("author", name),
                     "target": to[0] if to else None, "target_ns": "fb-name",
                     "target_text": (title or None) if page["meta"]["kind"] in ("group-post", "photo-with-comments") else None,
                     "ts_ms": r["ts_ms"], "precision": "second", "basis": "posted", "body": r.get("text") or None,
                     "context": f"saved page: {title}" if title else "saved page", "link": None, "place": None,
                     "external_id": pid if pid and pid != "None" else None,
                     "dkey": f"fbpage|post|{pid}" if pid and pid != "None" else f"fbpage|post|{fold(name)}|{r['ts_ms']}|{text_hash(r.get('text'))}"})
        for r in recs:
            if r["kind"] != "comment":
                continue
            name = (r.get("author") or {}).get("name")
            has_id = bool(r.get("id"))
            cid = r.get("id") or f"{r['parent']}|{fold(name)}|{r.get('ts_ms')}|{text_hash(r.get('text'))}"
            rid = f"p{fi}:comment:{cid}"
            parent_rid = canon.get(r["parent"], f"p{fi}:post:{r['parent']}")
            if r["parent"] in bad_posts or r["parent"] not in posts:
                out.add({"rid": rid, "file": fi, "type": "skip", "what": "comment", "reason": "parent-left-out", "parent": parent_rid,
                         "author": name, "ts_ms": r.get("ts_ms")})
                continue
            if not r.get("ts_ms"):
                out.add({"rid": rid, "file": fi, "type": "skip", "what": "comment", "reason": "no-time", "parent": parent_rid, "author": name})
                continue
            # only a Facebook id is authoritative; a synthesized fallback key never merges two records
            (out.add_unique if has_id else out.add)({"rid": rid, "file": fi, "type": "comment", "parent": parent_rid, "reply": r.get("reply_to") == "nested",
                     **person_fields("author", name), "on": None, "on_ns": "fb-name", "ts_ms": r["ts_ms"], "precision": "second",
                     "body": r.get("text") or None, "context": None, "dkey": f"fbpage|comment|{cid}"})
    head = {"export": "fb-saved-pages", "platform": "facebook", "account": FB_ACCOUNT, "me": ME,
            "time_rule": "Unix seconds printed in the page (data-utime, feedback_params.content_timestamp)", "reader": READER, "files": files}
    return head, out.recs


# ---------------- the 2011 "Download Your Information" export ----------------

def ms_2011(local_minute):
    if not local_minute:
        return None
    if ZONE_2011 is None:
        raise SystemExit("the 2011 export needs --zone (an IANA name or a fixed offset such as UTC-04:00)")
    d = datetime.datetime.fromisoformat(local_minute).replace(tzinfo=ZONE_2011)
    return int(d.timestamp() * 1000)


def _node_text(n, drop=()):
    return fsp.text_of(n, drop=drop) if n is not None else ""


def _comments_2011(node):
    """div.comments > div.comment (span.profile, text, span.time); like lines are div.comment.like."""
    out = []
    cm = next((c for c in node.children if isinstance(c, fsp.Node) and c.has("comments")), None)
    for c in (cm.find_all(lambda n: n.tag == "div" and n.has("comment")) if cm else []):
        if c.has("like"):
            out.append({"like": True, "text": _node_text(c)})
            continue
        p = c.find(lambda n: n.has("profile"))
        t = c.find(lambda n: n.has("time"))
        out.append({"like": False, "author": _node_text(p) or None, "text": fsp.text_of(c, drop=("profile", "time")),
                    "local_minute": fsp.dyi_time(_node_text(t))})
    return out


def _ckey(c):
    """A comment's identity inside the 2011 export: author, printed minute, text with whitespace removed."""
    return (fold(c.get("author")), c.get("local_minute"), re.sub(r"\s+", "", c.get("text") or "").casefold())


def _emit_2011_item(out, it):
    """One post (album photo, video, wall entry) with its comments, applying the post-before-its-comments test. `it["comments"]`
    already holds the comments of every repeat of the item (a wall story of the same photo), each once."""
    rid, cms, likes = it["rid"], [c for c in it["comments"] if not c["like"]], [c for c in it["comments"] if c["like"]]
    likes_rids = [c.get("crid") for c in likes]
    first = min((c["local_minute"] for c in cms if c["local_minute"]), default=None)
    for j, c in enumerate(likes):
        out.add({"rid": likes_rids[j] or f"{rid}:like{j}", "file": it["file"], "type": "skip", "what": "like-line", "reason": "likes-left-out",
                 "parent": rid})
    bad = None
    if not it["minute"]:
        bad = "no-time"
    elif first and it["minute"] > first:
        bad = "time-not-own"
    if bad:
        out.add({"rid": rid, "file": it["file"], "type": "skip", "what": it["kind"], "reason": bad, "author": it["author"],
                 "ts_ms": ms_2011(it["minute"]), "note": f"printed {it['minute']}, first comment {first}" if first else None})
    else:
        out.add({"rid": rid, "file": it["file"], "type": "post", "kind": it["kind"], **person_fields("author", it["author"]),
                 "target": None, "target_ns": "fb-name", "target_text": it.get("target_text"), "ts_ms": ms_2011(it["minute"]),
                 "precision": "minute", "basis": "posted" if it["kind"] == "wall-post" else "uploaded", "body": it["body"] or None,
                 "context": it["context"], "link": it.get("link"), "place": None, "external_id": it.get("external_id"), "dkey": it["dkey"]})
    for j, c in enumerate(cms):
        crid = c.get("crid") or f"{rid}:c{j}"
        if bad:
            out.add({"rid": crid, "file": c.get("file", it["file"]), "type": "skip", "what": "comment", "reason": "parent-left-out",
                     "parent": rid, "author": c["author"], "ts_ms": ms_2011(c["local_minute"])})
            continue
        if not c["local_minute"]:
            out.add({"rid": crid, "file": c.get("file", it["file"]), "type": "skip", "what": "comment", "reason": "no-time", "parent": rid,
                     "author": c["author"]})
            continue
        out.add({"rid": crid, "file": c.get("file", it["file"]), "type": "comment", "parent": rid, "reply": False,
                 **person_fields("author", c["author"]), "on": None, "on_ns": "fb-name", "ts_ms": ms_2011(c["local_minute"]),
                 "precision": "minute", "body": c["text"] or None, "context": f"printed under {c['from_rid']}" if c.get("from_rid") else None,
                 "dkey": f"{it['dkey']}|c|{fold(c['author'])}|{c['local_minute']}|{text_hash(c['text'])}"})


LOCAL_ANCHOR = re.compile(r"^(?:album-[^#]*|videos)\.html#(\d+)$")
REMOTE_ID = re.compile(r"(?:photo\.php\?fbid=|video\.php\?v=)(\d+)")


def read_fb2011(root, origin):
    """The 2011 export: album photos and videos first (each has its own Facebook id and upload time), then the wall.

    The export repeats itself: a photo or video the owner uploaded is also a wall story (linking to the photo, or with the same text
    in the same minute), and some wall stories are printed twice. A repeat is the same record: it is ledgered as left out
    ("repeat-in-export", with the record it repeats), its comments that the record already has are left out the same way, and
    the ones it lacks are added to that record, so nothing is written twice and no comment is lost."""
    out = Out()
    html_dir = os.path.join(root, "html")
    wall = os.path.join(html_dir, "wall.html")
    albums = sorted(glob.glob(os.path.join(html_dir, "album-*.html")))
    videos = os.path.join(html_dir, "videos.html")
    paths = [wall] + albums + ([videos] if os.path.exists(videos) else [])
    files = []
    for p in paths:
        sha, size = sha256_file(p)
        files.append({"path": p, "origin": f"{origin}/html/{os.path.basename(p)}" if origin else p, "sha256": sha, "bytes": size})

    items, by_id, by_text = [], {}, {}
    for ai, p in enumerate(albums, start=1):
        r, _ = fsp.parse_html(read_text(p))
        h2 = r.find(lambda n: n.tag == "h2")
        album = _node_text(h2) or os.path.basename(p)[6:-5]
        for ph in r.find_all(lambda n: n.tag == "div" and n.has("photo")):
            anchor = next((c for c in ph.children if isinstance(c, fsp.Node) and c.tag == "a" and c.attrs.get("name")), None)
            fbid = anchor.attrs["name"] if anchor else None
            t = ph.find(lambda n: n.has("time"))
            minute = fsp.dyi_time(_node_text(t))
            cap = []
            for c in ph.children:
                if isinstance(c, str):
                    cap.append(c)
                elif c.tag == "br" or c.has("comments") or c.has("profile") or c.find(lambda n: n.has("time")) is not None or c.tag == "a":
                    continue
                else:
                    cap.append(fsp.text_of(c))
            caption = re.sub(r"\s+", " ", " ".join(cap)).strip()
            caption = re.sub(r"\s*In this (?:photo|video):\s*$", "", caption).strip()
            img = ph.find(lambda n: n.tag == "img")
            items.append({"rid": f"album{ai}:{fbid}", "file": ai, "kind": "album-photo", "author": ME, "minute": minute, "body": caption,
                          "target_text": album, "external_id": fbid,
                          "dkey": f"fb2011|photo|{fbid}" if fbid else f"fb2011|photo|{album}|{minute}|{text_hash(caption)}",
                          "context": "album photo" + (f" ({img.attrs.get('src')})" if img is not None else ""), "comments": _comments_2011(ph)})
    if os.path.exists(videos):
        vi = len(paths) - 1
        r, _ = fsp.parse_html(read_text(videos))
        anchors = [a.attrs["name"] for a in r.find_all(lambda n: n.tag == "a" and n.attrs.get("name"))]
        for k, v in enumerate(r.find_all(lambda n: n.tag == "div" and n.has("video"))):
            info = v.find(lambda n: n.has("vidinfo"))
            a = info.find(lambda n: n.tag == "a") if info else None
            t = info.find(lambda n: n.has("time")) if info else None
            fbid = anchors[k] if k < len(anchors) else None
            items.append({"rid": f"video:{fbid or k}", "file": vi, "kind": "video", "author": ME, "minute": fsp.dyi_time(_node_text(t)),
                          "body": _node_text(a), "external_id": fbid, "dkey": f"fb2011|video|{fbid or k}",
                          "context": "video" + (f" ({a.attrs.get('href')})" if a is not None else ""), "comments": _comments_2011(v)})
    for it in items:
        if it["external_id"]:
            by_id[it["external_id"]] = it
        if it["body"]:
            by_text.setdefault((it["minute"], re.sub(r"\s+", "", it["body"]).casefold()), it)

    # the wall, in printed-time order (earliest first), so a story printed several times is kept at its first printing
    root_w, _ = fsp.parse_html(read_text(wall))
    entries = []
    for ei, e in enumerate(root_w.find_all(lambda n: n.tag == "div" and n.has("feedentry"))):
        prof = next((c for c in e.children if isinstance(c, fsp.Node) and c.has("profile")), None)
        tr = next((c for c in e.children if isinstance(c, fsp.Node) and c.has("timerow")), None)
        parts = []
        for c in e.children:
            if c is prof or (isinstance(c, fsp.Node) and (c.has("timerow") or c.has("comments"))):
                continue
            parts.append(c if isinstance(c, str) else fsp.text_of(c))
        body = re.sub(r"\s+", " ", " ".join(p.strip() for p in parts if p.strip())).strip()
        # the story's own links only: a link inside a comment says nothing about which post this is
        links = [a.attrs.get("href") for c in e.children if isinstance(c, fsp.Node) and not c.has("comments")
                 for a in ([c] if c.tag == "a" else []) + c.find_all(lambda n: n.tag == "a") if a.attrs.get("href")]
        ext = [l for l in links if l and l.startswith("http")]
        author = _node_text(prof) or None
        minute = fsp.dyi_time(_node_text(tr))
        target, album = None, None
        for l in links:
            m = LOCAL_ANCHOR.match(l or "") or REMOTE_ID.search(l or "")
            if m and m.group(1) in by_id:
                target = by_id[m.group(1)]
                album = (l or "").split("#")[0] if (l or "").startswith("album-") else None
                break
        if target is None and is_me(author) and body:
            target = by_text.get((minute, re.sub(r"\s+", "", body).casefold()))
        entries.append({"rid": f"wall:{ei}", "ei": ei, "file": 0, "kind": "wall-post", "author": author, "minute": minute or "", "body": body,
                        "link": ext[0] if ext else None, "album": album, "target": target, "context": "wall", "raw_comments": _comments_2011(e)})
    # a comment is the same comment only on the same post or photo: each record keeps the multiset of its
    # comments, and a repeat's comment is a repeat only when that record already holds it as many times
    owner_keys = {it["rid"]: collections.Counter(_ckey(c) for c in it["comments"] if not c["like"]) for it in items}
    def gkey(en):
        wsbody = re.sub(r"\s+", "", en["body"]).casefold()
        return (fold(en["author"]), wsbody, en["album"]) if en["album"] else (fold(en["author"]), wsbody, en["link"], en["minute"])
    # an album story: the same (non-empty) text linking to two or more photos of one album, printed with one comment thread
    # (Facebook prints the album's story at every update, each time with the album's comments); any other story that links to a
    # photo or video is that photo's or video's own story
    photos_of, printed_under = collections.defaultdict(set), collections.defaultdict(lambda: collections.Counter())
    for en in entries:
        if en["album"] and en["target"] is not None and en["body"]:
            photos_of[gkey(en)].add(en["target"]["rid"])
            for k in {_ckey(c) for c in en["raw_comments"] if not c["like"]}:
                printed_under[gkey(en)][k] += 1
    # ... and the stories share a comment thread (one comment printed under two or more of them)
    album_stories = {k for k, v in photos_of.items() if len(v) >= 2 and any(n >= 2 for n in printed_under[k].values())}
    groups, wall_items, repeat_skips = {}, [], []
    for en in sorted(entries, key=lambda x: (x["minute"], x["ei"])):
        cms = en["raw_comments"]
        gk = gkey(en)
        album_story = gk in album_stories
        if en["target"] is not None and not album_story:
            owner, why = en["target"], "the story of this photo or video (links to it, or has its text in its minute)"
        elif gk in groups:
            owner, why = groups[gk], ("a later printing of the same album story" if en["album"] else "the same wall story printed again")
        else:
            owner, why = None, None
        if owner is None:
            it = {k: en[k] for k in ("rid", "file", "kind", "author", "minute", "body", "link", "context")}
            it["target_text"] = os.path.basename(en["album"])[6:-5].replace("%20", " ") if en["album"] else None
            it["minute"] = en["minute"] or None
            it["dkey"] = f"fb2011|wall|{fold(en['author'])}|{en['minute']}|{text_hash(en['body'])}|{hashlib.sha1((en['album'] or en['link'] or '').encode()).hexdigest()[:8]}"
            it["comments"] = [dict(c, crid=f"{en['rid']}:{'like' if c['like'] else 'c'}{j}") for j, c in enumerate(cms)]
            owner_keys[it["rid"]] = collections.Counter(_ckey(c) for c in cms if not c["like"])
            groups[gk] = it
            wall_items.append(it)
            continue
        repeat_skips.append({"rid": en["rid"], "file": 0, "type": "skip", "what": "wall-post", "reason": "repeat-in-export",
                             "same_as": owner["rid"], "note": why, "author": en["author"], "ts_ms": ms_2011(en["minute"] or None)})
        have = collections.Counter(owner_keys[owner["rid"]])
        for j, c in enumerate(cms):
            crid = f"{en['rid']}:c{j}" if not c["like"] else f"{en['rid']}:like{j}"
            if c["like"]:
                repeat_skips.append({"rid": crid, "file": 0, "type": "skip", "what": "like-line", "reason": "likes-left-out", "parent": en["rid"]})
            elif have[_ckey(c)] > 0:
                have[_ckey(c)] -= 1
                repeat_skips.append({"rid": crid, "file": 0, "type": "skip", "what": "comment", "reason": "repeat-in-export",
                                     "parent": en["rid"], "same_as_parent": owner["rid"], "note": f"the same comment is already on {owner['rid']}",
                                     "author": c["author"], "ts_ms": ms_2011(c["local_minute"])})
            else:
                owner_keys[owner["rid"]][_ckey(c)] += 1
                owner["comments"].append(dict(c, crid=crid, from_rid=en["rid"], file=0))
    wall_items.sort(key=lambda it: int(it["rid"].split(":")[1]))
    # emit: albums and videos, then the wall, then the repeats (their new comments are already with the record they repeat)
    for it in items + wall_items:
        _emit_2011_item(out, it)
    for r in repeat_skips:
        out.add(r)
    head = {"export": "fb-dyi-2011", "platform": "facebook", "account": FB_ACCOUNT, "me": ME,
            "time_rule": f"printed minute, read as {zone_label(ZONE_2011)}", "zone": zone_text(ZONE_2011),
            "reader": READER, "files": files}
    return head, out.recs


# ---------------- Meta exports of 2025 (Facebook "Download Your Information" and Instagram, HTML) ----------------

META_TIME_FORMATS = ("%b %d, %Y %I:%M:%S %p", "%b %d, %Y %I:%M %p")


def meta_ms(text, offset_s):
    """Meta's wall-clock text ("Apr 18, 2010 9:31:31 am", Instagram without seconds) at the page's fixed offset (or in a named zone) -> (Unix ms, precision)."""
    t = (text or "").replace(" ", " ").replace(" ", " ").strip()
    for f, prec in zip(META_TIME_FORMATS, ("second", "minute")):
        try:
            d = datetime.datetime.strptime(t, f)
        except ValueError:
            continue
        return int(d.replace(tzinfo=_tz(offset_s)).timestamp() * 1000), prec
    return None, None


def _tz(offset_s):
    """A fixed offset in seconds, or an IANA zone name (wall clock with DST: some Facebook exports)."""
    if isinstance(offset_s, str):
        import zoneinfo
        return zoneinfo.ZoneInfo(offset_s)
    return datetime.timezone(datetime.timedelta(seconds=offset_s))


def page_offset(raw):
    """The offset the page states ("Generated by ... UTC+08:00"), or None (Instagram states none)."""
    m = re.search(r"UTC([+-])(\d{2}):(\d{2})", raw[:200000])
    return None if not m else (1 if m.group(1) == "+" else -1) * (int(m.group(2)) * 3600 + int(m.group(3)) * 60)


def meta_blocks(path):
    """(raw, top-level record blocks): div._a6-g (section._a6-g in newer exports) inside role=main, not nested in another _a6-g. Each block: header text (div._a6-h),
    the content node (div._a6-p), the footer time text (div._a6-o), and the node itself."""
    raw = read_text(path)
    root, _ = fsp.parse_html(raw)
    main = root.find(lambda n: n.attrs.get("role") == "main") or root
    out = []
    for n in main.iter():
        if n is main or not (n.tag in ("div", "section") and n.has("_a6-g")):      # a section in newer exports' markup
            continue
        if any(a.has("_a6-g") for a in n.ancestors() if isinstance(a, fsp.Node)):
            continue
        h = n.find(lambda x: x.has("_a6-h"))              # a div in most pages, an h2 in some account exports
        c = n.find(lambda x: x.tag == "div" and x.has("_a6-p"))
        o = n.find(lambda x: x.tag in ("div", "footer") and x.has("_a6-o"))       # a footer in newer exports' markup
        out.append({"node": n, "header": fsp.text_of(h, drop=()) if h is not None else "", "content": c,
                    "time": fsp.text_of(o, drop=()) if o is not None else ""})
    return raw, out


def meta_labels(node):
    """Label/value pairs printed as tables: td._a6_q + td._a6_r, td._a6_q holding its value in a child div, div._a6-q pairs."""
    out = []
    if node is None:
        return out
    for td in node.find_all(lambda n: n.tag == "td" and n.has("_a6_q")):
        sib = [c for c in td.parent.children if isinstance(c, fsp.Node) and c is not td and c.tag == "td"] if td.parent else []
        if sib and sib[0].has("_a6_r"):
            out.append((fsp.text_of(td, drop=()), fsp.text_of(sib[0], drop=())))
            continue
        label = next((c.strip() for c in td.children if isinstance(c, str) and c.strip()), None)
        divs = [c for c in td.children if isinstance(c, fsp.Node) and c.tag == "div"]
        if label is not None:
            out.append((label, fsp.text_of(divs[0], drop=()) if divs else ""))
        elif len(divs) >= 2 and divs[0].has("_a6-q"):
            out.append((fsp.text_of(divs[0], drop=()), fsp.text_of(divs[1], drop=())))
    return out


MEDIA_ID = re.compile(r"(?:^|[/_])(\d{6,})\.(?:jpg|jpeg|png|gif|heic|webp|mp4|mov)$", re.I)   # ".../x_n_<id>.jpg" or ".../<id>.jpg"


def meta_media(node):
    """Local media paths in a block (img src, video src, a href into media folders), in order, once each."""
    seen, out = set(), []
    if node is None:
        return out
    for n in node.iter():
        for attr in ("src", "href"):
            v = n.attrs.get(attr) if isinstance(n, fsp.Node) else None
            if v and not v.startswith(("http", "data:", "#")) and re.search(r"\.(jpg|jpeg|png|gif|heic|webp|mp4|mov)$", v, re.I) and v not in seen:
                seen.add(v)
                out.append(v)
    return out


def meta_links(node):
    return [n.attrs["href"] for n in (node.iter() if node is not None else []) if isinstance(n, fsp.Node) and n.tag == "a"
            and n.attrs.get("href", "").startswith("http") and "/dyi/l/" not in n.attrs["href"]]


def _lines(node, skip_classes=()):
    """The text lines of a node: one per innermost div (or the node's own text), skipping nodes with the given classes."""
    if node is None:
        return []
    out = []

    def walk(n):
        if isinstance(n, str):
            return
        if n.cls() & set(skip_classes) or n.tag in ("table", "video", "a", "img"):
            return
        kids = [c for c in n.children if isinstance(c, fsp.Node) and c.tag == "div"]
        own = "".join(c for c in n.children if isinstance(c, str)).strip()
        if own or not kids:
            t = fsp.text_of(n, drop=tuple(skip_classes))
            if t:
                out.append(t)
            return
        for c in kids:
            walk(c)
    walk(node)
    return out


def _dedupe(lines):
    out = []
    for l in lines:
        if l and l not in out:
            out.append(l)
    return out


UPDATED = re.compile(r"^Updated [A-Z][a-z]{2} \d{2}, \d{4} \d{1,2}:\d{2}(?::\d{2})? [ap]m$")


class MetaFile:
    """One page of an export: its offset, its blocks, its index in the header's files list."""

    def __init__(self, path, origin, index, offset_default, zone=None):
        self.path, self.index = path, index
        self.raw, self.blocks = meta_blocks(path)
        off = page_offset(self.raw)
        header_offset = off if off is not None else offset_default
        self.offset = zone or header_offset                 # a named zone (with DST) replaces the header's fixed offset
        sha, size = sha256_file(path)
        self.entry = {"path": path, "origin": origin, "sha256": sha, "bytes": size, "offset_s": header_offset}
        if zone:
            self.entry["zone"] = zone


def _fb_post_kind(header):
    h = header[len(ME) + 1:] if header.startswith(ME + " ") else header
    if not header:
        return "status"
    for pat, kind in ((r"^shared a link", "link"), (r"^(added|uploaded) (a )?new (photo|video)s?", "photo"), (r"^shared an? (photo|video)", "photo"),
                      (r"^shared an album", "album-share"), (r"^shared a post", "share"), (r"^Shared from Instagram", "instagram-share"),
                      (r"^posted something via", "app-post"), (r"^(was|is) (with|at|in) ", "check-in"), (r"^shared a link to", "link"),
                      (r"^updated (his|her|their) status", "status"), (r"^(wrote|posted) on", "wall-post"), (r"^shared", "share")):
        if re.search(pat, h):
            return kind
    return "life-event" if not header.startswith(ME) else "post"


def pair_fb2025(recs, files):
    """The 2025 export prints some posts in two files: a post on someone else's timeline is also in "your posts", a group post too,
    and a photo or video posted in a group is also an uncategorized photo or video. Pairs are matched one to one (two birthday
    posts in the same second to two people are two posts in each file): same second and same text (whitespace removed) for a post
    in two lists; the same caption within a minute for a group post and its photo. The copy that says less is ledgered as a
    repeat of the other ("repeat-in-export", same_as), and the kept record takes its media, link or Facebook id when it lacks one.
    Identical records inside one file stay as printed (the near-match note says so)."""
    def src(r):
        return os.path.basename(files[r["file"]]["path"])
    def media_ids(r):
        """A record's media identity: its Facebook id and the ids and paths of its media files."""
        out = set()
        if r.get("external_id"):
            out.add("id:" + str(r["external_id"]))
        for m in r.get("media") or []:
            mm = MEDIA_ID.search(m)
            out.add("id:" + mm.group(1) if mm else "path:" + m)
        return out
    def conflict(a, b):
        """Two records whose media are both known and share nothing are two records, whatever their text."""
        x, y = media_ids(a), media_ids(b)
        return bool(x) and bool(y) and not (x & y)
    def wkey(r):
        return re.sub(r"\s+", "", r.get("body") or "").casefold()
    def absorb(keep, gone, why):
        for k in ("external_id", "link", "place"):
            if not keep.get(k) and gone.get(k):
                keep[k] = gone[k]
        keep["media"] = (keep.get("media") or []) + [m for m in (gone.get("media") or []) if m not in (keep.get("media") or [])]
        for x in recs:                                      # a repeat of the record that goes now repeats the one kept
            if x.get("same_as") == gone["rid"]:
                x["same_as"] = keep["rid"]
        i = recs.index(gone)
        recs[i] = {"rid": gone["rid"], "file": gone["file"], "type": "skip", "what": gone.get("kind", "post"), "reason": "repeat-in-export",
                   "same_as": keep["rid"], "note": why, "ts_ms": gone.get("ts_ms")}
    posts = [r for r in recs if r["type"] == "post" and r.get("by_me")]
    def pair(lefts, rights, window_ms, key, keep_left, why):
        """Greedy one-to-one pairing, nearest in time first, same key, within the window."""
        cands = sorted(((abs(l["ts_ms"] - r["ts_ms"]), li, ri) for li, l in enumerate(lefts) for ri, r in enumerate(rights)
                        if key(l, r) and abs(l["ts_ms"] - r["ts_ms"]) <= window_ms), key=lambda x: x[0])
        used_l, used_r = set(), set()
        for _, li, ri in cands:
            if li in used_l or ri in used_r:
                continue
            used_l.add(li); used_r.add(ri)
            l, r = lefts[li], rights[ri]
            if keep_left:
                absorb(l, r, why)
            else:
                absorb(r, l, why)
    def same_text(l, r):
        return bool(wkey(l)) and wkey(l) == wkey(r) and not conflict(l, r) and not destination_conflict(l, r)
    def same_media(l, r):
        return bool(media_ids(l) & media_ids(r)) and media_compatible(l, r)
    yours = [r for r in posts if src(r).startswith("your_posts")]
    others = [r for r in posts if src(r).startswith("posts_on_other_pages")]
    groups = [r for r in posts if src(r).startswith("group_posts")]
    media = [r for r in recs if r["type"] == "post" and src(r) in ("your_uncategorized_photos.html", "your_videos.html")]
    # the same media file or Facebook id is the same record first, captions or not
    pair(groups, yours, 10 ** 13, same_media, True, "the same photo or video in the group's list (same media)")
    pair([g for g in groups if g in recs], media, 10 ** 13, same_media, True, "the photo or video of this group post (same media)")
    yours = [r for r in yours if r in recs]
    media = [r for r in media if r in recs]
    # a post on someone else's timeline: the "your posts" copy names the timeline (its header); the other copy names none
    pair(yours, others, 2000, same_text, True, "the same post in your posts (same text within 2 s)")
    yours = [r for r in yours if r in recs]
    # a group post: the group copy names the group
    pair([g for g in groups if g in recs], yours, 2000, same_text, True, "the same post in the group's list (same text within 2 s)")
    # a photo or video posted in a group, its media not printed with the post: the same caption within a minute, never two
    # records whose media are both known and differ
    pair([g for g in groups if g in recs], media, 60000, same_text, True, "the photo or video of this group post (same caption within a minute)")
    dedupe_media(recs, absorb, src)


MEDIA_PRIORITY = ("group_posts", "your_posts", "posts_on_other_pages", "album", "your_uncategorized_photos", "your_videos", "photos_and_videos_you")


def destinations(r):
    """Where a record was published, as far as the export says: its group, album or page (target_text), the person whose timeline
    it is on (target), or the destination its header names ("posted in X.", "... to X's timeline.")."""
    out = set()
    for k in ("target_text", "target"):
        if r.get(k) and "not named in the export" not in r[k]:      # "someone else's timeline (not named ...)" names no place
            out.add(fold(r[k]))
    m = re.search(r" (?:posted in|in) (.+?)\.?$", r.get("context") or "") or re.search(r" to (.+?)(?:'s|’s|') timeline", r.get("context") or "")
    if m:
        out.add(fold(m.group(1)))
    return out


def destination_conflict(a, b):
    """Two records published to different named places are two records."""
    x, y = destinations(a), destinations(b)
    return bool(x) and bool(y) and not (x & y)


def media_compatible(keep, gone):
    """Sharing a photo makes two records one only when the one that goes adds no text of its own (one photo of a group album keeps
    its own caption) and they are printed within two hours of each other, or carry the same text (a re-share years later embeds
    the old post's photo; a photo is uploaded some minutes before the group post that shows it)."""
    if destination_conflict(keep, gone):
        return False
    g = re.sub(r"\s+", "", gone.get("body") or "").casefold()
    k = re.sub(r"\s+", "", keep.get("body") or "").casefold()
    if g and g not in k:
        return False
    return abs(keep["ts_ms"] - gone["ts_ms"]) <= 7200000 or (g and g == k)


def dedupe_media(recs, absorb, src):
    """Last pass: any two post records that share a media file or Facebook id are one record, whatever their
    kind or caption; the one kept is the one that says most about where it was posted (a group post, then your posts, ...)."""
    def keys(r):
        out = set()
        if r.get("external_id"):
            out.add("id:" + str(r["external_id"]))
        for m in r.get("media") or []:
            mm = MEDIA_ID.search(m)
            out.add("id:" + mm.group(1) if mm else "path:" + m)
        return out
    def rank(r):
        s = src(r)
        return next((i for i, p in enumerate(MEDIA_PRIORITY) if s.startswith(p) or (p == "album" and s[:1].isdigit())), len(MEDIA_PRIORITY))
    while True:
        holders = collections.defaultdict(list)            # every earlier record holding each media key
        merged = False
        pos = {id(r): i for i, r in enumerate(recs)}
        for r in sorted((r for r in recs if r["type"] == "post"), key=lambda r: (rank(r), r["file"], pos[id(r)])):
            for k in keys(r):
                for h in holders[k]:
                    if h is r or id(h) not in pos:
                        continue
                    if media_compatible(h, r):
                        absorb(h, r, "the same photo or video as this record (same media file or Facebook id)")
                    elif media_compatible(r, h):           # the later one carries more text: it is kept
                        absorb(r, h, "the same photo or video as this record (same media file or Facebook id)")
                    else:
                        continue
                    merged = True
                    break
                if merged:
                    break
            if merged:
                break
            for k in keys(r):
                holders[k].append(r)
        if not merged:
            return
    for r in recs:
        r.pop("_photo", None)


def read_fb2025(root, origin, zone=None, export="fb-2025"):
    """The Facebook export of 2025 (HTML; times at the page header's offset, seconds; proven against the 2011 export, step 0 note).

    Posts: your posts (statuses, links, photos, app posts, life events, check-ins), posts on other people's timelines (the export
    does not name whose), album photos, uncategorized photos and videos, group posts, photos the owner is tagged in (the export's time
    is when he was tagged: basis "tagged"). Comments: his comments (comments.html, on "X's post"), his comments in groups. A photo
    or video that is also one of his posts is one record (by its Facebook id). Left out and counted: likes and reactions, edit
    histories, group admin lines, places tagged, birthday and memories media, events, records with nothing in them."""
    out = Out()
    pending = []                                            # every record, emitted after the in-export pairing below
    act = os.path.join(root, "your_facebook_activity")
    files = []

    def mf(rel):
        p = os.path.join(act, rel)
        if not os.path.exists(p):
            return None
        f = MetaFile(p, f"{origin}/your_facebook_activity/{rel}" if origin else p, len(files), 8 * 3600, zone)
        files.append(f.entry)
        return f

    def ts(f, b):
        return meta_ms(b["time"], f.offset)

    seen_media = {}                                         # Facebook id -> rid of the post that has it

    def ids_of(b):
        return [m.group(1) for m in (MEDIA_ID.search(x) for x in meta_media(b["content"])) if m]

    def skip(f, i, what, reason, **kw):
        pending.append({"rid": f"f{f.index}:{i}", "file": f.index, "type": "skip", "what": what, "reason": reason, **kw})

    # 1. your posts
    f = mf("posts/your_posts__check_ins__photos_and_videos_1.html")
    for i, b in enumerate(f.blocks if f else []):
        c = b["content"]
        tags = " ".join(fsp.text_of(n, drop=()) for n in (c.find_all(lambda n: n.has("_a701")) if c is not None else []))
        pins = [n for n in (c.find_all(lambda n: n.tag == "div" and n.has("_2pin")) if c is not None else [])
                if not any(a.has("_2pin") for a in n.ancestors() if isinstance(a, fsp.Node))]
        text_lines, place, desc, album = [], None, [], None
        for pin in pins:
            is_att = pin.find(lambda n: n.has("_a7nf") or n.tag in ("img", "video")) is not None or "Place:" in fsp.text_of(pin, drop=())
            if is_att:
                for n in pin.find_all(lambda n: n.has("_3-95")):
                    desc.append(fsp.text_of(n, drop=()))
                g = pin.find(lambda n: n.has("_a7ng"))
                if g is not None:
                    names = [fsp.text_of(d, drop=()) for d in g.find_all(lambda n: n.tag == "div" and not n.cls() and not n.find(lambda x: x.tag in ("a", "img")))]
                    album = next((x for x in names if x and x not in desc), None)
                for l in _lines(pin):
                    if l.startswith("Place:"):
                        place = l[6:].strip()
                    elif l.startswith("Address:") and place:
                        place += "; " + l
            else:
                text_lines += [l for l in _lines(pin) if not UPDATED.match(l)]
        links = meta_links(c)
        text_lines = _dedupe([l for l in text_lines if l not in links and l != "Click for video:"])
        body = mention_text("\n".join(text_lines) or "\n".join(_dedupe(desc))) or None
        if album == "Click for video:":
            album = None
        tm = re.search(r" (?:to|on) (.+?)(?:'s|’s|') timeline\.?$", b["header"])
        t, prec = ts(f, b)
        ids = ids_of(b)
        if not t:
            skip(f, i, "post", "no-time")
            continue
        if not b["header"] and not body and not ids and not links:
            skip(f, i, "post", "empty-record", ts_ms=t)
            continue
        rid = f"f{f.index}:{i}"
        for x in ids:
            seen_media.setdefault(x, rid)
        pending.append({"rid": rid, "file": f.index, "type": "post", "kind": _fb_post_kind(b["header"]), "author": None, "author_ns": "fb-name",
                 "by_me": True, "target": tm.group(1) if tm else None, "target_ns": "fb-name", "target_text": album, "ts_ms": t, "precision": prec, "basis": "posted",
                 "body": body, "context": " | ".join(x for x in (b["header"], tags) if x) or None, "link": links[0] if links else None,
                 "place": place, "external_id": ids[0] if ids else None, "media": meta_media(c),
                 "dkey": f"fb2025|post|{t}|{text_hash(body)}|{ids[0] if ids else ''}"})

    # 2. posts on other people's timelines (whose is not in the export)
    f = mf("posts/posts_on_other_pages_and_profiles.html")
    for i, b in enumerate(f.blocks if f else []):
        lab = dict(meta_labels(b["content"]))
        t, prec = ts(f, b)
        body = mention_text(lab.get("Message")) or None
        if not t or (not body and not meta_media(b["content"]) and not meta_links(b["content"])):
            skip(f, i, "post", "empty-record" if t else "no-time", ts_ms=t)
            continue
        pending.append({"rid": f"f{f.index}:{i}", "file": f.index, "type": "post", "kind": "wall-post", "author": None, "author_ns": "fb-name",
                 "by_me": True, "target": None, "target_ns": "fb-name", "target_text": "someone else's timeline (not named in the export)",
                 "ts_ms": t, "precision": prec, "basis": "posted", "body": body, "context": b["header"] or None, "link": None, "place": None,
                 "external_id": None, "media": meta_media(b["content"]), "dkey": f"fb2025|other|{t}|{text_hash(body)}"})

    # 3. album photos, uncategorized photos, videos (one record per Facebook id; a photo that is a post is that post)
    album_files = sorted(glob.glob(os.path.join(act, "posts", "album", "*.html")), key=lambda p: int(re.sub(r"\D", "", os.path.basename(p)) or 0))
    for rel, kind in [(os.path.relpath(p, act), "album-photo") for p in album_files] + [("posts/your_uncategorized_photos.html", "photo"), ("posts/your_videos.html", "video")]:
        f = mf(rel)
        if f is None:
            continue
        title = re.search(r"<title>([^<]*)</title>", f.raw)
        album = html_unescape(title.group(1)).strip() if title and kind == "album-photo" else None
        for i, b in enumerate(f.blocks):
            c = b["content"]
            ids = ids_of(b)
            t, prec = ts(f, b)
            cap = _dedupe([fsp.text_of(n, drop=()) for n in (c.find_all(lambda n: n.has("_3-95")) if c is not None else [])])
            body = mention_text("\n".join(x for x in cap if x)) or None
            if not ids:
                skip(f, i, kind, "no-media-id", ts_ms=t)
                continue
            if ids[0] in seen_media:
                skip(f, i, kind, "repeat-in-export", same_as=seen_media[ids[0]], note="the same photo or video (Facebook id) as a post", ts_ms=t)
                continue
            if not t:
                skip(f, i, kind, "no-time")
                continue
            rid = f"f{f.index}:{i}"
            seen_media[ids[0]] = rid
            pending.append({"rid": rid, "file": f.index, "type": "post", "kind": kind, "author": None, "author_ns": "fb-name", "by_me": True,
                     "target": None, "target_ns": "fb-name", "target_text": album, "ts_ms": t, "precision": prec, "basis": "uploaded",
                     "body": body, "context": b["header"] or None, "link": None, "place": None, "external_id": ids[0], "media": meta_media(c),
                     "dkey": f"fb2025|media|{ids[0]}"})

    # 4. group posts (admin lines are left out)
    f = mf("groups/group_posts_and_comments.html")
    for i, b in enumerate(f.blocks if f else []):
        h = b["header"]
        t, prec = ts(f, b)
        m = re.match(r"^" + re.escape(ME) + r" posted in (.+?)\.?$", h)
        if h and not m and not h.startswith(ME + " contributed"):
            skip(f, i, "group-post", "group-admin-activity", ts_ms=t)
            continue
        links = meta_links(b["content"])
        gtags = " ".join(fsp.text_of(n, drop=()) for n in (b["content"].find_all(lambda n: n.has("_a701")) if b["content"] is not None else []))
        lines = _dedupe([l for l in _lines(b["content"], skip_classes=("_a701",)) if not UPDATED.match(l) and l not in links])
        body = mention_text("\n".join(lines)) or None
        if not t or (not body and not links and not meta_media(b["content"])):
            skip(f, i, "group-post", "empty-record" if t else "no-time", ts_ms=t)
            continue
        pending.append({"rid": f"f{f.index}:{i}", "file": f.index, "type": "post", "kind": "group-post", "author": None, "author_ns": "fb-name",
                 "by_me": True, "target": None, "target_ns": "fb-name", "target_text": m.group(1) if m else None, "ts_ms": t, "precision": prec,
                 "basis": "posted", "body": body, "context": " | ".join(x for x in (h, gtags) if x) or None, "link": links[0] if links else None,
                 "place": None, "external_id": ids_of(b)[0] if ids_of(b) else None, "media": meta_media(b["content"]), "dkey": f"fb2025|group-post|{t}|{text_hash(body)}"})

    # 5. tagged photos: someone's photo; the time is when the owner was tagged
    f = mf("activity_you're_tagged_in/photos_and_videos_you're_tagged_in.html")
    for i, b in enumerate(f.blocks if f else []):
        lab = dict(meta_labels(b["content"]))
        t, prec = ts(f, b)
        url = next((l for l in meta_links(b["content"]) if "facebook.com/" in l), None) or lab.get("URL")
        fbid = (re.search(r"fbid=(\d+)", url or "") or re.search(r"v=(\d+)", url or ""))
        if not t or not url:
            skip(f, i, "tagged-photo", "no-time" if not t else "empty-record", ts_ms=t)
            continue
        if fbid and fbid.group(1) in seen_media:
            skip(f, i, "tagged-photo", "repeat-in-export", same_as=seen_media[fbid.group(1)], note="his own photo, already a post", ts_ms=t)
            continue
        name = lab.get("Name")
        pending.append({"rid": f"f{f.index}:{i}", "file": f.index, "type": "post", "kind": "tagged-photo", **person_fields("author", name),
                 "target": None, "target_ns": "fb-name", "target_text": None, "ts_ms": t, "precision": prec, "basis": "tagged", "body": None,
                 "context": "tagged in this photo or video", "link": url, "place": None, "external_id": fbid.group(1) if fbid else None,
                 "dkey": f"fb2025|tagged|{fbid.group(1) if fbid else url}"})

    # 6. comments (his): comments.html and comments in groups; "X's post" names whose post, never which
    for rel, ctx in (("comments_and_reactions/comments.html", None), ("groups/your_comments_in_groups.html", "group")):
        f = mf(rel)
        for i, b in enumerate(f.blocks if f else []):
            h = b["header"]
            t, prec = ts(f, b)
            m = re.match(r"^" + re.escape(ME) + r" (?:commented on|replied to) (.+?)(?:'s|’s|') (?:own )?(post|photo|link|album|comment|video|event|note|status|life event|reel|story|live video|cover photo|profile picture)\.?$", h)
            own = re.match(r"^" + re.escape(ME) + r" (?:commented on|replied to) (?:his|her|their) own ", h)
            c = b["content"]
            group = None
            if c is not None:
                g = c.find(lambda n: n.has("_3-95") and "Group:" in fsp.text_of(n, drop=()))
                if g is not None:
                    group = fsp.text_of(g, drop=()).replace("Group:", "", 1).strip()
            lines = [l for l in _lines(c, skip_classes=("_3-95",)) if l]
            body = mention_text("\n".join(_dedupe(lines))) or None
            if not t:
                skip(f, i, "comment", "no-time")
                continue
            if not h.startswith(ME + " commented") and not h.startswith(ME + " replied") and h:
                skip(f, i, "comment", "not-a-comment", ts_ms=t, note=h.split(" ", 3)[2] if h.count(" ") >= 2 else None)
                continue
            if not body and not meta_media(c):
                skip(f, i, "comment", "empty-record", ts_ms=t)
                continue
            on = None if own else (m.group(1) if m else None)
            pending.append({"rid": f"f{f.index}:{i}", "file": f.index, "type": "comment", "parent": None, "reply": " replied to " in h,
                     "author": None, "author_ns": "fb-name", "by_me": True, "on": on, "on_ns": "fb-name", "on_me": bool(own), "ts_ms": t, "precision": prec,
                     "body": body, "context": " | ".join(x for x in (h, f"group: {group}" if group else None) if x) or None,
                     "dkey": f"fb2025|comment|{ctx or ''}|{t}|{text_hash(body)}|{fold(on) if on else ('me' if own else '')}"})

    # 7. left out and counted
    def count_only(rel, what, reason):
        f = mf(rel)
        for i, b in enumerate(f.blocks if f else []):
            t, _ = ts(f, b)
            skip(f, i, what, reason, ts_ms=t)
    for rel in sorted(glob.glob(os.path.join(act, "comments_and_reactions", "likes_and_reactions*.html"))):
        count_only(os.path.relpath(rel, act), "like", "likes-left-out")
    count_only("posts/edits_you_made_to_posts.html", "post-edit", "edit-history-left-out")
    count_only("comments_and_reactions/your_comment_edits.html", "comment-edit", "edit-history-left-out")
    count_only("posts/places_you_have_been_tagged_in.html", "place-tag", "place-tags-left-out")
    count_only("posts/birthday_media.html", "birthday-media", "memories-media-left-out")
    count_only("posts/media_used_for_memories.html", "memories-media", "memories-media-left-out")
    count_only("posts/shared_memories.html", "memories-media", "memories-media-left-out")
    f = mf("posts/check-ins.html")
    for i, b in enumerate(f.blocks if f else []):
        lab = dict(meta_labels(b["content"]))
        t, prec = ts(f, b)
        if not t:
            skip(f, i, "check-in", "no-time")
            continue
        pending.append({"rid": f"f{f.index}:{i}", "file": f.index, "type": "post", "kind": "check-in", "author": None, "author_ns": "fb-name",
                 "by_me": True, "target": None, "target_ns": "fb-name", "target_text": None, "ts_ms": t, "precision": prec, "basis": "posted",
                 "body": lab.get("Message"), "context": b["header"] or None, "link": None,
                 "place": "; ".join(v for k, v in lab.items() if k in ("Place tags", "Coordinates") and v) or None, "external_id": None,
                 "dkey": f"fb2025|check-in|{t}|{text_hash(lab.get('Message'))}"})
    pair_fb2025(pending, files)
    for r in pending:
        out.add(r)
    head = {"export": export, "platform": "facebook", "account": FB_ACCOUNT, "me": ME,
            "time_rule": (f"named zone {zone} with DST, seconds (--zone replaces the page header's fixed offset)" if zone else
                          "the page header's offset, seconds"),
            "reader": READER, "files": files}
    return head, out.recs


MENTION = re.compile(r"@\[\d+:\d+:([^\]]+)\]")


def mention_text(s):
    """Meta writes a mention as @[<id>:<n>:<Name>]; the post shows the name."""
    return MENTION.sub(lambda m: m.group(1), s) if s else s


def html_unescape(s):
    import html as _h
    return _h.unescape(s)


def read_instagram(root, origin, account, owner, separate=False):
    """An Instagram export (HTML; times printed to the minute with no zone: fixed UTC-08:00, calibrated on the DMs and re-proven on
    the two posts the Facebook export also has). Posts, stories, reels, profile photos (all as posts);
    his comments (post_comments_1.html, reels_comments.html: the media owner's username, never which post). `owner` is the account's
    own username: its posts are by_me, unless `separate` (a project or shared account): then they get its own handle (ig:@<owner>).
    Left out and counted: likes, saved posts, story sticker answers and likes."""
    out = Out()
    files = []
    me_account = not separate
    act = os.path.join(root, "your_instagram_activity")

    def mf(rel):
        p = os.path.join(act, rel)
        if not os.path.exists(p):
            return None
        f = MetaFile(p, f"{origin}/your_instagram_activity/{rel}" if origin else p, len(files), -8 * 3600)
        files.append(f.entry)
        return f

    def skip(f, i, what, reason, **kw):
        out.add({"rid": f"f{f.index}:{i}", "file": f.index, "type": "skip", "what": what, "reason": reason, **kw})

    author = {"author": None, "by_me": True} if me_account else {"author": owner, "by_me": False}
    for rels, kind in ((("content/posts_1.html", "media/posts_1.html"), "post"), (("content/stories.html", "media/stories.html"), "story"),
                       (("content/reels.html", "media/reels.html"), "reel"), (("content/profile_photos.html", "media/profile_photos.html"), "profile-photo"),
                       (("content/archived_posts.html",), "archived-post")):
        f = next((x for x in (mf(r) for r in rels) if x is not None), None)
        for i, b in enumerate(f.blocks if f else []):
            t, prec = meta_ms(b["time"], f.offset)
            media = meta_media(b["content"])
            ids = [m.group(1) for m in (MEDIA_ID.search(x) for x in media) if m]
            body = b["header"].strip() or None
            lab = dict(meta_labels(b["content"]))
            place = None
            if lab.get("Latitude") and lab.get("Longitude"):
                place = f"{lab['Latitude']}, {lab['Longitude']}"
            if not t:
                skip(f, i, kind, "no-time")
                continue
            if not media and not body:
                skip(f, i, kind, "empty-record", ts_ms=t)
                continue
            tagged = lab.get("Tagged users")
            out.add({"rid": f"f{f.index}:{i}", "file": f.index, "type": "post", "kind": kind, **author, "author_ns": "ig-user",
                     "target": None, "target_ns": "ig-user", "target_text": None, "ts_ms": t, "precision": prec, "basis": "posted",
                     "body": body, "context": f"tagged: {tagged}" if tagged else None, "link": None, "place": place,
                     "external_id": ids[0] if ids else None, "media": media,
                     "dkey": f"ig|{account}|{kind}|{t}|{ids[0] if ids else text_hash(body)}"})
    for rel in ("comments/post_comments_1.html", "comments/reels_comments.html"):
        f = mf(rel)
        for i, b in enumerate(f.blocks if f else []):
            lab = dict(meta_labels(b["content"] if b["content"] is not None else b["node"]))
            t, prec = meta_ms(lab.get("Time") or b["time"], f.offset)
            body = lab.get("Comment") or None
            owner_name = lab.get("Media Owner") or None
            if not t:
                skip(f, i, "comment", "no-time")
                continue
            if not body:
                skip(f, i, "comment", "empty-record", ts_ms=t)
                continue
            on_me = owner_name and owner_name.lower() == owner.lower()
            out.add({"rid": f"f{f.index}:{i}", "file": f.index, "type": "comment", "parent": None, "reply": False, **author,
                     "author_ns": "ig-user", "on": None if (on_me and me_account) else owner_name, "on_ns": "ig-user",
                     "on_me": bool(on_me and me_account), "ts_ms": t,
                     "precision": prec, "body": body, "context": ("on his own post" if on_me else None) if me_account else None,
                     "dkey": f"ig|{account}|comment|{t}|{text_hash(body)}|{(owner_name or '').lower()}"})
    for rel, what, reason in (("likes/liked_posts.html", "like", "likes-left-out"), ("likes/liked_comments.html", "like", "likes-left-out"),
                              ("saved/saved_posts.html", "saved-post", "saved-posts-left-out")):
        f = mf(rel)
        for i, b in enumerate(f.blocks if f else []):
            t, _ = meta_ms(b["time"] or next((v for k, v in meta_labels(b["content"]) if meta_ms(v, f.offset)[0]), ""), f.offset)
            skip(f, i, what, reason, ts_ms=t)
    for p in sorted(glob.glob(os.path.join(act, "story_sticker_interactions", "*.html"))):
        f = mf(os.path.relpath(p, act))
        for i, b in enumerate(f.blocks):
            skip(f, i, "story-sticker", "story-sticker-left-out")
    head = {"export": f"ig-{owner}", "platform": "instagram", "account": account, "me": ME,
            "time_rule": "printed minute, fixed UTC-08:00 (Instagram prints no zone; checked against Facebook copies of the same posts)",
            "reader": READER, "files": files}
    return head, out.recs


def annotate_near_matches(recs):
    """Records written as two that look alike (same author, same printed minute, same text with whitespace removed) get a
    `near_match` note naming the others and why both are kept, so the ledger carries it (manager, gate 1: ledgered as near-matches)."""
    groups = collections.defaultdict(list)
    for r in recs:
        if r["type"] not in ("post", "comment") or not r.get("ts_ms"):
            continue
        body = re.sub(r"\s+", "", r.get("body") or "").casefold()
        if not body:
            continue
        groups[(r["type"], r.get("by_me"), fold(r.get("author")), r["ts_ms"] // 60000, body)].append(r)
    for g in groups.values():
        if len(g) < 2:
            continue
        for r in g:
            others = [x["rid"] for x in g if x is not r]
            if r["type"] == "post":
                why = "a different photo or link" if len({(x.get("external_id"), x.get("link")) for x in g}) == len(g) else "printed as separate posts by the export"
            else:
                parents = {x.get("parent") for x in g}
                if parents == {None}:
                    why = "printed twice by the export; it names no post" if len({x.get("on") for x in g}) == 1 else "on different people's posts"
                else:
                    why = "printed twice under the same post by the export" if len(parents) == 1 else "on different posts"
            r["near_match"] = f"near-match of {';'.join(others)}: kept as printed ({why})"
    return recs


def dump(head, recs, stream=sys.stdout):
    stream.write(json.dumps(head, ensure_ascii=False, sort_keys=True) + "\n")
    for r in recs:
        stream.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    cmd, rest = argv[1], argv[2:]
    global ME, FB_ACCOUNT, ZONE_2011
    origins, args, zone, export, separate = {}, [], None, "fb-2025", False
    i = 0
    while i < len(rest):
        if rest[i] == "--me":
            ME = rest[i + 1].strip()
            i += 2
        elif rest[i] == "--account":
            FB_ACCOUNT = rest[i + 1]
            i += 2
        elif rest[i] == "--separate":
            separate = True
            i += 1
        elif rest[i] == "--export":                        # the importer keeps one time rule per export name: a different rule needs its own name
            export = rest[i + 1]
            i += 2
        elif rest[i] == "--zone":
            zone = rest[i + 1]
            parse_zone(zone)
            i += 2
        elif rest[i] == "--origin":
            origins[rest[i + 1].split("=", 1)[0] if "=" in rest[i + 1] else ""] = rest[i + 1].split("=", 1)[-1]
            i += 2
        else:
            args.append(rest[i])
            i += 1
    if cmd in ("saved-pages", "fb2011", "fb2025") and not ME:
        print("--me NAME is required for Facebook exports (the owner's name as Facebook prints it)", file=sys.stderr)
        return 2
    if cmd == "saved-pages":
        head, recs = read_saved_pages(args, origins)
    elif cmd == "fb2011" and len(args) == 1:
        if not zone:
            print("fb2011 needs --zone (an IANA name, or a fixed offset such as UTC-04:00)", file=sys.stderr)
            return 2
        ZONE_2011 = parse_zone(zone)
        head, recs = read_fb2011(args[0], origins.get(""))
    elif cmd == "fb2025" and len(args) == 1:
        head, recs = read_fb2025(args[0], origins.get(""), zone, export)
    elif cmd == "instagram" and len(args) == 2:
        head, recs = read_instagram(args[1], origins.get(""), f"instagram:{args[0]}", args[0], separate)
    else:
        print(__doc__)
        return 2
    dump(head, annotate_near_matches(recs))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
