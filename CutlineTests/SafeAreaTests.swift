import XCTest
@testable import Cutline

final class SafeAreaTests: XCTestCase {
    private let canvas = CanvasSize(width: 1080, height: 1920)

    func testBundledOverlaysLoad() {
        XCTAssertEqual(Set(PlatformOverlay.all.map(\.id)), ["tiktok", "reels", "shorts"])
    }

    func testSafeAreaClearsTopBottomAndTheButtonColumn() throws {
        let tiktok = try XCTUnwrap(PlatformOverlay.all.first { $0.id == "tiktok" })
        let safe = try XCTUnwrap(SafeArea.rect(canvas: canvas, avoiding: tiktok.rects(on: canvas)))
        XCTAssertEqual(safe.maxY, 1920 - 150, accuracy: 0.01, "below the top bar")
        XCTAssertEqual(safe.minY, 440, accuracy: 0.01, "above the caption")
        XCTAssertEqual(safe.maxX, 930, accuracy: 0.01, "left of the buttons")
        XCTAssertEqual(safe.minX, 0, accuracy: 0.01)
        for zone in tiktok.rects(on: canvas) { XCTAssertFalse(safe.intersects(zone.insetBy(dx: 0.5, dy: 0.5))) }
    }

    func testSeveralPlatformsTakeTheDeepestZoneOnEachEdge() throws {
        var p = Project(type: .social, canvas: canvas)
        p.platformOverlays = ["tiktok", "reels"]
        let safe = try XCTUnwrap(SafeArea.rect(for: p))
        XCTAssertEqual(safe.maxY, 1920 - 220, accuracy: 0.01)   // Reels' top bar is deeper
        XCTAssertEqual(safe.minY, 440, accuracy: 0.01)          // TikTok's caption is deeper
    }

    func testNoOverlaysOrMusicVideoMeansNoSafeArea() {
        var p = Project(type: .social, canvas: canvas)
        XCTAssertNil(SafeArea.rect(for: p))
        p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.platformOverlays = ["tiktok"]
        XCTAssertNil(SafeArea.rect(for: p), "landscape projects have no platform zones")
    }

    func testZonesScaleToTheCanvas() throws {
        let tiktok = try XCTUnwrap(PlatformOverlay.all.first { $0.id == "tiktok" })
        let half = tiktok.rects(on: CanvasSize(width: 540, height: 960))
        XCTAssertEqual(half[0], CGRect(x: 0, y: 960 - 75, width: 540, height: 75))
    }

    /// Automatically stacked lyrics move clear of the zones; hand-placed lines stay put.
    func testAutoPlacedLyricsAvoidTheZones() throws {
        var p = Project(type: .social, canvas: canvas)
        p.lyricStyle.verticalPosition = 0.95            // would sit in the caption zone
        p.lyricTracks[0].lines = [LyricLine(start: 0, end: 5, words: [LyricWord(text: "Hello", start: 0, end: 5)]),]
        p.lyricTracks.append(LyricTrack(lines: [LyricLine(start: 0, end: 5, words: [LyricWord(text: "There", start: 0, end: 5)])]))
        let before = LyricRenderer(project: p).placedLines(at: 1).map(\.rect)
        p.platformOverlays = ["tiktok"]
        let safe = try XCTUnwrap(SafeArea.rect(for: p))
        let after = LyricRenderer(project: p).placedLines(at: 1).map(\.rect)
        XCTAssertTrue(before.contains { $0.minY < 440 }, "the test starts inside the caption zone")
        for r in after { XCTAssertTrue(safe.contains(r), "\(r) inside \(safe)") }

        p.lyricTracks[0].lines[0].centerX = 540; p.lyricTracks[0].lines[0].centerY = 200
        let manual = LyricRenderer(project: p).placedLines(at: 1).first { $0.line.id == p.lyricTracks[0].lines[0].id }
        XCTAssertEqual(manual?.rect.midY ?? 0, 200, accuracy: 0.5, "a hand-placed line is not moved")
    }
}
