import Testing
import Foundation
@testable import ArchiveCore

/// Voicemails and voice memos through the web app's routes: the list, the search, one recording, the audio by content hash,
/// and a voicemail carried by its caller's message pages. Synthetic data only (RecordingFixtures).
@Suite(.serialized) struct RecordingsWebTests {
    typealias F = RecordingFixtures

    private func fixture() throws -> (TestArchive, WebSite, F.Audio, F.Audio) {
        let t = try F.archive()
        let tr = t.dir.appendingPathComponent("transcripts")
        let p = try F.basePlan(t, transcripts: tr)
        _ = try RecordingImporter.run(plan: p.url, transcripts: tr, into: t.db, root: t.root)
        _ = try PeopleStore.rematch(db: t.db)
        try t.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        return (t, WebSite(service: try WebService(root: t.root)), p.amr, p.aac)
    }

    private func get(_ path: String, _ query: [String: String] = [:], headers: [String: String] = [:]) -> HTTPRequest {
        var h = ["Host": "127.0.0.1:8452", "X-Requested-With": WebSite.requestedWith]
        for (k, v) in headers { h[k] = v }
        return HTTPRequest(method: "GET", path: path, query: query, headers: h, peer: "127.0.0.1")
    }
    private func dict(_ r: HTTPResponse) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]) ?? [:] }
    private func list(_ r: HTTPResponse) -> [[String: Any]] { ((try? JSONSerialization.jsonObject(with: r.body)) as? [[String: Any]]) ?? [] }

    @Test func theListSearchAndOneRecording() throws {
        let (t, site, _, aac) = try fixture(); defer { t.cleanup() }
        #expect(dict(site.handle(get("/api/overview")))["recordings"] as? Int == 5)
        let page = dict(site.handle(get("/api/recordings", ["limit": "2"])))
        let rows = page["recordings"] as? [[String: Any]] ?? []
        #expect(rows.count == 2 && page["voicemails"] as? Int == 3 && page["memos"] as? Int == 2)
        #expect(rows[0]["title"] as? String == "Voicemail from Alice Example")                  // the export, tied to her by its name
        #expect(rows[0]["heard"] == nil && rows[0]["timeIsOwn"] as? Bool == true)
        #expect(rows[1]["title"] as? String == "Voicemail from (212) 555-0199" && rows[1]["person"] == nil)   // a number the archive does not know
        let next = dict(site.handle(get("/api/recordings", ["limit": "10", "ts": "\(page["nextTs"] as? Int ?? 0)", "id": "\(page["nextID"] as? Int ?? 0)"])))
        let rest = next["recordings"] as? [[String: Any]] ?? []
        #expect(rest.map { $0["title"] as? String } == ["Porch", "Kitchen", "Voicemail from Alice Example"] && next["nextTs"] == nil)
        #expect(rest[0]["audio"] == nil && (rest[0]["note"] as? String)?.contains("iCloud") == true)   // listed without audio, and says why
        // the voicemail plays its AAC copy and names the original
        #expect(rest[2]["audio"] as? String == aac.sha && rest[2]["mime"] as? String == "audio/mp4" && rest[2]["original"] != nil)
        let tr = (rest[2]["transcripts"] as? [[String: Any]])?.first
        #expect(tr?["origin"] as? String == "machine" && tr?["model"] as? String == "test/parakeet" && tr?["segments"] == nil)
        #expect((dict(site.handle(get("/api/recordings", ["kind": "memo"])))["recordings"] as? [[String: Any]])?.count == 2)
        #expect(site.handle(get("/api/recordings", ["kind": "calls"])).status == 400)

        let hits = list(site.handle(get("/api/recordings/search", ["q": "lighthouse"])))
        #expect(hits.count == 1 && (hits[0]["snippet"] as? String)?.contains("\u{1}lighthouse\u{2}") == true)
        #expect(site.handle(get("/api/recordings/search")).status == 400)
        #expect(list(site.handle(get("/api/recordings/search", ["q": "ferns", "kind": "voicemail"]))).isEmpty)
        let one = dict(site.handle(get("/api/recording/\(hits[0]["id"] as? Int ?? 0)")))
        let segs = ((one["transcripts"] as? [[String: Any]])?.first?["segments"] as? [[String: Any]]) ?? []
        #expect(segs.count == 1 && segs[0]["end"] as? Double == 1.5)
        #expect(site.handle(get("/api/recording/9999")).status == 404)
        #expect(site.handle(get("/api/recordings", headers: ["X-Requested-With": "x"])).status == 403)
    }

    @Test func theAudioIsServedByEitherHashWithRanges() throws {
        let (t, site, amr, aac) = try fixture(); defer { t.cleanup() }
        let play = site.handle(get("/media/\(aac.sha)"))
        #expect(play.status == 200 && play.headers["Content-Type"] == "audio/mp4" && play.headers["Accept-Ranges"] == "bytes")
        #expect(play.headers["Cache-Control"]?.contains("immutable") == true)
        let part = site.handle(get("/media/\(aac.sha)", headers: ["Range": "bytes=0-3"]))
        #expect(part.status == 206 && part.headers["Content-Range"] == "bytes 0-3/\(aac.bytes)")
        #expect(site.handle(get("/media/\(amr.sha)")).headers["Content-Type"] == "audio/amr")       // the source's own file stays reachable
        #expect(site.handle(get("/media/" + String(repeating: "0", count: 64))).status == 404)
    }

    @Test func aVoicemailRidesItsCallersMessagePages() throws {
        let (t, site, _, _) = try fixture(); defer { t.cleanup() }
        let people = dict(site.handle(get("/api/people")))["people"] as? [[String: Any]] ?? []
        let alice = try #require(people.first { $0["name"] as? String == "Alice Example" })
        #expect(alice["voicemails"] as? Int == 2)
        let id = "\(alice["id"] as? Int ?? 0)"
        #expect(dict(site.handle(get("/api/person/\(id)")))["voicemails"] as? Int == 2)
        let latest = dict(site.handle(get("/api/messages", ["person": id, "mode": "latest", "limit": "40"])))
        let vms = latest["voicemails"] as? [[String: Any]] ?? []
        #expect(vms.count == 2 && vms[0]["ts"] as? Int64 == F.t0 + 150_000 && vms[0]["kind"] as? String == "voicemail")
        #expect((vms[0]["transcripts"] as? [[String: Any]])?.first?["text"] as? String == "hey it is alice calling about the lighthouse")
        // a page of the first three messages carries the voicemail that falls between them, not the one a day later
        let msgs = latest["messages"] as? [[String: Any]] ?? []
        let fourth = msgs[3]
        let before = dict(site.handle(get("/api/messages", ["person": id, "mode": "before", "ts": "\(fourth["ts"] as? Int64 ?? 0)", "id": "\(fourth["id"] as? Int ?? 0)", "limit": "3"])))
        #expect((before["voicemails"] as? [[String: Any]])?.map { $0["ts"] as? Int64 } == [F.t0 + 150_000])
        // under another service's filter a voicemail (a phone call) is not shown
        #expect(dict(site.handle(get("/api/messages", ["person": id, "mode": "latest", "services": "messenger"])))["voicemails"] == nil)
        // Bob left none
        let bob = try #require(people.first { ($0["name"] as? String)?.contains("555-0122") == true })
        #expect(bob["voicemails"] == nil)
        #expect(dict(site.handle(get("/api/messages", ["person": "\(bob["id"] as? Int ?? 0)", "mode": "latest"])))["voicemails"] == nil)
    }
}
