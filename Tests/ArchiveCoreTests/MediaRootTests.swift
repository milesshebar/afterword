import Testing
import Foundation
@testable import ArchiveCore

@Suite struct MediaRootTests {
    @Test func defaultsToTheFolderInsideTheArchive() {
        let dir = Fixtures.tempDir("mr"); defer { try? FileManager.default.removeItem(at: dir) }
        let root = ArchiveRoot(url: dir, environment: [:])
        #expect(root.mediaOverride == nil && root.mediaURL.lastPathComponent == "media" && root.mediaProblem == nil)
        #expect(root.resolve(relativePath: "media/ab/x.jpg").path == dir.appendingPathComponent("media/ab/x.jpg").standardizedFileURL.path)
    }

    @Test func mediaRootFileRedirectsOnlyMediaPaths() throws {
        let dir = Fixtures.tempDir("mr"), far = Fixtures.tempDir("mrfar")
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: far) }
        try (far.path + "\n").write(to: dir.appendingPathComponent("media-root"), atomically: true, encoding: .utf8)
        let root = ArchiveRoot(url: dir, environment: [:])
        #expect(root.mediaOverride?.path == far.standardizedFileURL.path && root.mediaProblem == nil)
        #expect(root.resolve(relativePath: "media/ab/x.jpg").path == far.standardizedFileURL.appendingPathComponent("ab/x.jpg").path)
        #expect(root.resolve(relativePath: "people.sqlite").path == dir.appendingPathComponent("people.sqlite").standardizedFileURL.path)
        // the environment variable wins over the file
        let other = Fixtures.tempDir("mrenv"); defer { try? FileManager.default.removeItem(at: other) }
        #expect(ArchiveRoot(url: dir, environment: [ArchiveRoot.mediaRootEnvironmentKey: other.path]).mediaOverride?.path == other.standardizedFileURL.path)
    }

    @Test func storingAndOpeningFollowTheMediaRoot() throws {
        let dir = Fixtures.tempDir("mr"), far = Fixtures.tempDir("mrfar")
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: far) }
        try far.path.write(to: dir.appendingPathComponent("media-root"), atomically: true, encoding: .utf8)
        let root = ArchiveRoot(url: dir, environment: [:])
        let db = try Schema.openArchive(root: root)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("media").path))       // no stray media/ next to the database
        let bytes = Data(Fixtures.blob(5, count: 100))
        let stored = try bytes.withUnsafeBytes { try MediaStore(root: root).store($0, mime: "image/jpeg", filename: "a.jpg", lookup: { _ in nil }) }
        #expect(stored.relativePath.hasPrefix("media/"))
        #expect(FileManager.default.fileExists(atPath: far.appendingPathComponent(String(stored.relativePath.dropFirst(6))).path))
        _ = db
    }

    @Test func aMediaRootOnAnUnmountedVolumeFailsClearlyAndCreatesNothing() throws {
        let dir = Fixtures.tempDir("mr"); defer { try? FileManager.default.removeItem(at: dir) }
        try "/Volumes/NoSuchVolume-\(UUID().uuidString)/MessageArchive/media".write(to: dir.appendingPathComponent("media-root"), atomically: true, encoding: .utf8)
        let root = ArchiveRoot(url: dir, environment: [:])
        let problem = try #require(root.mediaProblem)
        #expect(problem.contains("is not mounted") && problem.contains("media-root"))
        #expect(throws: ArchiveError.self) { try root.createIfNeeded() }
        #expect(throws: ArchiveError.self) { _ = try Schema.openArchive(root: root) }
        #expect(!FileManager.default.fileExists(atPath: "/Volumes/" + (root.mediaOverride!.pathComponents[2])))
        // a read-only open of an existing archive is refused the same way
        try Data().write(to: dir.appendingPathComponent("archive.sqlite"))
        #expect(throws: ArchiveError.self) { _ = try Schema.openArchive(root: root, readOnly: true) }
    }

    @Test func aMissingMediaFolderOnAMountedPlaceIsReported() throws {
        let dir = Fixtures.tempDir("mr"); defer { try? FileManager.default.removeItem(at: dir) }
        try dir.appendingPathComponent("nowhere").path.write(to: dir.appendingPathComponent("media-root"), atomically: true, encoding: .utf8)
        #expect(ArchiveRoot(url: dir, environment: [:]).mediaProblem?.contains("does not exist") == true)
    }
}
