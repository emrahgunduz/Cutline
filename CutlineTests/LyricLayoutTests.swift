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

final class ShadowStrengthTests: XCTestCase {
    func testOldProjectsWithoutStrengthDecodeAtOne() throws {
        let json = try JSONEncoder().encode(LyricStyle())
        var dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        dict.removeValue(forKey: "shadowStrengthValue")
        let style = try JSONDecoder().decode(LyricStyle.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertEqual(style.shadowStrength, 1)
    }

    func testStrongerShadowIsDarkerAroundText() throws {
        func meanAlpha(_ strength: Double) throws -> Double {
            var p = Project(type: .musicVideo, canvas: .init(width: 640, height: 360))
            p.fps = 24
            p.lyricStyle.shadowBlur = 10
            p.lyricStyle.shadowStrength = strength
            p.lyricTracks[0].lines = [LyricLine(start: 0, end: 5, words: [LyricWord(text: "WWWW", start: 0, end: 5)])]
            let img = try XCTUnwrap(LyricRenderer(project: p).image(at: 2))
            let avg = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)])
            var px = [UInt8](repeating: 0, count: 4)
            CIContext().render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return Double(px[3])
        }
        XCTAssertGreaterThan(try meanAlpha(3), try meanAlpha(1))
    }
}

final class LyricAnimationTests: XCTestCase {
    let word = LyricWord(text: "abcd", start: 10, end: 12)

    func testCustomWordFadeTimes() {
        let a = LyricAnimation(fadeIn: 0.4, fadeOut: 0.2)
        XCTAssertEqual(LyricLayout.alpha(of: word, at: 10.2, animation: a), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LyricLayout.alpha(of: word, at: 11, animation: a), 1)
        XCTAssertEqual(LyricLayout.alpha(of: word, at: 12.1, animation: a), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LyricLayout.alpha(of: word, at: 12.2, animation: a), 0)
    }

    func testLettersStaggerInsideTheWordFade() {
        // 0.5 s fade, 4 letters, 50% overlap: each letter fades 0.2 s, starting every 0.1 s.
        let a = LyricAnimation(fadeIn: 0.5, fadeOut: 0.5, letterByLetter: true, overlap: 0.5)
        let timing = LyricLayout.letterTiming(total: 0.5, letters: 4, overlap: 0.5)
        XCTAssertEqual(timing.length, 0.2, accuracy: 1e-9)
        XCTAssertEqual(timing.step, 0.1, accuracy: 1e-9)
        XCTAssertEqual(LyricLayout.alpha(of: word, letter: 0, of: 4, at: 10.1, animation: a), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LyricLayout.alpha(of: word, letter: 1, of: 4, at: 10.1, animation: a), 0)
        XCTAssertEqual(LyricLayout.alpha(of: word, letter: 3, of: 4, at: 10.5, animation: a), 1, accuracy: 1e-9)   // whole word in by 0.5 s
        XCTAssertEqual(LyricLayout.alpha(of: word, letter: 3, of: 4, at: 12.49, animation: a), 1 - (12.49 - 12.3) / 0.2, accuracy: 1e-6)
        XCTAssertEqual(LyricLayout.alpha(of: word, letter: 3, of: 4, at: 12.5, animation: a), 0)
        XCTAssertEqual(LyricLayout.visibleEnd(of: word, letters: 4, animation: a), 12.5, accuracy: 1e-9)
    }

    func testRasterHasOneBoxPerLetterIncludingTurkish() throws {
        let r = try XCTUnwrap(LineRasterizer.rasterize(words: ["Sığınak", "değil"], style: LyricStyle(), fontSize: 60))
        XCTAssertEqual(r.letterRects.map(\.count), [7, 5])
        XCTAssertTrue(zip(r.letterRects[0], r.letterRects[0].dropFirst()).allSatisfy { $0.maxX <= $1.minX + 0.5 })
    }
}
