import Foundation

/// Last.fm scrobbles as dated listening rows (`listen`), from a folder written by `scripts/lastfm-pull.py`: `pull.json`
/// (user, to, total), `info.json` (user.getInfo) and `page-NNNNN.json` (user.getRecentTracks, extended=1). An optional `loves.json`
/// (`{"loves": [{"title", "artist", "loved_at"}]}`, from any tool that lists your loved tracks) marks loved tracks.
///
/// The `listen` table is additive and created here (`CREATE TABLE IF NOT EXISTS`) rather than by a numbered migration: a schema
/// version bump would make the deployed web app (an older build) refuse the archive. Older readers ignore the table.
/// Idempotent: a scrobble's key is user + Unix second + artist + track, so a rerun, or a later pull that overlaps, adds only new rows.
public struct LastfmImportStats: Codable, Equatable, Sendable {
    public var user = ""
    public var pages = 0
    public var reportedTotal = 0          // the API's total for the pulled window
    public var reportedPlaycount = 0      // user.getInfo playcount at pull time
    public var parsed = 0
    public var inserted = 0
    public var alreadyThere = 0
    public var nowPlayingSkipped = 0
    public var undated = 0
    public var lovedFromAPI = 0           // rows the API marked loved (current state)
    public var lovesInFile = 0
    public var lovesMatched = 0           // loves.json entries that matched at least one scrobble
    public var rowsMarkedLoved = 0
    public var firstTsMs: Int64?
    public var lastTsMs: Int64?
    public var placeholderDated = 0       // plays Last.fm keeps without a real time (uts 1, 2, 3 ...: an old dateless import)
}

public enum LastfmImporter {
    public static let kind = "lastfm"
    /// Below this Unix second (2002-01-01, before Last.fm existed) a scrobble's time is Last.fm's placeholder, not a time: the row is
    /// kept (it is a real play and counts toward the playcount) but reported as undated.
    public static let realTimeFloor: Int64 = 1_009_843_200

    public static let tableSQL = [
        """
        CREATE TABLE IF NOT EXISTS listen (
            id INTEGER PRIMARY KEY,
            ts_ms INTEGER NOT NULL,              -- when the track was scrobbled (Unix ms, UTC)
            artist TEXT NOT NULL,
            album TEXT,
            track TEXT NOT NULL,
            artist_mbid TEXT, album_mbid TEXT, track_mbid TEXT,
            loved INTEGER NOT NULL DEFAULT 0,    -- 1 = loved on Last.fm (the API's flag or the loves list)
            service TEXT NOT NULL,               -- lastfm
            source_id INTEGER NOT NULL REFERENCES source(id),
            source_key TEXT NOT NULL UNIQUE      -- lastfm:<user>:<uts>:<artist>\u{1}<track>
        )
        """,
        "CREATE INDEX IF NOT EXISTS listen_ts ON listen(ts_ms)",
        "CREATE INDEX IF NOT EXISTS listen_artist ON listen(artist COLLATE NOCASE)",
    ]

    public static func ensureTable(_ db: Database) throws {
        for s in tableSQL { try db.exec(s) }
    }

    /// A pull folder: `pull.json` plus at least one `page-*.json`.
    public static func isPullFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent("pull.json").path) else { return false }
        return ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).contains { $0.hasPrefix("page-") && $0.hasSuffix(".json") }
    }

    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        if let d = v as? [String: Any] { return string(d["#text"] ?? d["name"]) }
        return nil
    }

    static func loveKey(_ artist: String, _ track: String) -> String {
        artist.lowercased().trimmingCharacters(in: .whitespaces) + "\u{1}" + track.lowercased().trimmingCharacters(in: .whitespaces)
    }

    public static func importPull(at folder: URL, into db: Database, loves lovesURL: URL? = nil) throws -> LastfmImportStats {
        var s = LastfmImportStats()
        let pull = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("pull.json"))) as? [String: Any] ?? [:]
        s.user = pull["user"] as? String ?? "?"
        s.reportedTotal = pull["total"] as? Int ?? 0
        if let info = try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("info.json"))) as? [String: Any],
           let u = info["user"] as? [String: Any] {
            s.reportedPlaycount = Int(string(u["playcount"]) ?? "") ?? 0
        }
        let pages = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("page-") && $0.hasSuffix(".json") }.sorted()
        s.pages = pages.count

        var loves = Set<String>()
        let lovesFile = lovesURL ?? folder.appendingPathComponent("loves.json")
        if FileManager.default.fileExists(atPath: lovesFile.path),
           let lj = try JSONSerialization.jsonObject(with: Data(contentsOf: lovesFile)) as? [String: Any],
           let list = lj["loves"] as? [[String: Any]] {
            for l in list {
                if let a = string(l["artist"]), let t = string(l["title"]) { loves.insert(loveKey(a, t)) }
            }
            s.lovesInFile = list.count
        }

        try ensureTable(db)
        try db.transaction {
            let sourceKey = "\(kind):\(s.user):to=\(pull["to"] ?? "?")"
            let selSrc = try db.prepare("SELECT id FROM source WHERE sha256 = ?")
            selSrc.bind(1, sourceKey)
            var sourceID: Int64
            if try selSrc.step() { sourceID = selSrc.int(0); selSrc.reset() }
            else {
                selSrc.reset()
                let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,0,?,NULL)")
                ins.bind(1, kind).bind(2, folder.path).bind(3, sourceKey).bind(4, Int64(Date().timeIntervalSince1970))
                try ins.run()
                sourceID = db.lastInsertRowID
            }
            let insListen = try db.prepare("""
                INSERT OR IGNORE INTO listen(ts_ms, artist, album, track, artist_mbid, album_mbid, track_mbid, loved, service, source_id, source_key)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """)
            for name in pages {
                let data = try Data(contentsOf: folder.appendingPathComponent(name))
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rt = root["recenttracks"] as? [String: Any] else { throw ArchiveError("\(name): not a getRecentTracks page") }
                let tracks: [[String: Any]]
                if let arr = rt["track"] as? [[String: Any]] { tracks = arr }
                else if let one = rt["track"] as? [String: Any] { tracks = [one] }
                else { tracks = [] }
                for t in tracks {
                    if let attr = t["@attr"] as? [String: Any], (attr["nowplaying"] as? String) == "true" { s.nowPlayingSkipped += 1; continue }
                    guard let date = t["date"] as? [String: Any], let uts = Int64(string(date["uts"]) ?? "") else { s.undated += 1; continue }
                    guard let artist = string(t["artist"]), let track = string(t["name"]) else { s.undated += 1; continue }
                    s.parsed += 1
                    let album = string(t["album"])
                    let artistMBID = (t["artist"] as? [String: Any]).flatMap { string($0["mbid"]) }
                    let albumMBID = (t["album"] as? [String: Any]).flatMap { string($0["mbid"]) }
                    let apiLoved = string(t["loved"]) == "1"
                    if apiLoved { s.lovedFromAPI += 1 }
                    let loved = apiLoved || loves.contains(loveKey(artist, track))
                    let key = "\(kind):\(s.user):\(uts):\(artist)\u{1}\(track)"
                    insListen.bind(1, uts * 1000).bind(2, artist).bind(3, album).bind(4, track).bind(5, artistMBID).bind(6, albumMBID)
                        .bind(7, string(t["mbid"])).bind(8, loved).bind(9, kind).bind(10, sourceID).bind(11, key)
                    try insListen.run()
                    if db.changes > 0 { s.inserted += 1 } else { s.alreadyThere += 1 }
                    if uts < LastfmImporter.realTimeFloor { s.placeholderDated += 1; continue }
                    s.firstTsMs = min(s.firstTsMs ?? uts * 1000, uts * 1000)
                    s.lastTsMs = max(s.lastTsMs ?? uts * 1000, uts * 1000)
                }
            }
            // Loves from the list mark every matching scrobble (a love is per track, not per play).
            if !loves.isEmpty {
                var matched = Set<String>()
                let sel = try db.prepare("SELECT DISTINCT lower(artist) || char(1) || lower(track) FROM listen WHERE service = 'lastfm'")
                while try sel.step() { if let k = sel.string(0), loves.contains(k) { matched.insert(k) } }
                s.lovesMatched = matched.count
                let upd = try db.prepare("UPDATE listen SET loved = 1 WHERE loved = 0 AND lower(artist) || char(1) || lower(track) = ?")
                for k in matched { upd.bind(1, k); try upd.run() }
            }
            s.rowsMarkedLoved = Int(try db.scalarInt("SELECT count(*) FROM listen WHERE loved = 1"))
            let upd = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            upd.bind(1, String(decoding: try JSONEncoder().encode(s), as: UTF8.self)).bind(2, sourceID)
            try upd.run()
        }
        return s
    }

    /// Rows, range and per-year counts for `archivectl stats` (nil when the archive has no `listen` table).
    public static func summary(_ db: Database) throws -> (rows: Int, first: Int64?, last: Int64?, loved: Int, undated: Int, byYear: [(Int, Int)])? {
        guard try db.tableExists("listen") else { return nil }
        let floor = realTimeFloor * 1000
        let rows = Int(try db.scalarInt("SELECT count(*) FROM listen"))
        let loved = Int(try db.scalarInt("SELECT count(*) FROM listen WHERE loved = 1"))
        let undated = Int(try db.scalarInt("SELECT count(*) FROM listen WHERE ts_ms < \(floor)"))
        let r = try db.prepare("SELECT min(ts_ms), max(ts_ms) FROM listen WHERE ts_ms >= \(floor)")
        var first: Int64?, last: Int64?
        if try r.step() { first = r.optInt(0); last = r.optInt(1) }
        var years: [(Int, Int)] = []
        let y = try db.prepare("SELECT CAST(strftime('%Y', ts_ms / 1000, 'unixepoch') AS INTEGER), count(*) FROM listen WHERE ts_ms >= \(floor) GROUP BY 1 ORDER BY 1")
        while try y.step() { years.append((Int(y.int(0)), Int(y.int(1)))) }
        return (rows, first, last, loved, undated, years)
    }
}
