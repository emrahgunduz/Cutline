import AVFoundation
import XCTest
@testable import Cutline

@MainActor
final class SegmentExporterTests: XCTestCase {
    private var cache: URL!
    private var src: URL!

    override func setUp() async throws {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("segments-\(UUID())", isDirectory: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cache)
        if let src { try? FileManager.default.removeItem(at: src) }
    }

    /// 5 s at 24 fps (3 segments: 2 + 2 + 1 s), a clip, a song and a lyric line.
    private func editor() async throws -> EditorModel {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 640, height: 360)))
        src = try await TestMedia.video(width: 640, height: 360, fps: 24, frames: 24 * 5)
        let wav = try TestMedia.sineWAV(seconds: 5)
        _ = await doc.editor.importFiles([src, wav])
        let v = doc.editor.project.assets.first { $0.kind == .video }!.id
        let a = doc.editor.project.assets.first { $0.kind == .audio }!.id
        doc.editor.edit("setup") { p in
            _ = p.addClip(assetID: v, track: 0, at: 0)
            p.setAudio(assetID: a)
            p.lyricTracks[0].lines = [LyricLine(start: 1.5, end: 3.5, words: [LyricWord(text: "hi", start: 1.5, end: 3.5)])]
        }
        return doc.editor
    }

    private func frames(_ url: URL) async throws -> (count: Int, descriptions: Int, duration: Double, audio: Bool) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var n = 0
        while out.copyNextSampleBuffer() != nil { n += 1 }
        XCTAssertEqual(reader.status, .completed, "every frame decodes")
        let descs = try await track.load(.formatDescriptions).count
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = !audioTracks.isEmpty
        return (n, descs, try await asset.load(.duration).seconds, audio)
    }

    /// The spike: independently encoded segments join without re-encoding into a file that
    /// plays every frame, at the right length, with the audio.
    func testJoinedSegmentsDecodeEveryFrame() async throws {
        let e = try await editor()
        let out = TestMedia.tempURL("mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        var settings = ExportSettings.defaults(for: e.project)
        settings.rateMode = .bitrate; settings.bitrateMbps = 4
        let stats = try await SegmentExporter(cacheDir: cache).export(project: e.project, settings: settings, to: out) { _ in }
        XCTAssertEqual(stats, .init(encoded: 3, reused: 0))
        let info = try await frames(out)
        XCTAssertEqual(info.count, 120, "5 s × 24 fps, no frame lost or doubled at the joins")
        XCTAssertEqual(info.duration, 5, accuracy: 0.05)
        XCTAssertTrue(info.audio)
        XCTAssertGreaterThanOrEqual(info.descriptions, 1)
    }

    func testReExportAfterALyricEditReencodesOnlyTheSegmentsItTouches() async throws {
        let e = try await editor()
        let out = TestMedia.tempURL("mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let settings = ExportSettings.defaults(for: e.project)
        try await SegmentExporter(cacheDir: cache).export(project: e.project, settings: settings, to: out) { _ in }
        // The word was visible in segments 0 and 1 (1.5-3.5 s) and now in 1 only (2.5-3.5 s):
        // both re-encode; segment 2 (4-5 s) is reused.
        e.edit("x") { p in p.lyricTracks[0].lines[0].words[0].start = 2.5; p.lyricTracks[0].lines[0].start = 2.5 }
        let segs = SegmentExporter.segments(project: e.project, settings: settings)
        let again = try await SegmentExporter(cacheDir: cache).export(project: e.project, settings: settings, to: out) { _ in }
        XCTAssertEqual(again.encoded, 2)
        XCTAssertEqual(again.reused, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent(segs[2].fileName).path))
        let unchanged = try await SegmentExporter(cacheDir: cache).export(project: e.project, settings: settings, to: out) { _ in }
        XCTAssertEqual(unchanged, .init(encoded: 0, reused: 3))
    }

    func testChangingTheBitrateReencodesEverything() async throws {
        let e = try await editor()
        let out = TestMedia.tempURL("mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        var settings = ExportSettings.defaults(for: e.project)
        settings.rateMode = .bitrate; settings.bitrateMbps = 4
        try await SegmentExporter(cacheDir: cache).export(project: e.project, settings: settings, to: out) { _ in }
        settings.bitrateMbps = 6
        let again = try await SegmentExporter(cacheDir: cache).export(project: e.project, settings: settings, to: out) { _ in }
        XCTAssertEqual(again, .init(encoded: 3, reused: 0))
        let files = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".mov") }
        XCTAssertEqual(files.count, 3, "the old versions were replaced")
    }

    func testCancelledExportKeepsFinishedSegmentsForResume() async throws {
        let e = try await editor()
        let out = TestMedia.tempURL("mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let settings = ExportSettings.defaults(for: e.project)
        let exporter = SegmentExporter(cacheDir: cache, concurrency: 1)
        do {
            try await exporter.export(project: e.project, settings: settings, to: out) { p in if p > 0.4 { exporter.cancel() } }
            XCTFail("expected cancellation")
        } catch ExportError.cancelled {}
        let kept = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".mov") && !$0.hasPrefix(".") }.count
        XCTAssertGreaterThan(kept, 0)
        let resumed = try await SegmentExporter(cacheDir: cache).export(project: e.project, settings: settings, to: out) { _ in }
        XCTAssertEqual(resumed.reused, kept)
        XCTAssertEqual(resumed.encoded, 3 - kept)
    }
}

/// U14 verification on a real project: after a one-word fix the re-export reuses almost
/// every segment. Runs only with CUTLINE_SAMPLE_PROJECT=<path to a .cutline>.
@MainActor
final class SegmentReuseOnRealProjectTests: XCTestCase {
    func testOneWordFixReexportsAFraction() async throws {
        guard let path = ProcessInfo.processInfo.environment["CUTLINE_SAMPLE_PROJECT"] else { throw XCTSkip("set CUTLINE_SAMPLE_PROJECT") }
        let doc = try ProjectDocument(contentsOf: URL(fileURLWithPath: path), ofType: "com.emrahgunduz.cutline.project")
        doc.editor.autoAnalyze = false
        // CUTLINE_SEGMENT_CACHE keeps the segments (e.g. the project's own cache, to inspect the strip).
        let keep = ProcessInfo.processInfo.environment["CUTLINE_SEGMENT_CACHE"]
        let cache = keep.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("real-seg-\(UUID())")
        defer { if keep == nil { try? FileManager.default.removeItem(at: cache) } }
        let out = TestMedia.tempURL("mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        var p = doc.editor.project
        let settings = ExportSettings.defaults(for: p)
        var t0 = Date()
        let first = try await SegmentExporter(cacheDir: cache).export(project: p, settings: settings, to: out) { _ in }
        let firstTime = Date().timeIntervalSince(t0)
        // Nudge one word in the middle of the song.
        let lines = p.lyricLineOrder()
        let target = lines[lines.count / 2]
        if let loc = p.lineLocation(target.id) { p.lyricTracks[loc.track].lines[loc.index].words[0].start += 0.1 }
        t0 = Date()
        let second = try await SegmentExporter(cacheDir: cache).export(project: p, settings: settings, to: out) { _ in }
        let secondTime = Date().timeIntervalSince(t0)
        print("SEGMENT-REUSE first: \(first) in \(Int(firstTime)) s; after one word: \(second) in \(String(format: "%.1f", secondTime)) s")
        XCTAssertLessThanOrEqual(second.encoded, 3)
        // The join still writes the whole file (gigabytes at maximum quality), so the disk sets
        // the floor; the re-export must still be well under the full export.
        XCTAssertLessThan(secondTime, firstTime * 0.5)
    }
}
