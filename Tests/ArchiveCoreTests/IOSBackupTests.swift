import Testing
import Foundation
@testable import ArchiveCore

extension TestArchive {
    @discardableResult
    func importBackup(_ fx: BackupFixture, origin: String? = nil) throws -> BackupImportReport {
        try IOSBackupImporter.importBackup(at: fx.folder, into: db, root: root, origin: origin)
    }
}

// MARK: epochs and typedstream

@Suite struct IOSDateTests {
    @Test func modernSecondsAndNanosecondsAreToldApartByMagnitude() {
        let unix: Int64 = 1_393_675_200       // 2014-03-01 12:00:00 UTC
        #expect(IOSDates.modernToUnixMs(IOSFixtures.apple(unix)) == unix * 1000)
        #expect(IOSDates.modernToUnixMs(IOSFixtures.appleNS(unix)) == unix * 1000)
        #expect(IOSDates.modernToUnixMs(IOSFixtures.appleNS(unix) + 1_500_000_000) == unix * 1000 + 1500)
        #expect(IOSDates.modernToUnixMs(0) == nil)
        #expect(IOSDates.modernToUnixMs(-5) == nil)
    }
    @Test func legacyEpochDependsOnIsMadrid() {
        let unix: Int64 = 1_325_419_200       // 2012-01-01 12:00:00 UTC
        #expect(IOSDates.legacyToUnixMs(unix, isMadrid: false) == unix * 1000)                       // SMS: Unix seconds
        #expect(IOSDates.legacyToUnixMs(IOSFixtures.apple(unix), isMadrid: true) == unix * 1000)       // iMessage: Apple seconds
        // the trap: reading an SMS row as Apple seconds lands 31 years late
        #expect(IOSDates.legacyToUnixMs(unix, isMadrid: true) == (unix + 978_307_200) * 1000)
    }
}

@Suite struct TypedStreamTests {
    @Test func matchesNSUnarchiverOnArchivedAttributedStrings() {
        let samples = ["hi", "emoji \u{1F600} and caf\u{E9}", String(repeating: "long ", count: 40),       // > 127 bytes: 0x81 length
                       String(repeating: "x", count: 70_000)]                                              // > 65535 bytes: 0x82 length
        for s in samples {
            for mutable in [true, false] {
                let blob = IOSFixtures.attributedBody(s, mutable: mutable)
                #if canImport(Darwin)
                let viaFoundation = (NSUnarchiver.unarchiveObject(with: blob) as? NSAttributedString)?.string
                #expect(viaFoundation == s)
                #endif
                #expect(TypedStream.attributedBodyText([UInt8](blob)) == s)
                #expect(TypedStream.attributedBodyText([UInt8](IOSFixtures.typedStream(s, mutable: mutable))) == s)
            }
        }
    }
    #if canImport(Darwin)
    @Test func typedStreamMatchesNSArchiver() {
        for s in ["hi", "caf\u{E9} \u{1F600}", String(repeating: "long ", count: 40)] {
            for mutable in [true, false] {
                #expect(IOSFixtures.typedStream(s, mutable: mutable) == IOSFixtures.attributedBody(s, mutable: mutable))
            }
        }
    }
    #endif
    @Test func garbageAndTruncationReturnNil() throws {
        #expect(TypedStream.attributedBodyText([]) == nil)
        #expect(TypedStream.attributedBodyText(Array("not a typedstream at all, just text".utf8)) == nil)
        let data = IOSFixtures.attributedBody("truncate me please")
        let start = try! #require(data.range(of: Data("truncate".utf8))).lowerBound     // cut inside the string payload
        #expect(TypedStream.attributedBodyText([UInt8](data.prefix(start + 6))) == nil)
    }
}

// MARK: manifest

@Suite struct BackupManifestTests {
    @Test func fileIDIsSHA1OfDomainDashPath() {
        // The well-known id of sms.db in every iPhone backup.
        #expect(BackupManifest.fileID(domain: "HomeDomain", path: "Library/SMS/sms.db") == "3d0d7e5fb2ce288813306e4d4636395e047a3d28")
    }

    @Test func modernManifestFindsNestedAndFlatFiles() throws {
        let dir = Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fx = BackupFixture(under: dir)
        fx.addFile(domain: "MediaDomain", path: "Library/SMS/Attachments/aa/01/G/a.jpg", data: Data([1]), nested: true)
        fx.addFile(domain: "MediaDomain", path: "Library/SMS/Attachments/aa/01/G/flat.jpg", data: Data([2]), nested: false)
        fx.addFile(domain: "MediaDomain", path: "Library/SMS/Attachments/aa/01/G/gone.jpg", data: Data([3]), nested: true, onDisk: false)
        fx.writeManifestDB()
        let m = try BackupManifest(folder: fx.folder)
        #expect(m.format == .db)
        #expect(m.fileURL(domain: "MediaDomain", path: "Library/SMS/Attachments/aa/01/G/a.jpg") != nil)
        #expect(m.fileURL(domain: "MediaDomain", path: "Library/SMS/Attachments/aa/01/G/flat.jpg") != nil)
        #expect(m.contains(domain: "MediaDomain", path: "Library/SMS/Attachments/aa/01/G/gone.jpg"))
        #expect(m.fileURL(domain: "MediaDomain", path: "Library/SMS/Attachments/aa/01/G/gone.jpg") == nil)
        #expect(!m.contains(domain: "HomeDomain", path: "Library/SMS/Attachments/aa/01/G/a.jpg"))   // domain matters
        // the importer never writes next to the backup (immutable open): no -wal/-shm/-journal appears
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fx.folder.path).filter { $0.hasPrefix("Manifest.db-") }
        #expect(leftovers.isEmpty)
    }

    @Test func legacyMbdbIsParsedAndDirectoriesSkipped() throws {
        let dir = Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fx = BackupFixture(under: dir)
        fx.addFile(domain: "HomeDomain", path: "Library/SMS/sms.db", data: Data([9]), nested: false)
        fx.addFile(domain: "MediaDomain", path: "Library/SMS/Parts/00/00/1-1.jpg", data: Data([8]), nested: false)
        fx.writeManifestMBDB()
        let m = try BackupManifest(folder: fx.folder)
        #expect(m.format == .mbdb)
        #expect(m.entryCount == 3)                                   // two files + one directory record
        #expect(m.fileURL(domain: "HomeDomain", path: "Library/SMS/sms.db") != nil)
        #expect(m.fileURL(domain: "MediaDomain", path: "Library/SMS/Parts/00/00/1-1.jpg") != nil)
        #expect(!m.contains(domain: "HomeDomain", path: "Library/SMS"))
    }

    @Test func encryptedAndNonBackupFoldersAreRejectedClearly() throws {
        let dir = Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fx = BackupFixture(under: dir)
        fx.addFile(domain: "HomeDomain", path: "Library/SMS/sms.db", data: Data([9]), nested: true)
        fx.writeManifestDB(encryptedPlist: true)
        #expect(throws: ArchiveError.self) { try BackupManifest(folder: fx.folder) }
        do { _ = try BackupManifest(folder: fx.folder) } catch { #expect("\(error)".contains("encrypted")) }
        let empty = dir.appendingPathComponent("empty"); try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(!IOSBackupImporter.isBackupFolder(empty))
        #expect(throws: ArchiveError.self) { try BackupManifest(folder: empty) }
    }
}

// MARK: modern importer

@Suite struct ModernBackupImportTests {
    static let photo = Data(Fixtures.blob(7, count: 3000))
    static let photo2 = Data(Fixtures.blob(9, count: 1500))

    /// alice 1:1 (+ an email-only friend), a group of alice + bob, attachments present/missing/unlisted, a reaction,
    /// a system row, a deleted-from-chat message, and an orphan.
    static func make(dir: URL, name: String = "backup") -> BackupFixture {
        let fx = BackupFixture(under: dir, name: name)
        fx.addFile(domain: "MediaDomain", path: "Library/SMS/Attachments/ab/11/GUID1/IMG_0001.jpg", data: photo, nested: true)
        fx.addFile(domain: "MediaDomain", path: "Library/SMS/Attachments/cd/22/GUID2/IMG_0002.jpg", data: photo2, nested: true)
        fx.addFile(domain: "MediaDomain", path: "Library/SMS/Attachments/ee/33/GUID3/lost.jpg", data: Data([1]), nested: true, onDisk: false)
        fx.addSMSDatabase(nested: true) { db in
            for s in IOSFixtures.modernSchema { try db.exec(s) }
            try db.exec("""
                INSERT INTO handle(id, service) VALUES ('+12125550111','iMessage'), ('bob@example.com','iMessage'), ('+12125550133','SMS');
                INSERT INTO chat(guid, style, chat_identifier, service_name) VALUES
                    ('iMessage;-;+12125550111', 45, '+12125550111', 'iMessage'),
                    ('iMessage;+;chat1', 43, 'chat1', 'iMessage'),
                    ('SMS;-;+12125550133', 45, '+12125550133', 'SMS');
                INSERT INTO chat_handle_join VALUES (1,1), (2,1), (2,2), (3,3);
                """)
            let t: Int64 = 1_393_675_200                       // 2014-03-01 12:00:00 UTC
            let bodyBlob = IOSFixtures.hex(IOSFixtures.attributedBody("typed body only in attributedBody"))
            // (guid, text, attributedBody, handle, service, date, from_me, assoc, has_att, item_type)
            try db.exec("""
                INSERT INTO message(guid, text, attributedBody, handle_id, service, date, is_from_me, associated_message_type, cache_has_attachments, item_type) VALUES
                    ('G-1', 'hello from alice', NULL, 1, 'iMessage', \(IOSFixtures.apple(t)), 0, 0, 0, 0),
                    ('G-2', NULL, \(bodyBlob), 1, 'iMessage', \(IOSFixtures.appleNS(t + 60)), 1, 0, 0, 0),
                    ('G-3', char(65532), NULL, 1, 'iMessage', \(IOSFixtures.apple(t + 120)), 0, 0, 1, 0),
                    ('G-4', 'photo that is gone', NULL, 1, 'iMessage', \(IOSFixtures.apple(t + 180)), 1, 0, 1, 0),
                    ('G-5', 'Loved "hello from alice"', NULL, 1, 'iMessage', \(IOSFixtures.apple(t + 240)), 1, 2000, 0, 0),
                    ('G-6', 'group hello from bob', NULL, 2, 'iMessage', \(IOSFixtures.apple(t + 300)), 0, 0, 0, 0),
                    ('G-7', 'group reply from me', NULL, 0, 'iMessage', \(IOSFixtures.apple(t + 360)), 1, 0, 0, 0),
                    ('G-8', NULL, NULL, 0, 'iMessage', \(IOSFixtures.apple(t + 420)), 1, 0, 0, 1),
                    ('G-9', 'deleted from the chat list but still here', NULL, 1, 'iMessage', \(IOSFixtures.apple(t + 480)), 0, 0, 0, 0),
                    ('G-10', 'nobody to attach me to', NULL, 0, 'iMessage', \(IOSFixtures.apple(t + 540)), 0, 0, 0, 0),
                    ('G-11', 'sms with a picture', NULL, 3, 'SMS', \(IOSFixtures.apple(t + 600)), 0, 0, 1, 0),
                    ('G-12', 'no date', NULL, 1, 'iMessage', 0, 0, 0, 0, 0);
                UPDATE message SET associated_message_guid = 'p:0/G-1' WHERE guid = 'G-5';
                INSERT INTO chat_message_join VALUES (1,1),(1,2),(1,3),(1,4),(1,5),(2,6),(2,7),(2,8),(3,11);
                INSERT INTO attachment(guid, filename, mime_type, transfer_name, total_bytes) VALUES
                    ('A1', '~/Library/SMS/Attachments/ab/11/GUID1/IMG_0001.jpg', 'image/jpeg', 'IMG_0001.jpg', 3000),
                    ('A2', '~/Library/SMS/Attachments/ee/33/GUID3/lost.jpg', 'image/jpeg', 'lost.jpg', 1),
                    ('A3', '/var/mobile/Library/SMS/Attachments/cd/22/GUID2/IMG_0002.jpg', 'image/jpeg', 'IMG_0002.jpg', 1500),
                    ('A4', '/var/tmp/NOT-IN-ANY-BACKUP/x.jpg', 'image/jpeg', 'x.jpg', 5);
                INSERT INTO message_attachment_join VALUES (3,1), (4,2), (11,3), (11,4);
                """)
        }
        fx.addAddressBook(nested: true) { ab in
            try ab.exec("""
                CREATE TABLE ABPerson (ROWID INTEGER PRIMARY KEY, First TEXT, Last TEXT, Middle TEXT, Organization TEXT, Nickname TEXT, Kind INTEGER);
                CREATE TABLE ABMultiValue (UID INTEGER PRIMARY KEY, record_id INTEGER, property INTEGER, identifier INTEGER, label INTEGER, value TEXT);
                INSERT INTO ABPerson(ROWID, First, Last, Organization) VALUES (1,'Alice','Example',NULL), (2,NULL,NULL,'Bob Industries'), (3,NULL,NULL,NULL), (4,'Carol','Nophone',NULL);
                INSERT INTO ABMultiValue(record_id, property, identifier, label, value) VALUES
                    (1, 3, 0, 1, '(212) 555-0111'), (1, 4, 1, 1, 'Alice@Example.com'), (2, 4, 0, 1, 'bob@example.com'),
                    (3, 3, 0, 1, '212-555-0199'), (1, 5, 2, 1, '123 Fake St');
                """)
        }
        fx.writeManifestDB()
        return fx
    }

    @Test func importsMessagesEpochsBodiesAndSkipsNoise() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let fx = Self.make(dir: t.dir)
        let rep = try t.importBackup(fx)
        let s = rep.stats
        #expect(rep.status == .imported)
        #expect(s.schema == "modern" && s.manifestFormat == "db")
        #expect(s.messagesParsed == 12)
        #expect(s.reactionsSkipped == 0 && s.reactionsImported == 1)   // G-5 reacts to G-1
        #expect(try t.db.scalarInt("SELECT count(*) FROM reaction r JOIN message m ON m.id = r.message_id WHERE m.source_key = 'ios:G-1' AND r.emoji = '❤️' AND r.by_me = 1") == 1)
        #expect(s.emptySkipped == 1)          // G-8 (item_type 1, no text)
        #expect(s.orphansSkipped == 1)        // G-10
        #expect(s.invalidSkipped == 1)        // G-12
        #expect(s.inserted == 8 && s.duplicates == 0)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message") == 8)

        let base: Int64 = 1_393_675_200_000
        // seconds epoch, and the iMessage service
        #expect(try t.db.scalarInt("SELECT ts_ms FROM message WHERE source_key = 'ios:G-1'") == base)
        #expect(try t.db.scalarString("SELECT service FROM message WHERE source_key = 'ios:G-1'") == "imessage")
        // nanosecond epoch, body only in attributedBody, from-me has a NULL sender
        #expect(try t.db.scalarInt("SELECT ts_ms FROM message WHERE source_key = 'ios:G-2'") == base + 60_000)
        #expect(try t.db.scalarString("SELECT body FROM message WHERE source_key = 'ios:G-2'") == "typed body only in attributedBody")
        #expect(try t.db.scalarInt("SELECT sender_handle_id IS NULL AND is_from_me = 1 FROM message WHERE source_key = 'ios:G-2'") == 1)
        // incoming sender is the handle
        #expect(try t.db.scalarString("SELECT h.normalized FROM message m JOIN handle h ON h.id = m.sender_handle_id WHERE m.source_key = 'ios:G-1'") == "+12125550111")
        // attachment placeholder character removed: no body
        #expect(try t.db.scalarInt("SELECT body IS NULL FROM message WHERE source_key = 'ios:G-3'") == 1)
        // a message deleted from the chat list lands in the sender's thread via handle_id
        #expect(try t.db.scalarInt("""
            SELECT t.key = '+12125550111' FROM message m JOIN thread t ON t.id = m.thread_id WHERE m.source_key = 'ios:G-9'
            """) == 1)
        // group chat: participants from chat_handle_join, sender from handle_id, me = NULL
        #expect(try t.db.scalarInt("SELECT is_group FROM thread WHERE key = '+12125550111|bob@example.com'") == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message m JOIN thread t ON t.id = m.thread_id WHERE t.is_group = 1") == 2)
        #expect(try t.db.scalarString("SELECT h.normalized FROM message m JOIN handle h ON h.id = m.sender_handle_id WHERE m.source_key = 'ios:G-6'") == "bob@example.com")
        #expect(try t.db.scalarInt("SELECT sender_handle_id IS NULL FROM message WHERE source_key = 'ios:G-7'") == 1)
        // the reaction never became a row
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE source_key = 'ios:G-5'") == 0)
        // SMS with an attachment is an MMS
        #expect(try t.db.scalarString("SELECT service FROM message WHERE source_key = 'ios:G-11'") == "mms")
        // FTS sees the decoded body
        #expect(try t.db.scalarInt("SELECT count(*) FROM message_fts WHERE message_fts MATCH 'attributedbody'") == 1)
    }

    @Test func attachmentsResolveThroughTheManifestIntoTheMediaStore() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let fx = Self.make(dir: t.dir)
        let s = try t.importBackup(fx).stats
        // 4 joined attachments: IMG_0001 (~/ form), lost.jpg (listed, no file), IMG_0002 (/var/mobile/ form), x.jpg (not in the manifest)
        #expect(s.attachmentsReferenced == 4)
        #expect(s.attachmentsInManifest == 3)
        #expect(s.attachmentsStored == 2)
        #expect(s.attachmentsMissing == 2)
        #expect(s.mediaNewFiles == 2)
        #expect(try t.db.scalarInt("SELECT count(*) FROM attachment") == 2)

        let sha = IOSFixtures.sha256(Self.photo)
        let path = try t.db.scalarString("SELECT media_path FROM attachment WHERE sha256 = '\(sha)'")
        #expect(path == "media/\(sha.prefix(2))/\(sha).jpg")                      // root-relative, content-addressed
        #expect(try Data(contentsOf: t.root.resolve(relativePath: path!)) == Self.photo)
        #expect(try t.db.scalarString("SELECT filename FROM attachment WHERE sha256 = '\(sha)'") == "IMG_0001.jpg")
        #expect(try t.db.scalarString("SELECT mime FROM attachment WHERE sha256 = '\(sha)'") == "image/jpeg")
        // a message whose only attachment is missing is kept (the row proves a photo existed)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE source_key = 'ios:G-4'") == 1)
        // nothing absolute anywhere, and the whole archive verifies
        let v = try ArchiveVerifier.run(db: t.db, root: t.root)
        #expect(v.passed, "\(v.lines)")
    }

    @Test func contactsFromAddressBookUseTheirOwnOriginAndPriority() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let s = try t.importBackup(Self.make(dir: t.dir)).stats
        #expect(s.contactPeople == 3)                  // Alice, Bob Industries and Carol (named, though she has no number)
        #expect(s.contactNames == 3)                   // one number + two emails; the nameless person and the street address (property 5) are ignored
        let q = try t.db.prepare("SELECT n.name, n.origin, n.priority FROM contact_name n JOIN handle h ON h.id = n.handle_id WHERE h.normalized = ? ORDER BY n.name")
        q.bind(1, "+12125550111")
        #expect(try q.step())
        #expect(q.string(0) == "Alice Example" && q.string(1) == "iphone-addressbook" && q.int(2) == 20)
        q.reset()
        q.bind(1, "alice@example.com")
        #expect(try q.step() && q.string(0) == "Alice Example")
        q.reset()
        q.bind(1, "bob@example.com")
        #expect(try q.step() && q.string(0) == "Bob Industries")          // organization when there is no person name
    }

    @Test func reimportingTheSameOrAnIdenticalSnapshotIsANoOp() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let fx = Self.make(dir: t.dir)
        let first = try t.importBackup(fx)
        #expect(first.status == .imported)
        let again = try t.importBackup(fx)
        #expect(again.status == .alreadyImported && again.sourceID == first.sourceID && again.stats == first.stats)
        // an iMazing "Versions" copy: same sms.db bytes under another folder
        let copy = BackupFixture(under: t.dir, name: "snapshot")
        try FileManager.default.removeItem(at: copy.folder)
        try FileManager.default.copyItem(at: fx.folder, to: copy.folder)
        #expect(try t.importBackup(copy).status == .alreadyImported)
        #expect(try t.db.scalarInt("SELECT count(*) FROM source") == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message") == 8)
    }

    @Test func provenanceRecordsTheBackupFolderOrTheGivenOrigin() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        _ = try t.importBackup(Self.make(dir: t.dir), origin: "host:/share/archive/iMazing.Backups/xyz")
        #expect(try t.db.scalarString("SELECT path FROM source") == "host:/share/archive/iMazing.Backups/xyz")
        #expect(try t.db.scalarString("SELECT kind FROM source") == "ios-backup")
    }

    @Test func missingAddressBookIsNotAnError() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let fx = BackupFixture(under: t.dir)
        fx.addSMSDatabase(nested: true) { db in
            for s in IOSFixtures.modernSchema { try db.exec(s) }
            try db.exec("INSERT INTO handle(id, service) VALUES ('+12125550111','iMessage'); INSERT INTO chat(guid, style) VALUES ('c', 45); INSERT INTO chat_handle_join VALUES (1,1)")
        }
        fx.writeManifestDB()
        let s = try t.importBackup(fx).stats
        #expect(s.contactsNote?.contains("no AddressBook") == true && s.contactNames == 0)
    }
}

// MARK: legacy importer

@Suite struct LegacyBackupImportTests {
    static let thumb = Data(Fixtures.blob(3, count: 2200))
    static let partFile = Data(Fixtures.blob(5, count: 1800))
    static let madridPhoto = Data(Fixtures.blob(7, count: 1500))

    static func make(dir: URL, name: String = "legacy") -> BackupFixture {
        let fx = BackupFixture(under: dir, name: name)
        fx.addFile(domain: "MediaDomain", path: "Library/SMS/Parts/00/06/6-2.jpg", data: partFile, nested: false)
        fx.addFile(domain: "MediaDomain", path: "Library/SMS/Parts/00/06/6-2-preview.jpg", data: Data(Fixtures.blob(9, count: 300)), nested: false)
        fx.addFile(domain: "MediaDomain", path: "Library/SMS/Attachments/ab/11/IMG_1.jpg", data: madridPhoto, nested: false)
        fx.addSMSDatabase(nested: false) { db in
            for s in IOSFixtures.legacySchema { try db.exec(s) }
            let unix: Int64 = 1_325_419_200                 // 2012-01-01 12:00:00 UTC
            let blob = IOSFixtures.hex(IOSFixtures.attributedBody("legacy typed body"))
            try db.exec("""
                INSERT INTO msg_group(type) VALUES (0), (0), (1);
                INSERT INTO group_member(group_id, address) VALUES (1, '+12125550111'), (2, '+12125550122'), (3, '+12125550111'), (3, '+12125550122');
                INSERT INTO message(address, date, text, flags, group_id, madrid_attributedBody, madrid_handle, madrid_guid, madrid_roomname, is_madrid, subject, madrid_flags) VALUES
                    ('+12125550111', \(unix), 'sms in from alice', 2, 1, NULL, NULL, NULL, NULL, 0, NULL, NULL),
                    ('+12125550111', \(unix + 30), 'sms out to alice', 3, 1, NULL, NULL, NULL, NULL, 0, NULL, NULL),
                    (NULL, \(IOSFixtures.apple(unix + 60)), 'imessage in from bob', 0, 2, NULL, '+12125550122', 'MAD-1', NULL, 1, NULL, 77825),
                    (NULL, \(IOSFixtures.apple(unix + 90)), NULL, 0, 2, \(blob), '+12125550122', 'MAD-2', NULL, 1, NULL, 36869),
                    ('+12125550111', \(unix + 120), NULL, 2, 1, NULL, NULL, NULL, NULL, 0, NULL, NULL),
                    ('+12125550122', \(unix + 150), NULL, 3, 2, NULL, NULL, NULL, NULL, 0, NULL, NULL),
                    (NULL, \(IOSFixtures.apple(unix + 180)), 'group imessage from bob', 0, 3, NULL, '+12125550122', 'MAD-3', 'chat123', 1, NULL, 12289),
                    ('+12125550111', 0, 'bad date', 2, 1, NULL, NULL, NULL, NULL, 0, NULL, NULL),
                    ('+12125550111', \(unix + 200), 'sent to the group', 3, 3, NULL, NULL, NULL, NULL, 0, NULL, NULL),
                    ('+12125550122', \(unix + 200), 'sent to the group', 3, 3, NULL, NULL, NULL, NULL, 0, NULL, NULL),
                    ('+12125550111', \(unix + 230), 'sent to the group', 3, 3, NULL, NULL, NULL, NULL, 0, NULL, NULL),
                    (NULL, \(IOSFixtures.apple(unix + 260)), NULL, 0, 2, NULL, '+12125550122', 'MAD-4', NULL, 1, NULL, 12289);
                INSERT INTO madrid_attachment(message_id, filename, mime_type) VALUES (12, '/var/mobile/Library/SMS/Attachments/ab/11/IMG_1.jpg', 'image/jpeg');
                INSERT INTO msg_pieces(message_id, data, content_type, content_loc, part_id) VALUES
                    (5, \(IOSFixtures.hex(Data("mms caption".utf8))), 'text/plain', NULL, 0),
                    (5, \(IOSFixtures.hex(thumb)), 'image/jpeg', 'inline.jpg', 1),
                    (5, NULL, 'application/smil', NULL, 2),
                    (6, NULL, 'image/jpeg', 'photo.jpg', 2),
                    (6, NULL, 'image/jpeg', 'not-there.jpg', 3);
                """)
        }
        fx.writeManifestMBDB()
        return fx
    }

    @Test func importsLegacySchemaWithBothEpochs() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let fx = Self.make(dir: t.dir)
        let rep = try t.importBackup(fx)
        let s = rep.stats
        #expect(s.schema == "legacy" && s.manifestFormat == "mbdb")
        #expect(s.messagesParsed == 12 && s.invalidSkipped == 1 && s.inserted == 10 && s.groupSendCollapsed == 1)

        let base: Int64 = 1_325_419_200_000
        // SMS rows: Unix seconds. iMessage rows: Apple seconds. Same wall-clock offsets land on the same scale.
        #expect(try t.db.scalarInt("SELECT ts_ms FROM message WHERE body = 'sms in from alice'") == base)
        #expect(try t.db.scalarInt("SELECT ts_ms FROM message WHERE body = 'imessage in from bob'") == base + 60_000)
        #expect(try t.db.scalarInt("SELECT ts_ms FROM message WHERE body = 'legacy typed body'") == base + 90_000)
        // direction: SMS from flags (2 in / 3 out); iMessage rows have flags 0 and carry it in madrid_flags bit 2
        #expect(try t.db.scalarInt("SELECT is_from_me FROM message WHERE body = 'sms in from alice'") == 0)
        #expect(try t.db.scalarInt("SELECT is_from_me FROM message WHERE body = 'sms out to alice'") == 1)
        #expect(try t.db.scalarInt("SELECT is_from_me FROM message WHERE body = 'imessage in from bob'") == 0)
        #expect(try t.db.scalarInt("SELECT is_from_me FROM message WHERE body = 'legacy typed body'") == 1)
        #expect(try t.db.scalarString("SELECT sh.normalized FROM message m JOIN handle sh ON sh.id = m.sender_handle_id WHERE m.body = 'imessage in from bob'") == "+12125550122")
        #expect(try t.db.scalarString("SELECT service FROM message WHERE body = 'imessage in from bob'") == "imessage")
        #expect(try t.db.scalarString("SELECT service FROM message WHERE body = 'sms in from alice'") == "sms")
        // iMessage guid becomes the cross-source key
        #expect(try t.db.scalarString("SELECT source_key FROM message WHERE body = 'imessage in from bob'") == "ios:MAD-1")
        // group via group_member
        #expect(try t.db.scalarInt("SELECT is_group FROM thread WHERE key = '+12125550111|+12125550122'") == 1)
        #expect(try t.db.scalarString("SELECT h.normalized FROM message m JOIN handle h ON h.id = m.sender_handle_id WHERE m.body = 'group imessage from bob'") == "+12125550122")
    }

    @Test func legacyPiecesBecomeBodyAndAttachments() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let s = try t.importBackup(Self.make(dir: t.dir)).stats
        // message 5: caption + inline image; message 6: image via manifest + a missing one
        #expect(try t.db.scalarString("SELECT body FROM message WHERE ts_ms = 1325419200000 + 120000") == "mms caption")
        #expect(try t.db.scalarString("SELECT service FROM message WHERE ts_ms = 1325419200000 + 120000") == "mms")
        // message 5: inline thumb. message 6: Parts/<mid>-<pid> file (not its -preview) + a missing one. message 12: madrid_attachment.
        #expect(s.attachmentsReferenced == 4 && s.attachmentsInline == 1 && s.attachmentsStored == 3 && s.attachmentsMissing == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM attachment WHERE message_id IN (SELECT id FROM message WHERE ts_ms = 1325419200000 + 260000)") == 1)
        #expect(try t.db.scalarString("SELECT service FROM message WHERE ts_ms = 1325419200000 + 260000") == "imessage")
        for data in [Self.thumb, Self.partFile, Self.madridPhoto] {
            let sha = IOSFixtures.sha256(data)
            let p = try #require(try t.db.scalarString("SELECT media_path FROM attachment WHERE sha256 = '\(sha)'"))
            #expect(try Data(contentsOf: t.root.resolve(relativePath: p)) == data)
        }
        let v = try ArchiveVerifier.run(db: t.db, root: t.root)
        #expect(v.passed, "\(v.lines)")
    }

    @Test func sentGroupSMSStoredPerRecipientIsFoldedToOneRow() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        _ = try t.importBackup(Self.make(dir: t.dir))
        // two copies at +200 fold into one; the later send with the same text stays a separate message
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE body = 'sent to the group'") == 2)
    }
}

// MARK: cross-source dedup

@Suite struct CrossSourceDedupTests {
    static let t: Int64 = 1_478_000_000          // 2016-11-01, inside the iPhone/Android overlap

    /// iPhone backup with one iMessage out to alice, one in from alice, and one photo-only iMessage.
    static func iphone(dir: URL) -> BackupFixture {
        let fx = BackupFixture(under: dir, name: "iphone")
        fx.addFile(domain: "MediaDomain", path: "Library/SMS/Attachments/aa/aa/G/p.jpg", data: ModernBackupImportTests.photo, nested: true)
        fx.addSMSDatabase(nested: true) { db in
            for s in IOSFixtures.modernSchema { try db.exec(s) }
            try db.exec("""
                INSERT INTO handle(id, service) VALUES ('+12125550111','iMessage');
                INSERT INTO chat(guid, style) VALUES ('c1', 45);
                INSERT INTO chat_handle_join VALUES (1,1);
                INSERT INTO message(guid, text, handle_id, service, date, is_from_me) VALUES
                    ('IM-1', 'see you at five', 1, 'iMessage', \(IOSFixtures.apple(t)), 1),
                    ('IM-2', 'sounds good', 1, 'iMessage', \(IOSFixtures.apple(t + 100)), 0),
                    ('IM-3', 'iphone only', 1, 'iMessage', \(IOSFixtures.apple(t + 200)), 1);
                INSERT INTO chat_message_join VALUES (1,1), (1,2), (1,3);
                """)
        }
        fx.writeManifestDB()
        return fx
    }

    /// The Android export: iMessage copies flattened to SMS (some with jittered clocks) plus lookalikes that must not match.
    static func android() -> String {
        let a = Fixtures.alice          // (212) 555-0111
        return Fixtures.file([
            Fixtures.sms(address: a, date: t * 1000 + 1500, type: 2, body: "see you at five"),        // +1.5 s, same direction: copy
            Fixtures.sms(address: a, date: (t + 100) * 1000, type: 1, body: "sounds good"),           // exact: copy
            Fixtures.sms(address: a, date: (t + 100) * 1000, type: 2, body: "sounds good"),           // other direction: NOT a copy
            Fixtures.sms(address: a, date: (t + 5) * 1000, type: 2, body: "see you at five"),         // +5 s: NOT a copy
            Fixtures.sms(address: a, date: (t + 300) * 1000, type: 1, body: "android only"),
        ])
    }

    func check(_ t: TestArchive) throws {
        // 3 iPhone + 5 Android rows; exactly the two flattened copies are duplicates.
        #expect(try t.db.scalarInt("SELECT count(*) FROM message") == 8)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NOT NULL") == 2)
        // every duplicate points at the iPhone row, regardless of import order
        let q = try t.db.prepare("""
            SELECT d.body, d.service, c.service, s.kind FROM message d
            JOIN message c ON c.id = d.canonical_id JOIN source s ON s.id = c.source_id ORDER BY d.ts_ms
            """)
        var seen = 0
        while try q.step() {
            seen += 1
            #expect(q.string(1) == "sms")                    // the duplicate is the flattened Android copy
            #expect(q.string(2) == "imessage" && q.string(3) == "ios-backup")
        }
        #expect(seen == 2)
        // lookalikes outside the rules stay canonical
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NULL AND body IN ('android only','iphone only')") == 2)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NULL AND service = 'sms' AND ts_ms IN (\((Self.t + 5) * 1000), \((Self.t + 100) * 1000))") == 2)
        let v = try ArchiveVerifier.run(db: t.db, root: t.root)
        #expect(v.passed, "\(v.lines)")
    }

    @Test func androidCopyOfIMessageLosesWhenIPhoneIsImportedFirst() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let ip = try t.importBackup(Self.iphone(dir: t.dir))
        #expect(ip.stats.duplicates == 0)
        let an = try t.importXML(Self.android(), name: "a.xml")
        #expect(an.stats.duplicates == 2 && an.stats.inserted == 3)
        try check(t)
    }

    @Test func iPhoneRowTakesOverWhenImportedAfterTheAndroidCopy() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        let an = try t.importXML(Self.android(), name: "a.xml")
        #expect(an.stats.duplicates == 0)
        // the Android rows were canonical until the iPhone rows outrank them
        let ip = try t.importBackup(Self.iphone(dir: t.dir))
        #expect(ip.stats.duplicates == 2 && ip.stats.inserted == 1)
        try check(t)
    }

    @Test func serviceIsIgnoredWhenMatching() throws {
        // The Android copy says "sms", the iPhone row says "imessage": they still match (asserted above); and an iPhone
        // SMS row matches an Android SMS row too.
        let t = try TestArchive(); defer { t.cleanup() }
        let fx = BackupFixture(under: t.dir, name: "smsphone")
        fx.addSMSDatabase(nested: true) { db in
            for s in IOSFixtures.modernSchema { try db.exec(s) }
            try db.exec("""
                INSERT INTO handle(id, service) VALUES ('+12125550111','SMS');
                INSERT INTO chat(guid, style) VALUES ('c1', 45);
                INSERT INTO chat_handle_join VALUES (1,1);
                INSERT INTO message(guid, text, handle_id, service, date, is_from_me) VALUES ('S-1', 'plain sms', 1, 'SMS', \(IOSFixtures.apple(Self.t)), 0);
                INSERT INTO chat_message_join VALUES (1,1);
                """)
        }
        fx.writeManifestDB()
        try t.importBackup(fx)
        let an = try t.importXML(Fixtures.file([Fixtures.sms(address: Fixtures.alice, date: Self.t * 1000, type: 1, body: "plain sms")]), name: "b.xml")
        #expect(an.stats.duplicates == 1)
    }

    @Test func iPhoneSnapshotsOfTheSameMessagesDedupByGuid() throws {
        // iOS 5 backup and iOS 10 backup of the same iMessage: the shared guid links them even when clocks differ a lot.
        let t = try TestArchive(); defer { t.cleanup() }
        _ = try t.importBackup(Self.iphone(dir: t.dir))
        let fx = BackupFixture(under: t.dir, name: "old")
        fx.addSMSDatabase(nested: false) { db in
            for s in IOSFixtures.legacySchema { try db.exec(s) }
            try db.exec("""
                INSERT INTO msg_group(type) VALUES (0);
                INSERT INTO group_member(group_id, address) VALUES (1, '+12125550111');
                INSERT INTO message(address, date, text, flags, group_id, madrid_handle, madrid_guid, is_madrid) VALUES
                    (NULL, \(IOSFixtures.apple(Self.t + 30)), 'see you at five', 13, 1, '+12125550111', 'IM-1', 1);
                """)
        }
        fx.writeManifestMBDB()
        let rep = try t.importBackup(fx)
        #expect(rep.stats.duplicates == 1)
        // equal rank (both iPhone, no attachments): the earlier source stays canonical
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NOT NULL AND source_id = \(rep.sourceID)") == 1)
    }

    @Test func rowWithAttachmentsBeatsRowWithout() throws {
        // Two iPhone sources carrying the same message; the copy that kept its photo is canonical.
        let t = try TestArchive(); defer { t.cleanup() }
        func backup(name: String, withPhoto: Bool, guid: String = "SAME-GUID") -> BackupFixture {
            let fx = BackupFixture(under: t.dir, name: name)
            fx.addFile(domain: "MediaDomain", path: "Library/SMS/Attachments/aa/aa/G/p.jpg", data: ModernBackupImportTests.photo, nested: true)
            fx.addSMSDatabase(nested: true) { db in
                for s in IOSFixtures.modernSchema { try db.exec(s) }
                try db.exec("""
                    INSERT INTO handle(id, service) VALUES ('+12125550111','SMS');
                    INSERT INTO chat(guid, style) VALUES ('c1', 45);
                    INSERT INTO chat_handle_join VALUES (1,1);
                    INSERT INTO message(guid, text, handle_id, service, date, is_from_me) VALUES ('\(guid)', 'pic caption', 1, 'SMS', \(IOSFixtures.apple(Self.t)), 0);
                    INSERT INTO chat_message_join VALUES (1,1);
                    """)
                if withPhoto {
                    try db.exec("""
                        UPDATE message SET cache_has_attachments = 1;
                        INSERT INTO attachment(guid, filename, mime_type) VALUES ('A', '~/Library/SMS/Attachments/aa/aa/G/p.jpg', 'image/jpeg');
                        INSERT INTO message_attachment_join VALUES (1,1);
                        """)
                }
            }
            fx.writeManifestDB()
            return fx
        }
        try t.importBackup(backup(name: "plain", withPhoto: false))
        let rep = try t.importBackup(backup(name: "photo", withPhoto: true))
        #expect(rep.stats.duplicates == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message m WHERE canonical_id IS NULL AND EXISTS (SELECT 1 FROM attachment a WHERE a.message_id = m.id)") == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NULL") == 1)

        // Different iMessage guids are different messages even when the clocks and text agree.
        try t.importBackup(backup(name: "other", withPhoto: false, guid: "DIFFERENT-GUID"))
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NULL") == 2)
    }
}

// MARK: contacts across sources

@Suite struct ContactNameTests {
    @Test func androidXMLNamesUseTheirOwnOriginAndLosePriority() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        try t.importXML(Fixtures.file([Fixtures.sms(address: Fixtures.alice, date: 1_478_000_000_000, type: 1, body: "hi", name: "Ali From Xml")]), name: "a.xml")
        _ = try t.importBackup(ModernBackupImportTests.make(dir: t.dir))
        let q = try t.db.prepare("""
            SELECT n.name, n.origin, n.priority FROM contact_name n JOIN handle h ON h.id = n.handle_id
            WHERE h.normalized = '+12125550111' ORDER BY n.priority DESC
            """)
        #expect(try q.step() && q.string(0) == "Alice Example" && q.string(1) == "iphone-addressbook" && q.int(2) == 20)
        #expect(try q.step() && q.string(0) == "Ali From Xml" && q.string(1) == "android-xml" && q.int(2) == 10)
        #expect(try !q.step())
    }

    @Test func migrationRenamesTheOldXMLOrigin() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        // simulate a v1 archive carrying the old spelling
        try t.db.exec("INSERT INTO handle(id, raw, normalized, kind) VALUES (1, '+1', '+1', 'phone')")
        try t.db.exec("INSERT INTO contact_name(handle_id, name, origin, priority) VALUES (1, 'Old', 'xml', 10)")
        try t.db.exec("PRAGMA user_version = 1")
        try Schema.migrate(t.db)
        #expect(try t.db.scalarString("SELECT origin FROM contact_name") == "android-xml")
        #expect(try t.db.userVersion() == Schema.currentVersion)
    }
}
