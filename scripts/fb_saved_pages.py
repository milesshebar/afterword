#!/usr/bin/env python3 -I
"""Reader for Facebook web pages saved from a browser, and for the 2011 "Download Your Information" HTML.

Formats met in real backups:
  * 2013-2014 desktop pages saved with "Save Page As" (an .html plus a `<name>_files` folder):
    - a Messages thread (facebook.com/messages/<user>): li.webMessengerMessageGroup per sender run, div._53 id="mid.<ms>:<hex>"
      per block, div._38 per message (a block can hold several messages sent in a row; only the block carries a time);
    - a group post or a photo page with its comments: form.commentable_item carries `feedback_params` JSON (actor,
      target_fbid, content_timestamp); comments are li.UFIComment with a.UFICommentActorName and abbr[data-utime].
  * 2016-2018 desktop pages (timeline posts: div.userContentWrapper, abbr[data-utime], div.userContent; much of the
    page sits inside <code><!-- ... --></code> blocks that the browser had not rendered yet, so those are unwrapped).
  * the 2011 export: html/messages.html (div.thread > div.message[.reply] > span.profile, span.time, div.msgbody) and
    html/wall.html (div.feedentry, div.comment), times as minute-level wall-clock text with no zone.

Times: `data-utime` is absolute Unix seconds (precision "exact-s"); a message's `mid.<ms>` id is absolute Unix ms
("exact-ms"). A message that shares a block with an earlier one has only the block's time: "block" precision,
ts_ms = the block's start, block_end_ms = the next block's start (or the page's save time). The 2011 export's text
times are "minute-local" and need a zone. Nothing here is ever written next to the input.

Usage:
  fb_saved_pages.py summary <page.html>...                 counts per page, no text (safe to paste)
  fb_saved_pages.py extract <page.html> [--mtime S] > x.jsonl   one record per message/post/comment, with text
"""
import datetime, html, json, re, sys, unicodedata
from html.parser import HTMLParser

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr", "keygen"}
SKIP_TEXT = {"script", "style", "noscript", "template"}


class Node:
    __slots__ = ("tag", "attrs", "children", "parent")

    def __init__(self, tag, attrs=None, parent=None):
        self.tag, self.attrs, self.children, self.parent = tag, attrs or {}, [], parent

    def cls(self):
        return set(self.attrs.get("class", "").split())

    def has(self, c):
        return c in self.cls()

    def iter(self):
        stack = [self]
        while stack:
            n = stack.pop()
            yield n
            stack.extend(reversed([c for c in n.children if isinstance(c, Node)]))

    def find_all(self, pred):
        return [n for n in self.iter() if pred(n)]

    def find(self, pred):
        for n in self.iter():
            if pred(n):
                return n
        return None

    def ancestors(self):
        p = self.parent
        while p is not None:
            yield p
            p = p.parent


class _Builder(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("#root")
        self.cur = self.root
        self.comments = []

    def handle_starttag(self, tag, attrs):
        n = Node(tag, {k: (v if v is not None else "") for k, v in attrs}, self.cur)
        self.cur.children.append(n)
        if tag not in VOID:
            self.cur = n

    def handle_startendtag(self, tag, attrs):
        self.cur.children.append(Node(tag, {k: (v if v is not None else "") for k, v in attrs}, self.cur))

    def handle_endtag(self, tag):
        n = self.cur
        while n is not None and n.tag != tag:
            n = n.parent
        if n is not None and n.parent is not None:  # close to the nearest matching open tag; stray end tags are ignored
            self.cur = n.parent

    def handle_data(self, data):
        self.cur.children.append(data)

    def handle_comment(self, data):
        self.comments.append(data)


CODE_BLOCK = re.compile(r"<code[^>]*>\s*<!--(.*?)-->\s*</code>", re.S)


def parse_html(text):
    """DOM of a saved page; <code><!-- deferred markup --></code> blocks are unwrapped first."""
    b = _Builder()
    b.feed(CODE_BLOCK.sub(lambda m: m.group(1), text))
    b.close()
    return b.root, b.comments


def text_of(node, drop=("text_exposed_hide", "accessible_elem", "hidden_elem", "UFICommentActorName", "uiLinkSubtle")):
    """Visible text: <br> and block ends become newlines; 'See more' stubs and screen-reader-only spans are dropped."""
    out = []

    def walk(n):
        if isinstance(n, str):
            out.append(n)
            return
        if n.tag in SKIP_TEXT or (n.cls() & set(drop)):
            return
        if n.tag == "br":
            out.append("\n")
            return
        if n.tag == "img":  # an emoticon drawn as an image keeps its alt text
            if "emoticon" in n.attrs.get("class", "") and n.attrs.get("alt"):
                out.append(n.attrs["alt"])
            return
        for c in n.children:
            walk(c)
        if n.tag in ("p", "div", "li"):
            out.append("\n")

    walk(node)
    t = "".join(out).replace(" ", " ")
    t = re.sub(r"[ \t]+", " ", t)
    t = re.sub(r" *\n *", "\n", t)
    return re.sub(r"\n{2,}", "\n", t).strip()


def norm_text(s):
    """Matching key: NFC, case-folded, letters and digits only (emoji, punctuation and spacing ignored)."""
    s = unicodedata.normalize("NFC", s or "").casefold()
    return "".join(ch for ch in s if ch.isalnum())


HOVER_ID = re.compile(r"[?&]id=(\d+)")


def person(a):
    """{name, fbid, profile} from a profile link."""
    if a is None:
        return {"name": None, "fbid": None, "profile": None}
    m = HOVER_ID.search(html.unescape(a.attrs.get("data-hovercard", "")))
    href = a.attrs.get("href", "")
    prof = None
    pm = re.match(r"https?://www\.facebook\.com/([^/?#]+)", href)
    if pm and pm.group(1) not in ("profile.php", "groups", "messages", "photo.php"):
        prof = pm.group(1)
    elif "profile.php?id=" in href:
        prof = "profile.php?id=" + href.split("profile.php?id=")[1].split("&")[0]
    name = text_of(a, drop=()) or a.attrs.get("aria-label") or None
    return {"name": name, "fbid": m.group(1) if m else None, "profile": prof}


def page_meta(raw, comments, root):
    m = None
    for c in comments[:5]:
        m = re.match(r"\s*saved from url=\(\d+\)(\S+)", c)
        if m:
            break
    title = root.find(lambda n: n.tag == "title")
    viewer = re.search(r'"(?:USER_ID|ACCOUNT_ID|viewer|user)"\s*:\s*"(\d{5,})"', raw)
    st = re.search(r'"?serverTime"?\D{0,5}(\d{12,13})', raw)
    return {
        "saved_url": m.group(1) if m else None,
        "title": text_of(title) if title is not None else None,
        "viewer_fbid": viewer.group(1) if viewer else None,
        "server_time_ms": int(st.group(1)) if st else None,
    }


def _imgs(node, exclude_cls=("UFIActorImage", "_50dv", "_s0")):
    out = []
    for n in node.iter():
        if n.tag == "img":
            src = n.attrs.get("src", "")
            if not src or n.cls() & set(exclude_cls) or src.endswith(".gif") or src.startswith("data:"):
                continue
            if any("uiCloseButton" in a.attrs.get("class", "") for a in [n] + list(n.ancestors())[:2]):
                continue
            w = n.attrs.get("width")
            if w and w.isdigit() and int(w) <= 50:
                continue
            out.append(src)
        elif n.tag == "a" and re.search(r"/download/|\.pdf$|\.docx?$", n.attrs.get("href", "")):
            out.append(n.attrs["href"])
    return out


def utime(node):
    a = node.find(lambda n: n.tag == "abbr" and n.attrs.get("data-utime", "0") not in ("", "0"))
    if a is None:
        return None, None
    return int(round(float(a.attrs["data-utime"]) * 1000)), a.attrs.get("title")


# ---------- 2013 Messages thread ----------

def read_messages(root, meta, save_ms):
    groups = root.find_all(lambda n: n.tag == "li" and n.has("webMessengerMessageGroup"))
    if not groups:
        return []
    title = meta.get("title") or ""
    other = re.sub(r"^\(\d+\)\s*", "", title)
    other = re.sub(r"\s*-\s*Messages\s*$", "", other).strip() or None
    thread = {"kind": "messages", "other": other, "url": meta.get("saved_url")}
    blocks = []
    for g in groups:
        strong = g.find(lambda n: n.tag == "strong" and n.has("_36"))
        author = person(strong.find(lambda n: n.tag == "a") if strong else None)
        for b in g.find_all(lambda n: n.tag == "div" and n.has("_53") and n.attrs.get("id", "").startswith("mid.")):
            mid = b.attrs["id"]
            ms = int(re.match(r"mid\.(\d+)", mid).group(1))
            texts = [x for x in b.find_all(lambda n: n.tag == "div" and n.has("_38"))]
            blocks.append((ms, mid, author, texts, _imgs(b), b))
    blocks.sort(key=lambda x: x[0])
    out = []
    for i, (ms, mid, author, texts, imgs, b) in enumerate(blocks):
        # the last block's end is the save time when that is later; else unknown (None: the matcher allows an hour)
        end = blocks[i + 1][0] if i + 1 < len(blocks) else (save_ms if save_ms and save_ms > ms else None)
        if not texts:
            texts = [None]
        for j, t in enumerate(texts):
            rec = {"kind": "message", "id": mid if j == 0 else f"{mid}#{j}", "thread": thread, "author": author,
                   "text": text_of(t) if t is not None else "", "ts_ms": ms,
                   "precision": "exact-ms" if j == 0 else "block", "block_end_ms": end if j else None,
                   "block_end_known": (end is not None) if j else None,
                   "attachments": imgs if j == len(texts) - 1 else []}
            out.append(rec)
    return out


# ---------- posts and comments (2013 forms; 2016-18 userContentWrapper) ----------

def _feedback(form):
    inp = form.find(lambda n: n.tag == "input" and n.attrs.get("name") == "feedback_params")
    if inp is None:
        return None
    try:
        return json.loads(html.unescape(inp.attrs.get("value", "")))
    except ValueError:
        return None


def _post_container(form):
    """The story around a comment form: the nearest ancestor holding a post body or photo caption."""
    for a in form.ancestors():
        if a.tag in ("#root", "body", "html"):
            return None
        body = a.find(lambda n: n.has("userContent") or n.has("fbPhotosPhotoCaption"))
        if body is not None:
            return a
    return None


def read_posts_and_comments(root, meta):
    out, seen_posts = [], set()
    forms = root.find_all(lambda n: n.tag == "form" and n.has("commentable_item"))
    for f in forms:
        fb = _feedback(f)
        if not fb:
            continue
        pid = str(fb.get("target_fbid"))
        cont = _post_container(f)
        body = cont.find(lambda n: n.has("userContent") or n.has("fbPhotosPhotoCaption")) if cont else None
        actor = fb.get("actor")
        is_actor = lambda n: n.tag == "a" and f"id={actor}" in html.unescape(n.attrs.get("data-hovercard", "")) and bool(text_of(n, drop=()))
        alink = (cont.find(is_actor) if cont else None) or root.find(is_actor)
        ts = int(fb["content_timestamp"]) * 1000 if str(fb.get("content_timestamp", "")).isdigit() else None
        group = fb.get("assoc_obj_id") or None
        if pid not in seen_posts:
            seen_posts.add(pid)
            p = person(alink)
            p["fbid"] = p["fbid"] or str(actor)
            out.append({"kind": "post", "id": pid, "author": p, "text": text_of(body) if body is not None else "",
                        "ts_ms": ts, "precision": "exact-s" if ts else "none", "group_fbid": group,
                        "attachments": _imgs(body) if body is not None else []})
        out.extend(read_comments(f, pid))
    # 2016-2018 timeline/news-feed stories without a 2013-style form
    for w in root.find_all(lambda n: n.tag == "div" and n.has("userContentWrapper")):
        link = w.find(lambda n: n.tag == "a" and re.search(r"/posts/(\d+)|story_fbid=(\d+)|/permalink/(\d+)", n.attrs.get("href", "")))
        pid = None
        if link is not None:
            mm = re.search(r"/posts/(\d+)|story_fbid=(\d+)|/permalink/(\d+)", link.attrs["href"])
            pid = next(g for g in mm.groups() if g)
        if pid in seen_posts:
            continue
        h5 = w.find(lambda n: n.tag == "h5")
        alink = h5.find(lambda n: n.tag == "a" and n.attrs.get("data-hovercard")) if h5 else None
        targets = [person(a) for a in h5.find_all(lambda n: n.tag == "a" and n.attrs.get("data-hovercard"))][1:] if h5 else []
        body = w.find(lambda n: n.has("userContent"))
        ts, title = utime(w)
        seen_posts.add(pid)
        out.append({"kind": "post", "id": pid, "author": person(alink), "to": targets, "text": text_of(body) if body else "",
                    "ts_ms": ts, "ts_title": title, "precision": "exact-s" if ts else "none",
                    "attachments": _imgs(body) if body else []})
        out.extend(read_comments(w, pid))  # 2016-18 comments, when present (none in the pages met)
    return out


def read_comments(scope, post_id):
    out = []
    for li in scope.find_all(lambda n: n.tag == "li" and n.has("UFIComment")):
        actor = li.find(lambda n: n.tag == "a" and n.has("UFICommentActorName"))
        if actor is None:
            continue
        content = actor.parent
        # the comment's own text: the content block minus the actor link (and minus any nested reply list)
        body = li.find(lambda n: n.has("UFICommentBody")) or content
        text = text_of(body)
        name = text_of(actor, drop=())
        if body is content and text.startswith(name):
            text = text[len(name):].strip()
        own = [n for n in li.iter() if n.tag == "abbr" and n.attrs.get("data-utime")
               and next((a for a in n.ancestors() if a.tag == "li" and a.has("UFIComment")), None) is li]
        ts = int(float(own[0].attrs["data-utime"]) * 1000) if own else None
        cid = None
        for n in li.iter():
            for attr in ("href", "data-tooltip-uri", "data-reactid"):
                v = html.unescape(n.attrs.get(attr, ""))
                mm = re.search(r"comment_id=(?:\d+_)?(\d+)|\{comment\d+_(\d+)\}", v)
                if mm:
                    cid = mm.group(1) or mm.group(2)
                    break
            if cid:
                break
        parent_li = next((a for a in li.ancestors() if a.tag == "li" and a.has("UFIComment")), None)
        out.append({"kind": "comment", "id": f"{post_id}_{cid}" if cid else None, "parent": post_id,
                    "reply_to": None if parent_li is None else "nested", "author": person(actor), "text": text,
                    "ts_ms": ts, "ts_title": own[0].attrs.get("title") if own else None,
                    "precision": "exact-s" if ts else "none",
                    "attachments": _imgs(li)})
    return out


# ---------- 2011 Download Your Information ----------

DYI_TIME = re.compile(r"([A-Z][a-z]+ \d{1,2}, \d{4}) at (\d{1,2}:\d{2} [ap]m)")


def dyi_time(s):
    m = DYI_TIME.search(s or "")
    if not m:
        return None
    return datetime.datetime.strptime(f"{m.group(1)} {m.group(2)}", "%B %d, %Y %I:%M %p").isoformat(timespec="minutes")


def read_dyi_messages(root):
    out = []
    for ti, th in enumerate(root.find_all(lambda n: n.tag == "div" and n.has("thread"))):
        msgs = [m for m in th.children if isinstance(m, Node) and m.has("message")]
        first = msgs[0] if msgs else None
        prof = lambda n: n.tag == "span" and (n.has("profile") or n.has("page"))  # span.page: a Facebook Page's broadcast
        people = [text_of(p) for p in first.find_all(prof)] if first else []
        thread = {"kind": "dyi-thread", "index": ti, "participants_first_message": people}
        for mi, m in enumerate(msgs):
            profs = [text_of(p) for p in m.find_all(prof)]
            page = m.find(lambda n: n.tag == "span" and n.has("page")) is not None
            t = m.find(lambda n: n.has("time"))
            body = m.find(lambda n: n.has("msgbody"))
            subj = body.find(lambda n: n.has("subject")) if body else None
            text = text_of(body, drop=("subject",)) if body else ""
            out.append({"kind": "message", "id": f"dyi-t{ti}-m{mi}", "thread": thread, "author": {"name": profs[0] if profs else None, "page": page},
                        "to": profs[1:], "subject": text_of(subj) if subj else None, "text": text,
                        "local_minute": dyi_time(text_of(t) if t else ""), "precision": "minute-local",
                        "is_reply": m.has("reply")})
    return out


def read_dyi_wall(root):
    out = []
    for ei, e in enumerate(root.find_all(lambda n: n.tag == "div" and n.has("feedentry"))):
        prof = next((c for c in e.children if isinstance(c, Node) and c.has("profile")), None)
        tr = next((c for c in e.children if isinstance(c, Node) and c.has("timerow")), None)
        parts = []
        for c in e.children:
            if c is prof or (isinstance(c, Node) and (c.has("timerow") or c.has("comments"))):
                continue
            parts.append(c if isinstance(c, str) else text_of(c))
        links = [a.attrs.get("href") for a in e.find_all(lambda n: n.tag == "a") if a.attrs.get("href")]
        pid = f"dyi-wall-{ei}"
        out.append({"kind": "post", "id": pid, "author": {"name": text_of(prof) if prof else None},
                    "text": re.sub(r"\s+", " ", " ".join(p.strip() for p in parts if p.strip())).strip(),
                    "local_minute": dyi_time(text_of(tr) if tr else ""), "precision": "minute-local", "links": links})
        cm = next((c for c in e.children if isinstance(c, Node) and c.has("comments")), None)
        for ci, c in enumerate(cm.find_all(lambda n: n.tag == "div" and n.has("comment")) if cm else []):
            if c.has("like"):
                out.append({"kind": "like-line", "id": f"{pid}-c{ci}", "parent": pid, "text": text_of(c)})
                continue
            p = c.find(lambda n: n.has("profile"))
            t = c.find(lambda n: n.has("time"))
            txt = text_of(c, drop=("profile", "time"))
            out.append({"kind": "comment", "id": f"{pid}-c{ci}", "parent": pid, "author": {"name": text_of(p) if p else None},
                        "text": txt, "local_minute": dyi_time(text_of(t) if t else ""), "precision": "minute-local"})
    return out


# ---------- one page ----------

def read_page(path, mtime=None):
    with open(path, encoding="utf-8", errors="replace") as f:
        raw = f.read()
    root, comments = parse_html(raw)
    meta = page_meta(raw, comments, root)
    if root.find(lambda n: n.has("tabmessages") or n.has("tabwall")) is not None:
        kind = "dyi-2011-messages" if root.find(lambda n: n.has("tabmessages")) is not None else "dyi-2011-wall"
        recs = read_dyi_messages(root) if kind.endswith("messages") else read_dyi_wall(root)
        owner = re.split(r"\s+-\s+", meta.get("title") or "")[0].strip() or None  # "<account name> -  Messages"
        meta.update(kind=kind, owner=owner, save_ms=None, save_basis="the export's README.txt (zone not stated)")
        return {"path": path, "meta": meta, "records": recs}
    # The page kept updating after it loaded (serverTime): messages that arrived live are later than it. The save time
    # is the file's mtime when that is within two days after serverTime (an original copy), else serverTime itself.
    save_ms, basis = meta["server_time_ms"], "page serverTime"
    if mtime and (save_ms is None or 0 <= mtime * 1000 - save_ms <= 2 * 86400000):
        save_ms, basis = int(mtime * 1000), "file mtime" + (" (after serverTime)" if save_ms else "")
    recs = read_messages(root, meta, save_ms)
    kind = "messages-thread" if recs else None
    recs += read_posts_and_comments(root, meta)
    if kind is None:
        url = meta.get("saved_url") or ""
        if "Sorry, this content isn" in raw and not recs:
            kind = "unavailable"
        elif "/groups/" in url:
            kind = "group-post"
        elif "photo.php" in url or root.find(lambda n: n.attrs.get("id") == "fbPhotoPageCaption") is not None:
            kind = "photo-with-comments"
        elif recs:
            kind = "timeline"
        else:
            kind = "other"
    meta.update(kind=kind, save_ms=save_ms, save_basis=basis)
    return {"path": path, "meta": meta, "records": recs}


def iso(ms):
    return datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ") if ms else None


def summary(page):
    r = page["records"]
    ts = [x["ts_ms"] for x in r if x.get("ts_ms")] or []
    lm = [x["local_minute"] for x in r if x.get("local_minute")]
    by = {}
    for x in r:
        by[x["kind"]] = by.get(x["kind"], 0) + 1
    prec = {}
    for x in r:
        if x["kind"] in ("message", "post", "comment"):
            prec[x["precision"]] = prec.get(x["precision"], 0) + 1
    return {"path": page["path"], "kind": page["meta"]["kind"], "saved": iso(page["meta"]["save_ms"]),
            "save_basis": page["meta"]["save_basis"], "counts": by, "precision": prec,
            "first": iso(min(ts)) if ts else (min(lm) if lm else None), "last": iso(max(ts)) if ts else (max(lm) if lm else None),
            "attachments": sum(len(x.get("attachments") or []) for x in r)}


def main(argv):
    if len(argv) < 3 or argv[1] not in ("summary", "extract"):
        print(__doc__)
        return 2
    mtime = None
    if "--mtime" in argv:
        i = argv.index("--mtime")
        mtime = float(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    for p in argv[2:]:
        page = read_page(p, mtime)
        if argv[1] == "summary":
            print(json.dumps(summary(page), ensure_ascii=False))
        else:
            for rec in page["records"]:
                print(json.dumps(dict(rec, page=p, page_kind=page["meta"]["kind"], save_ms=page["meta"]["save_ms"]), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
