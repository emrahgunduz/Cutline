import XCTest
@testable import Cutline

final class LyricImportTests: XCTestCase {
    func testSampleLyricsParseIntoLinesAndStanzas() throws {
        let url = try SampleMedia.require(SampleMedia.lyrics)
        let parsed = LyricImport.parse(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(parsed.count, 19)
        // Stanza breaks after lines 7, 14, 17 and 18.
        XCTAssertEqual(parsed.map(\.stanza), [0,0,0,0,0,0,0, 1,1,1,1,1,1,1, 2,2,2, 3, 4])
        XCTAssertEqual(parsed[5].words, ["Her", "gece", "sınadığım", "dualar", "kadar"])
        XCTAssertEqual(parsed[4].words.last, "sahteymiş")
    }

    func testRoughTimingFillsRangeInOrderAndMarksUnaligned() {
        let parsed = LyricImport.parse("Kör aynalarda\nYüzümü kaybedişim\n\nRastlantı değilmiş")
        let lines = LyricImport.roughlyTimed(parsed, start: 10, end: 40, fps: 24)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.first?.start, 10)
        XCTAssertLessThanOrEqual(lines.last!.end, 40)
        let words = lines.flatMap(\.words)
        XCTAssertTrue(zip(words, words.dropFirst()).allSatisfy { $0.end <= $1.start })
        XCTAssertTrue(words.allSatisfy { $0.confidence == 0 && !$0.confirmed })
        XCTAssertTrue(lines.allSatisfy { l in l.words.allSatisfy { $0.start >= l.start && $0.end <= l.end } })
        // The stanza pause is longer than the line gap.
        XCTAssertGreaterThan(lines[2].start - lines[1].end, lines[1].start - lines[0].end)
    }

    func testWindowsLineEndingsAndExtraBlankLines() {
        let parsed = LyricImport.parse("a b\r\n\r\n\r\nc\r\n")
        XCTAssertEqual(parsed, [.init(words: ["a", "b"], stanza: 0), .init(words: ["c"], stanza: 1)])
    }

    // MARK: Alignment

    private func placed() -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        p.lyricTracks[0].lines = LyricImport.roughlyTimed(LyricImport.parse("Kör aynalarda\nYüzümü kaybedişim"), start: 0, end: 20, fps: 24)
        p.lyricStyle.leadIn = 0
        return p
    }

    private func result(_ times: [[(Double, Double, Double)]]) -> LyricAlignment.Result {
        .init(lines: times.map { $0.map { .init(text: "", start: $0.0, end: $0.1, confidence: $0.2, source: "mms") } })
    }

    func testAlignmentTimesWordsFromTheAudioStartOnTheFrameGrid() {
        var p = placed()
        p.applyAlignment(result([[(18.88, 19.32, 0.74), (19.34, 20.91, 0.78)], [(23.54, 24.28, 0.2), (24.30, 26.47, 0.9)]]),
                         track: 0, audioStart: 2, keepConfirmed: true)
        let l = p.lyricTracks[0].lines
        XCTAssertEqual(l[0].words[0].start, p.quantize(20.88))
        XCTAssertEqual(l[0].start, l[0].words[0].start)
        XCTAssertEqual(l[1].end, p.quantize(28.47))
        XCTAssertEqual(l[1].words[0].confidence, 0.2)
        XCTAssertTrue(LyricAlignment.isLow(l[1].words[0]))
        XCTAssertFalse(LyricAlignment.isLow(l[1].words[1]))
        XCTAssertEqual(l[0].words.map(\.text), ["Kör", "aynalarda"], "original Unicode text is kept")
    }

    func testConfirmedWordsKeepTheirTimesWhenAsked() {
        var p = placed()
        p.lyricTracks[0].lines[0].words[0].confirmed = true
        let before = p.lyricTracks[0].lines[0].words[0]
        let r = result([[(5, 5.5, 0.9), (6, 7, 0.9)], [(8, 9, 0.9), (9, 10, 0.9)]])
        var keep = p
        keep.applyAlignment(r, track: 0, audioStart: 0, keepConfirmed: true)
        XCTAssertEqual(keep.lyricTracks[0].lines[0].words[0].start, before.start)
        XCTAssertTrue(keep.lyricTracks[0].lines[0].words[0].confirmed)
        p.applyAlignment(r, track: 0, audioStart: 0, keepConfirmed: false)
        XCTAssertEqual(p.lyricTracks[0].lines[0].words[0].start, 5)
    }

    func testAlignedWordsNeverOverlapAfterQuantizing() {
        var p = placed()
        p.applyAlignment(result([[(1.0, 1.03, 0.9), (1.01, 1.2, 0.9)], [(3, 3.01, 0.9), (3.01, 3.02, 0.9)]]), track: 0, audioStart: 0, keepConfirmed: false)
        for line in p.lyricTracks[0].lines {
            for (a, b) in zip(line.words, line.words.dropFirst()) { XCTAssertLessThan(a.start, b.start) }
            for w in line.words {
                XCTAssertEqual(w.end, line.end, "every word ends with its line")
                XCTAssertGreaterThanOrEqual(w.end - w.start, p.frameDuration - 1e-9)
            }
        }
    }

    func testLanguageHint() {
        XCTAssertEqual(LyricAlignment.language(for: ["Kör", "aynalarda"]), "tr")
        XCTAssertNil(LyricAlignment.language(for: ["hello", "world"]))
    }

    // MARK: Lead-in

    func testLeadInShowsAlignedWordsEarlier() {
        var p = placed()
        p.lyricStyle.leadIn = 0.25
        p.applyAlignment(result([[(10, 10.5, 0.9), (11, 12, 0.9)], [(20, 21, 0.9), (21, 22, 0.9)]]), track: 0, audioStart: 0, keepConfirmed: false)
        let w = p.lyricTracks[0].lines[0].words[0]
        XCTAssertEqual(w.start, p.quantize(9.75))
        XCTAssertEqual(w.end, p.lyricTracks[0].lines[0].end)
        XCTAssertEqual(p.lyricTracks[0].lines[0].end, p.quantize(11.75), "the line ends at its last word's end, shown early too")
        XCTAssertEqual(w.alignedStart, 10)
        XCTAssertEqual(p.lyricTracks[0].lines[0].start, w.start)
    }

    func testChangingLeadInMovesOnlyAlignedUnconfirmedWords() {
        var p = placed()
        p.applyAlignment(result([[(10, 10.5, 0.9), (11, 12, 0.9)], [(20, 21, 0.9), (21, 22, 0.9)]]), track: 0, audioStart: 0, keepConfirmed: false)
        p.lyricTracks[0].lines[1].words[0].confirmed = true
        let handPlaced = p.lyricTracks[0].lines[0].words[1].id
        p.retimeWord(handPlaced, start: 11.5, confirm: false)
        p.lyricStyle.leadIn = 0.5
        p.applyLeadIn()
        let l = p.lyricTracks[0].lines
        XCTAssertEqual(l[0].words[0].start, p.quantize(9.5))
        XCTAssertEqual(l[0].words[1].start, p.quantize(11.5), "a hand-placed word keeps its time")
        XCTAssertEqual(l[1].words[0].start, 20, "a confirmed word keeps its time")
        XCTAssertEqual(l[1].words[1].start, p.quantize(20.5))
        XCTAssertEqual(l[0].start, l[0].words[0].start, "the line still hugs its words")
        p.lyricStyle.leadIn = 0
        p.applyLeadIn()
        XCTAssertEqual(p.lyricTracks[0].lines[0].words[0].start, 10, "lead-in is reversible")
    }

    func testAlignedTimesFollowLineAndAudioMoves() {
        var p = placed()
        p.applyAlignment(result([[(10, 10.5, 0.9), (11, 12, 0.9)], [(20, 21, 0.9), (21, 22, 0.9)]]), track: 0, audioStart: 0, keepConfirmed: false)
        let line = p.lyricTracks[0].lines[0]
        p.moveLine(line.id, toTrack: 0, start: line.start + 1)
        XCTAssertEqual(p.lyricTracks[0].lines.first { $0.id == line.id }!.words[0].alignedStart, 11)
    }

    func testOldProjectsDefaultToAShortLeadIn() throws {
        XCTAssertEqual(LyricStyle().leadIn, 0.15)
        let w = try JSONDecoder().decode(LyricWord.self, from: Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"a","start":1,"end":2,"confidence":1,"confirmed":false}"#.utf8))
        XCTAssertNil(w.alignedStart)
    }
}
