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
        XCTAssertEqual(keep.lyricTracks[0].lines[0].words[0], before)
        p.applyAlignment(r, track: 0, audioStart: 0, keepConfirmed: false)
        XCTAssertEqual(p.lyricTracks[0].lines[0].words[0].start, 5)
    }

    func testAlignedWordsNeverOverlapAfterQuantizing() {
        var p = placed()
        p.applyAlignment(result([[(1.0, 1.03, 0.9), (1.01, 1.2, 0.9)], [(3, 3.01, 0.9), (3.01, 3.02, 0.9)]]), track: 0, audioStart: 0, keepConfirmed: false)
        for line in p.lyricTracks[0].lines {
            for (a, b) in zip(line.words, line.words.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start) }
            for w in line.words { XCTAssertGreaterThanOrEqual(w.end - w.start, p.frameDuration - 1e-9) }
        }
    }

    func testLanguageHint() {
        XCTAssertEqual(LyricAlignment.language(for: ["Kör", "aynalarda"]), "tr")
        XCTAssertNil(LyricAlignment.language(for: ["hello", "world"]))
    }
}
