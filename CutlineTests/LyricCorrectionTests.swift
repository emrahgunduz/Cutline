import XCTest
@testable import Cutline

@MainActor
final class LyricCorrectionTests: XCTestCase {
    /// Five words, one line each second, with confidences.
    private func editor(confidences: [Double] = [0.9, 0.3, 0.9, 0.2, 0.9], confirmed: Set<Int> = []) -> EditorModel {
        let e = EditorModel(document: nil)
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        p.lyricStyle.leadIn = 0
        let words = confidences.enumerated().map { i, c in
            LyricWord(text: "w\(i + 1)", start: Double(10 + i), end: Double(10 + i) + 0.5, confidence: c, confirmed: confirmed.contains(i))
        }
        p.lyricTracks[0].lines = [LyricLine(start: 10, end: 14.5, words: words)]
        e.replaceWithoutUndo(p)
        return e
    }

    private func id(_ e: EditorModel, _ i: Int) -> UUID { e.project.lyricTracks[0].lines[0].words[i].id }
    private func w(_ e: EditorModel, _ i: Int) -> LyricWord { e.project.lyricTracks[0].lines[0].words[i] }

    func testNextUnsureSkipsConfirmedAndWraps() {
        let e = editor(confidences: [0.9, 0.3, 0.2, 0.1, 0.9], confirmed: [2])
        e.setPlayhead(0)
        e.jumpToUnsureWord()
        XCTAssertEqual(e.selection, .lyricWord(id(e, 1)))
        e.jumpToUnsureWord()
        XCTAssertEqual(e.selection, .lyricWord(id(e, 3)), "the confirmed w3 is skipped")
        e.jumpToUnsureWord()
        XCTAssertEqual(e.selection, .lyricWord(id(e, 1)), "wraps to the first unsure word")
        e.jumpToUnsureWord(forward: false)
        XCTAssertEqual(e.selection, .lyricWord(id(e, 3)), "backwards wraps to the last")
    }

    func testNextUnsureLoopsAroundTheWord() {
        let e = editor()
        e.jumpToUnsureWord()
        let word = w(e, 1)
        XCTAssertEqual(e.transport.loop?.lowerBound ?? 0, word.start - EditorModel.loopPadding, accuracy: 1e-9)
        XCTAssertEqual(e.transport.loop?.upperBound ?? 0, word.end + EditorModel.loopPadding, accuracy: 1e-9)
        XCTAssertTrue(e.isPlaying)
        e.clearLoop()
        XCTAssertNil(e.transport.loop)
    }

    func testConfirmToggles() {
        let e = editor()
        e.selection = .lyricWord(id(e, 1))
        e.toggleConfirmSelectedWords()
        XCTAssertTrue(w(e, 1).confirmed)
        XCTAssertFalse(LyricAlignment.isLow(w(e, 1)))
        e.toggleConfirmSelectedWords()
        XCTAssertFalse(w(e, 1).confirmed)
    }

    /// A tap in slowed playback uses the player's song time, not wall-clock time.
    func testTapRecordsSongTimeAndAdvances() {
        let e = editor()
        e.selection = .lyricWord(id(e, 0))
        e.startTapMode()
        e.setTapRate(0.5)
        XCTAssertEqual(e.transport.tapWordID, id(e, 0))
        e.transport.currentTime = { 10.25 }      // the song position, however fast it plays
        e.tap(snap: false)
        XCTAssertEqual(w(e, 0).start, e.project.quantize(10.25))
        XCTAssertTrue(w(e, 0).confirmed)
        XCTAssertEqual(e.transport.tapWordID, id(e, 1), "moves on to the next word")
        // Words after the tap follow it (no right anchor yet).
        XCTAssertEqual(w(e, 1).start, e.project.quantize(11.25))
    }

    func testTapsAnchorTheWordsBetween() {
        let e = editor()
        e.selection = .lyricWord(id(e, 0))
        e.startTapMode()
        e.transport.currentTime = { 10 }; e.tap(snap: false)
        // Skip ahead to w5 and tap it at 12 s (AE1 in the editor).
        e.transport.tapWordID = id(e, 4)
        e.transport.currentTime = { 12 }; e.tap(snap: false)
        let ws = (0..<5).map { w(e, $0) }
        XCTAssertEqual(ws[0].start, 10); XCTAssertEqual(ws[4].start, 12)
        XCTAssertTrue(ws[1...3].allSatisfy { $0.start > 10 && $0.start < 12 })
        XCTAssertNil(e.transport.tapWordID, "tap mode ends after the last word")
        XCTAssertEqual(e.transport.stopAt ?? 0, ws[4].end + EditorModel.tapTailTime, accuracy: 1e-9, "the song plays on 5 s, then pauses")
        XCTAssertTrue(e.isPlaying)
        e.reachedStopPoint()
        XCTAssertFalse(e.isPlaying)
        XCTAssertNil(e.transport.stopAt)
    }

    /// The song starts at 2 s on the timeline; the vocal onset at song time 8.5 is 10.5 on the timeline.
    private func editorWithOnsets() -> EditorModel {
        let e = editor()
        let asset = Asset(kind: .audio, name: "s", path: "/s", duration: 30)
        e.edit("x") { $0.assets = [asset]; $0.setAudio(assetID: asset.id); $0.moveAudio(start: 2, alone: true) }
        e.audioAnalysis.adopt(AudioAnalysis(hash: "h", result: .init(duration: 30, tempo: 120, beats: [], downbeats: [],
                                                                      onsets: [8.5], sections: [], vocals: "")))
        return e
    }

    func testTapSnapsToANearbyVocalOnset() {
        let e = editorWithOnsets()
        e.selection = .lyricWord(id(e, 0))
        e.startTapMode()
        e.transport.currentTime = { 10.53 }       // 30 ms from the onset at 10.5
        e.tap(snap: true)
        XCTAssertEqual(w(e, 0).start, e.project.quantize(10.5))
    }

    func testTapFarFromAnOnsetOrWithSnappingOffStaysRaw() {
        var e = editorWithOnsets()
        e.selection = .lyricWord(id(e, 0))
        e.startTapMode()
        e.transport.currentTime = { 10.56 }       // 60 ms away: outside the 40 ms window
        e.tap(snap: true)
        XCTAssertEqual(w(e, 0).start, e.project.quantize(10.56))
        e = editorWithOnsets()
        e.selection = .lyricWord(id(e, 0))
        e.startTapMode()
        e.transport.currentTime = { 10.53 }
        e.tap(snap: false)
        XCTAssertEqual(w(e, 0).start, e.project.quantize(10.53))
    }

    func testTapLaterThanTheWordsEndMovesTheWordThere() {
        let e = editor()                           // w1 is 10-10.5
        e.selection = .lyricWord(id(e, 0))
        e.startTapMode()
        e.transport.currentTime = { 12.25 }        // well after w1's end
        e.tap(snap: false)
        XCTAssertEqual(w(e, 0).start, e.project.quantize(12.25))
        XCTAssertEqual(w(e, 0).end - w(e, 0).start, 0.5, accuracy: 1e-9, "the word keeps its length")
        // The next tap also lands where it is played, not clamped.
        e.transport.currentTime = { 14.0 }
        e.tap(snap: false)
        XCTAssertEqual(w(e, 1).start, 14)
    }

    func testTapUsesTheLeadIn() {
        let e = editor()
        e.edit("x") { $0.lyricStyle.leadIn = 0.25 }
        e.selection = .lyricWord(id(e, 0))
        e.startTapMode()
        e.transport.currentTime = { 10.5 }
        e.tap(snap: false)
        XCTAssertEqual(w(e, 0).start, e.project.quantize(10.25))
    }

    func testEndTapModeResetsSpeed() {
        let e = editor()
        e.startTapMode()
        e.setTapRate(0.75)
        e.endTapMode()
        XCTAssertNil(e.transport.tapWordID)
        XCTAssertEqual(e.transport.rate, 1)
        XCTAssertFalse(e.isPlaying)
    }

    // MARK: Lines on several tracks are one sung sequence

    private func twoTrackEditor() -> EditorModel {
        let e = EditorModel(document: nil)
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        p.lyricStyle.leadIn = 0
        p.lyricTracks = [LyricTrack(), LyricTrack()]
        func line(_ a: String, _ b: String, at t: Double) -> LyricLine {
            LyricLine(start: t, end: t + 1.5, words: [LyricWord(text: a, start: t, end: t + 0.5, confidence: 0.2),
                                                       LyricWord(text: b, start: t + 1, end: t + 1.5, confidence: 0.2)])
        }
        p.lyricTracks[0].lines = [line("a1", "a2", at: 10), line("c1", "c2", at: 14)]
        p.lyricTracks[1].lines = [line("b1", "b2", at: 12)]
        e.replaceWithoutUndo(p)
        return e
    }

    func testSungOrderInterleavesTracksByTime() {
        let e = twoTrackEditor()
        XCTAssertEqual(e.project.lyricOrder().map(\.value.text), ["a1", "a2", "b1", "b2", "c1", "c2"])
    }

    func testTapMovesOnToTheNextTrackWhenThatLineIsSungNext() {
        let e = twoTrackEditor()
        let a2 = e.project.lyricTracks[0].lines[0].words[1].id
        let b1 = e.project.lyricTracks[1].lines[0].words[0].id
        e.selection = .lyricWord(a2)
        e.startTapMode()
        e.transport.currentTime = { 11 }
        e.tap(snap: false)
        XCTAssertEqual(e.transport.tapWordID, b1)
    }

    func testAnchorStretchSpansTracks() {
        let e = twoTrackEditor()
        let before = e.project
        e.edit("x") { p in
            p.lyricTracks[0].lines[0].words[0].confirmed = true
            p.lyricTracks[0].lines[1].words[1].confirmed = true
            p.lyricTracks[0].lines[1].words[1].start = 16.5   // c2 moved 1 s later
            p.lyricTracks[0].lines[1].words[1].end = 17
            p.applyAnchorStretch(from: before)
        }
        // b1 (on track 2) sits between the anchors a1 and c2 and is stretched with them.
        let b1 = e.project.lyricTracks[1].lines[0].words[0]
        XCTAssertGreaterThan(b1.start, 12)
        XCTAssertLessThan(b1.start, 16.5)
    }

    func testAlignmentResultGoesToLinesOnEveryTrack() {
        var p = twoTrackEditor().project
        let ids = p.lyricLineOrder().map(\.id)
        let r = LyricAlignment.Result(lines: [0.0, 5, 10].map { t in
            [.init(text: "", start: 20 + t, end: 20.4 + t, confidence: 0.9, source: "mms"), .init(text: "", start: 21 + t, end: 21.4 + t, confidence: 0.9, source: "mms")]
        })
        p.applyAlignment(r, lineIDs: ids, audioStart: 0, keepConfirmed: false)
        XCTAssertEqual(p.lyricTracks[1].lines[0].words[0].start, 25)
        XCTAssertEqual(p.lyricTracks[0].lines.map(\.start), [20, 30])
    }

    func testLateTapDoesNotPushTheNextWord() {
        let e = editor()
        for i in 0..<5 { e.edit("x") { $0.lyricTracks[0].lines[0].words[i].alignedStart = Double(10 + i) } }
        e.selection = .lyricWord(id(e, 1))
        e.startTapMode()
        e.transport.currentTime = { 11.4 }   // 0.4 s late; the word lasts 0.5 s, w3 starts at 12
        e.tap(snap: false)
        XCTAssertEqual(w(e, 2).start, 12, "the next aligned word keeps its time")
        XCTAssertGreaterThanOrEqual(w(e, 1).end - w(e, 1).start, e.project.frameDuration - 1e-9)
    }

    func testRetimeAllClearsConfirmation() {
        var p = editor(confirmed: [0]).project
        let r = LyricAlignment.Result(lines: [(0..<5).map { .init(text: "", start: 20 + Double($0), end: 20.5 + Double($0), confidence: 0.9, source: "mms") }])
        p.applyAlignment(r, track: 0, audioStart: 0, keepConfirmed: false)
        XCTAssertFalse(p.lyricTracks[0].lines[0].words[0].confirmed)
        XCTAssertEqual(p.lyricTracks[0].lines[0].words[0].start, 20)
    }

    func testTapModeStartsFiveSecondsBeforeTheWord() {
        let e = editor()
        let song = Asset(kind: .audio, name: "s", path: "/s", duration: 30)
        e.edit("x") { $0.assets = [song]; $0.setAudio(assetID: song.id) }
        e.selection = .lyricWord(id(e, 2))   // w3 at 12 s
        e.startTapMode()
        XCTAssertEqual(e.playhead, 7, accuracy: 1e-9)
    }
}
