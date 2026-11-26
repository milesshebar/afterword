#!/usr/bin/env python3 -I
"""Decrypt an ENCRYPTED iPhone backup read-only and stage the message-related files, one folder per source, with a manifest.

Read-only on the backup (files are opened 'rb'); the decrypted Manifest.db goes to a temp folder under --out and is removed at the end.
The passphrase comes on stdin only (never argv/env/file) and is never printed:
    security find-generic-password -s "<keychain item>" -a <account> -w | <venv>/bin/python -I scripts/iphone-backup-stage.py --backup <set> --out <dir>
    (or any command that prints the passphrase; typing it is fine too: read -rs P; printf %s "$P" | ...)

Output (<out> is one device's folder):
  extracted/<source>/<domain>/<relativePath>   decrypted files, folder structure kept
  extracted/sms/ATTACHMENTS.tsv                 every SMS attachment the manifest lists (domain path, size, mtime) and whether it was in the set
  MANIFEST.tsv                                  source, file, bytes, sha256, first and last date, rows (for the databases it knows)
  census.json                                   rows per year for the same databases
Sources: sms (sms.db + attachments), callhistory, whatsapp (shared group container: ChatStorage, CallHistory, Media), health, calendar,
addressbook, notes, safari, routined (significant locations, if the backup carries it), photos-metadata (Photos.sqlite only).
Needs iphone_backup_decrypt (pinned 0.11.2 + pycryptodome in a scratch venv).
"""
import argparse, collections, hashlib, json, os, shutil, sqlite3, sys, tempfile
from datetime import datetime, timezone

SOURCES = [
    ("sms", "HomeDomain", "Library/SMS/sms.db%"),
    ("sms", "MediaDomain", "Library/SMS/Attachments/%"),
    ("callhistory", "HomeDomain", "Library/CallHistoryDB/%"),
    ("whatsapp", "AppDomainGroup-group.net.whatsapp.WhatsApp.shared", "%"),
    ("health", "HealthDomain", "%"),
    ("calendar", "HomeDomain", "Library/Calendar/%"),
    ("addressbook", "HomeDomain", "Library/AddressBook/%"),
    ("notes", "AppDomainGroup-group.com.apple.notes", "%"),
    ("safari", "%Safari%", "%History.db%"),
    ("safari", "HomeDomain", "Library/Safari/%"),
    ("routined", "%", "%routined%"),
    ("photos-metadata", "CameraRollDomain", "Media/PhotoData/Photos.sqlite%"),
]
APPLE = 978307200

# (source, file name, SQL returning unix seconds per row, row-count SQL)
KNOWN = [
    ("sms", "sms.db", f"SELECT CASE WHEN date > 1e12 THEN date / 1e9 ELSE date END + {APPLE} FROM message WHERE date > 0", "SELECT count(*) FROM message"),
    ("callhistory", "CallHistory.storedata", f"SELECT ZDATE + {APPLE} FROM ZCALLRECORD", "SELECT count(*) FROM ZCALLRECORD"),
    ("whatsapp", "ChatStorage.sqlite", f"SELECT ZMESSAGEDATE + {APPLE} FROM ZWAMESSAGE WHERE ZMESSAGEDATE IS NOT NULL", "SELECT count(*) FROM ZWAMESSAGE"),
    ("whatsapp", "CallHistory.sqlite", f"SELECT ZDATE + {APPLE} FROM ZWACDCALLEVENT", "SELECT count(*) FROM ZWACDCALLEVENT"),
    ("health", "healthdb_secure.sqlite", f"SELECT start_date + {APPLE} FROM samples", "SELECT count(*) FROM samples"),
    ("calendar", "Calendar.sqlitedb", f"SELECT start_date + {APPLE} FROM CalendarItem WHERE start_date IS NOT NULL", "SELECT count(*) FROM CalendarItem"),
    ("addressbook", "AddressBook.sqlitedb", f"SELECT CreationDate + {APPLE} FROM ABPerson WHERE CreationDate IS NOT NULL", "SELECT count(*) FROM ABPerson"),
    ("notes", "NoteStore.sqlite", f"SELECT ZCREATIONDATE3 + {APPLE} FROM ZICCLOUDSYNCINGOBJECT WHERE ZCREATIONDATE3 IS NOT NULL", "SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZNOTE IS NOT NULL OR ZTITLE1 IS NOT NULL"),
    ("safari", "History.db", f"SELECT visit_time + {APPLE} FROM history_visits", "SELECT count(*) FROM history_visits"),
    ("photos-metadata", "Photos.sqlite", f"SELECT ZDATECREATED + {APPLE} FROM ZASSET WHERE ZDATECREATED IS NOT NULL", "SELECT count(*) FROM ZASSET"),
]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def measure(path, date_sql, count_sql):
    """(first day, last day, rows, {year: rows}) from a copy opened immutable; None when the query does not fit."""
    try:
        c = sqlite3.connect("file:" + path + "?immutable=1", uri=True)
        rows = c.execute(count_sql).fetchone()[0]
        years = collections.Counter()
        lo = hi = None
        for (t,) in c.execute(date_sql):
            if t is None or t < 946684800 or t > 2e9:      # 2000-01-01 .. 2033: drop zero dates and birthdays-in-1604
                continue
            years[datetime.fromtimestamp(t, timezone.utc).year] += 1
            lo = t if lo is None else min(lo, t); hi = t if hi is None else max(hi, t)
        day = lambda t: datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%d") if t else ""
        return day(lo), day(hi), rows, dict(sorted(years.items()))
    except Exception as e:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backup", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    if os.path.realpath(a.out).startswith(os.path.realpath(a.backup)):
        sys.exit("--out must not be inside the backup")
    os.makedirs(a.out, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="manifest-", dir=a.out)
    os.environ["TMPDIR"] = tmp; tempfile.tempdir = tmp
    from iphone_backup_decrypt import EncryptedBackup
    pw = sys.stdin.buffer.read().rstrip(b"\r\n")
    if not pw:
        sys.exit("no passphrase on stdin")
    try:
        b = EncryptedBackup(backup_directory=a.backup, passphrase=pw)
        del pw
        try:
            b.test_decryption()
        except Exception as e:
            print(f"cannot decrypt this backup with that password ({type(e).__name__}): stopping, nothing extracted")
            sys.exit(5)
        print("backup decrypts: ok", flush=True)
        ext = os.path.join(a.out, "extracted")
        # the SMS attachment list first (everything the manifest names, present or not)
        with b.manifest_db_cursor() as cur:
            cur.execute("SELECT fileID, relativePath FROM Files WHERE domain = 'MediaDomain' AND relativePath LIKE 'Library/SMS/Attachments/%' AND flags = 1")
            rows = cur.fetchall()
        os.makedirs(os.path.join(ext, "sms"), exist_ok=True)
        with open(os.path.join(ext, "sms", "ATTACHMENTS.tsv"), "w") as f:
            f.write("relative_path\tin_backup\n")
            for fid, rp in rows:
                f.write(f"{rp}\t{int(os.path.exists(os.path.join(a.backup, fid[:2], fid)))}\n")
        print(f"sms attachments listed: {len(rows)}", flush=True)
        for src, dom, rp in SOURCES:
            n = b.extract_files(relative_paths_like=rp, domain_like=dom, output_folder=os.path.join(ext, src),
                                preserve_folders=True, domain_subfolders=True,
                                filter_callback=lambda **kw: os.path.exists(os.path.join(a.backup, kw["file_id"][:2], kw["file_id"])))
            print(f"  {src:16} {dom[:40]:40} {rp[:34]:34} {n} files", flush=True)
    finally:
        try:
            del b
        except Exception:
            pass
        shutil.rmtree(tmp, ignore_errors=True)
    # manifest + census
    census = {}
    with open(os.path.join(a.out, "MANIFEST.tsv"), "w") as m:
        m.write("source\tfile\tbytes\tsha256\tfirst_date\tlast_date\trows\n")
        for root, _, fs in sorted(os.walk(ext)):
            for fn in sorted(fs):
                p = os.path.join(root, fn)
                rel = os.path.relpath(p, a.out)
                src = rel.split(os.sep)[1] if rel.count(os.sep) >= 1 else ""
                first = last = rows = ""
                for ksrc, kname, dsql, csql in KNOWN:
                    if ksrc == src and fn == kname:
                        r = measure(p, dsql, csql)
                        if r:
                            first, last, rows, years = r
                            census[f"{src}/{fn}"] = {"first": first, "last": last, "rows": rows, "by_year": years}
                m.write(f"{src}\t{rel}\t{os.path.getsize(p)}\t{sha256(p)}\t{first}\t{last}\t{rows}\n")
    json.dump(census, open(os.path.join(a.out, "census.json"), "w"), indent=1)
    for k, v in census.items():
        print(f"{k:45} {v['first']} -> {v['last']}  rows {v['rows']}  " + " ".join(f"{y}:{n}" for y, n in v["by_year"].items()))
    print("temp manifest removed:", not os.path.exists(tmp))


if __name__ == "__main__":
    main()
