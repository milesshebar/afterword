import Foundation

/// Archive schema with forward-only migrations tracked in `PRAGMA user_version`.
public enum Schema {
    public static let currentVersion = 7

    static let migrations: [Int: [String]] = [
        1: [
            """
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)
            """,
            """
            CREATE TABLE source (
                id INTEGER PRIMARY KEY,
                kind TEXT NOT NULL,              -- android-xml | ios-backup | ...
                path TEXT NOT NULL,              -- original location (provenance only, never opened later)
                sha256 TEXT NOT NULL UNIQUE,     -- of the source file; makes import idempotent
                bytes INTEGER NOT NULL,
                imported_at INTEGER NOT NULL,    -- unix seconds
                stats_json TEXT
            )
            """,
            """
            CREATE TABLE handle (
                id INTEGER PRIMARY KEY,
                raw TEXT NOT NULL,               -- first spelling seen
                normalized TEXT NOT NULL UNIQUE, -- E.164 for phones; short codes / emails kept raw
                kind TEXT NOT NULL               -- phone | short | email | other
            )
            """,
            """
            CREATE TABLE contact_name (
                handle_id INTEGER NOT NULL REFERENCES handle(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                origin TEXT NOT NULL,            -- contacts-app | iphone-addressbook | android-xml
                priority INTEGER NOT NULL,       -- higher wins at view time
                PRIMARY KEY (handle_id, origin, name)
            ) WITHOUT ROWID
            """,
            """
            CREATE TABLE thread (
                id INTEGER PRIMARY KEY,
                key TEXT NOT NULL UNIQUE,        -- sorted participant set
                is_group INTEGER NOT NULL,
                title TEXT
            )
            """,
            """
            CREATE TABLE thread_member (
                thread_id INTEGER NOT NULL REFERENCES thread(id) ON DELETE CASCADE,
                handle_id INTEGER NOT NULL REFERENCES handle(id),
                PRIMARY KEY (thread_id, handle_id)
            ) WITHOUT ROWID
            """,
            """
            CREATE TABLE message (
                id INTEGER PRIMARY KEY,
                thread_id INTEGER NOT NULL REFERENCES thread(id),
                sender_handle_id INTEGER REFERENCES handle(id),  -- NULL = me
                ts_ms INTEGER NOT NULL,                          -- unix ms, UTC
                is_from_me INTEGER NOT NULL,
                service TEXT NOT NULL,                           -- sms | mms | imessage
                body TEXT,
                subject TEXT,
                source_id INTEGER NOT NULL REFERENCES source(id),
                source_key TEXT,                                 -- carrier / app id when one exists
                canonical_id INTEGER REFERENCES message(id) ON DELETE SET NULL, -- NULL = this row is canonical
                content_hash INTEGER NOT NULL,                   -- FNV-1a 64 of normalized body
                att_hash INTEGER                                 -- FNV-1a 64 of sorted attachment sha256s
            )
            """,
            "CREATE INDEX message_thread_ts ON message(thread_id, ts_ms)",
            "CREATE INDEX message_source ON message(source_id)",
            "CREATE INDEX message_source_key ON message(source_key) WHERE source_key IS NOT NULL",
            "CREATE INDEX message_canonical ON message(canonical_id) WHERE canonical_id IS NOT NULL",
            "CREATE INDEX message_ts ON message(ts_ms)",
            """
            CREATE TABLE media (
                sha256 TEXT PRIMARY KEY,
                path TEXT NOT NULL,              -- root-relative: media/<xx>/<sha256>.<ext>
                bytes INTEGER NOT NULL,
                mime TEXT
            )
            """,
            """
            CREATE TABLE attachment (
                id INTEGER PRIMARY KEY,
                message_id INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                mime TEXT,
                filename TEXT,
                media_path TEXT NOT NULL,        -- root-relative
                bytes INTEGER NOT NULL,
                sha256 TEXT NOT NULL REFERENCES media(sha256)
            )
            """,
            "CREATE INDEX attachment_message ON attachment(message_id)",
            "CREATE INDEX attachment_sha ON attachment(sha256)",
            """
            CREATE VIRTUAL TABLE message_fts USING fts5(
                body, content='message', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
            )
            """,
            """
            CREATE TRIGGER message_ai AFTER INSERT ON message BEGIN
                INSERT INTO message_fts(rowid, body) VALUES (new.id, new.body);
            END
            """,
            """
            CREATE TRIGGER message_ad AFTER DELETE ON message BEGIN
                INSERT INTO message_fts(message_fts, rowid, body) VALUES ('delete', old.id, old.body);
            END
            """,
            """
            CREATE TRIGGER message_au AFTER UPDATE OF body ON message BEGIN
                INSERT INTO message_fts(message_fts, rowid, body) VALUES ('delete', old.id, old.body);
                INSERT INTO message_fts(rowid, body) VALUES (new.id, new.body);
            END
            """,
        ],
        2: [
            // The Android XML name origin is now spelled out (priority order: contacts-app > iphone-addressbook > android-xml).
            "UPDATE OR IGNORE contact_name SET origin = 'android-xml' WHERE origin = 'xml'",
        ],
        3: [
            // Full-text index over canonical rows only. Duplicate rows (every later export repeats the earlier ones) are kept for
            // provenance but never searched, so the index no longer grows with each re-import (a 158-file daily series made the
            // old index, which held every row, the dominant cost of an import: 70 s and a 12 GB WAL for a 50k-row file).
            // The index's content table is a view of the canonical rows, so FTS5's own integrity-check compares like with like.
            "DROP TRIGGER IF EXISTS message_ai",
            "DROP TRIGGER IF EXISTS message_ad",
            "DROP TRIGGER IF EXISTS message_au",
            "DROP TRIGGER IF EXISTS message_demote",
            "DROP TRIGGER IF EXISTS message_promote",
            "DROP TABLE IF EXISTS message_fts",
            "DROP VIEW IF EXISTS canonical_message",
            "CREATE VIEW canonical_message AS SELECT id, body FROM message WHERE canonical_id IS NULL",
            """
            CREATE VIRTUAL TABLE message_fts USING fts5(
                body, content='canonical_message', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
            )
            """,
            "INSERT INTO message_fts(message_fts) VALUES ('rebuild')",
            """
            CREATE TRIGGER message_ai AFTER INSERT ON message WHEN new.canonical_id IS NULL BEGIN
                INSERT INTO message_fts(rowid, body) VALUES (new.id, new.body);
            END
            """,
            """
            CREATE TRIGGER message_ad AFTER DELETE ON message WHEN old.canonical_id IS NULL BEGIN
                INSERT INTO message_fts(message_fts, rowid, body) VALUES ('delete', old.id, old.body);
            END
            """,
            """
            CREATE TRIGGER message_au AFTER UPDATE OF body ON message WHEN old.canonical_id IS NULL AND new.canonical_id IS NULL BEGIN
                INSERT INTO message_fts(message_fts, rowid, body) VALUES ('delete', old.id, old.body);
                INSERT INTO message_fts(rowid, body) VALUES (new.id, new.body);
            END
            """,
            """
            CREATE TRIGGER message_demote AFTER UPDATE OF canonical_id ON message WHEN old.canonical_id IS NULL AND new.canonical_id IS NOT NULL BEGIN
                INSERT INTO message_fts(message_fts, rowid, body) VALUES ('delete', old.id, old.body);
            END
            """,
            """
            CREATE TRIGGER message_promote AFTER UPDATE OF canonical_id ON message WHEN old.canonical_id IS NOT NULL AND new.canonical_id IS NULL BEGIN
                INSERT INTO message_fts(rowid, body) VALUES (new.id, new.body);
            END
            """,
        ],
        4: [
            // The reader only ever shows canonical rows. Once a daily series made duplicates 96% of the table, scans that skipped
            // them cost seconds (conversation list: 7.4 s), so the canonical rows get their own small indexes.
            "CREATE INDEX IF NOT EXISTS message_canon_thread_ts ON message(thread_id, ts_ms, source_id) WHERE canonical_id IS NULL",
            "CREATE INDEX IF NOT EXISTS message_canon_ts ON message(ts_ms) WHERE canonical_id IS NULL",
        ],
        5: [
            // v2 (Messenger + Instagram). All additive and metadata-only in SQLite (ADD COLUMN with a constant default does not
            // rewrite the table), so this runs instantly on a multi-million-row archive.
            // message.kind: NULL = an ordinary message; 'system' (added/left/named the group...), 'call', 'unsent'. For those the
            // human-readable line is `note` and `body` stays NULL, so system chatter never reaches the full-text index.
            "ALTER TABLE message ADD COLUMN kind TEXT",
            "ALTER TABLE message ADD COLUMN note TEXT",
            // thread.service: NULL for the SMS/iMessage threads of v1, 'messenger' | 'instagram' for Meta threads.
            // thread.origin: the Meta folder the thread came from (inbox | archived | e2ee | filtered | requests).
            // thread.hidden: 1 for filtered threads and message requests (hidden by default in the app).
            "ALTER TABLE thread ADD COLUMN service TEXT",
            "ALTER TABLE thread ADD COLUMN origin TEXT",
            "ALTER TABLE thread ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE thread ADD COLUMN external_id TEXT",
            """
            CREATE TABLE IF NOT EXISTS reaction (
                message_id INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                emoji TEXT NOT NULL,
                actor_handle_id INTEGER REFERENCES handle(id),   -- NULL with by_me = 1: the owner
                by_me INTEGER NOT NULL DEFAULT 0
            )
            """,
            "CREATE INDEX IF NOT EXISTS reaction_message ON reaction(message_id)",
        ],
        6: [
            // v2 stage B: automatic person matching (see PeopleMatcher). A person is a set of handles that have 1:1
            // conversations; person.id is the smallest handle id in the set. Only automatic matches live here: the user's
            // corrections are in people.sqlite next to this file, so the app can keep this database read-only.
            """
            CREATE TABLE IF NOT EXISTS person (
                id INTEGER PRIMARY KEY,
                display_name TEXT,
                handle_count INTEGER NOT NULL,
                confidence REAL NOT NULL,
                reason TEXT NOT NULL                -- single | name | name-phones | ig-username
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS person_handle (
                person_id INTEGER NOT NULL REFERENCES person(id) ON DELETE CASCADE,
                handle_id INTEGER NOT NULL REFERENCES handle(id) ON DELETE CASCADE,
                origin TEXT NOT NULL DEFAULT 'auto',     -- auto | manual (manual rows are never written here; see people.sqlite)
                confidence REAL NOT NULL,
                reason TEXT,
                PRIMARY KEY (handle_id)
            ) WITHOUT ROWID
            """,
            "CREATE INDEX IF NOT EXISTS person_handle_person ON person_handle(person_id)",
            // Names shared by two different people (two busy phone numbers): never linked, listed for review.
            // A person's per-service view (only SMS, only Messenger...) pages each (thread, service) in time order from this index.
            "CREATE INDEX IF NOT EXISTS message_canon_thread_service_ts ON message(thread_id, service, ts_ms) WHERE canonical_id IS NULL",
            """
            CREATE TABLE IF NOT EXISTS person_ambiguous (
                name_key TEXT NOT NULL,
                handle_id INTEGER NOT NULL REFERENCES handle(id) ON DELETE CASCADE,
                PRIMARY KEY (name_key, handle_id)
            ) WITHOUT ROWID
            """,
        ],
        7: [
            // Real Instagram usernames (see InstagramUsernames). The export never pairs a display name with a username, so each
            // Instagram handle gets zero or one *inferred* username with a confidence ('high' is shown as "@user", 'low' only as
            // "possible @user") and the method that found it. Purely additive: handle.id and handle.normalized, which people.sqlite
            // and the reject keys refer to, are never touched. Replaced wholesale by `archivectl ig-usernames`.
            """
            CREATE TABLE IF NOT EXISTS handle_username (
                handle_id INTEGER PRIMARY KEY REFERENCES handle(id) ON DELETE CASCADE,
                username TEXT NOT NULL,
                confidence TEXT NOT NULL CHECK (confidence IN ('high', 'low')),
                method TEXT NOT NULL
            )
            """,
        ],
    ]

    /// Opens (creating and migrating as needed) the archive database at the root.
    /// `preserveJournalMode`: a read-write open that leaves the journal mode as it finds it (`verify` on a copy that was
    /// prepared for moving must not switch it back to WAL, or the next read-only open of that copy is refused).
    public static func openArchive(root: ArchiveRoot, readOnly: Bool = false, assumeNetwork: Bool? = nil, preserveJournalMode: Bool = false) throws -> Database {
        if !readOnly { try root.createIfNeeded() }
        else if !FileManager.default.fileExists(atPath: root.databaseURL.path) {
            throw ArchiveError("no archive at \(root.url.path)")
        }
        if let problem = root.mediaProblem { throw ArchiveError(problem) }
        // A read-only view of an archive on a network mount (a NAS over SMB) or in a folder this process cannot write
        // (the container's read-only mount) opens `immutable`: WAL and its shared memory cannot work there, and nobody
        // writes while the archive is only being browsed. `archivectl prepare-move` checkpoints the WAL first so an
        // immutable open sees every row.
        let onNetwork = assumeNetwork ?? (root.isOnNetworkVolume || (readOnly && root.isReadOnlyLocation))
        if readOnly && onNetwork { try requirePreparedForMove(root: root) }
        let db = try Database(path: root.databaseURL.path, readOnly: readOnly, immutable: readOnly && onNetwork)
        if onNetwork {
            // WAL needs shared memory; network mounts cannot provide it.
            if !readOnly { try db.exec("PRAGMA journal_mode = DELETE") }
        } else if !readOnly && !preserveJournalMode {
            try db.exec("PRAGMA journal_mode = WAL")
        }
        try db.exec("PRAGMA foreign_keys = ON")
        try db.exec("PRAGMA synchronous = NORMAL")
        try db.exec("PRAGMA cache_size = -65536")
        try db.exec("PRAGMA temp_store = MEMORY")
        if !readOnly { try migrate(db) }
        return db
    }

    /// `immutable=1` ignores any -wal file, so a copy that still carries WAL state would open silently stale or empty.
    /// Refuse instead of showing a wrong archive.
    static func requirePreparedForMove(root: ArchiveRoot) throws {
        let fm = FileManager.default
        let wal = root.url.appendingPathComponent("archive.sqlite-wal").path
        let walSize = ((try? fm.attributesOfItem(atPath: wal))?[.size] as? NSNumber)?.intValue ?? 0
        var walMode = false
        if let h = try? FileHandle(forReadingFrom: root.databaseURL) {
            defer { try? h.close() }
            if let d = try? h.read(upToCount: 20), d.count >= 20 { walMode = d[18] == 2 || d[19] == 2 }
        }
        if walSize > 0 || walMode {
            throw ArchiveError("This copy wasn't prepared for moving: run `archivectl prepare-move` on the original and copy again.")
        }
    }

    /// ("message", "kind") for "ALTER TABLE message ADD COLUMN kind TEXT".
    static func addColumnTarget(_ sql: String) -> (String, String)? {
        let w = sql.split(separator: " ")
        guard w.count >= 6, w[0] == "ALTER", w[1] == "TABLE", w[3] == "ADD", w[4] == "COLUMN" else { return nil }
        return (String(w[2]), String(w[5]))
    }

    public static func migrate(_ db: Database, upTo target: Int = currentVersion) throws {
        var v = try db.userVersion()
        if v > currentVersion { throw ArchiveError("archive schema v\(v) is newer than this build (v\(currentVersion))") }
        while v < min(target, currentVersion) {
            let next = v + 1
            guard let stmts = migrations[next] else { throw ArchiveError("missing migration \(next)") }
            try db.transaction {
                for s in stmts {
                    // ADD COLUMN has no IF NOT EXISTS: skip a column that is already there (a replayed migration).
                    if let (table, column) = addColumnTarget(s), try db.hasColumn(table, column) { continue }
                    try db.exec(s)
                }
                try db.setUserVersion(next)
            }
            v = next
        }
    }
}
