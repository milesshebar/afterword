import Foundation

/// Helpers for moving a whole archive folder (database + media) to another volume, for example a NAS over SMB.
/// Everything the archive stores is root-relative, so the move is "copy the folder, point the root at it".
public enum Relocation {
    public struct Report: Sendable {
        public var journalModeBefore: String
        public var journalModeAfter: String
        public var leftoverFiles: [String]
        public var mediaFiles: Int
        public var mediaBytes: Int64
        public var absolutePaths: Int
        public var checkpointBusy: Bool = false
        /// True only when the folder is safe to copy as plain files.
        public var ok: Bool { journalModeAfter == "delete" && leftoverFiles.isEmpty && !checkpointBusy && absolutePaths == 0 }
    }

    /// Makes the folder safe to copy as plain files: folds the WAL into the main database, switches to the rollback
    /// journal (which network volumes can use), and counts what the copy will carry. Run it with no importer and no
    /// app writing. The next local import switches a local root back to WAL by itself.
    public static func prepareForMove(root: ArchiveRoot) throws -> Report {
        guard FileManager.default.fileExists(atPath: root.databaseURL.path) else { throw ArchiveError("no archive at \(root.url.path)") }
        var before = "?", after = "?", abs = 0, files = 0, busy = false
        var bytes: Int64 = 0
        do {   // the connection closes at the end of this scope, which removes -wal/-shm
            let db = try Database(path: root.databaseURL.path)
            before = try db.scalarString("PRAGMA journal_mode") ?? "?"
            // wal_checkpoint returns (busy, log frames, checkpointed frames); busy=1 or a partial checkpoint means data still in the WAL.
            let st = try db.prepare("PRAGMA wal_checkpoint(TRUNCATE)")
            if try st.step() { busy = st.int(0) != 0 || (st.int(1) >= 0 && st.int(1) != st.int(2)) }
            st.reset()
            after = try db.scalarString("PRAGMA journal_mode = DELETE") ?? "?"
            abs = Int(try db.scalarInt("SELECT (SELECT count(*) FROM media WHERE path LIKE '/%' OR path LIKE '%..%') + (SELECT count(*) FROM attachment WHERE media_path LIKE '/%' OR media_path LIKE '%..%')"))
            files = Int(try db.scalarInt("SELECT count(*) FROM media"))
            bytes = try db.scalarInt("SELECT coalesce(sum(bytes),0) FROM media")
        }
        let fm = FileManager.default
        // In rollback mode a stale -shm (and an empty -wal) can linger; neither carries data, so tidy them away.
        let shm = root.url.appendingPathComponent("archive.sqlite-shm").path, wal = root.url.appendingPathComponent("archive.sqlite-wal").path
        if fm.fileExists(atPath: shm) { try? fm.removeItem(atPath: shm) }
        if let size = (try? fm.attributesOfItem(atPath: wal))?[.size] as? NSNumber, size.intValue == 0 { try? fm.removeItem(atPath: wal) }
        let leftovers = ["archive.sqlite-wal", "archive.sqlite-shm", "archive.sqlite-journal"].filter { fm.fileExists(atPath: root.url.appendingPathComponent($0).path) }
        return Report(journalModeBefore: before, journalModeAfter: after, leftoverFiles: leftovers, mediaFiles: files, mediaBytes: bytes, absolutePaths: abs, checkpointBusy: busy)
    }
}
