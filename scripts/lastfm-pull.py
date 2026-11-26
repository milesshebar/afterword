#!/usr/bin/env python3 -I
"""Pull one Last.fm user's whole scrobble history (user.getRecentTracks, extended=1, 200 a page), slowly, into a folder of pages.

Rules followed (Last.fm API Terms of Service, https://www.last.fm/api/tos, and https://www.last.fm/api/intro):
- Rate: Last.fm publishes no number; it warns that an app "continuously making several calls per second" may be suspended, and the
  ToS (4.4) forbids circumventing its limits. This script makes ONE request at a time, never in parallel, waits a random 3-8 s
  between pages and a random 2-5 minutes after every ~50 pages (about 6-10 requests a minute, far below one a second).
- Identification: "Please use an identifiable User-Agent header on all requests": the User-Agent names this app and the Last.fm user
  whose own history it backs up.
- Caching (ToS 4.3.4): a page is fetched once and kept; a rerun resumes from the first missing page and never refetches one.
  `to` is fixed when the pull starts, so pages do not shift while new scrobbles land.
- Volume (ToS 4.3.4, the "Reasonable Usage Cap" of 100 MB of stored Last.fm data): pages are trimmed to the fields the archive uses
  (track, artist, album, mbids, date, loved): about 50 KB a page instead of the raw response with image URLs.
- The key (ToS 2.6) is the one Last.fm issued to you (https://www.last.fm/api/account/create); it is read from $LASTFM_API_KEY and
  never printed, logged or written. Request URLs are not logged either.
- Errors: error 29 (rate limit exceeded), HTTP 429, any 5xx or a network failure: stop, back off at least 30 minutes, retry the
  same page once; if it fails again, stop for the day (exit 3) so a person can look. Error 26 (suspended API key), 10 (invalid key)
  or any other account-type error: stop at once (exit 4). Error 8/16 (temporary): one retry after 60 s, then the 30-minute rule.
- Attribution (ToS 2.7, "powered by AudioScrobbler"): the archive notes the source as Last.fm on every row it imports.

    LASTFM_API_KEY=... python3 -I scripts/lastfm-pull.py --user <last.fm username> --out <folder>

Writes <out>/info.json (user.getInfo, trimmed), <out>/pull.json (user, to, totalPages, total), <out>/page-NNNNN.json (page 1 = newest)
and <out>/requests.tsv (one line per request: UTC time, method, page, HTTP status, bytes, outcome). At the end it prints the request
count, the duration and the most requests in any 60 s window.
"""
import argparse, json, os, random, sys, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone

API = "https://ws.audioscrobbler.com/2.0/"
UA = "personal-message-archive/1.0 (personal scrobble backup of last.fm user {user}; one request at a time, 3-8 s apart)"
STOP_DAY, STOP_NOW = 3, 4


class StopNow(Exception):
    pass


def api_key():
    k = os.environ.get("LASTFM_API_KEY")
    if k:
        return k.strip()
    sys.exit("no Last.fm API key: set LASTFM_API_KEY")


class Client:
    def __init__(self, key, user, log_path):
        self.key, self.ua = key, UA.format(user=user)
        self.log = open(log_path, "a")
        self.times = []

    def _once(self, params):
        url = API + "?" + urllib.parse.urlencode(dict(params, api_key=self.key, format="json"))
        req = urllib.request.Request(url, headers={"User-Agent": self.ua, "Accept": "application/json"})
        t = time.time(); self.times.append(t)
        stamp = datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        tag = f"{params['method']}\t{params.get('page', '-')}"
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                body = r.read()
                status = r.status
        except urllib.error.HTTPError as e:
            body = e.read() if hasattr(e, "read") else b""
            status = e.code
        except (urllib.error.URLError, TimeoutError) as e:
            self.log.write(f"{stamp}\t{tag}\t-\t0\tnetwork error {type(e).__name__}\n"); self.log.flush()
            return None, "network"
        try:
            data = json.loads(body.decode("utf-8"))
        except Exception:
            data = None
        err = data.get("error") if isinstance(data, dict) else None
        outcome = "ok" if status == 200 and err is None else f"error {err}" if err else f"http {status}"
        self.log.write(f"{stamp}\t{tag}\t{status}\t{len(body)}\t{outcome}\n"); self.log.flush()
        if status == 200 and err is None:
            return data, "ok"
        if err in (26, 10, 4, 9, 14, 15, 17) or status in (401, 403):
            raise StopNow(f"Last.fm says error {err} / HTTP {status}: {data.get('message', '') if isinstance(data, dict) else ''}")
        if err in (8, 16):
            return None, "temporary"
        return None, "limit"    # 29, 429, 5xx, anything else

    def call(self, params):
        data, kind = self._once(params)
        if data is not None:
            return data
        if kind in ("temporary", "network"):
            print(f"  {kind} failure on {params.get('page', params['method'])}; retrying once in 60 s", flush=True)
            time.sleep(60)
            data, kind = self._once(params)
            if data is not None:
                return data
        wait = random.uniform(30 * 60, 35 * 60)
        print(f"  {kind} on {params.get('page', params['method'])}: backing off {wait / 60:.0f} min", flush=True)
        time.sleep(wait)
        data, kind = self._once(params)
        if data is not None:
            return data
        print(f"  failed again ({kind}) after the back-off: stopping for the day", flush=True)
        sys.exit(STOP_DAY)


def trim_page(data):
    rt = data["recenttracks"]
    tracks = rt.get("track", [])
    if isinstance(tracks, dict):
        tracks = [tracks]
    out = []
    for t in tracks:
        x = {"name": t.get("name"), "mbid": t.get("mbid"), "loved": t.get("loved"),
             "artist": {"name": (t.get("artist") or {}).get("name"), "mbid": (t.get("artist") or {}).get("mbid")},
             "album": {"#text": (t.get("album") or {}).get("#text"), "mbid": (t.get("album") or {}).get("mbid")}}
        if "date" in t:
            x["date"] = {"uts": t["date"].get("uts")}
        if "@attr" in t:
            x["@attr"] = t["@attr"]
        out.append(x)
    return {"recenttracks": {"track": out, "@attr": rt.get("@attr", {})}}


def max_per_minute(times):
    best, j = 0, 0
    for i, t in enumerate(times):
        while times[j] < t - 60:
            j += 1
        best = max(best, i - j + 1)
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--user", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    c = Client(api_key(), a.user, os.path.join(a.out, "requests.tsv"))
    t0 = time.time()
    try:
        info = c.call({"method": "user.getinfo", "user": a.user})
        u = info["user"]
        json.dump({"user": {"name": u.get("name"), "playcount": u.get("playcount"), "registered": u.get("registered")}},
                  open(os.path.join(a.out, "info.json"), "w"))
        print(f"user {a.user}: playcount {u.get('playcount')}, registered {(u.get('registered') or {}).get('unixtime')}", flush=True)
        pull_path = os.path.join(a.out, "pull.json")
        pull = json.load(open(pull_path)) if os.path.exists(pull_path) else {"user": a.user, "to": int(time.time())}
        base = {"method": "user.getrecenttracks", "user": a.user, "limit": 200, "extended": 1, "to": pull["to"]}

        def path(p):
            return os.path.join(a.out, f"page-{p:05d}.json")

        if "totalPages" not in pull or not os.path.exists(path(1)):
            time.sleep(random.uniform(3, 8))
            first = c.call(dict(base, page=1))
            attr = first["recenttracks"]["@attr"]
            pull.update(totalPages=int(attr["totalPages"]), total=int(attr["total"]))
            json.dump(pull, open(pull_path, "w"))
            with open(path(1) + ".tmp", "w") as f:
                json.dump(trim_page(first), f)
            os.replace(path(1) + ".tmp", path(1))
        total = pull["totalPages"]
        print(f"{pull['total']} scrobbles up to {datetime.fromtimestamp(pull['to'], timezone.utc):%Y-%m-%d %H:%M} UTC, {total} pages", flush=True)
        since_pause, next_pause = 0, random.randint(45, 55)
        for p in range(2, total + 1):
            if os.path.exists(path(p)):
                continue                                     # cached: never fetch a page twice
            time.sleep(random.uniform(3, 8))
            data = c.call(dict(base, page=p))
            with open(path(p) + ".tmp", "w") as f:
                json.dump(trim_page(data), f)
            os.replace(path(p) + ".tmp", path(p))
            since_pause += 1
            if p % 25 == 0 or p == total:
                print(f"  page {p}/{total}  {(time.time() - t0) / 60:.0f} min", flush=True)
            if since_pause >= next_pause and p < total:
                rest = random.uniform(120, 300)
                print(f"  resting {rest / 60:.1f} min", flush=True)
                time.sleep(rest)
                since_pause, next_pause = 0, random.randint(45, 55)
    except StopNow as e:
        print(f"STOP: {e}. Not retrying; a person should look.", flush=True)
        sys.exit(STOP_NOW)
    finally:
        if c.times:
            print(f"requests {len(c.times)}, {(time.time() - t0) / 60:.1f} min, max {max_per_minute(c.times)} in any 60 s window", flush=True)
    print("done", flush=True)


if __name__ == "__main__":
    main()
