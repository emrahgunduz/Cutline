import XCTest
@testable import Cutline

final class LyricPlacementTests: XCTestCase {
    let canvas = CGSize(width: 1920, height: 1080)

    func testHorizontalAlignmentWithPadding() {
        XCTAssertEqual(LyricPlacement.x(for: .left, width: 400, canvas: canvas, padding: 60), 260)
        XCTAssertEqual(LyricPlacement.x(for: .center, width: 400, canvas: canvas, padding: 60), 960)
        XCTAssertEqual(LyricPlacement.x(for: .right, width: 400, canvas: canvas, padding: 60), 1660)
    }

    func testStackedLinesSitUnderEachOtherWithGap() {
        let ys = LyricPlacement.stackedY(.bottom, heights: [80, 80], canvas: canvas, padding: 60, gap: 20)
        // Block = 180 tall, bottom edge at 60: top line center 200, second line center 100.
        XCTAssertEqual(ys, [200, 100])
        XCTAssertEqual(LyricPlacement.stackedY(.top, heights: [80], canvas: canvas, padding: 60, gap: 0), [980])
    }

    @MainActor
    func testAlignedLinesKeepPositionAndAutoResets() {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        p.addLyricTrack()
        p.lyricTracks[0].lines = [LyricLine(start: 1, end: 3, words: [LyricWord(text: "Kör", start: 1, end: 3)])]
        p.lyricTracks[1].lines = [LyricLine(start: 1, end: 3, words: [LyricWord(text: "aynalarda", start: 1, end: 3)])]
        let doc = ProjectDocument(project: p)
        let e = doc.editor
        e.setSelection([.lyricLine(p.lyricTracks[0].lines[0].id), .lyricLine(p.lyricTracks[1].lines[0].id)])
        e.alignLines(horizontal: .left, vertical: .bottom, padding: 60, gap: 10)
        let placed = LyricRenderer(project: e.project).placedLines(at: 2)
        XCTAssertEqual(placed.count, 2)
        XCTAssertEqual(placed[0].rect.minX, 60, accuracy: 0.5)
        XCTAssertEqual(placed[1].rect.minY, 60, accuracy: 0.5)
        XCTAssertGreaterThan(placed[0].rect.minY, placed[1].rect.maxY)       // first line above the second
        e.resetLinePositions()
        XCTAssertFalse(e.project.lyricTracks.flatMap(\.lines).contains { $0.hasPosition })
    }
}
