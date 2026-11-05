import CoreImage
import XCTest
@testable import Cutline

@MainActor
final class ProjectImportTests: XCTestCase {
    private var package: URL!
    override func tearDown() async throws { if let package { try? FileManager.default.removeItem(at: package) } }

    /// A music video with a song, two video tracks, placed and auto lyrics, cinemascope and fixes.
    private func musicVideo() -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        p.fpsLocked = true
        let song = Asset(kind: .audio, name: "song.wav", path: "/tmp/song.wav", duration: 60)
        var video = Asset(kind: .video, name: "a.mov", path: "/tmp/a.mov", pixelSize: .init(width: 1920, height: 1080), duration: 20, frameRate: 24)
        video.proxy = ProxyInfo(scale: .quarter, fileName: ProxyManager.fileName(for: video.id))
        let image = Asset(kind: .image, name: "logo.png", path: "/tmp/logo.png", pixelSize: .init(width: 400, height: 400))
        p.assets = [song, video, image]
        p.audio = AudioClip(assetID: song.id, start: 1.5, duration: 60)
        var clip = Clip(assetID: video.id, start: 0, duration: 10, sourceIn: 2)
        clip.transform = ClipTransform(scale: 1.4, offsetX: 300, offsetY: -120)
        clip.filters.color.enabled = true
        clip.filters.color.saturation = 1.3
        var logo = Clip(assetID: image.id, start: 2, duration: 4)
        logo.transform = ClipTransform(scale: 0.3, offsetX: 700, offsetY: 400)
        p.videoTracks = [VideoTrack(clips: [clip]), VideoTrack(clips: [logo])]
        var placed = LyricLine(start: 3, end: 5, words: [LyricWord(text: "hello", start: 3.1, end: 4, confidence: 0.4),
                                                       LyricWord(text: "world", start: 4.05, end: 5, confirmed: true)])
        placed.centerX = 400
        placed.centerY = 200
        let second = LyricLine(start: 6, end: 7.5, words: [LyricWord(text: "again", start: 6.2, end: 7.5, alignedStart: 6.35, alignedEnd: 7.5)])
        p.lyricTracks = [LyricTrack(lines: [placed, second]), LyricTrack(lines: [LyricLine(start: 3, end: 5, words: [LyricWord(text: "echo", start: 3.2, end: 5)])])]
        p.lyricStyle.sizeFraction = 0.05
        p.lyricStyle.leadIn = 0.2
        p.cinemascope = Cinemascope(enabled: true, startMarker: 10, endMarker: 14)
        p.lyricsLanguage = "tr"
        return p
    }

    private func words(_ p: Project) -> [[[String: Double]]] {
        p.lyricTracks.map { $0.lines.flatMap { l in l.words.map { ["start": $0.start, "end": $0.end, "line": l.start, "lineEnd": l.end] } } }
    }

    func testAnAdImportedFromAMusicVideoHasTheSameWordTimes() {
        let src = musicVideo()
        let r = ProjectImport.make(from: src, type: .ad, canvas: .init(width: 1080, height: 1920))
        let p = r.project
        XCTAssertEqual(p.type, .ad)
        XCTAssertEqual(p.canvas, .init(width: 1080, height: 1920))
        XCTAssertEqual(words(p), words(src))
        XCTAssertEqual(p.lyricTracks.flatMap(\.lines).flatMap(\.words).map(\.text), ["hello", "world", "again", "echo"])
        let w = p.lyricTracks[0].lines.flatMap(\.words)
        XCTAssertEqual(w.map(\.confidence), [0.4, 1, 1], "confidence comes along")
        XCTAssertEqual(w.map(\.confirmed), [false, true, false])
        XCTAssertEqual(w[2].alignedStart, 6.35, "the lead-in keeps working on aligned words")
        XCTAssertEqual(p.audio?.start, 1.5)
        XCTAssertEqual(p.lyricStyle, src.lyricStyle)
        XCTAssertEqual(p.lyricsLanguage, "tr")
        XCTAssertEqual(p.fps, 24)
        XCTAssertTrue(p.fpsLocked)
        XCTAssertEqual(p.videoTracks.count, 2, "track layout comes along")
        XCTAssertEqual(p.lyricTracks.count, 2)
    }

    func testEverythingGetsNewIDs() {
        let src = musicVideo()
        let p = ProjectImport.make(from: src, type: .social, canvas: .init(width: 1080, height: 1920)).project
        let oldIDs = Set(src.assets.map(\.id) + src.videoTracks.map(\.id) + src.videoTracks.flatMap(\.clips).map(\.id)
                         + src.lyricTracks.map(\.id) + src.lyricTracks.flatMap(\.lines).map(\.id) + src.lyricTracks.flatMap(\.lines).flatMap(\.words).map(\.id))
        let newIDs = Set(p.assets.map(\.id) + p.videoTracks.map(\.id) + p.videoTracks.flatMap(\.clips).map(\.id)
                         + p.lyricTracks.map(\.id) + p.lyricTracks.flatMap(\.lines).map(\.id) + p.lyricTracks.flatMap(\.lines).flatMap(\.words).map(\.id))
        XCTAssertEqual(newIDs.count, oldIDs.count)
        XCTAssertTrue(oldIDs.isDisjoint(with: newIDs))
        // Every reference points at an imported asset.
        let assets = Set(p.assets.map(\.id))
        XCTAssertTrue(assets.contains(p.audio!.assetID))
        XCTAssertTrue(p.videoTracks.flatMap(\.clips).allSatisfy { assets.contains($0.assetID) })
        XCTAssertEqual(p.assets.compactMap(\.proxy).map(\.fileName), [ProxyManager.fileName(for: p.assets[1].id)])
    }

    func testEditingTheSourceAfterwardsDoesNotChangeTheImport() {
        var src = musicVideo()
        let p = ProjectImport.make(from: src, type: .ad, canvas: .init(width: 1080, height: 1920)).project
        let before = p
        src.lyricTracks[0].lines[0].words[0].start = 3.5
        src.videoTracks[0].clips[0].duration = 2
        src.assets[1].name = "renamed"
        src.audio?.start = 0
        XCTAssertEqual(p, before)
        // Edits in the import don't reach the source either (value types, no shared IDs).
        var imported = p
        imported.lyricTracks[0].lines[0].words[0].start = 3.3
        XCTAssertEqual(src.lyricTracks[0].lines[0].words[0].start, 3.5)
    }

    func testImportedClipsAreCentredOn1080x1920AtTheirOriginalScale() {
        let src = musicVideo()
        let p = ProjectImport.make(from: src, type: .ad, canvas: .init(width: 1080, height: 1920)).project
        let clips = p.videoTracks.flatMap(\.clips)
        XCTAssertEqual(clips.map(\.transform), [ClipTransform(scale: 1.4), ClipTransform(scale: 0.3)])
        XCTAssertEqual(clips.map(\.start), [0, 2])
        XCTAssertEqual(clips.map(\.duration), [10, 4])
        XCTAssertEqual(clips[0].sourceIn, 2)
        XCTAssertEqual(clips[0].filters, src.videoTracks[0].clips[0].filters, "filters come along")
        // The clip's centre is the canvas centre.
        let canvas = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let rect = FrameRenderer.place(image, transform: clips[0].transform, canvas: canvas).extent
        XCTAssertEqual(rect.midX, canvas.midX, accuracy: 0.5)
        XCTAssertEqual(rect.midY, canvas.midY, accuracy: 0.5)
        XCTAssertEqual(rect.width, 1080 * 1.4, accuracy: 0.5, "same scale relative to the fit")
    }

    func testLinePositionsResetAndCinemascopeOnlyForMusicVideos() {
        let src = musicVideo()
        let ad = ProjectImport.make(from: src, type: .ad, canvas: .init(width: 1080, height: 1920)).project
        XCTAssertTrue(ad.lyricTracks.flatMap(\.lines).allSatisfy { !$0.hasPosition })
        XCTAssertFalse(ad.cinemascope.enabled)
        let mv = ProjectImport.make(from: src, type: .musicVideo, canvas: .init(width: 3840, height: 2160)).project
        XCTAssertEqual(mv.cinemascope, src.cinemascope)
    }

    func testCachesAreCopiedUnderTheNewIDsAndNothingIsShared() throws {
        let src = musicVideo()
        package = FileManager.default.temporaryDirectory.appendingPathComponent("import-src-\(UUID().uuidString).cutline")
        let fm = FileManager.default
        for f in ProjectDocument.cacheFolders { try fm.createDirectory(at: package.appendingPathComponent(f), withIntermediateDirectories: true) }
        try ProjectDocument.save(project: src, layout: LayoutState(), to: package)
        let song = src.assets[0].id, video = src.assets[1].id
        try Data("a".utf8).write(to: package.appendingPathComponent("analysis/audio-abc.json"))
        try Data("v".utf8).write(to: package.appendingPathComponent("analysis/vocals-abc.flac"))
        try Data("w".utf8).write(to: package.appendingPathComponent("analysis/waveform-\(song.uuidString).plist"))
        try Data("t".utf8).write(to: package.appendingPathComponent("thumbnails/\(video.uuidString).png"))
        try Data("p".utf8).write(to: package.appendingPathComponent("proxies/\(ProxyManager.fileName(for: video))"))
        try fm.createDirectory(at: package.appendingPathComponent("cache/segments"), withIntermediateDirectories: true)
        try Data("s".utf8).write(to: package.appendingPathComponent("cache/segments/0-abc.mov"))

        let doc = try ProjectImport.document(importing: package, type: .ad, canvas: .init(width: 1080, height: 1920))
        defer { doc.close() }
        let p = doc.editor.project
        XCTAssertTrue(doc.isDocumentEdited, "an untitled import asks to be saved")
        XCTAssertNil(doc.fileURL)
        let newSong = p.assets[0].id, newVideo = p.assets[1].id
        let dst = doc.packageURL
        XCTAssertNotEqual(dst.standardizedFileURL, package.standardizedFileURL)
        for (path, body) in [("analysis/audio-abc.json", "a"), ("analysis/vocals-abc.flac", "v"),
                             ("analysis/waveform-\(newSong.uuidString).plist", "w"), ("thumbnails/\(newVideo.uuidString).png", "t"),
                             ("proxies/\(ProxyManager.fileName(for: newVideo))", "p")] {
            XCTAssertEqual(try? String(contentsOf: dst.appendingPathComponent(path), encoding: .utf8), body, path)
        }
        XCTAssertEqual(p.assets[1].proxy?.fileName, ProxyManager.fileName(for: newVideo))
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("cache/segments/0-abc.mov").path), "the render cache isn't copied")
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("analysis/waveform-\(song.uuidString).plist").path))

        // The copies are independent files.
        try Data("changed".utf8).write(to: package.appendingPathComponent("analysis/audio-abc.json"))
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("analysis/audio-abc.json"), encoding: .utf8), "a")
    }

    func testAProxyWhoseFileIsMissingIsDropped() throws {
        let src = musicVideo()
        package = FileManager.default.temporaryDirectory.appendingPathComponent("import-src-\(UUID().uuidString).cutline")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try ProjectDocument.save(project: src, layout: LayoutState(), to: package)
        let doc = try ProjectImport.document(importing: package, type: .social, canvas: .init(width: 1080, height: 1920))
        defer { doc.close() }
        XCTAssertNil(doc.editor.project.assets[1].proxy)
    }
}

/// F2 on a real project: set TEST_RUNNER_CUTLINE_IMPORT_SOURCE to a .cutline package and
/// TEST_RUNNER_CUTLINE_IMPORT_DEST to where the imported ad project is saved.
@MainActor
final class ProjectImportOnRealProjectTests: XCTestCase {
    func testImportAnAdFromTheSampleProject() throws {
        let env = ProcessInfo.processInfo.environment
        guard let src = env["CUTLINE_IMPORT_SOURCE"], let dst = env["CUTLINE_IMPORT_DEST"] else {
            throw XCTSkip("Set CUTLINE_IMPORT_SOURCE and CUTLINE_IMPORT_DEST to run")
        }
        let srcURL = URL(fileURLWithPath: src), dstURL = URL(fileURLWithPath: dst)
        let (source, _) = try ProjectDocument.load(from: srcURL)
        let doc = try ProjectImport.document(importing: srcURL, type: .ad, canvas: .init(width: 1080, height: 1920))
        defer { doc.close() }
        let p = doc.editor.project
        XCTAssertEqual(p.lyricTracks.flatMap(\.lines).flatMap(\.words).map(\.start), source.lyricTracks.flatMap(\.lines).flatMap(\.words).map(\.start))
        try? FileManager.default.removeItem(at: dstURL)
        try doc.write(to: dstURL, ofType: "com.emrahgunduz.cutline.project", for: .saveAsOperation, originalContentsURL: doc.packageURL)
        let analysis = try FileManager.default.contentsOfDirectory(atPath: dstURL.appendingPathComponent("analysis").path)
        XCTAssertTrue(analysis.contains { $0.hasPrefix("audio-") }, "song analysis came along: \(analysis)")
    }
}
