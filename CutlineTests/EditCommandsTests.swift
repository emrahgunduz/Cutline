import XCTest
@testable import Cutline

final class EditCommandsTests: XCTestCase {
    private func project() -> (Project, UUID, UUID) {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        let video = Asset(kind: .video, name: "A", path: "/a", duration: 10, frameRate: 24)
        let image = Asset(kind: .image, name: "B.png", path: "/b")
        p.assets = [video, image]
        return (p, video.id, image.id)
    }

    func testFirstVideoClipLocksStandardFrameRate() {
        var (p, v, _) = project()
        p.assets[0].frameRate = 24.125
        p.addClip(assetID: v, track: 0, at: 0)
        XCTAssertEqual(p.fps, 24)
        XCTAssertTrue(p.fpsLocked)
    }

    func testSplitCreatesContiguousSourceRanges() throws {
        var (p, v, _) = project()
        let id = try XCTUnwrap(p.addClip(assetID: v, track: 0, at: 2))
        p.trimStart(id, to: 3)                 // sourceIn 1, start 3, duration 9
        p.split(at: 6)
        let clips = p.videoTracks[0].clips
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].start, 3); XCTAssertEqual(clips[0].duration, 3); XCTAssertEqual(clips[0].sourceIn, 1)
        XCTAssertEqual(clips[1].start, 6); XCTAssertEqual(clips[1].duration, 6); XCTAssertEqual(clips[1].sourceIn, 4)
        XCTAssertNotEqual(clips[0].id, clips[1].id)
    }

    func testTrimPastSourceClamps() throws {
        var (p, v, _) = project()
        let id = try XCTUnwrap(p.addClip(assetID: v, track: 0, at: 5))
        p.trimEnd(id, to: 100)
        XCTAssertEqual(p.videoTracks[0].clips[0].duration, 10)
        p.trimStart(id, to: 0)                 // cannot reveal frames before source start
        XCTAssertEqual(p.videoTracks[0].clips[0].start, 5)
        XCTAssertEqual(p.videoTracks[0].clips[0].sourceIn, 0)
    }

    func testImageClipCanBeExtendedFreely() throws {
        var (p, _, img) = project()
        let id = try XCTUnwrap(p.addClip(assetID: img, track: 0, at: 0))
        p.trimEnd(id, to: 42)
        XCTAssertEqual(p.videoTracks[0].clips[0].duration, 42)
    }

    func testRemovingTrackRemovesItsClipsButKeepsLastTrack() throws {
        var (p, v, _) = project()
        p.addVideoTrack()
        p.addClip(assetID: v, track: 1, at: 0)
        p.removeVideoTrack(at: 1)
        XCTAssertEqual(p.videoTracks.count, 1)
        XCTAssertTrue(p.videoTracks.flatMap(\.clips).isEmpty)
        p.removeVideoTrack(at: 0)
        XCTAssertEqual(p.videoTracks.count, 1)
    }

    func testMoveClipBetweenTracks() throws {
        var (p, v, _) = project()
        p.addVideoTrack()
        let id = try XCTUnwrap(p.addClip(assetID: v, track: 0, at: 0))
        p.moveClip(id, toTrack: 1, start: 4)
        XCTAssertTrue(p.videoTracks[0].clips.isEmpty)
        XCTAssertEqual(p.videoTracks[1].clips.first?.start, 4)
    }

    @MainActor
    func testUndoAfterSplitRestoresOneClip() throws {
        let doc = ProjectDocument(project: project().0)
        let editor = doc.editor
        let v = editor.project.assets[0].id
        let um = try XCTUnwrap(doc.undoManager)
        um.groupsByEvent = false   // each call below stands for a separate user action
        um.beginUndoGrouping(); editor.edit("Add") { $0.addClip(assetID: v, track: 0, at: 0) }; um.endUndoGrouping()
        um.beginUndoGrouping(); editor.edit("Split") { $0.split(at: 5) }; um.endUndoGrouping()
        XCTAssertEqual(editor.project.videoTracks[0].clips.count, 2)
        doc.undoManager?.undo()
        XCTAssertEqual(editor.project.videoTracks[0].clips.count, 1)
        doc.undoManager?.redo()
        XCTAssertEqual(editor.project.videoTracks[0].clips.count, 2)
    }
}

@MainActor
final class LiveEditTests: XCTestCase {
    func testLiveEditsCollapseIntoOneUndoStep() throws {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        let e = doc.editor
        let um = try XCTUnwrap(doc.undoManager)
        um.groupsByEvent = false
        for v in stride(from: 0.06, through: 0.12, by: 0.02) {
            e.liveEdit { $0.lyricStyle.sizeFraction = v }
            XCTAssertEqual(e.project.lyricStyle.sizeFraction, v, accuracy: 1e-9)   // visible while dragging
        }
        um.beginUndoGrouping(); e.endLiveEdit("Size"); um.endUndoGrouping()
        XCTAssertEqual(e.project.lyricStyle.sizeFraction, 0.12, accuracy: 1e-9)
        um.undo()
        XCTAssertEqual(e.project.lyricStyle.sizeFraction, 0.06, accuracy: 1e-9)
    }
}

final class MoveAudioTests: XCTestCase {
    func testMovingAudioAddsIntroAndCarriesLyrics() {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        p.assets = [Asset(kind: .audio, name: "a", path: "/a", duration: 100)]
        p.setAudio(assetID: p.assets[0].id)
        p.lyricTracks[0].lines = [LyricLine(start: 10, end: 12, words: [LyricWord(text: "x", start: 10, end: 12)])]
        p.moveAudio(start: 8)
        XCTAssertEqual(p.audio?.start, 8)
        XCTAssertEqual(p.audio?.duration, 100)
        XCTAssertEqual(p.duration, 108)
        XCTAssertEqual(p.lyricTracks[0].lines[0].words[0].start, 18)
        p.moveAudio(start: -5)
        XCTAssertEqual(p.audio?.start, 0)
        XCTAssertEqual(p.lyricTracks[0].lines[0].start, 10)
    }

    private func laidOut() -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        let song = Asset(kind: .audio, name: "a", path: "/a", duration: 100)
        let img = Asset(kind: .image, name: "i", path: "/i")
        p.assets = [song, img]
        p.setAudio(assetID: song.id)
        p.moveAudio(start: 4, alone: true)
        _ = p.addClip(assetID: img.id, track: 0, at: 3)
        p.cinemascope.startMarker = 20; p.cinemascope.endMarker = 24
        return p
    }

    func testMovingAudioCarriesClipsAndMarkers() {
        var p = laidOut()
        p.moveAudio(start: 6)
        XCTAssertEqual(p.videoTracks[0].clips[0].start, 5)
        XCTAssertEqual(p.cinemascope.startMarker, 22)
        XCTAssertEqual(p.cinemascope.endMarker, 26)
    }

    func testMovingLeftStopsWhenTheEarliestItemReachesZero() {
        var p = laidOut()
        p.moveAudio(start: 0)            // the clip at 3 s can only go 3 s left
        XCTAssertEqual(p.audio?.start, 1)
        XCTAssertEqual(p.videoTracks[0].clips[0].start, 0)
    }

    func testOptionMoveLeavesClipsAndUnanchoredMarkers() {
        var p = laidOut()
        p.moveAudio(start: 10, alone: true)
        XCTAssertEqual(p.audio?.start, 10)
        XCTAssertEqual(p.videoTracks[0].clips[0].start, 3)
        XCTAssertEqual(p.cinemascope.startMarker, 20)
    }
}

@MainActor
final class MultiSelectTests: XCTestCase {
    func testToggleBuildsMultiSelectionAndDeleteRemovesAll() {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        let a = Asset(kind: .image, name: "i", path: "/i")
        p.assets = [a]
        let c1 = p.addClip(assetID: a.id, track: 0, at: 0)!, c2 = p.addClip(assetID: a.id, track: 0, at: 10)!, c3 = p.addClip(assetID: a.id, track: 0, at: 20)!
        let doc = ProjectDocument(project: p)
        let e = doc.editor
        e.selection = .clip(c1)
        e.toggleSelected(.clip(c3))
        XCTAssertEqual(e.selectedItems, [.clip(c1), .clip(c3)])
        e.toggleSelected(.clip(c1))
        XCTAssertEqual(e.selectedItems, [.clip(c3)])
        e.toggleSelected(.clip(c1))
        e.deleteSelection()
        XCTAssertEqual(e.project.videoTracks[0].clips.map(\.id), [c2])
        XCTAssertTrue(e.selectedItems.isEmpty)
    }

    func testPlainSelectionResetsMulti() {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        doc.editor.setSelection([.audio, .clip(UUID())])
        doc.editor.selection = .none
        XCTAssertTrue(doc.editor.selectedItems.isEmpty)
    }
}

@MainActor
final class EditPointTests: XCTestCase {
    func testJumpBetweenEditPoints() {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        let a = Asset(kind: .image, name: "i", path: "/i")
        p.assets = [a]
        p.addClip(assetID: a.id, track: 0, at: 2)      // 2–7
        let doc = ProjectDocument(project: p)
        let e = doc.editor
        e.jumpToEditPoint(forward: true)
        XCTAssertEqual(e.playhead, 2)
        e.jumpToEditPoint(forward: true)
        XCTAssertEqual(e.playhead, 7)
        e.jumpToEditPoint(forward: false)
        XCTAssertEqual(e.playhead, 2)
        e.step(seconds: 1)
        XCTAssertEqual(e.playhead, 3)
    }
}

/// Clamping and scoping branches the timeline drag handlers rely on.
final class EditCommandBranchTests: XCTestCase {
    private func videoProject() -> (Project, video: UUID, image: UUID) {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        let video = Asset(kind: .video, name: "A", path: "/a", duration: 10, frameRate: 24)
        let image = Asset(kind: .image, name: "B.png", path: "/b")
        p.assets = [video, image]
        return (p, video.id, image.id)
    }

    private func lyricProject() -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 25
        p.lyricTracks[0].lines = [
            LyricLine(start: 5, end: 9, words: [
                LyricWord(text: "one", start: 5, end: 6),
                LyricWord(text: "two", start: 6.2, end: 8.8),
            ]),
            LyricLine(start: 10, end: 11, words: [LyricWord(text: "solo", start: 10, end: 11)]),
        ]
        return p
    }

    /// Words end with their line: a word's new end moves the line's end, but never before
    /// one frame after the line's last word starts.
    func testRetimeWordEndMovesTheLineEndWithinLimits() {
        var p = lyricProject()
        let w = p.lyricTracks[0].lines[0].words[0].id
        p.retimeWord(w, end: 8)
        XCTAssertEqual(p.lyricTracks[0].lines[0].end, 8, accuracy: 1e-9)
        XCTAssertTrue(p.lyricTracks[0].lines[0].words.allSatisfy { $0.end == 8 })
        p.retimeWord(w, end: 4)
        XCTAssertEqual(p.lyricTracks[0].lines[0].end, 6.2 + p.frameDuration, accuracy: 1e-9)
        XCTAssertEqual(p.lyricTracks[0].lines[0].words[0].start, 5, accuracy: 1e-9)
    }

    func testRetimeWordStartPastTheLineEndExtendsTheLine() {
        var p = lyricProject()
        let w = p.lyricTracks[0].lines[0].words[0].id
        p.retimeWord(w, start: 9.5)
        let line = p.lyricTracks[0].lines[0]
        XCTAssertEqual(line.words[0].start, p.quantize(9.5), accuracy: 1e-9)
        XCTAssertEqual(line.end, p.quantize(9.5) + p.frameDuration, accuracy: 1e-9)
        XCTAssertTrue(line.words.allSatisfy { $0.end == line.end })
    }

    /// Words: "one" at 5 (0 s from the start), "two" at 6.2 (1.2 s); the line ends at 9.
    func testDraggingTheLineStartCarriesWordsAtTheirOffsets() {
        var p = lyricProject()
        let id = p.lyricTracks[0].lines[0].id
        p.retimeLine(id, start: 4)
        let line = p.lyricTracks[0].lines[0]
        XCTAssertEqual(line.start, 4)
        XCTAssertEqual(line.words.map(\.start), [4, 5.2])
        XCTAssertEqual(line.end, 9, "the end stays")
        XCTAssertTrue(line.words.allSatisfy { $0.end == 9 }, "words stretch to the line end")
    }

    func testDraggingTheLineEndCarriesWordsAtTheirDistanceFromTheEnd() {
        var p = lyricProject()
        let id = p.lyricTracks[0].lines[0].id
        p.retimeLine(id, end: 9.6)
        let line = p.lyricTracks[0].lines[0]
        XCTAssertEqual(line.start, 5, "the start stays")
        XCTAssertEqual(line.end, 9.6, accuracy: 1e-9)
        XCTAssertEqual(line.words[0].start, 5.6, accuracy: 1e-9)
        XCTAssertEqual(line.words[1].start, 6.8, accuracy: 1e-9)
    }

    func testWordsNeverCrossTheFixedEdge() {
        var p = lyricProject()
        let id = p.lyricTracks[0].lines[0].id
        p.retimeLine(id, start: 8.5)            // "two" (1.2 s in) would pass the end at 9
        var line = p.lyricTracks[0].lines[0]
        XCTAssertEqual(line.words[1].start, 9 - p.frameDuration, accuracy: 1e-9)
        XCTAssertEqual(line.words[1].start - line.words[0].start, 1.2, accuracy: 1e-9, "offsets are kept")
        p = lyricProject()
        p.retimeLine(id, end: 6)                // "one" can't move before the start at 5
        line = p.lyricTracks[0].lines[0]
        XCTAssertEqual(line.words[0].start, 5, accuracy: 1e-9)
        XCTAssertEqual(line.end, 9, accuracy: 1e-9)
    }

    func testDeletingLastWordRemovesLineButNotOthers() {
        var p = lyricProject()
        p.deleteWord(p.lyricTracks[0].lines[0].words[0].id)
        XCTAssertEqual(p.lyricTracks[0].lines.count, 2)
        XCTAssertEqual(p.lyricTracks[0].lines[0].words.map(\.text), ["two"])
        p.deleteWord(p.lyricTracks[0].lines[1].words[0].id)
        XCTAssertEqual(p.lyricTracks[0].lines.count, 1)
        XCTAssertEqual(p.lyricTracks[0].lines[0].text, "two")
    }

    func testSplitWithClipIDSplitsOnlyThatClip() throws {
        var (p, v, _) = videoProject()
        p.addVideoTrack()
        let a = try XCTUnwrap(p.addClip(assetID: v, track: 0, at: 0))
        _ = try XCTUnwrap(p.addClip(assetID: v, track: 1, at: 0))
        p.split(at: 5, clipID: a)
        XCTAssertEqual(p.videoTracks[0].clips.count, 2)
        XCTAssertEqual(p.videoTracks[1].clips.count, 1)
    }

    func testSplitAndTrimStartOnImageKeepSourceInAtZero() throws {
        var (p, _, img) = videoProject()
        let id = try XCTUnwrap(p.addClip(assetID: img, track: 0, at: 0))   // 0-5
        p.split(at: 2)
        XCTAssertEqual(p.videoTracks[0].clips.map(\.sourceIn), [0, 0])
        let right = p.videoTracks[0].clips[1].id
        p.trimStart(right, to: 3)
        XCTAssertEqual(p.videoTracks[0].clips[1].start, 3)
        XCTAssertEqual(p.videoTracks[0].clips[1].sourceIn, 0)
        XCTAssertEqual(p.videoTracks[0].clips[0].id, id)
    }

    func testFrameRateStaysLockedAfterFirstVideo() {
        var (p, v, img) = videoProject()
        p.addClip(assetID: img, track: 0, at: 20)       // images never lock the rate
        XCTAssertFalse(p.fpsLocked)
        p.addClip(assetID: v, track: 0, at: 0)
        XCTAssertEqual(p.fps, 24)
        let other = Asset(kind: .video, name: "C", path: "/c", duration: 4, frameRate: 30)
        p.assets.append(other)
        p.addClip(assetID: other.id, track: 0, at: 40)
        XCTAssertEqual(p.fps, 24)
    }
}
