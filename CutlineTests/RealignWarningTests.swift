import XCTest
@testable import Cutline

/// Re-aligning knows which lyric timing is yours (confirmed or moved by hand) and asks first.
final class RealignWarningTests: XCTestCase {
    /// Two lines on one track, already aligned: "a b" at 10-12 and "c d" at 20-22.
    private func aligned() -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        p.lyricStyle.leadIn = 0
        p.lyricTracks[0].lines = [
            LyricLine(start: 0, end: 1, words: [LyricWord(text: "a", start: 0, end: 1), LyricWord(text: "b", start: 0.5, end: 1)]),
            LyricLine(start: 2, end: 3, words: [LyricWord(text: "c", start: 2, end: 3), LyricWord(text: "d", start: 2.5, end: 3)]),
        ]
        p.applyAlignment(result(), track: 0, audioStart: 0, keepEdits: false)
        return p
    }

    private func result(shift: Double = 0) -> LyricAlignment.Result {
        func w(_ t: String, _ s: Double, _ e: Double) -> LyricAlignment.Word { .init(text: t, start: s + shift, end: e + shift, confidence: 0.9, source: "a") }
        return .init(lines: [[w("a", 10, 11), w("b", 11, 12)], [w("c", 20, 21), w("d", 21, 22)]])
    }

    private func words(_ p: Project) -> [LyricWord] { p.lyricTracks.flatMap(\.lines).flatMap(\.words) }

    // MARK: Marking

    func testMovingALineMarksItsWordsAsHandEdited() {
        let before = aligned()
        var p = before
        p.moveLine(p.lyricTracks[0].lines[1].id, toTrack: 0, start: 19)
        p.markHandEditedWords(comparedTo: before)
        XCTAssertEqual(words(p).map(\.isHandEdited), [false, false, true, true])
        XCTAssertFalse(words(p).contains(where: \.confirmed), "moving isn't confirming")
    }

    func testDraggingALineEdgeMarksTheWordsItMoved() {
        let before = aligned()
        var p = before
        p.retimeLine(p.lyricTracks[0].lines[0].id, start: 9.5)      // every start in the line moves
        p.markHandEditedWords(comparedTo: before)
        XCTAssertEqual(words(p).map(\.isHandEdited), [true, true, false, false])
    }

    func testUnchangedWordsAreNotMarked() {
        let before = aligned()
        var p = before
        p.markHandEditedWords(comparedTo: before)
        XCTAssertFalse(words(p).contains(where: \.isHandEdited))
    }

    func testTheFlagIsSavedAndOlderProjectsLoadWithoutIt() throws {
        var w = LyricWord(text: "x", start: 1, end: 2)
        w.handEdited = true
        XCTAssertEqual(try JSONDecoder().decode(LyricWord.self, from: JSONEncoder().encode(w)).isHandEdited, true)
        let old = #"{"id":"5A1F2B3C-0000-0000-0000-000000000002","text":"x","start":1,"end":2,"confidence":1,"confirmed":false}"#
        XCTAssertFalse(try JSONDecoder().decode(LyricWord.self, from: Data(old.utf8)).isHandEdited)
    }

    // MARK: The question

    func testNoQuestionWhenNothingIsYours() {
        XCTAssertNil(EditorModel.userTimingSummary(words(aligned())))
    }

    func testTheQuestionCountsConfirmedAndHandEditedWords() throws {
        var p = aligned()
        p.lyricTracks[0].lines[0].words[0].confirmed = true
        p.lyricTracks[0].lines[1].words[0].handEdited = true
        p.lyricTracks[0].lines[1].words[1].handEdited = true
        let text = try XCTUnwrap(EditorModel.userTimingSummary(words(p)))
        XCTAssertTrue(text.contains("1 word confirmed"), text)
        XCTAssertTrue(text.contains("2 words moved or re-timed by hand"), text)
    }

    func testAConfirmedWordThatWasAlsoMovedCountsOnce() throws {
        var p = aligned()
        p.lyricTracks[0].lines[0].words[0].confirmed = true
        p.lyricTracks[0].lines[0].words[0].handEdited = true
        let text = try XCTUnwrap(EditorModel.userTimingSummary(words(p)))
        XCTAssertTrue(text.contains("1 word confirmed"))
        XCTAssertFalse(text.contains("by hand"))
    }

    func testOnlyHandEditsStillAsk() {
        var p = aligned()
        p.lyricTracks[0].lines[1].words[0].handEdited = true
        XCTAssertNotNil(EditorModel.userTimingSummary(words(p)), "a moved line alone is enough to ask")
    }

    // MARK: Keep or re-time

    func testKeepMyChangesKeepsMovedLinesAndConfirmedWords() {
        let before = aligned()
        var p = before
        p.moveLine(p.lyricTracks[0].lines[1].id, toTrack: 0, start: 18)    // c d now 18-20
        p.markHandEditedWords(comparedTo: before)
        p.lyricTracks[0].lines[0].words[0].confirmed = true
        let moved = words(p)
        p.applyAlignment(result(shift: 0.25), track: 0, audioStart: 0, keepEdits: true)
        let now = words(p)
        XCTAssertEqual(now[0].start, moved[0].start, "the confirmed word stays")
        XCTAssertEqual(now[2].start, moved[2].start, "the moved line's words stay")
        XCTAssertEqual(now[3].start, moved[3].start)
        XCTAssertEqual(now[1].start, p.quantize(11.25), "the other word is re-timed")
        XCTAssertTrue(now[2].isHandEdited && now[3].isHandEdited, "kept words keep their flags")
        XCTAssertTrue(now[0].confirmed)
        XCTAssertFalse(now[1].isUserTimed)
    }

    func testReTimeAllClearsConfirmationsAndHandEdits() {
        let before = aligned()
        var p = before
        p.moveLine(p.lyricTracks[0].lines[1].id, toTrack: 0, start: 18)
        p.markHandEditedWords(comparedTo: before)
        p.lyricTracks[0].lines[0].words[0].confirmed = true
        p.applyAlignment(result(), track: 0, audioStart: 0, keepEdits: false)
        let now = words(p)
        XCTAssertFalse(now.contains(where: \.isUserTimed), "nothing is yours any more")
        XCTAssertEqual(now.map(\.start), before.lyricTracks.flatMap(\.lines).flatMap(\.words).map(\.start), "back to the aligned times")
        XCTAssertNil(EditorModel.userTimingSummary(now), "so the next re-align doesn't ask")
    }

    func testKeptHandEditsStayWhenOverlapsAreResolved() {
        let before = aligned()
        var p = before
        // Drag line 2 so its words sit right after "a": they now overlap where "b" will land.
        p.moveLine(p.lyricTracks[0].lines[1].id, toTrack: 0, start: 10.5)
        p.markHandEditedWords(comparedTo: before)
        let moved = words(p)
        p.resolveLyricOverlaps()
        XCTAssertEqual(words(p)[2].start, moved[2].start, "the hand-edited word doesn't give way")
    }

    @MainActor
    func testUndoRestoresTheFlags() {
        let doc = ProjectDocument(project: aligned())
        let e = doc.editor
        let um = doc.undoManager!
        um.groupsByEvent = false
        um.beginUndoGrouping()
        e.edit("Move Lyric Line") { p in
            let before = p
            p.moveLine(p.lyricTracks[0].lines[1].id, toTrack: 0, start: 18)
            p.markHandEditedWords(comparedTo: before)
        }
        um.endUndoGrouping()
        XCTAssertNotNil(EditorModel.userTimingSummary(words(e.project)))
        um.undo()
        XCTAssertNil(EditorModel.userTimingSummary(words(e.project)), "undoing the move undoes the mark")
    }
}
