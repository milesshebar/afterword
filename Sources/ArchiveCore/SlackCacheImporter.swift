import Foundation

public struct SlackImportStats: Codable, Equatable, Sendable {
    public var saves = 0, unreadableSaves = 0          // blob files read / not readable (truncated writes)
    public var versions = 0                            // message copies across all saves
    public var distinct = 0                            // messages by workspace + conversation + ts
    public var inserted = 0
    public var text = 0, system = 0, bot = 0, filesNoted = 0, threadReplies = 0, edited = 0, editedTextDiffers = 0
    public var reactions = 0
    public var leftOutEphemeral = 0, leftOutDeleted = 0, leftOutEmpty = 0, leftOutBadTs = 0, heldKnown = 0
    public var threads = 0, people = 0
    /// Saves of a workspace left out by `--workspace` (nil in stats stored before that flag existed).
    public var savesOtherWorkspace: Int?
    public init() {}
}

public struct SlackImportReport: Sendable {
    public var status: ImportReport.Status
    public var sourceID: Int64
    public var stats: SlackImportStats
}

/// Slack's desktop app (4.x, Electron, around 2020-21) kept no message database: it saved its whole Redux state into
/// Chromium IndexedDB every so often, one blob file per save (`IndexedDB/https_app.slack.com_0.indexeddb.blob/<db>/<xx>/<hex>`), a
/// V8-serialized object with one workspace in `teams` and `messages[conversation][ts]`, `channels`, `members`, `bots`, `files` and
/// `reactions` beside it (some saves wrap a table as `{internalUseOnlyByIdMap: {...}, meta}`). The blob number rises with each save,
/// so the newest copy of a message is the one in the highest-numbered save that holds it.
///
/// A save is one workspace's state, but from 2022 its `teams` table also lists the client's other workspaces and the Slack Connect
/// teams of outside people: the save's own workspace is `selfTeamIds.teamId` (every save since 2020 carries it; without it, the
/// only team), and it must be the team of the signed-in member. A caller can name the workspaces to import (`workspaces`); the
/// saves of any other workspace are ledgered and left out.
///
/// One thread per conversation (service `slack`, keyed `slack:<team>:<conversation>`: channel, private channel, group DM, DM); each
/// message keyed by its own ts (`slack:<team>:<conversation>:<ts>`), so a second snapshot of the cache never duplicates one; people
/// are `slack-user` handles keyed `slack:<team>:<user id>`. The owner is the save's own signed-in user (`bootData.user_id`, which must be
/// the one member marked `is_self`). Times are the ts (Unix seconds, UTC). Joins, leaves and app (bot) messages are system lines
/// that say what they are; files are a note (the cache holds their metadata, not the file); reactions go to the reaction table with
/// who reacted. Ephemeral "only visible to you" items and deleted-message tombstones are left out. Every message gets a ledger line.
public enum SlackCacheImporter {
    public static let kind = "slack-cache"

    // MARK: reading the saves

    public struct Save {
        public var file: String                    // path relative to the blob folder
        public var number: (db: Int, blob: Int)
        public var state: V8Value?
        public var error: String?
        public var team: String?                   // the save's own workspace, once known
        public var notChosen = false               // a readable save of a workspace the caller did not name
    }

    /// The blob files under `dir` (the `.indexeddb.blob` folder or any folder above it), in save order.
    public static func blobFiles(in dir: URL) throws -> [(url: URL, rel: String, db: Int, blob: Int)] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { throw ArchiveError("cannot list \(dir.path)") }
        var out: [(URL, String, Int, Int)] = []
        let base = dir.standardizedFileURL.path
        for case let u as URL in e {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let comps = u.standardizedFileURL.pathComponents
            guard comps.count >= 4, comps[comps.count - 4].hasSuffix(".indexeddb.blob"),
                  let db = Int(comps[comps.count - 3]), let blob = Int(comps[comps.count - 1], radix: 16) else { continue }
            var rel = u.standardizedFileURL.path
            if rel.hasPrefix(base + "/") { rel.removeFirst(base.count + 1) }
            out.append((u, rel, db, blob))
        }
        return out.sorted { ($0.2, $0.3) < ($1.2, $1.3) }
    }

    /// A table that may be wrapped as `{internalUseOnlyByIdMap: {...}, meta: {...}}`.
    static func table(_ v: V8Value?) -> [String: V8Value] {
        guard let o = v?.object else { return [:] }
        if let inner = o["internalUseOnlyByIdMap"]?.object { return inner }
        return o
    }

    // MARK: Slack's text markup

    /// Slack's message markup made readable: `<@U1>` -> `@Name`, `<#C1|name>` -> `#name`, `<!here>` -> `@here`, `<url|label>` ->
    /// `label (url)` (just `label` when it only repeats the address), `<url>` -> the url; then `&lt;`, `&gt;`, `&amp;`.
    public static func render(_ text: String, user: (String) -> String?, channel: (String) -> String?) -> String {
        var out = "", i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "<", let close = text[i...].firstIndex(of: ">") else { out.append(text[i]); i = text.index(after: i); continue }
            let inner = String(text[text.index(after: i)..<close])
            let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let target = parts[0], label = parts.count > 1 ? parts[1] : nil
            if target.hasPrefix("@") {
                let id = String(target.dropFirst())
                out += "@" + (user(id) ?? label ?? id)
            } else if target.hasPrefix("#") {
                let id = String(target.dropFirst())
                out += "#" + (label ?? channel(id) ?? id)
            } else if target.hasPrefix("!") {
                let cmd = String(target.dropFirst())
                if let label { out += label }
                else if cmd.hasPrefix("subteam^") { out += "@group" }
                else { out += "@" + cmd }
            } else if let label, !label.isEmpty {
                let bare = target.replacingOccurrences(of: #"^(mailto:|tel:|https?://)"#, with: "", options: .regularExpression)
                out += (label == target || label == bare || label == bare.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) ? label : "\(label) (\(target))"
            } else {
                out += target
            }
            i = text.index(after: close)
        }
        return out.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Slack's standard emoji names as characters (the ones these workspaces used, and the common ones); a skin tone suffix
    /// (`::skin-tone-2`..`6`) adds its modifier. A workspace's own custom emoji have no character and stay `:name:`.
    static let emoji: [String: String] = [
        "+1": "👍", "thumbsup": "👍", "-1": "👎", "thumbsdown": "👎", "heart": "❤️", "heart_eyes": "😍", "joy": "😂", "laughing": "😆",
        "satisfied": "😆", "rolling_on_the_floor_laughing": "🤣", "smile": "😄", "smiley": "😃", "grinning": "😀", "sweat_smile": "😅",
        "slightly_smiling_face": "🙂", "wink": "😉", "blush": "😊", "sunglasses": "😎", "thinking_face": "🤔", "flushed": "😳",
        "cold_sweat": "😰", "cry": "😢", "sob": "😭", "rage": "😡", "zany_face": "🤪", "hot_face": "🥵", "pleading_face": "🥺",
        "pleading-face_1f97a": "🥺", "skull": "💀", "eyes": "👀", "raised_hands": "🙌", "clap": "👏", "pray": "🙏", "muscle": "💪",
        "point_up": "☝️", "point_up_2": "👆", "v": "✌️", "ok_hand": "👌", "wave": "👋", "100": "💯", "fire": "🔥", "tada": "🎉",
        "white_check_mark": "✅", "heavy_check_mark": "✔️", "exclamation": "❗", "bangbang": "‼️", "question": "❓", "zzz": "💤",
        "green_heart": "💚", "blue_heart": "💙", "purple_heart": "💜", "yellow_heart": "💛", "broken_heart": "💔", "sparkles": "✨",
        "star": "⭐", "trophy": "🏆", "lock": "🔒", "siren": "🚨", "rotating_light": "🚨", "hankey": "💩", "poop": "💩",
        "door": "🚪", "school": "🏫", "beer": "🍺", "beers": "🍻", "wine_glass": "🍷", "champagne": "🍾", "chocolate_bar": "🍫",
        "shopping_bags": "🛍️", "airplane": "✈️", "statue_of_liberty": "🗽", "us": "🇺🇸", "flag-us": "🇺🇸", "eagle": "🦅",
        "boot": "👢", "bear": "🐻", "dog2": "🐕", "dog": "🐶", "cat": "🐱", "shark": "🦈", "blowfish": "🐡",
        "fishing_pole_and_fish": "🎣", "pill": "💊", "one": "1️⃣", "dancer": "💃", "man_in_lotus_position": "🧘‍♂️",
        "male-farmer": "👨‍🌾", "dance": "💃", "rocket": "🚀", "pizza": "🍕", "coffee": "☕", "sunny": "☀️", "camera": "📷",
        "movie_camera": "🎥", "clapper": "🎬", "film_frames": "🎞️", "headphones": "🎧", "musical_note": "🎵", "x": "❌",
        "no_entry": "⛔", "warning": "⚠️", "heavy_plus_sign": "➕", "pushpin": "📌", "memo": "📝", "calendar": "📆", "smirk": "😏",
        "upside_down_face": "🙃", "grimacing": "😬", "scream": "😱", "open_mouth": "😮", "hugging_face": "🤗", "partying_face": "🥳",
        "star-struck": "🤩", "money_mouth_face": "🤑", "facepalm": "🤦", "shrug": "🤷", "raised_hand": "✋", "handshake": "🤝",
        "heart_on_fire": "❤️‍🔥", "gift": "🎁", "birthday": "🎂", "balloon": "🎈", "crown": "👑", "gem": "💎", "moneybag": "💰",
    ]

    public static func emojiText(_ name: String) -> String {
        var base = name, tone: Int? = nil
        if let r = name.range(of: "::skin-tone-") { base = String(name[..<r.lowerBound]); tone = Int(name[r.upperBound...]) }
        guard let e = emoji[base] else { return ":\(name):" }
        guard let t = tone, (2...6).contains(t) else { return e }
        let mod = String(UnicodeScalar(UInt32(0x1F3FB + t - 2))!)
        // The modifier follows the first character (before a variation selector or a joiner sequence's rest).
        var scalars = Array(e.unicodeScalars)
        if scalars.count > 1, scalars[1].value == 0xFE0F { scalars.remove(at: 1) }
        return String(String.UnicodeScalarView([scalars[0]])) + mod + String(String.UnicodeScalarView(Array(scalars.dropFirst())))
    }

    /// A message's file entry: an id (the workspace's record) or an inline object (used as it is). `SlackCachedFiles` calls this too.
    public static func fileObject(_ f: V8Value, files: [String: [String: V8Value]]) -> (id: String, fo: [String: V8Value]?) {
        let fo: [String: V8Value]? = f.text.flatMap { files[$0] } ?? f.object
        return (f.text ?? fo?["id"]?.text ?? "?", fo)
    }

    /// What the note says of one file of a message (the cache keeps metadata, not the file). `SlackCachedFiles` rewrites exactly
    /// this text when it attaches a copy found in Slack's HTTP cache.
    public static func fileNote(_ fo: [String: V8Value]?, id: String) -> String {
        guard let fo else { return "a file (\(id)) not attached" }
        if fo["mode"]?.text == "tombstone" || fo["is_tombstoned"]?.bool == true { return "a file since deleted from Slack" }
        let title = fo["title"]?.text ?? fo["name"]?.text ?? id
        let type = fo["pretty_type"]?.text ?? fo["filetype"]?.text ?? "file"
        if fo["is_external"]?.bool == true, let url = fo["external_url"]?.text ?? fo["url_private"]?.text {
            return "a link to \(type) “\(title)” on \(fo["external_type"]?.text.map { $0 == "app" ? "an outside service" : $0 } ?? "an outside service"): \(url)"
        }
        return "\(type) “\(title)” not attached (the Slack cache keeps no copy)"
    }

    /// A ts ("1608352978.032800") as Unix milliseconds, read as decimal digits (no floating point).
    public static func tsMs(_ ts: String) -> Int64? {
        let p = ts.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count <= 2, let s = Int64(p[0]), s > 0 else { return nil }
        var frac: Int64 = 0
        if p.count == 2 {
            let f = String(p[1].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            guard p[1].allSatisfy(\.isNumber), let v = Int64(f) else { return nil }
            frac = v
        }
        // A numeric but impossible ts (beyond Int64 milliseconds) is a bad ts, not a trap.
        let (ms, overflow) = s.multipliedReportingOverflow(by: 1000)
        guard !overflow, ms <= Int64.max - frac else { return nil }
        return ms + frac
    }

    // MARK: the merged view

    struct Copy {
        var message: [String: V8Value]
        var save: Int                              // index into saves
        var reactions: [V8Value]
    }

    struct Workspace {
        var id: String
        var name: String?
        var me: String
        var members: [String: [String: V8Value]] = [:]
        var bots: [String: [String: V8Value]] = [:]
        var channels: [String: [String: V8Value]] = [:]
        var files: [String: [String: V8Value]] = [:]
    }

    struct Merged {
        var saves: [Save] = []
        var workspaces: [String: Workspace] = [:]
        var copies: [String: [Copy]] = [:]         // "team|conversation|ts" -> every copy, oldest save first
    }

    /// `only`: the workspaces to read (empty = every workspace); a save of another workspace is marked `notChosen` and adds nothing.
    static func merge(_ files: [(url: URL, rel: String, db: Int, blob: Int)], only: Set<String> = []) throws -> Merged {
        var m = Merged()
        for f in files {
            var save = Save(file: f.rel, number: (f.db, f.blob), state: nil, error: nil)
            do { save.state = try V8Deserializer.readIndexedDBValue(try Data(contentsOf: f.url)) }
            catch { save.error = "\(error)" }
            m.saves.append(save)
            let idx = m.saves.count - 1
            guard let st = save.state else { continue }
            let teams = table(st["teams"])
            // The save's own workspace: selfTeamIds.teamId; a save without selfTeamIds must list exactly one team. A selfTeamIds
            // that is there but names no workspace is not read as "absent".
            let team: String
            switch st["selfTeamIds"] {
            case nil, .some(.undefined), .some(.null):
                guard teams.count == 1, let single = teams.first else {
                    m.saves[idx].error = "a save with \(teams.count) workspaces and no selfTeamIds.teamId"; continue
                }
                team = single.key
            case .some(let own):
                guard let id = own["teamId"]?.text else { m.saves[idx].error = "a save whose selfTeamIds names no workspace"; continue }
                team = id
            }
            guard let tinfo = teams[team], tinfo.object != nil else {
                m.saves[idx].error = "a save whose own workspace \(team) is not in its teams table"; continue
            }
            m.saves[idx].team = team
            // A workspace the caller did not name is left out before anything else of the save is looked at.
            if !only.isEmpty, !only.contains(team) { m.saves[idx].notChosen = true; continue }
            guard let me = st["bootData"]?["user_id"]?.text else { m.saves[idx].error = "a save without bootData.user_id"; continue }
            let members = table(st["members"])
            // The signed-in user must be the one member marked is_self (when the save lists members at all), and a member of
            // the save's own workspace (when the record says which workspace it belongs to; a team_id that is not an id fails).
            let selfs = members.filter { $0.value["is_self"]?.bool == true }.map(\.key)
            if !members.isEmpty, selfs != [me] { throw ArchiveError("save \(f.rel): bootData.user_id \(me) but is_self on \(selfs)") }
            if let home = members[me]?["team_id"], home != .undefined, home != .null, home.text != team {
                throw ArchiveError("save \(f.rel): the signed-in user \(me) belongs to \(home.text ?? "no readable workspace"), not to the save's workspace \(team)")
            }
            var w = m.workspaces[team] ?? Workspace(id: team, name: nil, me: me)
            if w.me != me { throw ArchiveError("workspace \(team): signed-in user \(w.me) in one save and \(me) in \(f.rel)") }
            w.name = tinfo["name"]?.text ?? w.name
            for (k, v) in members { if let o = v.object { w.members[k] = o } }
            for (k, v) in table(st["bots"]) { if let o = v.object { w.bots[k] = o } }
            for (k, v) in table(st["channels"]) where k != "meta" { if let o = v.object { w.channels[k] = o } }
            for (k, v) in table(st["files"]) { if let o = v.object { w.files[k] = o } }
            m.workspaces[team] = w
            let reactions = table(st["reactions"])
            for (cid, list) in st["messages"]?.object ?? [:] {
                for (_, mv) in table(list) {
                    guard let msg = mv.object, let ts = msg["ts"]?.text else { continue }
                    let key = "\(team)|\(cid)|\(ts)"
                    let rk = msg["_rxn_key"]?.text ?? "message-\(ts)-\(cid)"
                    m.copies[key, default: []].append(Copy(message: msg, save: idx, reactions: reactions[rk]?.array ?? []))
                }
            }
        }
        return m
    }

    // MARK: import

    /// A Slack team id: `T` and at least one more capital letter or digit, nothing else.
    public static func isTeamID(_ s: String) -> Bool {
        s.count >= 2 && s.hasPrefix("T") && s.unicodeScalars.allSatisfy { ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A) }
    }

    public static func importCache(at dir: URL, into db: Database, origin: String? = nil, holdKeys: Set<String> = [], workspaces: Set<String> = [],
                                   ledger: URL? = nil) throws -> SlackImportReport {
        // A workspace is named by its Slack team id; anything else (a comma, a blank) would also blur the source's identity.
        if let bad = workspaces.first(where: { !isTeamID($0) }) { throw ArchiveError("not a Slack team id: “\(bad)” (T and capital letters or digits)") }
        let files = try blobFiles(in: dir)
        guard !files.isEmpty else { throw ArchiveError("\(dir.path) holds no IndexedDB blob files (…/https_app.slack.com_0.indexeddb.blob/<db>/<xx>/<hex>)") }
        // The source's identity: every blob's path and sha256, so the same cache imports once.
        var listing = ""
        var bytes: Int64 = 0
        for f in files { let (sha, n) = try Hashing.sha256Hex(ofFile: f.url); listing += "\(f.rel)\t\(sha)\n"; bytes += n }
        let key = "slack:" + Data(listing.utf8).withUnsafeBytes { Hashing.sha256Hex($0) }
            + (holdKeys.isEmpty ? "" : ":hold=\(holdKeys.count)/\(String(UInt64(bitPattern: Hashing.fnv1a(holdKeys.sorted().joined(separator: "\n"))), radix: 16))")
            + (workspaces.isEmpty ? "" : ":workspaces=" + workspaces.sorted().joined(separator: ","))
        let seen = try db.prepare("SELECT id, stats_json FROM source WHERE sha256 = ?")
        seen.bind(1, key)
        if try seen.step() {
            let s = seen.string(1).flatMap { try? JSONDecoder().decode(SlackImportStats.self, from: Data($0.utf8)) } ?? SlackImportStats()
            let id = seen.int(0); seen.reset()
            if let ledger, let body = try ImportLedger.load(db, sourceID: id) { try ImportLedger.publish(body, to: ledger) }
            return SlackImportReport(status: .alreadyImported, sourceID: id, stats: s)
        }
        seen.reset()

        let merged = try merge(files, only: workspaces)
        var stats = SlackImportStats()
        stats.saves = merged.saves.filter { $0.state != nil && $0.error == nil && !$0.notChosen }.count
        stats.savesOtherWorkspace = merged.saves.filter(\.notChosen).count
        stats.unreadableSaves = merged.saves.count - stats.saves - (stats.savesOtherWorkspace ?? 0)
        stats.versions = merged.copies.values.reduce(0) { $0 + $1.count }
        stats.distinct = merged.copies.count

        let iso = ISO8601DateFormatter()
        var out = ["source_file\tworkspace\tconversation\tconversation_kind\tts\tts_ms\tts_utc\tdirection\tsender\tdecision\twritten_message_id\tthread_id\tkind\tedited\tparent_ts\tcopies\treactions\tnote"]
        let base = origin ?? dir.path
        for s in merged.saves where s.state == nil || s.error != nil {
            out.append([base + "/" + s.file, "", "", "", "", "", "", "", "", "left-out-unreadable-save", "", "", "", "", "", "", "", (s.error ?? "").replacingOccurrences(of: "\t", with: " ")].joined(separator: "\t"))
        }
        for s in merged.saves where s.notChosen {
            out.append([base + "/" + s.file, s.team ?? "", "", "", "", "", "", "", "", "left-out-workspace-not-chosen", "", "", "", "", "", "", "", "a save of a workspace not named with --workspace"].joined(separator: "\t"))
        }

        func name(_ w: Workspace, _ uid: String) -> String? {
            if let u = w.members[uid] {
                let p = u["profile"]
                return u["real_name"]?.text ?? p?["real_name"]?.text ?? p?["display_name"]?.text ?? u["name"]?.text
            }
            if let b = w.bots[uid] { return b["name"]?.text }
            if uid == "USLACKBOT" { return "Slackbot" }
            return nil
        }
        func handle(_ w: Workspace, _ uid: String, fallback: String? = nil) -> ServiceHandle {
            ServiceHandle.slack(team: w.id, userID: uid, name: name(w, uid) ?? fallback ?? "Slack user \(uid)")
        }
        func convKind(_ c: [String: V8Value]?) -> String {
            guard let c else { return "unknown" }
            if c["is_im"]?.bool == true { return "dm" }
            if c["is_mpim"]?.bool == true { return "group-dm" }
            if c["is_private"]?.bool == true || c["is_group"]?.bool == true { return "private-channel" }
            return "channel"
        }
        func channelName(_ w: Workspace, _ cid: String) -> String? { w.channels[cid]?["name"]?.text }

        var report: SlackImportReport!
        let threadsBefore = try db.scalarInt("SELECT coalesce(max(id), 0) FROM thread")
        let known = try db.prepare("SELECT coalesce(canonical_id, id) FROM message WHERE source_key = ? LIMIT 1")
        try db.transaction {
            let ins = try db.prepare("INSERT INTO source(kind, path, sha256, bytes, imported_at, stats_json) VALUES (?,?,?,?,?,NULL)")
            ins.bind(1, kind).bind(2, base).bind(3, key).bind(4, bytes).bind(5, Int64(Date().timeIntervalSince1970))
            try ins.run()
            let sid = db.lastInsertRowID
            let writer = try ArchiveWriter(db: db, sourceID: sid, sourceKind: kind, sourceTier: SourceTier.other)
            // Every Slack message has its own ts: the source key decides "already here", never a content match.
            writer.skipDuplicateCheck = true
            var threadOf: [String: (thread: Int64, team: String, cid: String)] = [:]
            var people = Set<String>()

            // Workspace, conversation, then time.
            let order = merged.copies.keys.sorted { a, b in
                let x = a.split(separator: "|"), y = b.split(separator: "|")
                if x[0] != y[0] { return x[0] < y[0] }
                if x[1] != y[1] { return x[1] < y[1] }
                return (tsMs(String(x[2])) ?? 0, x[2]) < (tsMs(String(y[2])) ?? 0, y[2])
            }
            for k in order {
                let copies = merged.copies[k]!
                let parts = k.split(separator: "|").map(String.init)
                let (team, cid, ts) = (parts[0], parts[1], parts[2])
                let w = merged.workspaces[team]!
                let newest = copies.max { $0.save < $1.save }!
                let m = newest.message
                let conv = w.channels[cid]
                let ck = convKind(conv)
                let ms = tsMs(ts)
                let user = m["user"]?.text
                let botID = m["bot_id"]?.text
                let fromMe = user == w.me
                let edited = m["edited"] != nil || copies.contains { $0.message["edited"] != nil }
                let texts = Set(copies.map { $0.message["text"]?.string ?? "" })
                let threadTs = m["thread_ts"]?.text
                let parent = (threadTs != nil && threadTs != ts) ? threadTs : nil
                var reactionCount = 0
                for r in newest.reactions { reactionCount += r["users"]?.array?.count ?? 0 }
                func log(_ decision: String, written: Int64? = nil, thread: Int64? = nil, kind: String = "", note: String = "") {
                    // Built in parts: one long array literal was too slow for the Linux compiler's type checker (the Linux container build).
                    let file: String = base + "/" + merged.saves[newest.save].file
                    let msText: String = ms.map { String($0) } ?? ""
                    let utc: String = ms.map { iso.string(from: Date(timeIntervalSince1970: Double($0) / 1000)) } ?? ""
                    let direction: String = fromMe ? "out" : "in"
                    let who: String = user ?? botID ?? ""
                    let writtenText: String = written.map { String($0) } ?? ""
                    let threadText: String = thread.map { String($0) } ?? ""
                    let editedText: String = edited ? (texts.count > 1 ? "edited-text-differs" : "edited") : ""
                    let noteText: String = note.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                    var fields: [String] = [file, team, cid, ck, ts, msText, utc, direction, who, decision]
                    fields += [writtenText, threadText, kind, editedText, parent ?? "", String(copies.count), String(reactionCount), noteText]
                    out.append(fields.joined(separator: "\t"))
                }
                guard let ms else { log("left-out-bad-ts"); stats.leftOutBadTs += 1; continue }
                let subtype = m["subtype"]?.text ?? ""
                if m["is_ephemeral"]?.bool == true || m["_hidden_stub"]?.bool == true || copies.contains(where: { $0.message["is_ephemeral"]?.bool == true }) {
                    stats.leftOutEphemeral += 1; log("left-out-ephemeral", note: "an only-visible-to-you notice (\(subtype.isEmpty ? "stub" : subtype)), not a message"); continue
                }
                if subtype == "tombstone" || subtype == "message_deleted" || m["deleted"]?.bool == true {
                    stats.leftOutDeleted += 1; log("left-out-deleted"); continue
                }
                let sourceKey = "slack:\(team):\(cid):\(ts)"
                if holdKeys.contains(sourceKey) { stats.heldKnown += 1; log("left-out-hold-list"); continue }
                known.bind(1, sourceKey)
                if try known.step() { let a = known.int(0); known.reset(); stats.heldKnown += 1; log("held-source-key", note: "archive row \(a)"); continue }
                known.reset()

                let renderUser: (String) -> String? = { uid in uid == w.me ? (name(w, uid) ?? "Me") : name(w, uid) }
                let text = render(m["text"]?.string ?? "", user: renderUser, channel: { channelName(w, $0) })
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var rec = MessageRecord(participants: [], sender: nil, tsMs: ms, isFromMe: fromMe, service: "slack")
                rec.sourceKey = sourceKey
                // Members: the DM's other person, a group DM's members, and whoever wrote.
                var handles: [ServiceHandle] = []
                if ck == "dm", let other = conv?["user"]?.text, other != w.me { handles.append(handle(w, other)) }
                if ck == "group-dm" { for u in conv?["members"]?.array ?? [] { if let u = u.text, u != w.me { handles.append(handle(w, u)) } } }
                var senderHandle: ServiceHandle? = nil
                if !fromMe {
                    if let u = user, u != "USLACKBOT" || botID == nil { senderHandle = handle(w, u) }
                    else if let b = botID {
                        let botName = m["username"]?.text ?? m["bot_profile"]?["name"]?.text ?? w.bots[b]?["name"]?.text
                        senderHandle = handle(w, b, fallback: botName.map { "\($0) (Slack app)" } ?? "Slack app \(b)")
                    }
                    if let s = senderHandle, !handles.contains(where: { $0.normalized == s.normalized }) { handles.append(s) }
                }
                rec.participantHandles = handles
                rec.senderHandle = senderHandle
                for h in handles { people.insert(h.normalized) }
                let actor = fromMe ? "You" : (senderHandle?.raw ?? "Someone")
                var notes: [String] = []
                var kindOut = "message"
                switch subtype {
                case "channel_join", "group_join", "channel_leave", "group_leave":
                    let place = ck == "channel" || ck == "private-channel" ? "#" + (channelName(w, cid) ?? cid) : "the conversation"
                    let did = subtype.hasSuffix("join") ? "joined" : "left"
                    var line = "\(actor) \(did) \(place)"
                    if let inviter = m["inviter"]?.text { line += " (added by \(inviter == w.me ? "you" : (name(w, inviter) ?? inviter)))" }
                    rec.kind = "system"; rec.note = "Slack: " + line; kindOut = "system"; stats.system += 1
                case "bot_message":
                    let who = senderHandle?.raw ?? "a Slack app"
                    rec.kind = "system"; rec.note = "Slack app message from \(who): " + (text.isEmpty ? "(no text)" : text); kindOut = "bot"; stats.bot += 1
                case "", "thread_broadcast", "me_message", "reply_broadcast":
                    if !text.isEmpty { rec.body = text; stats.text += 1 }
                    else if m["room_id"]?.text != nil, (m["files"]?.array ?? []).isEmpty {
                        // A huddle (Slack's calls, 2021 on): the message has no text of its own, only the call's room.
                        rec.kind = "system"; rec.note = "Slack: \(actor) started a huddle"; kindOut = "system"; stats.system += 1
                    }
                    if subtype == "thread_broadcast" || subtype == "reply_broadcast" { notes.append("a thread reply also sent to the conversation") }
                default:
                    // Any other Slack event (topic, purpose, name, pins, invitations): a system line with Slack's own words.
                    rec.kind = "system"
                    rec.note = "Slack (\(subtype.replacingOccurrences(of: "_", with: " "))): " + (text.isEmpty ? "(no text)" : text)
                    kindOut = "system"; stats.system += 1
                }
                // Files: what each one was; the cache holds no file itself.
                var fileNotes: [String] = []
                for f in m["files"]?.array ?? [] {
                    let (id, fo) = fileObject(f, files: w.files)
                    fileNotes.append(fileNote(fo, id: id))
                }
                if !fileNotes.isEmpty {
                    stats.filesNoted += 1
                    notes.append(fileNotes.joined(separator: "; "))
                    if rec.body == nil && rec.kind == nil { rec.kind = "system"; kindOut = "file" }
                }
                if let p = parent, let pms = tsMs(p) {
                    stats.threadReplies += 1
                    notes.append("a reply in the thread of the message of \(iso.string(from: Date(timeIntervalSince1970: Double(pms) / 1000)))")
                }
                if !notes.isEmpty {
                    let joined = notes.joined(separator: " · ")
                    rec.note = rec.note.map { $0 + " · " + joined } ?? (rec.body == nil ? "(" + joined + ")" : joined)
                }
                if rec.body == nil && rec.note == nil { stats.leftOutEmpty += 1; log("left-out-empty"); continue }
                if edited { stats.edited += 1; if texts.count > 1 { stats.editedTextDiffers += 1 } }
                // Reactions, with who reacted (the copy in the newest save).
                for r in newest.reactions {
                    guard let nm = r["name"]?.text else { continue }
                    for u in r["users"]?.array ?? [] {
                        guard let u = u.text else { continue }
                        if u == w.me { rec.reactions.append(ReactionRecord(emoji: emojiText(nm), actor: nil, byMe: true)) }
                        else { let h = handle(w, u); people.insert(h.normalized); rec.reactions.append(ReactionRecord(emoji: emojiText(nm), actor: h, byMe: false)) }
                    }
                }
                stats.reactions += rec.reactions.count
                writer.threadKey = "slack:\(team):\(cid)"
                writer.threadKeyIsGroup = ck != "dm"
                _ = try writer.add(rec)
                stats.inserted += 1
                threadOf[writer.threadKey!] = (writer.lastThreadID, team, cid)
                log("new", written: writer.lastMessageID, thread: writer.lastThreadID, kind: kindOut, note: rec.note ?? "")
            }
            // Names of everyone seen (senders, group members, reactors).
            for n in people.sorted() {
                let p = n.split(separator: ":").map(String.init)            // slack:<team>:<uid>
                guard p.count == 3, let w = merged.workspaces[p[1]], let nm = name(w, p[2]) else { continue }
                try writer.noteName(service: handle(w, p[2]), name: nm, origin: "slack", priority: ContactPriority.androidXML)
            }
            stats.people = people.count
            // The threads this run created: service, kind, title and the conversation's id.
            let up = try db.prepare("UPDATE thread SET service = 'slack', origin = ?, title = coalesce(title, ?), external_id = coalesce(external_id, ?) WHERE id = ? AND id > ?")
            for (tkey, t) in threadOf.sorted(by: { $0.key < $1.key }) {
                let w = merged.workspaces[t.team]!
                let conv = w.channels[t.cid]
                let ck = convKind(conv)
                let ws = w.name ?? t.team
                var title: String
                switch ck {
                case "dm": title = (conv?["user"]?.text).flatMap { name(w, $0) } ?? "Slack DM \(t.cid)"
                case "group-dm":
                    let names = (conv?["members"]?.array ?? []).compactMap(\.text).filter { $0 != w.me }.map { name(w, $0) ?? $0 }
                    title = names.isEmpty ? (conv?["name"]?.text ?? t.cid) : names.joined(separator: ", ")
                default: title = "#" + (conv?["name"]?.text ?? t.cid)
                }
                title += " · \(ws) Slack"
                up.bind(1, ck == "group-dm" ? "group" : ck).bind(2, title).bind(3, tkey).bind(4, t.thread).bind(5, threadsBefore)
                try up.run()
                stats.threads += 1
            }
            let st = try db.prepare("UPDATE source SET stats_json = ? WHERE id = ?")
            st.bind(1, String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)).bind(2, sid)
            try st.run()
            try ImportLedger.save(db, sourceID: sid, body: out.joined(separator: "\n") + "\n")
            report = SlackImportReport(status: .imported, sourceID: sid, stats: stats)
        }
        if let ledger, let body = try ImportLedger.load(db, sourceID: report.sourceID) { try ImportLedger.publish(body, to: ledger) }
        return report
    }

    /// One line per distinct message (newest copy), for comparing this reader with Node's `v8.deserialize` on the same saves:
    /// team, conversation, ts, user or bot id, subtype, sha256 of the text, edited ts, thread ts, file ids, reactions, copies, save.
    public static func extractListing(at dir: URL) throws -> String {
        let merged = try merge(try blobFiles(in: dir))
        var lines: [String] = []
        for (k, copies) in merged.copies {
            let c = copies.max { $0.save < $1.save }!
            let m = c.message
            let files = (m["files"]?.array ?? []).map { $0.text ?? $0["id"]?.text ?? "?" }.joined(separator: ",")
            let rx = c.reactions.map { r in (r["name"]?.text ?? "") + "=" + (r["users"]?.array ?? []).compactMap(\.text).joined(separator: "+") }.joined(separator: ";")
            lines.append([k.replacingOccurrences(of: "|", with: "\t"), m["user"]?.text ?? m["bot_id"]?.text ?? "", m["subtype"]?.text ?? "",
                          Data((m["text"]?.string ?? "").utf8).withUnsafeBytes { Hashing.sha256Hex($0) }, m["edited"]?["ts"]?.text ?? "", m["thread_ts"]?.text ?? "",
                          files, rx, "\(copies.count)", merged.saves[c.save].file].joined(separator: "\t"))
        }
        let readable = merged.saves.filter { $0.state != nil && $0.error == nil }.count
        return "# saves \(merged.saves.count), readable \(readable)\n" + lines.sorted().joined(separator: "\n") + "\n"
    }
}
