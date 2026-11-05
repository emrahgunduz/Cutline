import Darwin
import XCTest
@testable import Cutline

// MARK: - Placing dummies (the tool's model work)

final class PlaceDummiesTests: XCTestCase {
    private func project(songStart: Double = 0) -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        let song = Asset(kind: .audio, name: "song", path: "/s", duration: 200)
        let clip = Asset(kind: .video, name: "v", path: "/v", pixelSize: .init(width: 1920, height: 1080), duration: 60, frameRate: 24)
        p.assets = [song, clip]
        p.audio = AudioClip(assetID: song.id, start: songStart, duration: 200)
        p.videoTracks[0].clips = [Clip(assetID: clip.id, start: 0, duration: 60)]
        p.lyricTracks[0].lines = [LyricLine(start: 5, end: 7, words: [LyricWord(text: "hi", start: 5, end: 7)])]
        return p
    }

    private let scenes = [PlacedScene(title: "Opening", description: "Dawn.", start: 0, end: 12.5, color: nil),
                          PlacedScene(title: "", description: "Verse", start: 12.5, end: 31, color: RGBA(r: 1, g: 0, b: 0, a: 1))]

    func testScenesBecomeDummiesAtTheirTimesOnTheDummiesTrack() throws {
        var p = project()
        let placed = try p.placeDummies(scenes, songTime: true, replace: true, defaults: DummyDefaults())
        XCTAssertEqual(placed.map(\.start), [0, 12.5])
        XCTAssertEqual(placed.map(\.end), [12.5, 31])
        let t = p.videoTracks.firstIndex { $0.name == "Dummies" }!
        XCTAssertEqual(t, p.videoTracks.count - 1, "a new track on top")
        XCTAssertEqual(p.videoTracks[t].clips.map(\.start), [0, 12.5])
        XCTAssertEqual(p.videoTracks[t].clips.map(\.duration), [12.5, 18.5])
        let cards = p.videoTracks[t].clips.compactMap { p.asset($0.assetID)?.dummy }
        XCTAssertEqual(cards.map(\.title), ["Opening", "Dummy 0001"])
        XCTAssertEqual(cards.map(\.sceneDescription), ["Dawn.", "Verse"])
        XCTAssertEqual(cards[1].color, RGBA(r: 1, g: 0, b: 0, a: 1))
        XCTAssertEqual(cards.map(\.length), [12.5, 18.5], "each card says how long its scene is")
    }

    func testSongTimesFollowWhereTheSongStarts() throws {
        var p = project(songStart: 2)
        let placed = try p.placeDummies(scenes, songTime: true, replace: true, defaults: DummyDefaults())
        XCTAssertEqual(placed.map(\.start), [2, 14.5])
        var q = project(songStart: 2)
        XCTAssertEqual(try q.placeDummies(scenes, songTime: false, replace: true, defaults: DummyDefaults()).map(\.start), [0, 12.5], "timeline times as given")
    }

    func testTimesLandOnFrames() throws {
        var p = project()
        let placed = try p.placeDummies([PlacedScene(title: "x", description: "", start: 1.01, end: 2.03, color: nil)], songTime: true, replace: true, defaults: DummyDefaults())
        XCTAssertEqual(placed[0].start, p.quantize(1.01))
        XCTAssertEqual(placed[0].end, p.quantize(2.03))
    }

    func testAudioLyricsAndOtherClipsAreNeverTouched() throws {
        let before = project()
        var p = before
        try p.placeDummies(scenes, songTime: true, replace: true, defaults: DummyDefaults())
        p.clearDummiesTrack()
        XCTAssertEqual(p.audio, before.audio)
        XCTAssertEqual(p.lyricTracks, before.lyricTracks)
        XCTAssertEqual(p.videoTracks[0], before.videoTracks[0])
    }

    func testRunningAgainReplacesTheEarlierDummies() throws {
        var p = project()
        try p.placeDummies(scenes, songTime: true, replace: true, defaults: DummyDefaults())
        try p.placeDummies([scenes[0]], songTime: true, replace: true, defaults: DummyDefaults())
        let t = p.videoTracks.firstIndex { $0.name == "Dummies" }!
        XCTAssertEqual(p.videoTracks[t].clips.count, 1)
        XCTAssertEqual(p.assets.filter(\.isDummy).count, 1, "the replaced cards are gone from the assets too")
        XCTAssertEqual(p.videoTracks.filter { $0.name == "Dummies" }.count, 1, "the same track is reused")
        try p.placeDummies([scenes[1]], songTime: true, replace: false, defaults: DummyDefaults())
        XCTAssertEqual(p.videoTracks[t].clips.count, 2, "replace: false adds")
    }

    func testClearingKeepsDummiesUsedElsewhere() throws {
        var p = project()
        try p.placeDummies([scenes[0]], songTime: true, replace: true, defaults: DummyDefaults())
        let card = p.assets.first(where: \.isDummy)!
        p.videoTracks[0].clips.append(Clip(assetID: card.id, start: 100, duration: 5))
        XCTAssertEqual(p.clearDummiesTrack(), 1)
        XCTAssertNotNil(p.asset(card.id), "still used on Video 1")
    }

    func testArgumentsAreChecked() throws {
        func args(_ json: String) throws -> [PlacedScene] { try ControlTools.scenes(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) }
        XCTAssertEqual(try args(##"{"scenes":[{"title":"A","start":1,"end":2,"color":"#FF8000"}]}"##).first?.color, RGBA(r: 1, g: 128.0 / 255, b: 0, a: 1))
        XCTAssertThrowsError(try args(#"{"scenes":[]}"#))
        XCTAssertThrowsError(try args(#"{"scenes":[{"start":3,"end":2}]}"#), "end before start")
        XCTAssertThrowsError(try args(#"{"scenes":[{"start":-1,"end":2}]}"#))
        XCTAssertThrowsError(try args(#"{"scenes":[{"start":"1","end":2}]}"#), "times are numbers")
        XCTAssertThrowsError(try args(#"{"scenes":[{"start":1,"end":2,"color":"red"}]}"#))
        XCTAssertThrowsError(try args(#"{"nothing":1}"#))
    }
}

// MARK: - Tracks

final class ControlTrackTests: XCTestCase {
    /// Video 1 has footage at 0-20 s and 40-60 s; an image on Video 2 at 10-15 s.
    private func project() -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        let v = Asset(kind: .video, name: "a.mp4", path: "/a", pixelSize: .init(width: 1920, height: 1080), duration: 60, frameRate: 24)
        let i = Asset(kind: .image, name: "logo.png", path: "/l.png", pixelSize: .init(width: 400, height: 400))
        p.assets = [v, i]
        p.videoTracks = [VideoTrack(clips: [Clip(assetID: v.id, start: 0, duration: 20), Clip(assetID: v.id, start: 40, duration: 20)]),
                         VideoTrack(clips: [Clip(assetID: i.id, start: 10, duration: 5)])]
        return p
    }

    private func scene(_ s: Double, _ e: Double, _ t: String = "") -> PlacedScene { PlacedScene(title: t, description: "", start: s, end: e, color: nil) }

    func testTracksAreListedBottomFirstWithWhatIsOnThem() throws {
        var p = project()
        try p.placeDummies([scene(70, 80, "Outro")], songTime: false, replace: true, defaults: DummyDefaults())
        let tracks = try XCTUnwrap(p.videoTrackListing.array)
        XCTAssertEqual(tracks.count, 3)
        XCTAssertEqual(tracks.map { $0["name"]?.string }, ["Video 1", "Video 2", "Dummies"])
        XCTAssertEqual(tracks.map { $0["index"]?.number }, [0, 1, 2])
        XCTAssertEqual(tracks[0]["id"]?.string, p.videoTracks[0].id.uuidString.lowercased())
        let items = try XCTUnwrap(tracks[0]["items"]?.array)
        XCTAssertEqual(items.map { $0["kind"]?.string }, ["video", "video"])
        XCTAssertEqual(items.map { $0["start"]?.number }, [0, 40])
        XCTAssertEqual(items.map { $0["end"]?.number }, [20, 60])
        XCTAssertEqual(items[0]["name"]?.string, "a.mp4")
        XCTAssertEqual(tracks[1]["items"]?.array?.first?["kind"]?.string, "image")
        XCTAssertEqual(tracks[2]["items"]?.array?.first?["kind"]?.string, "dummy")
        XCTAssertEqual(tracks[2]["items"]?.array?.first?["name"]?.string, "Outro")
    }

    func testTracksCanBeCreatedAnywhere() {
        var p = project()
        XCTAssertEqual(p.createVideoTrack(name: "Scenes", above: nil), 2, "top by default")
        XCTAssertEqual(p.videoTracks[2].name, "Scenes")
        XCTAssertEqual(p.createVideoTrack(name: nil, above: -1), 0, "bottom")
        XCTAssertNil(p.videoTracks[0].name)
        XCTAssertEqual(p.createVideoTrack(name: "  ", above: 1), 2, "right above track 1; a blank name is no name")
        XCTAssertNil(p.videoTracks[2].name)
        XCTAssertEqual(p.videoTracks.count, 5)
    }

    func testDummiesGoOnTheChosenTrackInTheGaps() throws {
        var p = project()
        let placed = try p.placeDummies([scene(20, 40, "Bridge"), scene(60, 70)], track: 0, songTime: false, replace: true, defaults: DummyDefaults())
        XCTAssertEqual(placed.map(\.start), [20, 60])
        XCTAssertEqual(p.videoTracks[0].clips.map(\.start), [0, 20, 40, 60], "fitted between the footage, in time order")
        XCTAssertNil(p.videoTracks.first { $0.name == "Dummies" }, "no Dummies track made when a track is chosen")
    }

    func testAnOverlapRefusesTheWholeCallAndChangesNothing() {
        var p = project()
        let before = p
        XCTAssertThrowsError(try p.placeDummies([scene(20, 30), scene(35, 45)], track: 0, songTime: false, replace: true, defaults: DummyDefaults())) { e in
            XCTAssertTrue(e.localizedDescription.contains("a.mp4"), e.localizedDescription)
        }
        XCTAssertEqual(p, before, "not even the first scene was placed")
        XCTAssertThrowsError(try p.placeDummies([scene(11, 12)], track: 1, songTime: false, replace: true, defaults: DummyDefaults()), "images count too")
    }

    func testReplacingAndRemovingOnlyEverTouchDummies() throws {
        var p = project()
        try p.placeDummies([scene(20, 40)], track: 0, songTime: false, replace: true, defaults: DummyDefaults())
        try p.placeDummies([scene(25, 35)], track: 0, songTime: false, replace: true, defaults: DummyDefaults())
        XCTAssertEqual(p.videoTracks[0].clips.map(\.start), [0, 25, 40], "the earlier dummy is replaced, the footage stays")
        XCTAssertEqual(p.clearDummies(onTrack: 0), 1)
        XCTAssertEqual(p.videoTracks[0].clips.count, 2)
        XCTAssertEqual(p.assets.filter(\.isDummy).count, 0)
        // Without replace, an earlier dummy in the way is an overlap.
        try p.placeDummies([scene(20, 30)], track: 0, songTime: false, replace: true, defaults: DummyDefaults())
        XCTAssertThrowsError(try p.placeDummies([scene(25, 35)], track: 0, songTime: false, replace: false, defaults: DummyDefaults()))
    }

    func testTracksAreFoundByIndexOrId() throws {
        let p = project()
        XCTAssertEqual(try p.videoTrackIndex(.number(1)), 1)
        XCTAssertEqual(try p.videoTrackIndex(.string(p.videoTracks[1].id.uuidString.lowercased())), 1)
        XCTAssertEqual(try p.videoTrackIndex(.string(p.videoTracks[1].id.uuidString)), 1, "any case")
        XCTAssertNil(try p.videoTrackIndex(nil))
        XCTAssertThrowsError(try p.videoTrackIndex(.number(5)))
        XCTAssertThrowsError(try p.videoTrackIndex(.number(0.5)))
        XCTAssertThrowsError(try p.videoTrackIndex(.string("nope")))
        XCTAssertThrowsError(try p.videoTrackIndex(.bool(true)))
    }
}

@MainActor
final class ControlTrackToolTests: XCTestCase {
    func testClaudesWorkflow() async throws {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        let v = Asset(kind: .video, name: "a.mp4", path: "/a", pixelSize: .init(width: 1920, height: 1080), duration: 60, frameRate: 24)
        p.assets = [v]
        p.videoTracks[0].clips = [Clip(assetID: v.id, start: 0, duration: 30)]
        let doc = ProjectDocument(project: p)
        let s = ControlService()
        s.approve = { _, _ in true }
        s.documents = { [doc] }
        let token = await s.handle(ControlRequest(type: "hello", client: "Claude")).token!
        _ = await s.handle(ControlRequest(type: "use", token: token, project: doc.controlID))
        // 1. Look at the tracks: Video 1 has footage at 0-30 s, so it isn't usable for 0-60 s scenes.
        let list = await s.handle(ControlRequest(type: "call", token: token, tool: "list_video_tracks"))
        XCTAssertEqual(list.result?["tracks"]?.array?.count, 1)
        // 2. Placing there is refused with the reason.
        let scenes = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"scenes":[{"title":"A","start":0,"end":20},{"title":"B","start":20,"end":60}],"track":0}"#.utf8))
        let refused = await s.handle(ControlRequest(type: "call", token: token, tool: "add_dummies", args: scenes))
        XCTAssertEqual(refused.type, "error")
        // 3. Create a track of its own and fill it.
        let made = await s.handle(ControlRequest(type: "call", token: token, tool: "create_video_track",
                                                 args: .object(["name": .string("Treatment v2")])))
        let id = try XCTUnwrap(made.result?["id"]?.string)
        XCTAssertEqual(made.result?["index"]?.number, 1)
        var a = scenes
        if case .object(var o) = a { o["track"] = .string(id); a = .object(o) }
        let ok = await s.handle(ControlRequest(type: "call", token: token, tool: "add_dummies", args: a))
        XCTAssertEqual(ok.type, "result", ok.message ?? "")
        XCTAssertEqual(ok.result?["track"]?["name"]?.string, "Treatment v2")
        XCTAssertEqual(doc.editor.project.videoTracks[1].clips.count, 2)
        XCTAssertEqual(doc.editor.project.videoTracks[0].clips.count, 1, "the footage track is untouched")
        // 4. There is no way to delete a track.
        let del = await s.handle(ControlRequest(type: "call", token: token, tool: "delete_video_track", args: .object(["track": .number(1)])))
        XCTAssertEqual(del.type, "error")
        XCTAssertEqual(doc.editor.project.videoTracks.count, 2)
    }
}

// MARK: - The handshake

@MainActor
final class ControlHandshakeTests: XCTestCase {
    private var docs: [ProjectDocument] = []
    private var asked: [(String, String)] = []

    private func service(approve: Bool) -> ControlService {
        let s = ControlService()
        s.approve = { [unowned self] c, p in self.asked.append((c, p)); return approve }
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        docs = [ProjectDocument(project: p), ProjectDocument(project: Project(type: .ad, canvas: .init(width: 1080, height: 1920)))]
        s.documents = { [unowned self] in self.docs }
        return s
    }

    func testNothingWorksBeforeTheUserApproves() async {
        let s = service(approve: true)
        for type in ["projects", "use", "tools", "call", "bye"] {
            let r = await s.handle(ControlRequest(type: type, token: "made-up"))
            XCTAssertEqual(r.type, "error", type)
        }
        XCTAssertTrue(asked.isEmpty)
    }

    func testTheUserIsAskedAndCanSayNo() async {
        let s = service(approve: false)
        let r = await s.handle(ControlRequest(type: "hello", client: "Claude", purpose: "Place dummies"))
        XCTAssertEqual(r.type, "denied")
        XCTAssertNil(r.token)
        XCTAssertNil(r.projects, "no project names without approval")
        XCTAssertEqual(asked.first?.0, "Claude")
        XCTAssertEqual(asked.first?.1, "Place dummies")
        XCTAssertTrue(s.sessions.isEmpty)
    }

    func testTheWholeConversation() async throws {
        let s = service(approve: true)
        let hello = await s.handle(ControlRequest(type: "hello", client: "Claude", purpose: "Place dummies"))
        XCTAssertEqual(hello.type, "welcome")
        let token = try XCTUnwrap(hello.token)
        XCTAssertEqual(token.count, 64, "256 random bits")
        XCTAssertEqual(hello.projects?.count, 2, "the open projects")
        // Calling a tool before choosing a project is refused.
        let early = await s.handle(ControlRequest(type: "call", token: token, tool: "project_info"))
        XCTAssertEqual(early.type, "error")
        let use = await s.handle(ControlRequest(type: "use", token: token, project: docs[0].controlID))
        XCTAssertEqual(use.type, "ok")
        XCTAssertEqual(use.project?.width, 1920)
        let tools = await s.handle(ControlRequest(type: "tools", token: token))
        XCTAssertEqual(tools.tools?.map(\.name), ["project_info", "list_video_tracks", "create_video_track", "add_dummies", "remove_dummies"])
        let args = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"scenes":[{"title":"Intro","description":"Dawn","start":0,"end":4}]}"#.utf8))
        let call = await s.handle(ControlRequest(type: "call", token: token, tool: "add_dummies", args: args))
        XCTAssertEqual(call.type, "result")
        XCTAssertEqual(docs[0].editor.project.assets.filter(\.isDummy).map(\.name), ["Intro"])
        XCTAssertTrue(docs[1].editor.project.assets.isEmpty, "only the chosen project changes")
        let bye = await s.handle(ControlRequest(type: "bye", token: token))
        XCTAssertEqual(bye.type, "bye")
        let after = await s.handle(ControlRequest(type: "tools", token: token))
        XCTAssertEqual(after.type, "error", "the session is over")
    }

    func testPlacingDummiesIsOneUndoStep() async throws {
        let s = service(approve: true)
        let token = await s.handle(ControlRequest(type: "hello", client: "Claude")).token!
        _ = await s.handle(ControlRequest(type: "use", token: token, project: docs[0].controlID))
        let args = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"scenes":[{"start":0,"end":4},{"start":4,"end":9}]}"#.utf8))
        _ = await s.handle(ControlRequest(type: "call", token: token, tool: "add_dummies", args: args))
        XCTAssertEqual(docs[0].editor.project.assets.filter(\.isDummy).count, 2)
        docs[0].undoManager?.undo()
        XCTAssertTrue(docs[0].editor.project.assets.filter(\.isDummy).isEmpty)
        XCTAssertNil(docs[0].editor.project.videoTracks.first { $0.name == "Dummies" }, "the track goes too")
    }

    func testUnknownProjectsAndToolsAreRefused() async {
        let s = service(approve: true)
        let token = await s.handle(ControlRequest(type: "hello", client: "Claude")).token!
        let r1 = await s.handle(ControlRequest(type: "use", token: token, project: "nope"))
        XCTAssertEqual(r1.type, "error")
        _ = await s.handle(ControlRequest(type: "use", token: token, project: docs[0].controlID))
        let r2 = await s.handle(ControlRequest(type: "call", token: token, tool: "delete_everything"))
        XCTAssertEqual(r2.type, "error")
        let r3 = await s.handle(ControlRequest(type: "hello"))
        XCTAssertEqual(r3.type, "error", "hello needs a client name")
    }

    func testIdleSessionsExpireAndTheUserCanDisconnect() async {
        let s = service(approve: true)
        var clock = Date()
        s.now = { clock }
        let a = await s.handle(ControlRequest(type: "hello", client: "Claude")).token!
        clock = clock.addingTimeInterval(ControlProtocol.idleTimeout + 1)
        let r4 = await s.handle(ControlRequest(type: "tools", token: a))
        XCTAssertEqual(r4.type, "error", "15 minutes of silence ends it")
        let b = await s.handle(ControlRequest(type: "hello", client: "Claude")).token!
        s.disconnectAll()
        let r5 = await s.handle(ControlRequest(type: "tools", token: b))
        XCTAssertEqual(r5.type, "error", "Disconnect ends it")
    }

    func testEveryHelloAsksAgain() async {
        let s = service(approve: true)
        _ = await s.handle(ControlRequest(type: "hello", client: "Claude"))
        _ = await s.handle(ControlRequest(type: "hello", client: "Claude"))
        XCTAssertEqual(asked.count, 2, "approval is never remembered")
    }
}

// MARK: - The socket

final class ControlSocketTests: XCTestCase {
    private func roundTrip(_ url: URL, _ lines: [ControlRequest]) throws -> [ControlResponse] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: url.path.utf8); raw[url.path.utf8.count] = 0 }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(ok, 0)
        var out: [ControlResponse] = []
        var buffer = Data(), chunk = [UInt8](repeating: 0, count: 65536)
        for req in lines {
            let d = ControlProtocol.encodeLine(req)
            _ = d.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            while buffer.firstIndex(of: 0x0A) == nil {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                buffer.append(contentsOf: chunk[0..<n])
            }
            guard let nl = buffer.firstIndex(of: 0x0A) else { break }
            out.append(try JSONDecoder().decode(ControlResponse.self, from: buffer[..<nl]))
            buffer.removeSubrange(...nl)
        }
        return out
    }

    func testRequestsGoThroughTheSocketAndOnlyTheUserCanOpenIt() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cc-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("1.sock")
        let server = ControlServer(url: url) { r in
            r.type == "hello" ? ControlResponse(type: "welcome", token: "t") : ControlResponse(type: r.type == "bye" ? "bye" : "echo", message: r.tool)
        }
        try server.start()
        defer { server.stop() }
        let mode = { (path: String) in ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 }
        XCTAssertEqual(mode(dir.path), 0o700, "only the user can enter the folder")
        XCTAssertEqual(mode(url.path), 0o600, "only the user can open the socket")
        let replies = try roundTrip(url, [ControlRequest(type: "hello", client: "Claude"), ControlRequest(type: "call", token: "t", tool: "x"),
                                          ControlRequest(type: "bye", token: "t")])
        XCTAssertEqual(replies.map(\.type), ["welcome", "echo", "bye"])
        XCTAssertEqual(replies[1].message, "x", "several requests on one connection")
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the socket goes away with the app")
    }

    func testGarbageGetsAnErrorNotACrash() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cc-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("2.sock")
        let server = ControlServer(url: url) { _ in ControlResponse(type: "ok") }
        try server.start()
        defer { server.stop() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: url.path.utf8); raw[url.path.utf8.count] = 0 }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        _ = "not json\n".withCString { write(fd, $0, 9) }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &chunk, chunk.count)
        let reply = try JSONDecoder().decode(ControlResponse.self, from: Data(chunk[0..<max(0, n - 1)]))
        XCTAssertEqual(reply.type, "error")
    }

    func testJSONValuesRoundTrip() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":[1,"two",true,null,{"b":2.5}]}"#.utf8))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v)), v)
        XCTAssertEqual(v["a"]?.array?[1].string, "two")
        XCTAssertEqual(v["a"]?.array?[4]["b"]?.number, 2.5)
    }
}
