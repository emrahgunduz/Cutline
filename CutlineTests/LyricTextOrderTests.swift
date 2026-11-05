import XCTest
@testable import Cutline

/// Alignment sings the lines in the lyrics file's order, wherever they sit on the timeline.
final class LyricTextOrderTests: XCTestCase {
    private let txt = """
    Adlandıramıyor
    Yeşil, mavi
    Gökyüzü hangi renkteyse

    Aynı kıyıdan varıyoruz şehre
    Yeşil, mavi
    """

    /// The TXT placed on track 1 at 20 s and roughly timed.
    private func imported() -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        p.lyricTracks[0].lines = LyricImport.roughlyTimed(LyricImport.parse(txt), start: 20, end: 60, fps: 24)
        p.addLyricTrack()
        return p
    }

    private func texts(_ lines: [LyricLine]) -> [String] { lines.map(\.text) }

    func testImportedLinesRememberTheirPlaceInTheFile() {
        let lines = imported().lyricTracks[0].lines
        XCTAssertEqual(lines.map { $0.textOrder?.index }, [0, 1, 2, 3, 4])
        XCTAssertEqual(Set(lines.compactMap { $0.textOrder?.group }).count, 1, "one file, one group")
    }

    func testMovingALineToAnotherTrackAndEarlierKeepsTheSungOrder() {
        var p = imported()
        let moved = p.lyricTracks[0].lines[3]                  // "Aynı kıyıdan varıyoruz şehre"
        p.moveLine(moved.id, toTrack: 1, start: 15)            // the screenshot: track 2, before everything
        XCTAssertEqual(p.lyricLineOrder().first?.id, moved.id, "by time it is now first")
        XCTAssertEqual(texts(p.lyricTextOrder()), LyricImport.parse(txt).map { $0.words.joined(separator: " ") },
                       "but it is still sung fourth")
    }

    func testRepeatedLinesKeepTheirOwnPlaces() {
        var p = imported()
        // Swap the two "Yeşil, mavi" lines in time; each keeps its own place in the file.
        let first = p.lyricTracks[0].lines[1], second = p.lyricTracks[0].lines[4]
        p.moveLine(second.id, toTrack: 1, start: 10)
        let order = p.lyricTextOrder().map(\.id)
        XCTAssertEqual(order.firstIndex(of: first.id), 1)
        XCTAssertEqual(order.firstIndex(of: second.id), 4)
    }

    func testTwoLyricsFilesInterleaveByTimeEachInItsOwnOrder() {
        var p = imported()
        // A second file on track 2 (a duet part) starting between lines 1 and 2 of the first.
        var duet = LyricImport.roughlyTimed(LyricImport.parse("Ben\nSen"), start: 27, end: 30, fps: 24)
        p.lyricTracks[1].lines = duet
        let order = texts(p.lyricTextOrder())
        XCTAssertEqual(order.filter { $0 == "Ben" || $0 == "Sen" }, ["Ben", "Sen"], "the second file keeps its order")
        XCTAssertLessThan(order.firstIndex(of: "Ben")!, order.firstIndex(of: "Aynı kıyıdan varıyoruz şehre")!)
        // Moving the duet's second line before its first doesn't reorder that file.
        duet = p.lyricTracks[1].lines
        p.moveLine(duet[1].id, toTrack: 1, start: 0)
        XCTAssertEqual(texts(p.lyricTextOrder()).filter { $0 == "Ben" || $0 == "Sen" }, ["Ben", "Sen"])
    }

    func testLinesFromNoFileGoByTime() {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.lyricTracks[0].lines = [LyricLine(start: 5, end: 6, words: [LyricWord(text: "b", start: 5, end: 6)]),
                                  LyricLine(start: 1, end: 2, words: [LyricWord(text: "a", start: 1, end: 2)])]
        XCTAssertEqual(texts(p.lyricTextOrder()), ["a", "b"])
    }

    func testTheOrderIsSavedAndOlderLinesLoadWithout() throws {
        let line = imported().lyricTracks[0].lines[2]
        XCTAssertEqual(try JSONDecoder().decode(LyricLine.self, from: JSONEncoder().encode(line)).textOrder, line.textOrder)
        let old = #"{"id":"5A1F2B3C-0000-0000-0000-000000000003","start":1,"end":2,"words":[],"stanza":0}"#
        XCTAssertNil(try JSONDecoder().decode(LyricLine.self, from: Data(old.utf8)).textOrder)
    }

    // MARK: Older projects

    private func legacy() -> Project {
        var p = imported()
        for t in p.lyricTracks.indices { for l in p.lyricTracks[t].lines.indices { p.lyricTracks[t].lines[l].textOrder = nil } }
        return p
    }

    func testOlderProjectsRecoverTheOrderFromTheFile() {
        var p = legacy()
        let moved = p.lyricTracks[0].lines[3].id
        p.moveLine(moved, toTrack: 1, start: 15)
        let group = UUID()
        XCTAssertTrue(p.recoverTextOrder(from: txt, group: group))
        XCTAssertEqual(p.line(moved)?.textOrder, TextOrder(group: group, index: 3))
        XCTAssertEqual(texts(p.lyricTextOrder()), LyricImport.parse(txt).map { $0.words.joined(separator: " ") })
    }

    func testRecoveredRepeatsGoToTheEarlierCopyFirst() {
        var p = legacy()
        XCTAssertTrue(p.recoverTextOrder(from: txt, group: UUID()))
        XCTAssertEqual(p.lyricTracks[0].lines[1].textOrder?.index, 1, "the first 'Yeşil, mavi' on the timeline is the first in the file")
        XCTAssertEqual(p.lyricTracks[0].lines[4].textOrder?.index, 4)
    }

    func testLinesThatMatchNothingStayUnordered() {
        var p = legacy()
        p.lyricTracks[0].lines[0].words[0].text = "Değişti"
        p.recoverTextOrder(from: txt, group: UUID())
        XCTAssertNil(p.lyricTracks[0].lines[0].textOrder)
        XCTAssertNotNil(p.lyricTracks[0].lines[1].textOrder)
    }

    func testRecoveryNeverOverwritesAKnownOrder() {
        var p = imported()
        let before = p.lyricTracks[0].lines.map(\.textOrder)
        XCTAssertFalse(p.recoverTextOrder(from: "Yeşil, mavi\nAdlandıramıyor", group: UUID()))
        XCTAssertEqual(p.lyricTracks[0].lines.map(\.textOrder), before)
    }

    // MARK: Alignment

    func testAMovedLineGetsTheTimesOfTheWordsItContains() {
        var p = imported()
        p.lyricStyle.leadIn = 0
        let moved = p.lyricTracks[0].lines[3]
        p.moveLine(moved.id, toTrack: 1, start: 15)
        // The helper answers in the order it was asked: the file's order.
        let order = p.lyricTextOrder()
        var t = 100.0
        let result = LyricAlignment.Result(lines: order.map { line in
            line.words.map { w in defer { t += 1 }; return LyricAlignment.Word(text: w.text, start: t, end: t + 0.8, confidence: 0.9, source: "a") }
        })
        p.applyAlignment(result, lineIDs: order.map(\.id), audioStart: 0, keepEdits: false)
        // "Aynı kıyıdan varıyoruz şehre" is file line 4: after the 1 + 2 + 3 words of lines 1-3.
        let line = p.line(moved.id)!
        XCTAssertEqual(line.words.first?.start, 106, "sung after the first three lines, though it was moved first")
        XCTAssertEqual(p.lineLocation(moved.id)?.track, 1, "it stays on the track you moved it to")
        let starts = p.lyricTextOrder().map(\.start)
        XCTAssertEqual(starts, starts.sorted(), "after aligning, time order and file order agree again")
    }
}
