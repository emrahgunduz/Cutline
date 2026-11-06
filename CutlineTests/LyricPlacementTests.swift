import XCTest
@testable import Cutline

final class LyricPlacementTests: XCTestCase {
    let canvas = CGSize(width: 1920, height: 1080)
    /// A 400×100 box whose letters are inset 10 px left/right, 20 px below and 15 px above.
    let box = LyricPlacement.Box(size: CGSize(width: 400, height: 100), ink: CGRect(x: 10, y: 20, width: 380, height: 65))

    func testHorizontalPaddingIsMeasuredToTheLetters() {
        XCTAssertEqual(LyricPlacement.x(for: .left, box: box, canvasWidth: 1920, padding: 60), 60 + 200 - 10)
        XCTAssertEqual(LyricPlacement.x(for: .center, box: box, canvasWidth: 1920, padding: 60), 960)
        XCTAssertEqual(LyricPlacement.x(for: .right, box: box, canvasWidth: 1920, padding: 60), 1920 - 60 - 190)
    }

    func testVerticalPaddingIsMeasuredToTheLetters() {
        let bottom = LyricPlacement.stackedY(.bottom, boxes: [box], frame: 0...1080, padding: 40, gap: 0)[0]
        XCTAssertEqual(bottom - 50 + 20, 40, "the letters' bottom is 40 px over the frame's bottom edge")
        let top = LyricPlacement.stackedY(.top, boxes: [box], frame: 0...1080, padding: 40, gap: 0)[0]
        XCTAssertEqual(top - 50 + 85, 1080 - 40, "the letters' top is 40 px under the frame's top edge")
    }

    func testStackedLinesSitUnderEachOtherWithGap() {
        let plain = LyricPlacement.Box(size: CGSize(width: 300, height: 80))
        let ys = LyricPlacement.stackedY(.bottom, boxes: [plain, plain], frame: 0...1080, padding: 60, gap: 20)
        // Block = 180 tall, bottom edge at 60: top line center 200, second line center 100.
        XCTAssertEqual(ys, [200, 100])
        XCTAssertEqual(LyricPlacement.stackedY(.top, boxes: [plain], frame: 0...1080, padding: 60, gap: 0), [980])
        XCTAssertEqual(LyricPlacement.stackedY(.center, boxes: [plain], frame: 100...980, padding: 60, gap: 0), [540])
    }

    @MainActor
    func testSeveralLinesAlignAsOneBlockWithSeparatePaddings() throws {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        p.cinemascope = Cinemascope(enabled: true, startMarker: 0, endMarker: 0.5)
        p.addLyricTrack()
        p.lyricTracks[0].lines = [LyricLine(start: 1, end: 3, words: [LyricWord(text: "Kör", start: 1, end: 3)])]
        p.lyricTracks[1].lines = [LyricLine(start: 1, end: 3, words: [LyricWord(text: "aynalarda", start: 1, end: 3)])]
        let doc = ProjectDocument(project: p)
        let e = doc.editor
        e.setSelection([.lyricLine(p.lyricTracks[0].lines[0].id), .lyricLine(p.lyricTracks[1].lines[0].id)])
        e.alignLines(horizontal: .left, vertical: .bottom, paddingX: 80, paddingY: 30, gap: 10)
        let r = LyricRenderer(project: e.project)
        let placed = r.placedLines(at: 2)
        XCTAssertEqual(placed.count, 2)
        let bar = CGFloat(Letterbox.defaultBarHeight(p.canvas))
        for pl in placed {
            let ink = pl.raster.ink.applying(CGAffineTransform(scaleX: pl.fit, y: pl.fit)).offsetBy(dx: pl.rect.minX, dy: pl.rect.minY)
            XCTAssertEqual(ink.minX, 80, accuracy: 1, "each line's letters start 80 px from the left")
        }
        let lower = try XCTUnwrap(placed.last)
        let lowerInk = lower.raster.ink.applying(CGAffineTransform(scaleX: lower.fit, y: lower.fit)).offsetBy(dx: lower.rect.minX, dy: lower.rect.minY)
        XCTAssertEqual(lowerInk.minY, 30, accuracy: 1, "measured from the frame's bottom edge, not the bar (\(bar) px)")
        XCTAssertGreaterThan(placed[0].rect.minY, placed[1].rect.maxY - 1)       // first line above the second
        e.resetLinePositions()
        XCTAssertFalse(e.project.lyricTracks.flatMap(\.lines).contains { $0.hasPosition })
    }
}

final class NegativeGapTests: XCTestCase {
    func testNegativeGapOverlapsLines() {
        let plain = LyricPlacement.Box(size: CGSize(width: 300, height: 80))
        let ys = LyricPlacement.stackedY(.bottom, boxes: [plain, plain], frame: 0...1080, padding: 60, gap: -20)
        XCTAssertEqual(ys[0] - ys[1], 60)      // 80 tall lines, 20 px closer than touching
    }
}
