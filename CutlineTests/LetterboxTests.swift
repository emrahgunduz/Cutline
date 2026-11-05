import CoreImage
import XCTest
@testable import Cutline

final class LetterboxTests: XCTestCase {
    private func project() -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.cinemascope = Cinemascope(enabled: true, startMarker: 2, endMarker: 6)
        return p
    }

    func testBarHeightsAcrossTheTransition() {
        let p = project()
        XCTAssertEqual(Letterbox.fullBarHeight(p.canvas), 131.49, accuracy: 0.01)
        XCTAssertEqual(Letterbox.barHeight(project: p, at: 1), 0)
        XCTAssertEqual(Letterbox.barHeight(project: p, at: 4), 131.49 / 2, accuracy: 0.01)
        XCTAssertEqual(Letterbox.barHeight(project: p, at: 6), 131.49, accuracy: 0.01)
        XCTAssertEqual(Letterbox.barHeight(project: p, at: 100), 131.49, accuracy: 0.01)
    }

    func testOffOrPortraitHasNoBars() {
        var p = project()
        p.cinemascope.enabled = false
        XCTAssertEqual(Letterbox.barHeight(project: p, at: 10), 0)
        var q = project()
        q.type = .social
        XCTAssertEqual(Letterbox.barHeight(project: q, at: 10), 0)
    }

    func testBarsAreBlackOverThePicture() {
        let p = project()
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let out = Letterbox.apply(to: white, project: p, at: 10)
        XCTAssertEqual(FilterChainTests.meanLuma(out, CGRect(x: 0, y: 0, width: 1920, height: 120)), 0, accuracy: 0.01)
        XCTAssertEqual(FilterChainTests.meanLuma(out, CGRect(x: 0, y: 500, width: 1920, height: 80)), 1, accuracy: 0.01)
    }

    func testLyricsStayAboveTheBottomBar() {
        var p = project()
        p.fps = 24
        p.lyricStyle.verticalPosition = 0.97            // would sit under the bar
        p.addLyricTrack()
        p.lyricTracks[0].lines = [LyricLine(start: 8, end: 10, words: [LyricWord(text: "Kör", start: 8, end: 10)])]
        p.lyricTracks[1].lines = [LyricLine(start: 8, end: 10, words: [LyricWord(text: "aynalarda", start: 8, end: 10)])]
        let placed = LyricRenderer(project: p).placedLines(at: 9)
        XCTAssertEqual(placed.count, 2)
        let bar = Letterbox.fullBarHeight(p.canvas)
        XCTAssertTrue(placed.allSatisfy { $0.rect.minY >= bar })
        XCTAssertTrue(placed.allSatisfy { $0.rect.maxY <= 1080 - bar })
    }
}
