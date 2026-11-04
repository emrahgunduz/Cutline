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
