import CoreImage
import XCTest
@testable import Cutline

final class LyricLayoutTests: XCTestCase {
    func testWordIsDrawnFromStartUntilFadeOutEnds() {
        let w = LyricWord(text: "a", start: 1, end: 2)
        let fps = 24.0, fade = 3 / fps
        XCTAssertEqual(LyricLayout.alpha(of: w, at: 0.99, fps: fps), 0)
        XCTAssertEqual(LyricLayout.alpha(of: w, at: 1 + fade / 2, fps: fps), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LyricLayout.alpha(of: w, at: 1.5, fps: fps), 1)
        XCTAssertEqual(LyricLayout.alpha(of: w, at: 2 + fade / 2, fps: fps), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LyricLayout.alpha(of: w, at: 2 + fade, fps: fps), 0)
    }

    func testTwoFrameWordGetsOneFrameFades() {
        XCTAssertEqual(LyricLayout.fadeDuration(wordDuration: 2 / 24, fps: 24), 1 / 24, accuracy: 1e-12)
        XCTAssertEqual(LyricLayout.fadeDuration(wordDuration: 1, fps: 24), 3 / 24, accuracy: 1e-12)
    }

    func testStackPutsFirstTrackOnTop() {
        let style = LyricStyle()
        let canvas = CanvasSize(width: 1920, height: 1080)
        let o = LyricLayout.stackOrigins(count: 2, style: style, canvas: canvas)
        XCTAssertGreaterThan(o[0], o[1])
        XCTAssertEqual(o[0] - o[1], LyricLayout.lineHeight(style, canvas: canvas), accuracy: 0.001)
    }

    func testTurkishTextIsFullyCovered() throws {
        let style = LyricStyle()
        XCTAssertTrue(LineRasterizer.covers("Yüzümü kaybedişim Sığınakların ğ İ ç ö", style: style))
        let r = try XCTUnwrap(LineRasterizer.rasterize(words: ["Yüzümü", "kaybedişim"], style: style, fontSize: 60))
        XCTAssertEqual(r.wordRects.count, 2)
        XCTAssertLessThan(r.wordRects[0].maxX, r.wordRects[1].maxX)
    }

    func testOverlappingLinesOnTwoTracksRenderStacked() throws {
        var p = Project(type: .musicVideo, canvas: .init(width: 640, height: 360))
        p.fps = 24
        p.lyricStyle.shadowEnabled = false
        p.addLyricTrack()
        p.lyricTracks[0].lines = [LyricLine(start: 5, end: 9, words: [LyricWord(text: "AAAA", start: 5, end: 9)])]
        p.lyricTracks[1].lines = [LyricLine(start: 7, end: 11, words: [LyricWord(text: "BBBB", start: 7, end: 11)])]
        let r = LyricRenderer(project: p)
        XCTAssertEqual(r.drawnLines(at: 6).map(\.text), ["AAAA"])
        XCTAssertEqual(r.drawnLines(at: 8).map(\.text), ["AAAA", "BBBB"])
        XCTAssertEqual(r.drawnLines(at: 10).map(\.text), ["BBBB"])
        let one = try XCTUnwrap(r.image(at: 6)), two = try XCTUnwrap(r.image(at: 8))
        XCTAssertGreaterThan(two.extent.height, one.extent.height)
        XCTAssertNil(r.image(at: 12))
    }
}
