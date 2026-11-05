import XCTest
@testable import Cutline

final class LineSpacingTests: XCTestCase {
    /// One track: A 2-4 s, B 6-8 s, C 10-11 s.
    private func project() -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        func line(_ t: String, _ s: Double, _ e: Double) -> LyricLine { LyricLine(start: s, end: e, words: [LyricWord(text: t, start: s, end: e)]) }
        p.lyricTracks = [LyricTrack(lines: [line("A", 2, 4), line("B", 6, 8), line("C", 10, 11)])]
        return p
    }

    func testAMovedLineStopsAtItsNeighbourThenJumpsPastIt() {
        let p = project()
        let b = p.lyricTracks[0].lines[1]
        // Dragged left into A: stuck at A's end.
        XCTAssertEqual(p.freeLineStart(3, duration: 2, track: 0, ignoring: [b.id]), 4)
        XCTAssertEqual(p.freeLineStart(2.5, duration: 2, track: 0, ignoring: [b.id]), 4)
        // Far enough left that the room before A is closer: it jumps before A.
        XCTAssertEqual(p.freeLineStart(0.5, duration: 2, track: 0, ignoring: [b.id]), 0)
        // Free room: goes exactly where it is dragged.
        XCTAssertEqual(p.freeLineStart(4.5, duration: 2, track: 0, ignoring: [b.id]), 4.5)
        // Into C from the left: stuck at C's start, then past C's end.
        XCTAssertEqual(p.freeLineStart(9.5, duration: 2, track: 0, ignoring: [b.id]), 8)
        XCTAssertEqual(p.freeLineStart(10.8, duration: 2, track: 0, ignoring: [b.id]), 11)
    }

    func testALineThatFitsNowhereDoesNotMove() {
        var p = project()
        p.lyricTracks[0].lines.append(LyricLine(start: 0, end: 2, words: [LyricWord(text: "Z", start: 0, end: 2)]))
        p.lyricTracks[0].lines.append(LyricLine(start: 4, end: 6, words: [LyricWord(text: "Y", start: 4, end: 6)]))
        p.lyricTracks[0].lines.append(LyricLine(start: 8, end: 10, words: [LyricWord(text: "X", start: 8, end: 10)]))
        // 3 s long with gaps of 0 s only up to C's end: only the open end fits.
        XCTAssertEqual(p.freeLineStart(1, duration: 3, track: 0, ignoring: []), 11)
    }

    func testEdgesStopAtTheNeighbours() {
        let p = project()
        let limits = p.lineEdgeLimits(p.lyricTracks[0].lines[1].id)
        XCTAssertEqual(limits.minStart, 4)
        XCTAssertEqual(limits.maxEnd, 10)
        XCTAssertEqual(p.lineEdgeLimits(p.lyricTracks[0].lines[0].id).minStart, 0)
    }

    func testAGroupShiftStopsAtLinesOutsideTheGroup() {
        let p = project()
        let a = p.lyricTracks[0].lines[0].id, b = p.lyricTracks[0].lines[1].id
        XCTAssertEqual(p.clampLineShift(5, lines: [a, b]), 2, "B stops at C")
        XCTAssertEqual(p.clampLineShift(-1, lines: [a, b]), -1, "nothing before A (the drag itself keeps it at 0 or later)")
        XCTAssertEqual(p.clampLineShift(1, lines: [a, b]), 1)
    }

    func testLeadOutKeepsAlignedLinesLongerButNeverIntoTheNextLine() {
        var p = project()
        p.lyricStyle.leadIn = 0
        let ids = p.lyricTracks[0].lines.map(\.id)
        let r = LyricAlignment.Result(lines: [[.init(text: "A", start: 2, end: 3, confidence: 1, source: "a")],
                                             [.init(text: "B", start: 6, end: 7, confidence: 1, source: "a")],
                                             [.init(text: "C", start: 10, end: 10.5, confidence: 1, source: "a")]])
        p.applyAlignment(r, lineIDs: ids, audioStart: 0, keepConfirmed: false)
        XCTAssertEqual(p.lyricTracks[0].lines[0].end, 3)
        p.lyricStyle.leadOut = 0.5
        p.applyLeadIn()
        XCTAssertEqual(p.lyricTracks[0].lines[0].end, 3.5)
        XCTAssertEqual(p.lyricTracks[0].lines[0].words[0].end, 3.5)
        p.lyricStyle.leadOut = 5
        p.applyLeadIn()
        XCTAssertEqual(p.lyricTracks[0].lines[0].end, 6, "held at the next line's start")
        XCTAssertEqual(p.lyricTracks[0].lines[1].end, 10)
        XCTAssertEqual(p.lyricTracks[0].lines[2].end, 15.5, "the last line has room")
        p.lyricStyle.leadOut = 0
        p.applyLeadIn()
        XCTAssertEqual(p.lyricTracks[0].lines[0].end, 3, "and back")
    }
}

final class ExportSettingsTargetTests: XCTestCase {
    func testTargetSizeModeUsesTheShownTargetEvenBeforeItIsEdited() {
        let p = Project(type: .social, canvas: .init(width: 1080, height: 1920))
        var s = ExportSettings.defaults(for: p)
        XCTAssertEqual(s.rateMode, .bitrate)
        s.rateMode = .size
        XCTAssertEqual(s.sizeTarget, 50)
        XCTAssertEqual(s.estimatedBytes(duration: 284), 50_000_000, "the estimate is the target, not the bitrate's size")
        XCTAssertNotNil(s.sizeTargetBitrateMbps(duration: 284))
        s.sizeTargetMB = nil
        XCTAssertEqual(s.estimatedBytes(duration: 284), 50_000_000)
    }

    func testASolvedBitrateIsReusedOnlyForTheSameTargetAndLength() {
        var s = ExportSettings.defaults(for: Project(type: .ad, canvas: .init(width: 1080, height: 1920)))
        s.solvedSize = .init(targetMB: s.sizeTarget, duration: 30, audioKbps: s.audioBitrateKbps, bitrate: 9_000_000)
        XCTAssertEqual(s.solvedBitrate(duration: 30), 9_000_000)
        XCTAssertNil(s.solvedBitrate(duration: 29))
        s.sizeTargetMB = 20
        XCTAssertNil(s.solvedBitrate(duration: 30))
    }

    @MainActor
    func testExportChoicesAreRememberedWithoutUndo() {
        let doc = ProjectDocument(project: Project(type: .ad, canvas: .init(width: 1080, height: 1920)))
        let e = doc.editor
        e.edit("x") { $0.lyricStyle.leadIn = 0.3 }
        var s = ExportSettings.defaults(for: e.project)
        s.sizeTargetMB = 12
        e.rememberExportSettings(s)
        XCTAssertTrue(doc.isDocumentEdited)
        doc.undoManager?.undo()
        XCTAssertEqual(e.project.lyricStyle.leadIn, 0.15)
        XCTAssertEqual(e.project.exportSettings?.sizeTargetMB, 12, "undo doesn't throw away the export choices")
        XCTAssertEqual(ExportSettings.defaults(for: e.project).sizeTargetMB, 12)
    }
}
