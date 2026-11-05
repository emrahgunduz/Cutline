import AVFoundation
import XCTest
@testable import Cutline

@MainActor
final class MediaCacheResetTests: XCTestCase {
    private var src: URL!
    override func tearDown() async throws { if let src { try? FileManager.default.removeItem(at: src) } }

    /// A project with a video (with a 1/4 proxy), lyric timing, and files in every cache folder.
    private func document() async throws -> ProjectDocument {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 640, height: 360)))
        let e = doc.editor
        e.autoAnalyze = false
        src = try await TestMedia.video(width: 640, height: 360, fps: 24, frames: 24)
        _ = await e.importFiles([src])
        let id = try XCTUnwrap(e.project.assets.first?.id)
        e.edit("setup") { p in
            _ = p.addClip(assetID: id, track: 0, at: 0)
            p.lyricTracks[0].lines = [LyricLine(start: 0.2, end: 0.8, words: [LyricWord(text: "hi", start: 0.2, end: 0.8)])]
        }
        try await e.createProxy(assetID: id, scale: .quarter)
        await e.thumbnails.ensureThumbnail(for: e.project.assets[0])
        try Data("analysis".utf8).write(to: XCTUnwrap(e.folder("analysis")).appendingPathComponent("audio-abc.json"))
        let seg = try XCTUnwrap(e.segmentCacheURL)
        try FileManager.default.createDirectory(at: seg, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: seg.appendingPathComponent("0-abc.mov"))
        return doc
    }

    private func stamp(_ urls: [URL]) -> [String: Date] {
        Dictionary(uniqueKeysWithValues: urls.map { ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) })
    }

    func testClearCacheEmptiesOnlyTheRenderCache() async throws {
        let doc = try await document()
        let e = doc.editor
        e.segmentCacheChanged()
        let keep = MediaCacheKind.allCases.flatMap { e.mediaCacheFiles($0) }
        XCTAssertFalse(keep.isEmpty)
        let freed = e.clearRenderCache()
        XCTAssertGreaterThanOrEqual(freed, 1000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.segmentCacheURL!.appendingPathComponent("0-abc.mov").path))
        XCTAssertTrue(e.segmentFiles.isEmpty)
        for url in keep { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) is kept") }
    }

    func testRebuildingThumbnailsLeavesProxiesAnalysisAndSegmentsAlone() async throws {
        let doc = try await document()
        let e = doc.editor
        let proxies = stamp(e.mediaCacheFiles(.proxies)), analysis = stamp(e.mediaCacheFiles(.analysis))
        try await Task.sleep(nanoseconds: 50_000_000)
        await e.resetMediaCaches([.thumbnails])
        XCTAssertEqual(stamp(e.mediaCacheFiles(.proxies)), proxies)
        XCTAssertEqual(stamp(e.mediaCacheFiles(.analysis)), analysis)
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.segmentCacheURL!.appendingPathComponent("0-abc.mov").path), "Reset never touches the render cache")
        XCTAssertNotNil(e.thumbnails.images[e.project.assets[0].id], "the thumbnail is back")
        XCTAssertFalse(e.mediaCacheFiles(.thumbnails).isEmpty)
    }

    func testRebuiltProxiesKeepTheirScaleAndLyricTimesAreUntouched() async throws {
        let doc = try await document()
        let e = doc.editor
        let lyrics = e.project.lyricTracks
        await e.resetMediaCaches(Set(MediaCacheKind.allCases))
        let asset = e.project.assets[0]
        XCTAssertEqual(asset.proxy?.scale, .quarter)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(e.proxyURL(for: asset)).path))
        XCTAssertEqual(e.project.lyricTracks, lyrics)
        XCTAssertNil(e.mediaResetMessage, "done")
    }
}
