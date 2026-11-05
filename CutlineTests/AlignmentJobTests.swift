import XCTest
@testable import Cutline

/// Runs the real alignment flow against a fake helper that answers after a short delay.
@MainActor
final class AlignmentJobTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("align-job-\(UUID())", isDirectory: true)
        let pkg = dir.appendingPathComponent("helper/cutline_helper", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data("".utf8).write(to: pkg.appendingPathComponent("__init__.py"))
        // Each word i of each line gets 20 + i seconds (song time).
        try Data("""
        import json, sys, time
        req = json.loads(sys.stdin.readline())
        time.sleep(0.6)
        lines = req["args"]["lines"]
        out = [[{"text": w, "start": 20 + i, "end": 20.5 + i, "confidence": 0.9, "source": "mms"} for i, w in enumerate(l)] for l in lines]
        print(json.dumps({"type": "result", "data": {"lines": out}}), flush=True)
        """.utf8).write(to: pkg.appendingPathComponent("__main__.py"))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func document() throws -> ProjectDocument {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        p.lyricStyle.leadIn = 0
        let song = Asset(kind: .audio, name: "s", path: "/s", duration: 60)
        p.assets = [song]
        p.setAudio(assetID: song.id)
        p.moveAudio(start: 2, alone: true)
        p.lyricTracks[0].lines = LyricImport.roughlyTimed(LyricImport.parse("one two"), start: 5, end: 9, fps: 24)
        let doc = ProjectDocument(project: p)
        let e = doc.editor
        e.autoAnalyze = false
        e.audioAnalysis.adopt(AudioAnalysis(hash: "h", result: .init(duration: 60, tempo: 0, beats: [], downbeats: [], onsets: [], sections: [], vocals: "")))
        try Data("stem".utf8).write(to: XCTUnwrap(e.audioAnalysis.vocalsURL("h")))
        let python = try XCTUnwrap(JobRunnerTests.python)
        let config = HelperConfig(python: python, helperDir: dir.appendingPathComponent("helper"), modelsDir: dir)
        e.jobs = JobRunner(config: config,
                           scratchRoot: dir.appendingPathComponent("jobs"))
        return doc
    }

    func testAlignmentLandsRelativeToTheSong() async throws {
        let doc = try document()
        let e = doc.editor
        e.alignLyrics(window: nil)
        await e.alignmentTask?.value
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].words.map(\.start), [22, 23], "song time + the song's start (2 s)")
    }

    func testMovingTheSongDuringAlignmentDiscardsTheResult() async throws {
        let doc = try document()
        let e = doc.editor
        let before = e.project.lyricTracks[0].lines[0].words.map(\.start)
        e.alignLyrics(window: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        e.edit("Move Audio") { $0.moveAudio(start: 4, alone: true) }
        await e.alignmentTask?.value
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].words.map(\.start), before, "a stale result is not applied")
    }

    func testClosingTheDocumentCancelsItsJobs() async throws {
        let doc = try document()
        let e = doc.editor
        e.alignLyrics(window: nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(e.jobs.active.isEmpty, "the job is running")
        let task = try XCTUnwrap(e.alignmentTask)
        let started = Date()
        doc.close()
        await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the helper was stopped, not waited for")
        XCTAssertTrue(e.jobs.active.isEmpty)
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].words.first?.start, 5, "nothing was applied")
    }
}
