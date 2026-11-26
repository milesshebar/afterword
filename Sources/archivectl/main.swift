import Foundation
import ArchiveCore

setvbuf(stdout, nil, _IOLBF, 0)

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let usage = """
archivectl: \(Product.name) command line

usage: archivectl [--archive <dir>] <command> [options]

commands:
  import [--origin <label>] [--me <name>] [--fb-zone <IANA zone>] [--until <YYYY-MM-DD>] [--since <YYYY-MM-DD>] [--skip-known] [--add-only] [--hold <file>] [--ledger <file>] [--attachments <dir>] <path...>
                                        import SMS Backup & Restore XML exports, unencrypted iPhone backup folders, and Meta
                                        "Download your information" HTML exports (Facebook Messenger, Instagram; the export's
                                        root folder, detected by your_facebook_activity/ or your_instagram_activity/).
                                        A folder with Manifest.db / Manifest.mbdb is a backup; another folder is searched
                                        for sms-*.xml, backup folders and Meta exports one level down.
                                        A GroupMe account-data export (unzipped: profile/profile.json plus one folder per
                                        conversation) is detected the same way; unzip the .zip into an empty folder first.
                                        --me names you in a Meta export when it cannot be detected
                                        --fb-zone <zone> (e.g. America/New_York) reads a Facebook export's times in that zone with DST instead of the page
                                        header's fixed offset (some exports state UTC-05:00 in the header but print every time in Eastern with DST)
                                        A Messages chat.db snapshot (sqlite3 ~/Library/Messages/chat.db ".backup <copy>") is detected by its
                                        tables; --until YYYY-MM-DD (inclusive, local time or $\(LocalZone.environmentKey)) is the cutoff, and a later run with a later
                                        cutoff adds only what came after; --attachments <dir> (default ~/Library/Messages/Attachments)
                                        --since YYYY-MM-DD replaces the automatic resume point (a snapshot from another Mac); --skip-known
                                        counts rows whose guid the archive already holds (any source) instead of storing linked copies;
                                        --add-only (chat.db; implies --skip-known) changes no row that existed before: a row matching an
                                        existing one is held, not linked; tapbacks only on rows this run wrote; titles only on new threads;
                                        --hold <file> leaves out the guids listed (one per line); --ledger <file> writes one TSV line per row
                                        A decrypted extract (a folder holding HomeDomain/Library/SMS/sms.db, as written by scripts/iphone-backup-stage.py
                                        under extracted/sms/) imports like a backup folder, attachments resolved from the same tree
                                        An unzipped Snapchat "My Data" export (json/chat_history.json + friends.json, chat_media/) is detected the same way:
                                        saved chats as service snapchat; friends.json dates go to the additive contact_date table
                                        A Skype 5 for Mac `main.db` (Application Support/Skype/<account>/main.db) is detected by its tables: text, emotes,
                                        contact-request text and file-transfer lines become messages; call and membership events are counted, not stored
                                        A WhatsApp `ChatStorage.sqlite` (iPhone backup, AppDomainGroup-group.net.whatsapp.WhatsApp.shared) is detected by its tables; its
                                        files are stored when `Message/Media` sits beside it or `--attachments <the shared container folder>` is given
                                        A Last.fm pull folder (scripts/lastfm-pull.py: pull.json + page-*.json, optional loves.json) imports
                                        scrobbles into the `listen` table (idempotent: a rerun or an overlapping later pull adds only new ones)
  iphone-contacts [--label <name>] <AddressBook.sqlitedb or extracted/addressbook>
                                        store the AddressBook's names for handles already in the archive (never creates handles)
  calendar-import [--label <name>] [--origin <where the file lives>] [--skip-calendar <title>]... <Calendar.sqlitedb or extracted/calendar, or a Mac's Calendar Cache snapshot>   events into the additive
                                        calendar_event table (a Mac cache: add-only, an event whose uid the table has is held)
  telegram-import --chat <ns:id>... [--origin <label>] [--hold <file>] [--ledger <file>] <db_sqlite>   Telegram for macOS (Postbox) chats, add-only:
                                        one thread per chosen chat; every row of the store gets a ledger line
  slack-import [--origin <label>] [--hold <file>] [--workspace <team id>]... [--ledger <file>] <IndexedDB folder>   Slack desktop's cached state
                                        (Redux saves, 2020 on), add-only: one thread per conversation, each message by its own ts; every
                                        message gets a ledger line. --workspace names the workspaces to import (default: every one)
  slack-files-plan <cache entries folder> <IndexedDB folder> <plan.tsv>   Slack's cached files tied to the slack-cache messages by file id
                                        (full file, else the largest thumbnail); writes the plan only
  slack-files-extract --plan <plan.tsv> <cache entries folder> <out folder> <ledger.tsv> <copy-list.tsv>   each planned body as a file
  slack-files-attach --plan <plan.tsv> [--ledger <file>] [--origin <label>]   attach the planned files already in the media store
  slack-listing <IndexedDB folder>      one line per cached message (ids, sha256 of the text), to compare with another reader; writes nothing
  ichat-import [--origin <label>] [--hold <file>] [--mark <file>] [--ledger <file>] <folder>   saved Messages / iChat transcripts (.ichat; AIM too), add-only:
                                        held by guid, placed in the thread their held messages sit in or a 1:1 with one other party
  notes-import [--label <name>] [--origin <where the file lives>] <NoteStore.sqlite or extracted/notes, or a Mac's NotesV7.storedata snapshot>   Notes (text bodies) into the
                                        additive note table; private, counts only (NotesV7: add-only, held by uid, title+created or text)
  fb-dyi-2011-import [--dry-run] [--zone <IANA|UTC±hh:mm>] [--origin <label>] [--me <name>] [--ledger <file.tsv>] [--allow-unverified-file] <export root>
                                        CHECKED AGAINST ONE REAL EXPORT ONLY: runs only with --allow-unverified-file (try --dry-run first)
                                        the 2011 Facebook "Download Your Information" export (html/messages.html): only the messages the
                                        archive lacks (held = same direction, same text, within 90 s), at the printed minute read in --zone
                                        (default this machine's zone; compare dry runs with a named zone and a fixed offset such as UTC-04:00)
  posts-import [--dry-run] [--ledger <file.tsv>] <records.jsonl>
                                        Facebook / Instagram posts and comments from a records file written by scripts/posts_read.py into the
                                        additive post tables (post, post_comment, post_media, post_fts); held = already a row (same dkey, or
                                        another export's row by the overlap rule), left out = the reader's skips, ambiguous overlaps; one
                                        ledger row per record; people by fb:/ig: handles (new ones get no thread)
  posts-media [--dry-run] [--ledger <file.tsv>] [--photoprism-live <sha1-uid.tsv>] [--origin <label>] <plan.tsv>
                                        post photos and videos from a media plan into post_media: PhotoPrism links (uid + sha1, checked live
                                        against the list), files already in the media store, and files copied into it beforehand (every one
                                        re-hashed); any failed check refuses the whole plan; one ledger row per plan row. Advanced: you build the
                                        plan yourself (columns in Sources/ArchiveCore/PostsMedia.swift); PhotoPrism links are optional
  recordings-import [--dry-run] [--ledger <file.tsv>] [--transcripts <folder>] [--origin <label>] <recordings.tsv>
                                        voicemails and voice memos from a plan (recordings.tsv; columns in RecordingImporter.swift) into the additive tables
                                        recording, recording_transcript, recording_fts: every audio file must already be in the media store
                                        (each is re-hashed); transcripts are machine transcripts keyed by the audio's sha256; duplicates
                                        across sources are linked (canonical_id); any failed check refuses the whole plan
  recordings [--kind voicemail|memo|meeting] [--search <words>] [--limit N]
                                        counts, and the newest recordings or the ones matching the words (read-only)
  voice-messages-import [--dry-run] [--ledger <file.tsv>] --transcripts <folder> [--origin <label>] <voice-messages.tsv>
                                        machine transcripts of voice messages already on threads (attachments), from a plan written by
                                        a plan (voice-messages.tsv; columns in VoiceMessageImporter.swift): the transcript in recording_transcript keyed by the audio's sha256,
                                        a playable copy where browsers cannot play the file, voice_message and voice_message_fts; no
                                        message or attachment changes; every file re-hashed; any failed check refuses the whole plan
  calls-import <folder or calls.tsv>    build/extend the call table from calls.tsv + sources.tsv (columns in CallImporter.swift), then add the Messenger/Instagram/GroupMe
                                        call lines already in the archive; rows are never dropped, overlapping logs are linked (canonical_id), gaps recorded (call_gap);
                                        which log wins follows its label (CallImporter.priority, or a file in $\(SourcePriority.environmentKey))
  groupme-media <folder>                attach GroupMe images/videos fetched from their URLs (a folder with results.jsonl and the files, left by a
                                        downloader you run yourself; format in README.md, "GroupMe media"): stored content-addressed, the URL kept as the attachment name, the URL line removed from the body
  attachments-plan [--notes <file>] <input.tsv> <plan.tsv>   name each staged attachment's media path (MediaStore's rule) and its target (the canonical row)
  attachments-backfill --plan <plan.tsv> [--ledger <file>]   attach files already copied into the media store (every file re-hashed first)
  attachments-backfill [--dry-run] <staging folder>
                                        attach recovered Messages attachments by message guid from a staging folder (map.tsv + files/<guid>/),
                                        each checked against its SHA-256, and take their names out of the "offloaded to iCloud" note
  contacts [--dry-run] [--label macos-contacts-<date>] [<AddressBook Sources folder>]
                                        store names from the Mac's Contacts (default ~/Library/Application Support/AddressBook/Sources;
                                        each store is copied with its WAL and only the copy is read) for handles already in the archive,
                                        matched by E.164 phone and lowercased email; replaces any earlier macos-contacts names (refresh)
  ig-usernames [--dry-run] <export root>
                                        (re)compute the real Instagram usernames for the Instagram handles already in the archive, from
                                        the export's follower/following lists and story links; no messages are re-imported and handle
                                        identity never changes. "high" shows as @user, "low" only as "possible @user". Prints counts only.
                                        Also runs at the end of every Instagram import. --dry-run stores nothing.
  posts [--person <id> | --handle <fb:name...> | --mine] [--day YYYY-MM-DD] [--search <words> [--order best|newest|oldest]] [--limit 1-100000] [--expand]
                                        Facebook / Instagram posts and comments (prints their text): a person's (theirs, on their timeline,
                                        comments on their posts), the owner's own (by_me), one day's (local midnight to midnight), a search; the
                                        filters combine; newest first; album photos of one album and one day are one line unless --expand
  people [list] [--names] [--ambiguous] [--limit <n>]
                                        the by-person grouping: counts by default (no names printed); --names lists multi-handle people,
                                        --ambiguous lists names shared by two different people (left unlinked)
  people show <id>                      one person's handles, services and corrections (prints names and numbers)
  people match                          re-run the automatic matching (an import does this too); manual corrections are untouched
  people merge <id> <id>...             make people one          people split <id> <handle-id>...   take handles out as a new person
  people rename <id> <name...>          name a person (no name clears it)      people hide <id> | unhide <id> | reset <id>
                                        ids come from `people list --names`; corrections live in people.sqlite in the archive root
  serve [--port 8097] [--allow-host <name> --allow-login <login>]
                                        the review site: a mobile-first page on 127.0.0.1 for merging people across Messenger/Instagram and
                                        texts. Suggestions are never applied on their own; decisions go to people.sqlite (undo included).
                                        Bound to loopback only; put `tailscale serve` in front for the phone. Reads archive.sqlite read-only.
  serve-web [--port 8452] [--bind 127.0.0.1] [--web <dir>] [--cache <dir>] [--allow-host <name>] [--allow-login <login>]
            [--allow-peer <ip|prefix.>] [--any-peer] [--key-env ARCHIVE_WEB_KEY]
                                        the read-only web app (people, timelines, search, media with HTTP Range, thumbnails) over this
                                        archive: JSON API under /api/, the static page from <dir> (default: web/ beside the binary).
                                        Loopback unless --bind; any proxy in front must be matched by --allow-host plus --allow-login
                                        (tailscale serve) or the shared key read from $ARCHIVE_WEB_KEY (the proxy adds X-Archive-Key).
  suggest [--limit <n>]                 the review queues as counts and score distribution only (no names)
  suggest --cards                       every open card as JSON, WITH names (private, local use only)
  stats                                 counts by source, year and service; threads; media bytes
  verify                                integrity checks: sqlite, foreign keys, FTS, media files, relative paths
  where                                 print the resolved archive root
  demo-seed <dir> [--scale <x>]         write a clearly fake demo archive into an empty folder (31,000-message thread at
                                        scale 1; fake people, 555-01xx numbers, generated pictures) for QA and --snapshot
  relink                                fold canonical Android rows under the iPhone row they copy when the texts differ only by emoji
                                        (applies the import-time rule to rows already stored; idempotent)
  reclassify [--dry-run]                apply the importers' newer rules to rows already stored, no re-import: Instagram's Burmese system
                                        lines become English system / call notes, and Apple tapbacks received as text ("Loved “…”")
                                        become reactions on the message they quote (the text row is hidden, body kept). Idempotent,
                                        one transaction. Back up archive.sqlite first (sqlite3 .backup). --dry-run changes nothing.
  prepare-move                          fold the WAL into archive.sqlite and switch to the rollback journal, so the archive
                                        folder can be copied as plain files (for example to a NAS) and opened read-only there

archive root: --archive <dir>, else $\(ArchiveRoot.environmentKey), else ~/Library/Application Support/\(Product.supportFolder)
"""

var args = Array(CommandLine.arguments.dropFirst())
var archiveFlag: String?
if let i = args.firstIndex(of: "--archive") {
    guard i + 1 < args.count else { eprint("--archive needs a directory"); exit(2) }
    archiveFlag = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
guard let command = args.first else { print(usage); exit(2) }
args.removeFirst()
let root = ArchiveRoot.resolve(flag: archiveFlag)

func fmtBytes(_ b: Int64) -> String {
    let u = ["B", "KB", "MB", "GB", "TB"]; var v = Double(b); var i = 0
    while v >= 1024, i < u.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(b) B" : String(format: "%.1f", v) + " " + u[i]
}

func printUsernameReport(_ r: InstagramUsernames.Report, prefix: String = "") {
    let named = r.high + r.low + r.none
    let own = r.selfUsername ? "" : " (own username not found)"
    let methods = r.byMethod.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    print("\(prefix)Instagram usernames: \(r.high) high, \(r.low) low, \(r.none) none of \(named) named handles (+\(r.placeholders) deleted accounts, no identity); pool \(r.poolUsernames) usernames\(own)")
    print("\(prefix)  by method: \(methods)   story conflicts flagged \(r.storyConflicts); dropped: \(r.duplicateHighDropped) duplicate-high, \(r.lowDroppedForHigh) low shadowed by a high")
    print("\(prefix)  " + (r.written ? "stored; folder-slug aliases removed: \(r.legacyAliasesRemoved)" : "dry run, nothing stored (\(r.legacyAliasesRemoved) folder-slug aliases would be removed)"))
}

enum ImportInput {
    case xml(URL), backup(URL), meta(URL, MetaService), groupme(URL), chatdb(URL), lastfm(URL), skype(URL), whatsapp(URL), snapchat(URL)
    var name: String { switch self { case .xml(let u), .backup(let u), .meta(let u, _), .groupme(let u), .chatdb(let u), .lastfm(let u), .skype(let u), .whatsapp(let u), .snapchat(let u): return u.lastPathComponent } }
}

func expandInputs(_ paths: [String]) -> [ImportInput] {
    var out: [ImportInput] = []
    for p in paths {
        let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
            if IOSBackupImporter.isBackupFolder(u) { out.append(.backup(u)); continue }
            if SnapchatImporter.detect(u) { out.append(.snapchat(u)); continue }
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("HomeDomain/Library/SMS/sms.db").path) { out.append(.backup(u)); continue }   // a decrypted extract
            if LastfmImporter.isPullFolder(u) { out.append(.lastfm(u)); continue }
            let gms = GroupMeImporter.detectAll(u)
            if !gms.isEmpty { out += gms.map { .groupme($0) }; continue }
            let metas = MetaImporter.detectAll(u)
            if !metas.isEmpty { out += metas.map { .meta($0.root, $0.service) }; continue }
            let items = ((try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            out += items.filter { $0.pathExtension.lowercased() == "xml" && $0.lastPathComponent.hasPrefix("sms-") }.map { .xml($0) }
            out += items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && IOSBackupImporter.isBackupFolder($0) }
                        .map { .backup($0) }
        } else if MacChatDBImporter.isChatDB(u) { out.append(.chatdb(u)) }
        else if SkypeImporter.isSkypeDB(u) { out.append(.skype(u)) }
        else if WhatsAppImporter.isChatStorage(u) { out.append(.whatsapp(u)) }
        else { out.append(.xml(u)) }
    }
    return out
}

do {
    switch command {
    case "where":
        print(root.url.path)

    case "import":
        var origin: String?
        if let i = args.firstIndex(of: "--origin") {
            guard i + 1 < args.count else { eprint("--origin needs a label"); exit(2) }
            origin = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        var me: String?
        if let i = args.firstIndex(of: "--me") {
            guard i + 1 < args.count else { eprint("--me needs a display name"); exit(2) }
            me = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        var fbZone: String?
        if let i = args.firstIndex(of: "--fb-zone") {
            guard i + 1 < args.count, TimeZone(identifier: args[i + 1]) != nil else { eprint("--fb-zone needs an IANA zone name such as America/New_York"); exit(2) }
            fbZone = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        var until: String?
        if let i = args.firstIndex(of: "--until") {
            guard i + 1 < args.count else { eprint("--until needs YYYY-MM-DD"); exit(2) }
            until = args[i + 1]
            _ = try MacChatDBImporter.endOfDayMs(until!)
            args.removeSubrange(i...(i + 1))
        }
        var since: String?
        if let i = args.firstIndex(of: "--since") {
            guard i + 1 < args.count else { eprint("--since needs YYYY-MM-DD"); exit(2) }
            since = args[i + 1]
            _ = try MacChatDBImporter.startOfDayMs(since!)
            args.removeSubrange(i...(i + 1))
        }
        var skipKnown = false
        if let i = args.firstIndex(of: "--skip-known") { skipKnown = true; args.remove(at: i) }
        var addOnly = false
        if let i = args.firstIndex(of: "--add-only") { addOnly = true; args.remove(at: i) }
        var holdKeys = Set<String>()
        if let i = args.firstIndex(of: "--hold") {
            guard i + 1 < args.count else { eprint("--hold needs a file of guids"); exit(2) }
            let text = try String(contentsOfFile: (args[i + 1] as NSString).expandingTildeInPath, encoding: .utf8)
            for l in text.split(whereSeparator: \.isNewline) {
                let g = l.trimmingCharacters(in: .whitespaces)
                if g.isEmpty || g.hasPrefix("#") { continue }
                holdKeys.insert(g.hasPrefix("ios:") ? g : "ios:" + g)
            }
            args.removeSubrange(i...(i + 1))
        }
        var ledgerURL: URL?
        if let i = args.firstIndex(of: "--ledger") {
            guard i + 1 < args.count else { eprint("--ledger needs a file"); exit(2) }
            ledgerURL = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
            args.removeSubrange(i...(i + 1))
        }
        var attachmentsRoot = MacChatDBImporter.defaultAttachmentsRoot
        var whatsappMedia: URL?
        if let i = args.firstIndex(of: "--attachments") {
            guard i + 1 < args.count else { eprint("--attachments needs a folder"); exit(2) }
            attachmentsRoot = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
            whatsappMedia = attachmentsRoot
            args.removeSubrange(i...(i + 1))
        }
        let files = expandInputs(args)
        if files.isEmpty { eprint("nothing to import\n\n" + usage); exit(2) }
        if origin != nil, files.count > 1 { eprint("--origin applies to a single file or backup"); exit(2) }
        if addOnly || !holdKeys.isEmpty || ledgerURL != nil {
            guard files.count == 1, case .chatdb = files[0] else { eprint("--add-only, --hold and --ledger apply to a single chat.db snapshot"); exit(2) }
        }
        let db = try Schema.openArchive(root: root)
        print("archive: \(root.url.path)")
        var failed = false
        for input in files {
            let started = Date()
            func secs() -> String { String(format: "%.1f", Date().timeIntervalSince(started)) }
            func pct(_ p: ImportProgress) -> Int { p.totalBytes > 0 ? Int(Double(p.bytesRead) / Double(p.totalBytes) * 100) : 0 }
            do {
                switch input {
                case .meta(let f, let service):
                    let rep = try MetaImporter.importExport(at: f, service: service, into: db, root: root, options: { var o = MetaImportOptions(me: me); o.facebookZone = fbZone; return o }(), origin: origin) { p in
                        if p.foldersDone % 50 == 0 || p.foldersDone == p.foldersTotal { eprint("  \(p.foldersDone)/\(p.foldersTotal) threads  \(p.messages) messages") }
                    }
                    let s = rep.stats
                    if rep.status == .alreadyImported {
                        print("\(f.lastPathComponent): \(service.label) export already imported, skipped")
                        break
                    }
                    func day(_ ms: Int64?) -> String { ms.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1000)).prefix(10).description } ?? "-" }
                    print("""
                    \(f.lastPathComponent): \(service.label) export imported in \(secs()) s (you are "\(rep.me ?? "?")")
                      thread folders \(s.threadFolders): imported \(s.foldersImported), already there \(s.foldersSkipped)   by origin \(s.foldersByOrigin.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                      pages \(s.files)   message blocks \(s.blocks)   new rows \(s.inserted) (by origin \(s.messagesByOrigin.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))   duplicates (linked, kept) \(s.duplicates)
                      system \(s.system)   calls \(s.calls)   unsent \(s.unsent)   reactions \(s.reactions)   emoji-only \(s.emojiOnly)   repeated across pages \(s.repeatedAcrossFiles)
                      skipped     empty \(s.emptySkipped)   bad date \(s.badDate)   unattributed sender \(s.unattributed)   order inversions \(s.inversions)
                      attachments \(s.attachments)   missing \(s.mediaMissing)   payload \(fmtBytes(Int64(s.mediaBytes)))   newly stored \(s.mediaNewFiles) files / \(fmtBytes(Int64(s.mediaNewBytes)))
                      dates       \(day(s.firstTsMs)) -> \(day(s.lastTsMs))   hidden-by-default threads \(s.hiddenThreads)
                    """)
                    if let ur = rep.usernames { printUsernameReport(ur, prefix: "  ") }
                    if let ue = rep.usernameError { eprint("  Instagram usernames FAILED: \(ue)") }

                case .groupme(let f):
                    let rep = try GroupMeImporter.importExport(at: f, into: db, root: root, origin: origin) { done, total, msgs in
                        eprint("  \(done)/\(total) conversations  \(msgs) messages")
                    }
                    let s = rep.stats
                    if rep.status == .alreadyImported { print("\(f.lastPathComponent): GroupMe export already imported, skipped"); break }
                    func day(_ ms: Int64?) -> String { ms.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1000)).prefix(10).description } ?? "-" }
                    print("""
                    \(f.lastPathComponent): GroupMe export imported in \(secs()) s (you are "\(rep.meName ?? "?")", user \(rep.meID ?? "?"))
                      conversations \(s.conversations) (\(s.groups) groups, \(s.dms) DMs): imported \(s.foldersImported), already there \(s.foldersSkipped)
                      parsed \(s.parsed) messages   new rows \(s.inserted)   duplicates (linked, kept) \(s.duplicates)   system \(s.system)   likes (reactions) \(s.reactions)   empty skipped \(s.emptySkipped)
                      images stored \(s.attachmentsStored) (\(fmtBytes(Int64(s.mediaBytes))))   remote image/video links kept \(s.remoteLinks)   polls \(s.polls)   file attachments not in export \(s.filesMissing)   emoji-pack placeholders removed \(s.emojiPlaceholders)
                      dates       \(day(s.firstTsMs)) -> \(day(s.lastTsMs))
                    """)
                case .skype(let f):
                    let rep = try SkypeImporter.importDB(at: f, into: db, root: root, origin: origin)
                    let s = rep.stats
                    if rep.status == .alreadyImported { print("\(f.lastPathComponent): Skype database already imported, skipped"); break }
                    func day(_ ms: Int64?) -> String { ms.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1000)).prefix(10).description } ?? "-" }
                    print("""
                    \(f.lastPathComponent): Skype database imported in \(secs()) s (account \(rep.account ?? "?"))
                      parsed \(s.parsed) rows = \(s.textMessages) text + \(s.emotes) emotes + \(s.contactRequests) contact requests + \(s.fileTransfers) file transfers + \(s.eventsSkipped) events (not stored: \(s.eventsByType.sorted { Int($0.key)! < Int($1.key)! }.map { "type \($0.key) x\($0.value)" }.joined(separator: ", ")))
                      new rows \(s.inserted)   duplicates (linked, kept) \(s.duplicates)   empty skipped \(s.emptySkipped)   no chat \(s.noChatSkipped)
                      chats \(s.chats) (\(s.groups) groups, \(s.dms) 1:1)   people \(s.people)   smileys kept \(s.smileysKept)   links kept \(s.linksKept)
                      dates \(day(s.firstTsMs)) -> \(day(s.lastTsMs))
                    """)
                case .whatsapp(let f):
                    // The folder with Message/Media/... (the WhatsApp shared container root); none given = files are not stored.
                    let media: URL? = whatsappMedia ?? {
                        let c = f.deletingLastPathComponent()
                        return FileManager.default.fileExists(atPath: c.appendingPathComponent("Message/Media").path) ? c : nil
                    }()
                    let rep = try WhatsAppImporter.importChatStorage(at: f, into: db, root: root, attachments: media, origin: origin)
                    let s = rep.stats
                    if rep.status == .alreadyImported { print("\(f.lastPathComponent): WhatsApp ChatStorage already imported, skipped"); break }
                    func day(_ ms: Int64?) -> String { ms.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1000)).prefix(10).description } ?? "-" }
                    print("""
                    \(f.lastPathComponent): WhatsApp ChatStorage imported in \(secs()) s (your JID \(s.meJID ?? "?"), media from \(media?.path ?? "nowhere"))
                      parsed \(s.parsed) messages = new \(s.inserted) + duplicates (linked, kept) \(s.duplicates) + not in a 1:1/group chat \(s.otherChatsSkipped) + events (no text, no media) \(s.eventsSkipped) + empty \(s.emptySkipped)
                      kinds       text \(s.text)   links \(s.links)   media \(s.media) (files stored \(s.attachmentsStored), not in the backup \(s.mediaMissing))   contacts \(s.contacts)   locations \(s.locations)   deleted \(s.unsent)
                      events      \(s.eventsByType.sorted { Int($0.key)! < Int($1.key)! }.map { "type \($0.key) x\($0.value)" }.joined(separator: ", "))
                      chats \(s.chats) (\(s.groups) groups, \(s.dms) 1:1)   people \(s.people)   media payload \(fmtBytes(Int64(s.mediaBytes)))   newly stored \(s.mediaNewFiles) files / \(fmtBytes(Int64(s.mediaNewBytes)))
                      dates \(day(s.firstTsMs)) -> \(day(s.lastTsMs))
                    """)
                case .snapchat(let f):
                    let rep = try SnapchatImporter.importExport(at: f, into: db, root: root, origin: origin)
                    let s = rep.stats
                    if rep.status == .alreadyImported { print("\(f.lastPathComponent): Snapchat export already imported, skipped"); break }
                    func day(_ ms: Int64?) -> String { ms.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1000)).prefix(10).description } ?? "-" }
                    print("""
                    \(f.lastPathComponent): Snapchat export imported in \(secs()) s (you are \(s.me ?? "?"))
                      threads \(s.threads) (\(s.groups) groups, \(s.dms) 1:1)   parsed \(s.parsed) messages = new \(s.inserted) + duplicates \(s.duplicates) + empty \(s.emptySkipped)
                      kinds       text \(s.text)   media \(s.media) (files stored \(s.attachmentsStored), not in the export \(s.mediaMissing))   stickers \(s.stickers)   shares \(s.shares)
                      people \(s.people)   by year: \(s.byYear.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))   dates \(day(s.firstTsMs)) -> \(day(s.lastTsMs))
                      friend dates (contact_date): \(s.friendDates.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                    """)
                case .chatdb(let f):
                    let rep = try MacChatDBImporter.importChatDB(at: f, into: db, root: root, until: until, since: since, skipKnown: skipKnown, attachmentsRoot: attachmentsRoot, origin: origin,
                                                                 addOnly: addOnly, holdKeys: holdKeys, ledger: ledgerURL) { p in
                        eprint("  \(pct(p))%  \(p.messages) rows")
                    }
                    let s = rep.stats
                    if rep.status == .alreadyImported {
                        print("\(f.lastPathComponent): chat.db already imported with this cutoff (sha256 \(rep.sha256.prefix(12)), until \(until ?? "all")), skipped")
                        break
                    }
                    print("""
                    \(f.lastPathComponent): macOS chat.db (sha256 \(rep.sha256.prefix(12))) imported in \(secs()) s, \(s.since.map { "since \($0), " } ?? "")until \(s.until ?? "all") (\(LocalZone.current().identifier), inclusive)
                      parsed      \(s.messagesParsed) rows   after the cutoff \(s.afterCutoff)   covered by an earlier chat.db import \(s.coveredEarlier)   guid already in the archive (--skip-known) \(s.knownElsewhere)
                      new rows    \(s.inserted)   duplicates of other sources (linked, kept) \(s.duplicates) (by guid \(s.guidMatches), by content \(s.duplicates - s.guidMatches))
                      reactions   imported \(s.reactionsImported)   already there \(s.reactionsAlreadyThere)   skipped \(s.reactionsSkipped)   unsent \(s.unsent)   edited \(s.edited)
                      skipped     empty/system \(s.emptySkipped)   no chat or handle \(s.orphansSkipped)   bad date/guid \(s.invalidSkipped)
                      attachments referenced \(s.attachmentsReferenced)   stored \(s.attachmentsStored)   missing (offloaded) \(s.attachmentsMissing)   messages with the offloaded note \(s.offloadedNotes)
                      media       payload \(fmtBytes(Int64(s.mediaBytes)))   newly stored \(s.mediaNewFiles) files / \(fmtBytes(Int64(s.mediaNewBytes)))
                      groups      \(s.groupChats) group chats   \(s.groupTitles) threads titled from the chat name
                    """)
                    if s.addOnly == true {
                        print("  add-only    held (matches an existing row) \(s.heldMatches)   left out by --hold \(s.heldByList)   tapbacks on old rows left out \(s.reactionsOnOldRowsLeftOut)")
                    }
                case .lastfm(let f):
                    let s = try LastfmImporter.importPull(at: f, into: db)
                    func day(_ ms: Int64?) -> String { ms.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1000)).prefix(10).description } ?? "-" }
                    print("""
                    \(f.lastPathComponent): Last.fm scrobbles of \(s.user) imported in \(secs()) s (\(s.pages) pages)
                      parsed \(s.parsed)   new \(s.inserted)   already there \(s.alreadyThere)   now-playing skipped \(s.nowPlayingSkipped)   undated \(s.undated)
                      Last.fm reported: \(s.reportedTotal) in the pulled window, playcount \(s.reportedPlaycount) at pull time
                      loved: \(s.lovedFromAPI) scrobbles flagged by the API; loves list \(s.lovesInFile) (\(s.lovesMatched) matched a scrobble); rows marked loved \(s.rowsMarkedLoved)
                      dates \(day(s.firstTsMs)) -> \(day(s.lastTsMs))
                    """)
                case .backup(let f):
                    let progress: (ImportProgress) -> Void = { p in eprint("  \(pct(p))%  \(p.messages) messages") }
                    let rep = IOSBackupImporter.isBackupFolder(f)
                        ? try IOSBackupImporter.importBackup(at: f, into: db, root: root, origin: origin, progress: progress)
                        : try IOSBackupImporter.importExtractedTree(sms: f, into: db, root: root, origin: origin, progress: progress)
                    let s = rep.stats
                    if rep.status == .alreadyImported {
                        print("\(f.lastPathComponent): already imported (sms.db sha256 \(rep.sha256.prefix(12))), skipped")
                        break
                    }
                    print("""
                    \(f.lastPathComponent): iPhone backup (\(s.schema) schema, manifest \(s.manifestFormat)) imported in \(secs()) s
                      parsed      \(s.messagesParsed) messages
                      new rows    \(s.inserted)   duplicates of other sources (linked, kept) \(s.duplicates)
                      skipped     reactions \(s.reactionsSkipped)   empty/system \(s.emptySkipped)   no chat or handle \(s.orphansSkipped)   bad date \(s.invalidSkipped)   group-send copies folded \(s.groupSendCollapsed)
                      attachments referenced \(s.attachmentsReferenced)   in manifest \(s.attachmentsInManifest)   inline \(s.attachmentsInline)   stored \(s.attachmentsStored)   missing \(s.attachmentsMissing)
                      media       payload \(fmtBytes(Int64(s.mediaBytes)))   newly stored \(s.mediaNewFiles) files / \(fmtBytes(Int64(s.mediaNewBytes)))
                      contacts    \(s.contactPeople) people, \(s.contactNames) numbers/emails\(s.contactsNote.map { " (\($0))" } ?? "")
                    """)
                case .xml(let f):
                    let rep = try AndroidSMSImporter.importFile(at: f, into: db, root: root, origin: origin) { p in
                        eprint("  \(pct(p))%  \(p.messages) messages")
                    }
                    let s = rep.stats
                    switch rep.status {
                    case .alreadyImported:
                        print("\(f.lastPathComponent): already imported (sha256 \(rep.sha256.prefix(12))), skipped")
                    case .imported:
                        print("""
                        \(f.lastPathComponent): imported in \(secs()) s
                          parsed      \(s.smsParsed) sms + \(s.mmsParsed) mms = \(s.messagesParsed)
                          new rows    \(s.inserted)   duplicates (linked, kept) \(s.duplicates)   skipped invalid \(s.skippedInvalid)
                          attachments \(s.attachments)   payload \(fmtBytes(Int64(s.mediaBytes)))   newly stored \(s.mediaNewFiles) files / \(fmtBytes(Int64(s.mediaNewBytes)))
                          smil parts skipped \(s.smilParts)
                        """)
                    }
                }
            } catch {
                failed = true
                eprint("\(input.name): FAILED: \(error)")
            }
        }
        // Re-run the automatic person matching over what is now in the archive (corrections in people.sqlite are untouched).
        if let r = try? PeopleStore.rematch(db: db) {
            print("people: \(r.persons) (\(r.linkedPersons) matched across \(r.linkedHandles) handles, \(r.ambiguousNames) ambiguous names left unlinked)")
        }
        // Fold the WAL back into the main file so a large import never leaves gigabytes of log behind.
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        exit(failed ? 1 : 0)

    case "ig-usernames":
        let dry = args.contains("--dry-run")
        args.removeAll { $0 == "--dry-run" }
        guard let path = args.first else { eprint("ig-usernames needs the Instagram export folder\n\n" + usage); exit(2) }
        let u = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let export = MetaImporter.detectAll(u).first(where: { $0.service == .instagram }) else {
            eprint("no Instagram export (your_instagram_activity/messages) at \(path)"); exit(2)
        }
        let db = try Schema.openArchive(root: root, readOnly: dry)      // a dry run opens read-only: it never migrates the archive
        let r = try InstagramUsernames.apply(exportRoot: export.root, into: db, write: !dry)
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        print("archive: \(root.url.path)")
        printUsernameReport(r)

    case "people":
        try runPeople(args: args, root: root)

    case "posts":
        try runPosts(args: args, root: root)

    case "serve":
        try runServe(args: args, root: root)

    case "serve-web":
        try runServeWeb(args: args, root: root)
    case "suggest":
        try runSuggest(args: args, root: root)

    case "stats":
        let db = try Schema.openArchive(root: root, readOnly: true)
        let s = try ArchiveStats.collect(db: db)
        print("archive: \(root.url.path)")
        print("sources: \(s.sources.count)")
        if s.sources.count <= 40 {
            for r in s.sources { print("  #\(r.id) \(r.kind)  \(r.path)  rows \(r.messages)  duplicates \(r.duplicates)") }
        } else {
            // a Meta import has one source per thread folder: summarize by kind
            var byKind: [String: (n: Int, rows: Int, dups: Int)] = [:]
            for r in s.sources { var e = byKind[r.kind] ?? (0, 0, 0); e.n += 1; e.rows += r.messages; e.dups += r.duplicates; byKind[r.kind] = e }
            for (k, e) in byKind.sorted(by: { $0.key < $1.key }) { print("  \(k)  \(e.n) sources  rows \(e.rows)  duplicates \(e.dups)") }
        }
        print("messages: \(s.totalRows) rows, \(s.canonicalRows) canonical (\(s.totalRows - s.canonicalRows) duplicates)")
        print("by service (canonical): " + s.byService.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
        print("by year (canonical):")
        for (y, n) in s.byYear { print("  \(y)  \(n)") }
        print("threads: \(s.threads) (\(s.groupThreads) group)   handles: \(s.handles)")
        if let l = try LastfmImporter.summary(db) {
            func day(_ ms: Int64?) -> String { ms.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1000)).prefix(10).description } ?? "-" }
            print("listens: \(l.rows) (lastfm; \(l.loved) loved; \(l.undated) undated: Last.fm keeps no time for them) \(day(l.first)) -> \(day(l.last)); by year " + l.byYear.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
        }
        if let c = try CalendarImporter.summary(db) {
            func day(_ ms: Int64?) -> String { ms.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1000)).prefix(10).description } ?? "-" }
            print("calendar events: \(c.rows) (calendar_event; starts \(day(c.first)) -> \(day(c.last)))")
        }
        if let n = try NotesImporter.summary(db) {
            func day(_ ms: Int64?) -> String { ms.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1000)).prefix(10).description } ?? "-" }
            print("notes: \(n.rows) (\(n.withBody) with a body; modified \(day(n.first)) -> \(day(n.last)))")
        }
        if try db.tableExists("call") {
            let rows = try db.scalarInt("SELECT count(*) FROM call"), canon = try db.scalarInt("SELECT count(*) FROM call WHERE canonical_id IS NULL")
            print("calls: \(rows) rows, \(canon) canonical (\(rows - canon) duplicates); hole: \(try db.scalarString("SELECT value FROM meta WHERE key = 'calls.hole'") ?? "none recorded")")
        }
        print("contact names: \(s.contactNames) (" + s.contactNamesByOrigin.map { "\($0.0) \($0.1)" }.joined(separator: ", ") + ")")
        if s.metaThreads > 0 {
            print("meta threads: \(s.metaThreads) (\(s.metaHiddenThreads) hidden by default); system/call/unsent rows \(s.systemRows); reactions \(s.reactions)")
        }
        if s.groupme.threads > 0 {
            let g = s.groupme
            func day(_ ms: Int64?) -> String { ms.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1000)).prefix(10).description } ?? "-" }
            print("groupme: \(g.threads) threads (\(g.groups) groups, \(g.threads - g.groups) DMs), \(g.messages) canonical messages (\(g.systemRows) system), \(g.reactions) likes, \(g.attachments) stored images, \(g.people) people; \(day(g.firstTsMs)) -> \(day(g.lastTsMs))")
        }
        for (name, g) in [("skype", s.skype), ("whatsapp", s.whatsapp), ("snapchat", s.snapchat)] where g.threads > 0 {
            func day(_ ms: Int64?) -> String { ms.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1000)).prefix(10).description } ?? "-" }
            print("\(name): \(g.threads) threads (\(g.groups) groups, \(g.threads - g.groups) 1:1), \(g.messages) canonical messages (\(g.systemRows) system/unsent), \(g.attachments) stored attachments, \(g.people) people; \(day(g.firstTsMs)) -> \(day(g.lastTsMs))")
        }
        print("attachments: \(s.attachmentRows) rows, \(s.mediaFiles) media files, \(fmtBytes(s.mediaBytes))")

    case "verify":
        // Read-write (FTS integrity-check is an INSERT command) but journal mode untouched: on a prepared copy (a NAS's) WAL must stay off.
        let db = try Schema.openArchive(root: root, preserveJournalMode: true)
        let r = try ArchiveVerifier.run(db: db, root: root)
        r.lines.forEach { print($0) }
        print(r.passed ? "verify: PASS" : "verify: FAIL (\(r.failures))")
        exit(r.passed ? 0 : 1)

    case "demo-seed":
        var scale = 1.0
        if let i = args.firstIndex(of: "--scale") {
            guard i + 1 < args.count, let v = Double(args[i + 1]), v > 0 else { eprint("--scale needs a positive number"); exit(2) }
            scale = v
            args.removeSubrange(i...(i + 1))
        }
        guard let dir = args.first else { eprint("demo-seed needs a target folder\n\n" + usage); exit(2) }
        let target = ArchiveRoot(url: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true))
        let sum = try DemoSeed.seed(root: target, options: DemoSeed.Options(scale: scale)) { eprint("  " + $0) }
        print("demo archive at \(target.url.path): \(sum.messagesWritten) messages (+\(sum.duplicates) overlapping copies linked), \(sum.threads) threads, \(sum.mediaFiles) media files, \(String(format: "%.1f", sum.seconds)) s")

    case "iphone-contacts", "calendar-import", "notes-import":
        var label = "iphone-backup"
        if let i = args.firstIndex(of: "--label") {
            guard i + 1 < args.count else { eprint("--label needs a name"); exit(2) }
            label = args[i + 1]; args.removeSubrange(i...(i + 1))
        }
        var origin: String?
        if let i = args.firstIndex(of: "--origin") {
            guard i + 1 < args.count else { eprint("--origin needs a label"); exit(2) }
            origin = args[i + 1]; args.removeSubrange(i...(i + 1))
        }
        var skipCalendars = Set<String>()
        while let i = args.firstIndex(of: "--skip-calendar") {
            guard i + 1 < args.count else { eprint("--skip-calendar needs a calendar title"); exit(2) }
            skipCalendars.insert(args[i + 1]); args.removeSubrange(i...(i + 1))
        }
        guard args.count == 1 else { eprint("usage: archivectl \(command) [--label <backup name>] <extracted file or folder>"); exit(2) }
        let db = try Schema.openArchive(root: root)
        let path = URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath)
        func day(_ ms: Int64?) -> String { ms.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1000)).prefix(10).description } ?? "-" }
        switch command {
        case "iphone-contacts":
            let r = try IOSAddressBookImporter.importAddressBook(at: path, label: label, into: db)
            if r.alreadyImported { print("this AddressBook was already imported, skipped"); break }
            print("""
            iPhone AddressBook (\(label)): \(r.cards) cards, \(r.namedCards) with a name; \(r.values) phone numbers and emails on named cards, \(r.valuesMatched) are archive handles
              names stored \(r.namesStored) for \(r.handlesNamed) handles; \(r.handlesNewlyNamed) of them had no name before (\(r.phoneHandlesNewlyNamed) bare phone numbers)
              handles with no name at all: \(r.handlesWithoutAnyNameBefore) -> \(r.handlesWithoutAnyNameAfter)
            """)
        case "calendar-import":
            // A Mac's Calendar Cache (Core Data, ZCALENDARITEM) or an iPhone's Calendar.sqlitedb.
            let isMac = (try? Database(path: path.path, readOnly: true, immutable: true).tableExists("ZCALENDARITEM")) ?? false
            if !isMac, !skipCalendars.isEmpty { eprint("--skip-calendar applies to a Mac Calendar Cache"); exit(2) }
            let r = isMac ? try CalendarImporter.importMacCalendarCache(at: path, label: label, into: db, origin: origin, skipCalendars: skipCalendars)
                          : try CalendarImporter.importCalendar(at: path, label: label, into: db)
            if r.alreadyImported { print("this Calendar was already imported, skipped"); break }
            print("""
            Calendar (\(label)): \(r.items) events read, \(r.inserted) new, \(r.alreadyThere) already there\(r.skippedCalendar.map { ", \($0) left out (--skip-calendar)" } ?? ""); \(r.calendars) calendars
              recurring \(r.recurring)   edited occurrences \(r.exceptions)   all-day \(r.allDay)   hidden \(r.hidden)   with a location \(r.withLocation)   with notes \(r.withNotes)
              starts \(day(r.firstTsMs)) -> \(day(r.lastTsMs))   by year: \(r.byYear.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            """)
        default:
            // The Mac's pre-iCloud NotesV7.storedata (ZNOTEBODY) or a NoteStore.sqlite.
            let isV7 = (try? Database(path: path.path, readOnly: true, immutable: true).tableExists("ZNOTEBODY")) ?? false
            let r = isV7 ? try NotesImporter.importNotesV7(at: path, label: label, into: db, origin: origin)
                         : try NotesImporter.importNotes(at: path, label: label, into: db, origin: origin)
            if r.alreadyImported { print("this NoteStore was already imported, skipped"); break }
            print("""
            Notes (\(label)): \(r.notes) notes read, \(r.inserted) new, \(r.alreadyThere) already there; \(r.folders) folders
              with a body \(r.withBody) (\(r.bodyChars) characters)   password-protected (no body) \(r.locked)   recently deleted \(r.deleted)   undecodable \(r.undecodable)   no data \(r.noData)
              modified \(day(r.firstTsMs)) -> \(day(r.lastTsMs))   by year: \(r.byYear.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            """)
        }
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")

    case "telegram-import":
        var origin: String?, ledger: URL?
        var holdKeys = Set<String>(), chats = Set<Int64>()
        while let i = args.firstIndex(of: "--chat") {
            guard i + 1 < args.count, let c = TelegramPostboxImporter.parseChat(args[i + 1]) else { eprint("--chat needs a peer id: <namespace>:<id> (2:1196887755) or the 64-bit value"); exit(2) }
            chats.insert(c); args.removeSubrange(i...(i + 1))
        }
        for flag in ["--origin", "--ledger", "--hold"] {
            if let i = args.firstIndex(of: flag) {
                guard i + 1 < args.count else { eprint("\(flag) needs a value"); exit(2) }
                let v = args[i + 1]
                if flag == "--origin" { origin = v } else if flag == "--ledger" { ledger = URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }
                else {
                    for l in try String(contentsOfFile: (v as NSString).expandingTildeInPath, encoding: .utf8).split(whereSeparator: \.isNewline) {
                        let g = l.trimmingCharacters(in: .whitespaces); if !g.isEmpty && !g.hasPrefix("#") { holdKeys.insert(g) }
                    }
                }
                args.removeSubrange(i...(i + 1))
            }
        }
        guard args.count == 1, !chats.isEmpty else { eprint("usage: archivectl telegram-import --chat <id> [--chat <id>]... [--origin <label>] [--hold <file>] [--ledger <file>] <postbox/db/db_sqlite snapshot>"); exit(2) }
        let db = try Schema.openArchive(root: root)
        let r = try TelegramPostboxImporter.importStore(at: URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath), chats: chats, into: db, root: root,
                                                       origin: origin, holdKeys: holdKeys, ledger: ledger)
        let s = r.stats
        if r.status == .alreadyImported { print("this Telegram store was already imported with these chats (source \(r.sourceID)), skipped"); break }
        print("""
        Telegram (Postbox): \(s.rows) rows (\(s.unparsed) unreadable), \(s.notSelected) in chats not chosen
          new \(s.inserted): text \(s.text), system lines \(s.system), media without its file \(s.mediaWithoutFile), forwarded \(s.forwarded); empty left out \(s.empty)
          held (matches a row) \(s.heldMatches)   already there by key \(s.heldKnown)   left out by --hold \(s.heldByList)   threads \(s.threads)   people \(s.people)
        """)

    case "slack-files-plan":
        guard args.count == 3 else { eprint("usage: archivectl slack-files-plan <Slack Cache entries folder> <Slack IndexedDB folder> <plan.tsv>"); exit(2) }
        let p = args.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let db = try Schema.openArchive(root: root)
        let rows = try SlackCachedFiles.makePlan(cacheDir: p[0], indexedDB: p[1], db: db, root: root)
        try SlackCachedFiles.write(rows, to: p[2], db: db)
        let att = rows.filter { $0.decision == "attach" }
        let reasons = Dictionary(grouping: rows.filter { $0.decision != "attach" }, by: { "\($0.kind) \($0.reason)" }).mapValues(\.count)
        print("slack-files-plan: \(rows.count) rows; attach \(att.count) (full \(att.filter { $0.kind == "full" }.count), thumbnails \(att.filter { $0.kind == "thumb" }.count)) on \(Set(att.compactMap(\.messageID)).count) messages; \(Set(att.map(\.sha256)).count) files, \(Set(att.map(\.sha256)).count == 0 ? 0 : Dictionary(grouping: att, by: \.sha256).values.map { $0[0].bodyLength }.reduce(0, +)) bytes; already in the media table \(Set(att.filter(\.mediaPresent).map(\.sha256)).count)")
        for (k, v) in reasons.sorted(by: { $0.key < $1.key }) { print("  left out: \(k): \(v)") }

    case "slack-files-extract":
        var plan: URL?
        if let i = args.firstIndex(of: "--plan"), i + 1 < args.count { plan = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath); args.removeSubrange(i...(i + 1)) }
        guard let plan, args.count == 4 else { eprint("usage: archivectl slack-files-extract --plan <plan.tsv> <cache entries folder> <out folder> <ledger.tsv> <copy-list.tsv>"); exit(2) }
        let p = args.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let r = try SlackCachedFiles.extract(plan: plan, cacheDir: p[0], out: p[1], ledger: p[2], copyList: p[3])
        print("slack-files-extract: \(r.files) files, \(r.bytes) bytes")

    case "slack-files-attach":
        var plan: URL?, ledger: URL?, origin: String?
        for flag in ["--plan", "--ledger", "--origin"] {
            if let i = args.firstIndex(of: flag) {
                guard i + 1 < args.count else { eprint("\(flag) needs a value"); exit(2) }
                let v = args[i + 1]
                if flag == "--origin" { origin = v } else if flag == "--plan" { plan = URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }
                else { ledger = URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }
                args.removeSubrange(i...(i + 1))
            }
        }
        guard let plan, args.isEmpty else { eprint("usage: archivectl slack-files-attach --plan <plan.tsv> [--ledger <file>] [--origin <label>]"); exit(2) }
        let db = try Schema.openArchive(root: root)
        let r = try SlackCachedFiles.attach(plan: plan, into: db, root: root, ledger: ledger, origin: origin)
        if r.status == .alreadyImported { print("this plan was already applied (source \(r.sourceID)), skipped"); break }
        let s = r.stats
        print("slack-files-attach: \(s.rows) plan rows: attached \(s.attached) on \(s.messages) messages (new media \(s.newFiles), \(s.newBytes) bytes), already attached \(s.alreadyThere), left out \(s.leftOut); notes changed \(s.notesChanged), file-only rows now messages \(s.fileRowsNowMessages)")

    case "slack-listing":
        guard args.count == 1 else { eprint("usage: archivectl slack-listing <Slack IndexedDB folder>"); exit(2) }
        print(try SlackCacheImporter.extractListing(at: URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath)), terminator: "")

    case "slack-import":
        var origin: String?, ledger: URL?
        var holdKeys = Set<String>(), workspaces = Set<String>()
        for flag in ["--origin", "--ledger", "--hold"] {
            if let i = args.firstIndex(of: flag) {
                guard i + 1 < args.count else { eprint("\(flag) needs a value"); exit(2) }
                let v = args[i + 1]
                if flag == "--origin" { origin = v } else if flag == "--ledger" { ledger = URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }
                else {
                    for l in try String(contentsOfFile: (v as NSString).expandingTildeInPath, encoding: .utf8).split(whereSeparator: \.isNewline) {
                        let g = l.trimmingCharacters(in: .whitespaces); if !g.isEmpty && !g.hasPrefix("#") { holdKeys.insert(g) }
                    }
                }
                args.removeSubrange(i...(i + 1))
            }
        }
        while let i = args.firstIndex(of: "--workspace") {
            guard i + 1 < args.count, SlackCacheImporter.isTeamID(args[i + 1]) else { eprint("--workspace needs a Slack team id (T and capital letters or digits)"); exit(2) }
            workspaces.insert(args[i + 1]); args.removeSubrange(i...(i + 1))
        }
        guard args.count == 1 else { eprint("usage: archivectl slack-import [--origin <label>] [--hold <file>] [--workspace <team id>]... [--ledger <file>] <Slack IndexedDB folder>"); exit(2) }
        let db = try Schema.openArchive(root: root)
        let r = try SlackCacheImporter.importCache(at: URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath), into: db,
                                                   origin: origin, holdKeys: holdKeys, workspaces: workspaces, ledger: ledger)
        let s = r.stats
        if r.status == .alreadyImported { print("this Slack cache was already imported (source \(r.sourceID)), skipped"); break }
        print("""
        Slack cache: \(s.saves) saves read (\(s.unreadableSaves) unreadable, \(s.savesOtherWorkspace ?? 0) of workspaces not chosen), \(s.versions) message copies, \(s.distinct) distinct messages
          new \(s.inserted): text \(s.text), system lines \(s.system), app (bot) messages \(s.bot), with files noted \(s.filesNoted), thread replies \(s.threadReplies), edited \(s.edited) (text differs between saves \(s.editedTextDiffers)), reactions \(s.reactions)
          left out: ephemeral \(s.leftOutEphemeral), deleted \(s.leftOutDeleted), empty \(s.leftOutEmpty)   already there by key \(s.heldKnown)   threads \(s.threads)   people \(s.people)
        """)

    case "ichat-import":
        var origin: String?, ledger: URL?
        var holdKeys = Set<String>()
        var marks: [String: String] = [:]
        if let i = args.firstIndex(of: "--mark") {
            guard i + 1 < args.count else { eprint("--mark needs a file of <source key><TAB><ledger decision>"); exit(2) }
            for l in try String(contentsOfFile: (args[i + 1] as NSString).expandingTildeInPath, encoding: .utf8).split(whereSeparator: \.isNewline) {
                if l.hasPrefix("#") { continue }
                let f = l.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if f.count == 2, !f[0].isEmpty, !f[1].isEmpty { marks[f[0]] = f[1] }
            }
            args.removeSubrange(i...(i + 1))
        }
        for flag in ["--origin", "--ledger", "--hold"] {
            if let i = args.firstIndex(of: flag) {
                guard i + 1 < args.count else { eprint("\(flag) needs a value"); exit(2) }
                let v = args[i + 1]
                if flag == "--origin" { origin = v } else if flag == "--ledger" { ledger = URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }
                else {
                    for l in try String(contentsOfFile: (v as NSString).expandingTildeInPath, encoding: .utf8).split(whereSeparator: \.isNewline) {
                        let g = l.trimmingCharacters(in: .whitespaces); if !g.isEmpty && !g.hasPrefix("#") { holdKeys.insert(g) }
                    }
                }
                args.removeSubrange(i...(i + 1))
            }
        }
        guard args.count == 1 else { eprint("usage: archivectl ichat-import [--origin <label>] [--hold <file of source keys>] [--ledger <file>] <folder of .ichat files>"); exit(2) }
        let db = try Schema.openArchive(root: root)
        let r = try IChatImporter.importTranscripts(at: URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath), into: db, root: root,
                                                    origin: origin, holdKeys: holdKeys, ledger: ledger, marks: marks)
        let s = r.stats
        if r.status == .alreadyImported { print("these transcripts were already imported (source \(r.sourceID)), skipped"); break }
        print("""
        iChat transcripts: \(s.files) files (\(s.unreadable) unreadable), \(s.messages) messages
          new \(s.inserted) (\(s.byService.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))   held by guid \(s.heldGuid)   held (matches a row) \(s.heldMatches)   left out by --hold \(s.heldByList)
          left out: no text \(s.leftOutEmpty)   no date \(s.leftOutNoDate)   no thread to place it \(s.leftOutNoThread)   held messages in two threads \(s.leftOutTwoThreads)   sender not a member \(s.leftOutSender)
        """)

    case "fb-dyi-2011-import":
        let dry = args.contains("--dry-run"); args.removeAll { $0 == "--dry-run" }
        let unverified = args.contains("--allow-unverified-file"); args.removeAll { $0 == "--allow-unverified-file" }
        var origin: String?, me: String?, ledger: URL?, zone = LocalZone.current()
        for flag in ["--origin", "--me", "--ledger", "--zone"] {
            if let i = args.firstIndex(of: flag) {
                guard i + 1 < args.count else { eprint("\(flag) needs a value"); exit(2) }
                if flag == "--origin" { origin = args[i + 1] } else if flag == "--me" { me = args[i + 1] }
                else if flag == "--zone" {
                    guard let z = FacebookDYI2011Importer.zone(named: args[i + 1]) else { eprint("--zone needs an IANA zone (America/Chicago) or a fixed offset (UTC-04:00)"); exit(2) }
                    zone = z
                }
                else { ledger = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath) }
                args.removeSubrange(i...(i + 1))
            }
        }
        guard args.count == 1, let exportRoot = FacebookDYI2011Importer.detect(URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath)) else {
            eprint("usage: archivectl fb-dyi-2011-import [--dry-run] [--zone <IANA|UTC±hh:mm>] [--origin <label>] [--me <name>] [--ledger <file.tsv>] [--allow-unverified-file] <export root with html/messages.html>"); exit(2)
        }
        let db = try Schema.openArchive(root: root, readOnly: dry)
        let r: FacebookDYI2011Report
        var people: PeopleStore.RematchReport?
        if dry { r = try FacebookDYI2011Importer.importExport(at: exportRoot, into: db, allowUnverified: unverified, zone: zone, me: me, origin: origin, dryRun: true, ledger: ledger) }
        else {
            do { (r, people) = try FacebookDYI2011Importer.importAndRematch(at: exportRoot, into: db, allowUnverified: unverified, zone: zone, me: me, origin: origin, ledger: ledger) }
            catch let e as FacebookDYI2011Importer.PeopleIndexError { eprint("fb-dyi-2011-import: \(e)"); try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)"); exit(1) }
        }
        if r.status == .alreadyImported {
            print("this export's messages.html was already imported, skipped" + (people.map { "; people index rebuilt: \($0.persons) people" } ?? ""))
            break
        }
        let s = r.stats
        func day(_ ms: Int64?) -> String { ms.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1000)).prefix(10).description } ?? "-" }
        print("""
        2011 Facebook export (you are "\(r.me)")\(dry ? ": DRY RUN, nothing stored" : "")
          conversations \(s.conversations)   messages parsed \(s.parsed)
          already held \(s.held) (+\(s.heldTextDiffers) with slightly different text)   no text, left out \(s.emptySkipped)   unreadable time \(s.badTime)   no recipient \(s.unplaced)   thread ambiguous, left out \(s.ambiguousThread)   weak evidence, left out \(s.weakEvidence)   group sender unresolved, left out \(s.senderUnresolved)   duplicate in the export \(s.duplicateInExport)   opener time unknown, left out \(s.openerTimeUnknown)   late openers held \(s.heldLateOpeners)
          \(dry ? "would add \(s.intoExistingThreads + s.intoNewThreads): into existing threads \(s.intoExistingThreads), into new threads \(s.intoNewThreads)" : "new rows \(s.inserted): into existing threads \(s.intoExistingThreads), into threads this import created \(s.intoNewThreads) (threads created \(s.newThreads), handles created \(s.newHandles), duplicates linked \(s.duplicates))")
          dates \(day(s.firstTsMs)) -> \(day(s.lastTsMs))   precision: \(s.precision)
        """)
        if !r.leftOut.isEmpty { print("  left out: " + r.leftOut.map { "\($0.0) (\($0.1))" }.joined(separator: ", ")) }
        if let p = people {
            print("people: \(p.persons) (\(p.linkedPersons) matched across \(p.linkedHandles) handles, \(p.ambiguousNames) ambiguous names left unlinked)")
        }
        if !dry { try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)") }

    case "posts-media":
        let dry = args.contains("--dry-run"); args.removeAll { $0 == "--dry-run" }
        var ledger: URL?, live: URL?, origin: String?
        for flag in ["--ledger", "--photoprism-live", "--origin"] {
            if let i = args.firstIndex(of: flag) {
                guard i + 1 < args.count else { eprint("\(flag) needs a value"); exit(2) }
                let v = args[i + 1]
                switch flag { case "--ledger": ledger = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
                case "--photoprism-live": live = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
                default: origin = v }
                args.removeSubrange(i...(i + 1))
            }
        }
        guard args.count == 1 else { eprint("usage: archivectl posts-media [--dry-run] [--ledger <file.tsv>] [--photoprism-live <sha1-uid.tsv>] [--origin <label>] <plan.tsv>"); exit(2) }
        if let problem = root.mediaProblem { eprint(problem); exit(1) }
        let db = try Schema.openArchive(root: root, readOnly: dry)
        let r = try PostsMedia.run(plan: URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath), into: db, root: root, photoprismLive: live,
                                   dryRun: dry, ledger: ledger, origin: origin)
        if !dry { try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
        if r.status == .alreadyImported { print("this media plan was already imported (source \(r.sourceID ?? 0)), skipped" + (ledger != nil ? " (ledger republished from the database)" : "")); break }
        let s = r.stats
        print("""
        posts media\(dry ? ": DRY RUN, nothing stored" : "")
          plan rows \(s.rows)   post_media rows \(dry ? "to write" : "written") \(s.linked + s.inStore + s.copied): PhotoPrism links \(s.linked), in the store \(s.inStore), copied \(s.copied)   already there \(s.alreadyThere)
          new media rows \(s.newMediaRows) / \(s.newBytes) bytes   not a row: \(s.notARow.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))   every copied file re-hashed
        """)

    case "posts-import":
        let dry = args.contains("--dry-run"); args.removeAll { $0 == "--dry-run" }
        var ledger: URL?
        if let i = args.firstIndex(of: "--ledger") {
            guard i + 1 < args.count else { eprint("--ledger needs a value"); exit(2) }
            ledger = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath); args.removeSubrange(i...(i + 1))
        }
        guard args.count == 1 else { eprint("usage: archivectl posts-import [--dry-run] [--ledger <file.tsv>] <records.jsonl>"); exit(2) }
        let db = try Schema.openArchive(root: root, readOnly: dry)
        let r = try PostsImporter.importRecords(at: URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath), into: db, dryRun: dry, ledger: ledger)
        if r.status == .alreadyImported { print("this records file was already imported, skipped" + (ledger != nil ? " (ledger republished from the database)" : "")); break }
        let s = r.stats
        func day(_ ms: Int64?) -> String { ms.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1000)).prefix(10).description } ?? "-" }
        print("""
        posts and comments\(dry ? ": DRY RUN, nothing stored" : "")
          records \(s.records)   posts \(dry ? "to write" : "written") \(s.postsWritten)   comments \(dry ? "to write" : "written") \(s.commentsWritten)   held \(s.held) \(s.heldByRule.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
          left out \(s.leftOut): \(s.leftOutByReason.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
          new handles \(s.newHandles)   dates \(day(s.firstTsMs)) -> \(day(s.lastTsMs))
        """)
        if !dry { try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)") }

    case "recordings-import":
        let dry = args.contains("--dry-run"); args.removeAll { $0 == "--dry-run" }
        var ledger: URL?, transcripts: URL?, origin: String?
        for flag in ["--ledger", "--transcripts", "--origin"] {
            if let i = args.firstIndex(of: flag) {
                guard i + 1 < args.count else { eprint("\(flag) needs a value"); exit(2) }
                let v = args[i + 1]
                switch flag { case "--ledger": ledger = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
                case "--transcripts": transcripts = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
                default: origin = v }
                args.removeSubrange(i...(i + 1))
            }
        }
        guard args.count == 1 else { eprint("usage: archivectl recordings-import [--dry-run] [--ledger <file.tsv>] [--transcripts <folder>] [--origin <label>] <recordings.tsv>"); exit(2) }
        if let problem = root.mediaProblem { eprint(problem); exit(1) }
        let db = try Schema.openArchive(root: root, readOnly: dry)
        let r = try RecordingImporter.run(plan: URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath), transcripts: transcripts, into: db, root: root,
                                          dryRun: dry, ledger: ledger, origin: origin)
        if !dry { try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
        if r.status == .alreadyImported { print("this recordings plan was already imported (source \(r.sourceID ?? 0)), skipped" + (ledger != nil ? " (ledger republished from the database)" : "")); break }
        let s = r.stats
        print("""
        recordings\(dry ? ": DRY RUN, nothing stored" : "")
          plan rows \(s.planRows)   rows \(dry ? "to write" : "written") \(s.written): voicemails \(s.voicemails), memos \(s.memos)   with audio \(s.withAudio), without \(s.withoutAudio)   already there \(s.alreadyThere)
          new media rows \(s.newMediaRows) / \(s.newMediaBytes) bytes   transcripts \(dry ? "to write" : "written") \(s.transcripts), already there \(s.transcriptsAlready)   every audio file re-hashed
          voicemails tied to a known handle \(s.linkedToHandle), to a 1:1 thread \(s.linkedToThread)
          by source: \(s.perLabel.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        """)
        if !dry { print("  recording table: \(s.totalRows) rows = \(s.canonical) canonical + \(s.duplicates) linked duplicates") }

    case "voice-messages-import":
        let dry = args.contains("--dry-run"); args.removeAll { $0 == "--dry-run" }
        var ledger: URL?, transcripts: URL?, origin: String?
        for flag in ["--ledger", "--transcripts", "--origin"] {
            if let i = args.firstIndex(of: flag) {
                guard i + 1 < args.count else { eprint("\(flag) needs a value"); exit(2) }
                let v = args[i + 1]
                switch flag { case "--ledger": ledger = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
                case "--transcripts": transcripts = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
                default: origin = v }
                args.removeSubrange(i...(i + 1))
            }
        }
        guard args.count == 1, let transcripts else { eprint("usage: archivectl voice-messages-import [--dry-run] [--ledger <file.tsv>] --transcripts <folder> [--origin <label>] <voice-messages.tsv>"); exit(2) }
        if let problem = root.mediaProblem { eprint(problem); exit(1) }
        let db = try Schema.openArchive(root: root, readOnly: dry)
        let r = try VoiceMessageImporter.run(plan: URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath), transcripts: transcripts, into: db, root: root,
                                             dryRun: dry, ledger: ledger, origin: origin)
        if !dry { try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
        if r.status == .alreadyImported { print("this voice-messages plan was already imported (source \(r.sourceID ?? 0)), skipped" + (ledger != nil ? " (ledger republished from the database)" : "")); break }
        let s = r.stats
        print("""
        voice messages\(dry ? ": DRY RUN, nothing stored" : "")
          plan rows \(s.planRows)   rows \(dry ? "to write" : "written") \(s.written): with words \(s.withWords), no words \(s.noWords), playable copies \(s.playableCopies)   already there \(s.alreadyThere)
          new media rows \(s.newMediaRows) / \(s.newMediaBytes) bytes   transcripts \(dry ? "to write" : "written") \(s.transcripts), already there \(s.transcriptsAlready)   every file re-hashed
          canonical messages carrying them \(s.messages)
        """)
        if !dry { print("  voice_message table: \(s.totalRows) rows") }

    case "recordings":
        var kind: String?, search: String?, limit = 20
        for flag in ["--kind", "--search", "--limit"] {
            if let i = args.firstIndex(of: flag) {
                guard i + 1 < args.count else { eprint("\(flag) needs a value"); exit(2) }
                let v = args[i + 1]
                switch flag { case "--kind": kind = v
                case "--search": search = v
                default: limit = max(1, Int(v) ?? 20) }
                args.removeSubrange(i...(i + 1))
            }
        }
        guard args.isEmpty, kind == nil || RecordingImporter.kinds.contains(kind!) else { eprint("usage: archivectl recordings [--kind voicemail|memo|meeting] [--search <words>] [--limit N]"); exit(2) }
        let reader = try ArchiveReader(root: root)
        guard try reader.hasRecordings() else { print("this archive has no recordings yet"); break }
        let c = try reader.recordingCounts()
        print("recordings: \(c.voicemails) voicemails, \(c.memos) voice memos, \(c.meetings) meetings, \(String(format: "%.1f", c.seconds / 3600)) h (canonical rows)")
        let v = try reader.voiceMessageCounts()
        if v.files > 0 { print("voice messages on threads with a machine transcript: \(v.files) audio files, \(String(format: "%.1f", v.seconds / 3600)) h") }
        let rows = try search.map { try reader.searchRecordings($0, kind: kind, limit: limit) } ?? reader.recordings(kind: kind, limit: limit)
        let tf = DateFormatter(); tf.dateFormat = "yyyy-MM-dd HH:mm"; tf.timeZone = .current
        for r in rows {
            let when = r.tsMs.map { tf.string(from: Date(timeIntervalSince1970: Double($0) / 1000)) + (r.timeIsOwn ? "" : " (exported)") } ?? "(no date)        "
            let what = r.isVoicemail ? "voicemail " + (r.name ?? r.address ?? "(caller not in the source)") : r.kind + " " + (r.title ?? "(untitled)")
            // counts and titles only: a transcript is never printed here (terminal scrollback is not private storage)
            let words = r.transcripts.first.map { $0.text.split(separator: " ").count } ?? 0
            print("\(when)  #\(r.id)  \(RecordingRow.clock(r.durationS))  \(what)  [\(r.sha256 == nil ? "no audio" : "\(words) words")]")
        }

    case "calls-import":
        guard args.count == 1 else { eprint("usage: archivectl calls-import <folder with calls.tsv and sources.tsv, or calls.tsv>"); exit(2) }
        let db = try Schema.openArchive(root: root)
        let t0 = Date()
        let rep = try CallImporter.importExport(at: URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath), into: db)
        let msg = try CallImporter.importMessageCalls(into: db)
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let s = msg      // the last pass summarizes the whole table
        if rep.status == .alreadyImported { print("calls.tsv already imported, skipped (message calls: +\(msg.rows) new, \(msg.alreadyThere) already there)") }
        else { print("calls.tsv imported: +\(rep.stats.rows) rows (\(rep.stats.alreadyThere) already there, \(rep.stats.bad) bad); message calls +\(msg.rows) (\(msg.alreadyThere) already there)") }
        func day(_ ms: Int64?) -> String { ms.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1000)).prefix(10).description } ?? "-" }
        print("calls table: \(s.totalRows) rows = \(s.canonical) canonical + \(s.duplicates) linked duplicates; \(s.linkedToHandle) linked to a handle, \(s.linkedToThread) to a 1:1 thread; \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        print("per source (rows / canonical / minutes / first -> last):")
        for (k, v) in s.perSource.sorted(by: { $0.key < $1.key }) { print("  \(k.padding(toLength: 14, withPad: " ", startingAt: 0)) \(v.rows) / \(v.canonical) / \(v.minutes) / \(day(v.firstTsMs)) -> \(day(v.lastTsMs))") }
        print("gaps in the phone/FaceTime record (>= \(CallImporter.gapDays) days): " + (s.gaps.isEmpty ? "none" : s.gaps.joined(separator: "; ")))

    case "groupme-media":
        guard args.count == 1 else { eprint("usage: archivectl groupme-media <folder with results.jsonl and the fetched files>"); exit(2) }
        let db = try Schema.openArchive(root: root)
        let s = try GroupMeMedia.attach(fetchedDir: URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath), into: db, root: root)
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        print("groupme-media: \(s.urls) urls in the log: ok \(s.ok), gone \(s.gone), failed \(s.failed), rejected \(s.rejected); attached \(s.attached) to \(s.messagesChanged) messages (\(s.bodiesEmptied) now have no text), \(s.newFiles) new files / \(fmtBytes(Int64(s.newBytes))); urls not in the archive \(s.urlsNotInArchive)")

    case "attachments-plan":
        var notesOut: URL?
        if let i = args.firstIndex(of: "--notes") {
            guard i + 1 < args.count else { eprint("--notes needs a file"); exit(2) }
            notesOut = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath); args.removeSubrange(i...(i + 1))
        }
        guard args.count == 2 else { eprint("usage: archivectl attachments-plan <input.tsv: device, msg_guid, att_guid, date, mime, bytes, sha256, staged_path> <plan.tsv to write>"); exit(2) }
        // Read-write open like every other command, though the plan only reads: a read-only open of a WAL-mode archive fails with
        // "unable to open database file" when no -shm file sits beside it.
        let db = try Schema.openArchive(root: root)
        let rows = try AttachmentPlan.make(input: URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath), db: db, root: root)
        try AttachmentPlan.write(rows, to: URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath), db: db)
        if let notesOut {
            let p = try AttachmentPlan.notePreview(rows, db: db)
            var t = "message_id\tstatus\told_note\tnew_note\n"
            for x in p { t += "\(x.messageID)\t\(x.status)\t\(AttachmentPlan.escape(x.oldNote))\t\(AttachmentPlan.escape(x.newNote ?? ""))\n" }
            try t.write(to: notesOut, atomically: true, encoding: .utf8)
            var by: [String: Int] = [:]; for x in p { by[x.status, default: 0] += 1 }
            print("  notes: " + (by.isEmpty ? "none change" : by.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
        }
        var by: [String: Int] = [:]; for r in rows { by[r.decision, default: 0] += 1 }
        let copy = rows.filter { $0.decision == "attach" && !$0.mediaPresent }
        print("attachments-plan: \(rows.count) rows: " + by.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        print("  files the media store lacks: \(Set(copy.map(\.sha256)).count) (\(fmtBytes(Int64(Dictionary(copy.map { ($0.sha256, $0.bytes) }, uniquingKeysWith: { a, _ in a }).values.reduce(0, +)))))")

    case "attachments-backfill" where args.contains("--plan"):
        var ledger: URL?, origin: String?, plan: URL?
        for flag in ["--plan", "--ledger", "--origin"] {
            if let i = args.firstIndex(of: flag) {
                guard i + 1 < args.count else { eprint("\(flag) needs a value"); exit(2) }
                let v = args[i + 1]
                switch flag { case "--plan": plan = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
                case "--ledger": ledger = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
                default: origin = v }
                args.removeSubrange(i...(i + 1))
            }
        }
        guard args.isEmpty, let plan else { eprint("usage: archivectl attachments-backfill --plan <plan.tsv> [--ledger <file>] [--origin <label>]"); exit(2) }
        let db = try Schema.openArchive(root: root)
        let r = try AttachmentBackfill.runPlan(plan: plan, into: db, root: root, ledger: ledger, origin: origin)
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let s = r.stats
        if r.status == .alreadyImported { print("this plan was already attached (source \(r.sourceID)), skipped"); break }
        print("attachments-backfill --plan: \(s.rows) plan rows; attached \(s.attached) (" + s.byKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")")
        print("  not attached: already there / repeat \(s.alreadyThere)   message not in archive \(s.messageNotInArchive)   media file missing \(s.fileMissing)   size differs \(s.hashMismatch)")
        print("  notes shortened \(s.notesShortened)   notes cleared \(s.notesCleared)   system lines restored \(s.systemLinesRestored)   name not in note \(s.nameNotInNote)   new media rows \(s.newFiles) / \(fmtBytes(Int64(s.newBytes)))   every file re-hashed")

    case "attachments-backfill":
        let dry = args.contains("--dry-run")
        args.removeAll { $0 == "--dry-run" }
        guard args.count == 1 else { eprint("usage: archivectl attachments-backfill [--dry-run] <staging folder with map.tsv>"); exit(2) }
        let db = try Schema.openArchive(root: root, readOnly: dry)
        let s = try AttachmentBackfill.run(stagingDir: URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath), into: db, root: root, dryRun: dry)
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        print("attachments-backfill\(dry ? " (dry run: nothing stored)" : ""): \(s.rows) map rows; attached \(s.attached) (" + s.byKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")")
        print("  already there \(s.alreadyThere)   message not in archive \(s.messageNotInArchive)   file missing \(s.fileMissing)   hash/size mismatch \(s.hashMismatch)   on duplicate rows \(s.onDuplicateRows)")
        print("  notes shortened \(s.notesShortened)   notes cleared \(s.notesCleared)   system lines restored \(s.systemLinesRestored)   name not in note \(s.nameNotInNote)   new files \(s.newFiles) / \(fmtBytes(Int64(s.newBytes)))")

    case "relink":
        let db = try Schema.openArchive(root: root)
        let t0 = Date()
        let r = try Reconciler.relinkEmojiStrippedCopies(db: db) { eprint("  \($0) rows examined") }
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        print("relink: examined \(r.examined) non-iPhone canonical rows, folded \(r.linked) under an iPhone row (\(r.movedDuplicates) further copies follow them) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")

    case "reclassify":
        let db = try Schema.openArchive(root: root)
        let dry = args.contains("--dry-run")
        let r = try Reclassifier.run(db: db, dryRun: dry)
        if !dry { try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
        print("""
        reclassify\(dry ? " (dry run, nothing written)" : ""):
          Instagram Burmese lines: \(r.igExamined) examined, \(r.igTranslated) translated, \(r.igFallback) caught by the last-resort rule; by kind \(r.igByKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
          Instagram like lines repeating a real heart: \(r.twinsHidden) hidden, \(r.twinsKept) kept visible
          Apple tapbacks as text: \(r.tapbackExamined) found, \(r.tapbackResolved) became reactions, \(r.tapbackRemovalsApplied) removals applied (+\(r.tapbackRemovalsNoMatch) with no reaction to remove), \(r.tapbackUnresolved) unresolved (kept as system lines; \(r.unresolvedByService.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
        """)

    case "contacts":
        let dry = args.contains("--dry-run")
        args.removeAll { $0 == "--dry-run" }
        var label: String?
        if let i = args.firstIndex(of: "--label") {
            guard i + 1 < args.count else { eprint("--label needs macos-contacts-<date>"); exit(2) }
            label = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        let from = args.first.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? MacContactsImporter.defaultSourcesRoot
        let db = try Schema.openArchive(root: root, readOnly: dry)
        let r = try MacContactsImporter.importContacts(from: from, into: db, label: label, dryRun: dry)
        print("archive: \(root.url.path)")
        print("""
        \(r.label)\(dry ? " (dry run: nothing stored)" : ""): \(r.stores) Contacts stores, \(r.namedCards) named cards, \(r.values) phones/emails
          matched archive handles: \(r.valuesMatched) values -> \(r.handlesNamed) handles (\(r.handlesNewlyNamed) had no stored name; \(r.handlesWithSeveralNames) on cards with different names)
          names stored \(r.namesStored)   earlier macos-contacts names replaced \(r.previousNamesRemoved)
        """)
        if !dry, let m = try? PeopleStore.rematch(db: db) {
            print("people: \(m.persons) (\(m.linkedPersons) matched across \(m.linkedHandles) handles, \(m.ambiguousNames) ambiguous names left unlinked)")
        }
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")

    case "prepare-move":
        let r = try Relocation.prepareForMove(root: root)
        print("""
        archive: \(root.url.path)
        journal mode: \(r.journalModeBefore) -> \(r.journalModeAfter)
        media: \(r.mediaFiles) files, \(fmtBytes(r.mediaBytes))
        absolute stored paths: \(r.absolutePaths)\(r.absolutePaths == 0 ? " (good: the folder is relocatable)" : " (NOT relocatable)")
        leftover side files: \(r.leftoverFiles.isEmpty ? "none" : r.leftoverFiles.joined(separator: ", "))
        checkpoint: \(r.checkpointBusy ? "BUSY or partial (stop the importer/app and run again)" : "complete")
        \(r.ok ? "next:" : "NOT SAFE TO COPY. Fix the lines above, then run prepare-move again. next:") copy the whole folder (archive.sqlite + media/) to its new home, then point the app (Settings) or --archive at it.
        """)
        exit(r.ok ? 0 : 1)

    case "help", "--help", "-h":
        print(usage)

    default:
        eprint("unknown command: \(command)\n\n" + usage)
        exit(2)
    }
} catch {
    eprint("error: \(error)")
    exit(1)
}
