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
}
