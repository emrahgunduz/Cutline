import XCTest
@testable import Cutline

final class ProjectCodingTests: XCTestCase {
    private func sampleProject() -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        let video = Asset(kind: .video, name: "A.mp4", path: "/tmp/A.mp4", pixelSize: .init(width: 2560, height: 1440), duration: 8, frameRate: 24)
        let audio = Asset(kind: .audio, name: "song.wav", path: "/tmp/song.wav", duration: 225)
        p.assets = [video, audio]
        p.audio = AudioClip(assetID: audio.id, duration: 225)
        p.videoTracks[0].clips = [Clip(assetID: video.id, start: 2, duration: 4, sourceIn: 1)]
        p.lyricTracks[0].lines = [LyricLine(start: 1, end: 3, words: [
            LyricWord(text: "Kör", start: 1, end: 1.5),
            LyricWord(text: "aynalarda", start: 1.5, end: 3),
        ])]
        p.cinemascope.enabled = true
        return p
    }

    func testRoundTripThroughPackage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cutline")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = sampleProject()
        let layout = LayoutState(assetsWidth: 333, inspectorWidth: 222, timelineHeight: 411)
        try ProjectDocument.save(project: project, layout: layout, to: dir)
        let (loaded, loadedLayout) = try ProjectDocument.load(from: dir)
        XCTAssertEqual(loaded, project)
        XCTAssertEqual(loadedLayout, layout)
    }

    func testAdPresetIsPortraitWithThirtySecondLimit() {
        let preset = Presets.preset(for: .ad)
        XCTAssertEqual(preset.canvases.first, CanvasSize(width: 1080, height: 1920))
        XCTAssertEqual(preset.maxDuration, 30)
        XCTAssertEqual(preset.codec, .h264)
        XCTAssertNil(Presets.preset(for: .musicVideo).maxDuration)
        XCTAssertEqual(Presets.preset(for: .social).maxDuration, 180)
    }

    func testNewerSchemaFailsWithReadableError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cutline")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"schemaVersion": 99}"#.data(using: .utf8)!.write(to: dir.appendingPathComponent("project.json"))
        XCTAssertThrowsError(try ProjectDocument.load(from: dir)) { error in
            XCTAssertTrue(error.localizedDescription.contains("newer Cutline"))
        }
    }

    func testDurationIsLaterOfAudioAndLastClip() {
        var p = sampleProject()
        XCTAssertEqual(p.duration, 225)
        p.videoTracks[0].clips[0].start = 230
        XCTAssertEqual(p.duration, 234)
        XCTAssertEqual(Project(type: .social, canvas: .init(width: 1080, height: 1920)).duration, 0)
    }
}

@MainActor
final class ReopenTests: XCTestCase {
    func testReopenedProjectLoadsCachedWaveform() async throws {
        let wav = try TestMedia.sineWAV(seconds: 1)
        defer { try? FileManager.default.removeItem(at: wav) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reopen-\(UUID()).cutline")
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        _ = await doc.editor.importFiles([wav])
        try await Task.sleep(nanoseconds: 300_000_000)
        try await doc.save(to: url, ofType: "com.emrahgunduz.cutline.project", for: .saveAsOperation)

        let reopened = try ProjectDocument(contentsOf: url, ofType: "com.emrahgunduz.cutline.project")
        let id = try XCTUnwrap(reopened.editor.project.assets.first?.id)
        XCTAssertNil(reopened.editor.waveforms.waveforms[id])
        reopened.editor.warmCaches()
        for _ in 0..<50 where reopened.editor.waveforms.waveforms[id] == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(reopened.editor.waveforms.waveforms[id])
    }

    func testCacheWritesDoNotLookLikeOutsideEdits() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moddate-\(UUID()).cutline")
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        try await doc.save(to: url, ofType: "com.emrahgunduz.cutline.project", for: .saveAsOperation)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        _ = doc.folder("analysis")            // internal write after save
        doc.persistLayout()
        let onDisk = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(doc.fileModificationDate, onDisk)
    }
}
