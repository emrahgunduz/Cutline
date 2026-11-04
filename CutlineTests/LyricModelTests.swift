import XCTest
@testable import Cutline

final class LyricModelTests: XCTestCase {
    private func project() -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 25
        p.addLyricTrack()
        p.lyricTracks[0].lines = [LyricLine(start: 5, end: 9, words: [
            LyricWord(text: "Kör", start: 5, end: 6),
            LyricWord(text: "aynalarda", start: 6.2, end: 8.8),
        ])]
        return p
    }

    func testMovingLineToAnotherTrackKeepsWordTimes() {
        var p = project()
        let id = p.lyricTracks[0].lines[0].id
        p.moveLine(id, toTrack: 1, start: 5)
        XCTAssertTrue(p.lyricTracks[0].lines.isEmpty)
        XCTAssertEqual(p.lyricTracks[1].lines[0].words.map(\.start), [5, 6.2])
    }

    func testMovingLineMovesItsWords() {
        var p = project()
        let id = p.lyricTracks[0].lines[0].id
        p.moveLine(id, toTrack: 0, start: 7)
        let line = p.lyricTracks[0].lines[0]
        XCTAssertEqual(line.start, 7); XCTAssertEqual(line.end, 11)
        XCTAssertEqual(line.words[0].start, 7, accuracy: 1e-9)
        XCTAssertEqual(line.words[1].end, 10.8, accuracy: 1e-9)
    }

    func testWordBeforeLineStartExtendsLine() {
        var p = project()
        let w = p.lyricTracks[0].lines[0].words[0].id
        p.retimeWord(w, start: 4)
        XCTAssertEqual(p.lyricTracks[0].lines[0].start, 4)
        XCTAssertTrue(p.lyricTracks[0].lines[0].words[0].confirmed)
    }

    func testLineEdgeCannotCutIntoWords() {
        var p = project()
        let id = p.lyricTracks[0].lines[0].id
        p.retimeLine(id, start: 5.5, end: 8)
        XCTAssertEqual(p.lyricTracks[0].lines[0].start, 5)
        XCTAssertEqual(p.lyricTracks[0].lines[0].end, 8.8)
        p.retimeLine(id, start: 3)
        XCTAssertEqual(p.lyricTracks[0].lines[0].start, 3)
    }

    func testOverlappingLinesOnTwoTracksAreBothVisible() {
        var p = project()
        p.lyricTracks[1].lines = [LyricLine(start: 7, end: 11, words: [LyricWord(text: "B", start: 7, end: 11)])]
        XCTAssertEqual(p.visibleLines(at: 8).map(\.track), [0, 1])
        XCTAssertEqual(p.visibleLines(at: 6).map(\.track), [0])
        XCTAssertEqual(p.visibleLines(at: 10).map(\.track), [1])
    }
}
