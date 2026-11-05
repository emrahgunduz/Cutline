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
        let id = try XCTUnwrap(doc.editor.project.assets.first?.id)
        for _ in 0..<250 where doc.editor.waveforms.waveforms[id] == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(doc.editor.waveforms.waveforms[id])
        try await doc.save(to: url, ofType: "com.emrahgunduz.cutline.project", for: .saveAsOperation)
        let plist = url.appendingPathComponent("analysis/waveform-\(id.uuidString).plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))

        // With the source gone, only the cached plist can produce the waveform.
        try FileManager.default.removeItem(at: wav)
        let reopened = try ProjectDocument(contentsOf: url, ofType: "com.emrahgunduz.cutline.project")
        XCTAssertEqual(reopened.editor.project.assets.first?.id, id)
        XCTAssertNil(reopened.editor.waveforms.waveforms[id])
        reopened.editor.warmCaches()
        for _ in 0..<50 where reopened.editor.waveforms.waveforms[id] == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(reopened.editor.waveforms.waveforms[id])
    }

    private func savedDocument() async throws -> (ProjectDocument, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moddate-\(UUID()).cutline")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        try await doc.save(to: url, ofType: "com.emrahgunduz.cutline.project", for: .saveAsOperation)
        try await Task.sleep(nanoseconds: 20_000_000)
        return (doc, url)
    }

    private func assertSameDate(_ a: Date?, _ b: Date?, file: StaticString = #filePath, line: UInt = #line) {
        guard let a, let b else { return XCTFail("missing date", file: file, line: line) }
        XCTAssertEqual(a.timeIntervalSinceReferenceDate, b.timeIntervalSinceReferenceDate, accuracy: 0.000_5, file: file, line: line)
    }

    func testSaveCreatesEveryCacheFolder() async throws {
        let (_, url) = try await savedDocument()
        for name in ProjectDocument.cacheFolders {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path), name)
        }
    }

    func testInternalWritesDoNotLookLikeOutsideEdits() async throws {
        let (doc, url) = try await savedDocument()
        let saved = doc.fileModificationDate
        await MainActor.run { doc.persistLayout() }
        try Data([1]).write(to: url.appendingPathComponent("thumbnails/x.png"))   // cache write in a subfolder
        XCTAssertNotEqual(saved, doc.onDiskModificationDate, "layout.json should change the package date")
        assertSameDate(doc.fileModificationDate, doc.onDiskModificationDate)
    }

    func testCacheFolderCreatedOffMainIsAdopted() async throws {
        let (doc, url) = try await savedDocument()
        try FileManager.default.removeItem(at: url.appendingPathComponent("proxies"))
        doc.fileModificationDate = doc.onDiskModificationDate          // treat the removal as known
        await Task.detached { _ = doc.folder("proxies") }.value
        await MainActor.run {}                                          // let the adoption run
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("proxies").path))
        assertSameDate(doc.fileModificationDate, doc.onDiskModificationDate)
    }

    func testOutsideEditIsStillDetected() async throws {
        let (doc, url) = try await savedDocument()
        let saved = try XCTUnwrap(doc.fileModificationDate)
        // Another app replaces project.json (an atomic write changes the package date).
        let json = try Data(contentsOf: url.appendingPathComponent("project.json"))
        try json.write(to: url.appendingPathComponent("project.json"), options: .atomic)
        let edited = try XCTUnwrap(doc.onDiskModificationDate)
        XCTAssertGreaterThan(edited, saved)
        assertSameDate(doc.fileModificationDate, saved)
        // A later internal write must not hide the outside edit.
        await MainActor.run { doc.persistLayout() }
        assertSameDate(doc.fileModificationDate, saved)
        XCTAssertGreaterThan(try XCTUnwrap(doc.onDiskModificationDate), saved)
    }
}
