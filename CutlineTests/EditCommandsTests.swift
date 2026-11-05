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

    func testRetimeWordEndBeforeStartKeepsStartAndMinimumLength() {
        var p = lyricProject()
        let w = p.lyricTracks[0].lines[0].words[0].id
        p.retimeWord(w, end: 4)
        let word = p.lyricTracks[0].lines[0].words[0]
        XCTAssertEqual(word.start, 5, accuracy: 1e-9)
        XCTAssertEqual(word.end, 5 + p.frameDuration, accuracy: 1e-9)
    }

    /// A word's end is its own: changing it leaves the line and the other words alone.
    func testRetimeWordEndChangesOnlyThatWord() {
        var p = lyricProject()
        let w = p.lyricTracks[0].lines[0].words[0].id
        p.retimeWord(w, end: 7.4)
        let line = p.lyricTracks[0].lines[0]
        XCTAssertEqual(line.words[0].end, 7.4, accuracy: 1e-9)
        XCTAssertEqual(line.words[1].end, 8.8, accuracy: 1e-9)
        XCTAssertEqual(line.end, 9, accuracy: 1e-9)
        p.retimeWord(w, end: 9.6)                // past the line end: the line grows
        XCTAssertEqual(p.lyricTracks[0].lines[0].end, 9.6, accuracy: 1e-9)
    }

    func testRetimeWordStartAfterEndKeepsEndAndMinimumLength() {
        var p = lyricProject()
        let w = p.lyricTracks[0].lines[0].words[0].id
        p.retimeWord(w, start: 7)
        let word = p.lyricTracks[0].lines[0].words[0]
        XCTAssertEqual(word.end, 6, accuracy: 1e-9)
        XCTAssertEqual(word.start, 6 - p.frameDuration, accuracy: 1e-9)
    }

    /// Words: "one" 5-6, "two" 6.2-8.8; the line is 5-9.
    func testDraggingTheLineStartMovesWordStartsOnly() {
        var p = lyricProject()
        let id = p.lyricTracks[0].lines[0].id
        p.retimeLine(id, start: 4)
        let line = p.lyricTracks[0].lines[0]
        XCTAssertEqual(line.start, 4)
        XCTAssertEqual(line.words.map(\.start), [4, 5.2], "starts keep their distance from the line start")
        XCTAssertEqual(line.words.map(\.end), [6, 8.8], "ends stay")
        XCTAssertEqual(line.end, 9)
    }

    func testDraggingTheLineEndMovesWordEndsOnly() {
        var p = lyricProject()
        let id = p.lyricTracks[0].lines[0].id
        p.retimeLine(id, end: 9.6)
        let line = p.lyricTracks[0].lines[0]
        XCTAssertEqual(line.start, 5)
        XCTAssertEqual(line.end, 9.6, accuracy: 1e-9)
        XCTAssertEqual(line.words.map(\.start), [5, 6.2], "starts stay")
        XCTAssertEqual(line.words[0].end, 6.6, accuracy: 1e-9, "ends keep their distance from the line end")
        XCTAssertEqual(line.words[1].end, 9.4, accuracy: 1e-9)
    }

    func testLineEdgeDragStopsAtTheShortestWord() {
        var p = lyricProject()
        let id = p.lyricTracks[0].lines[0].id
        p.retimeLine(id, start: 8)               // "one" (5-6) can only lose 1 s minus a frame
        XCTAssertEqual(p.lyricTracks[0].lines[0].words[0].start, 6 - p.frameDuration, accuracy: 1e-9)
        p = lyricProject()
        p.retimeLine(p.lyricTracks[0].lines[0].id, end: 6)   // "one" can only lose its length minus a frame
        XCTAssertEqual(p.lyricTracks[0].lines[0].words[0].end, 5 + p.frameDuration, accuracy: 1e-9)
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

final class DefaultClipScaleTests: XCTestCase {
    private func scale(_ type: ProjectType, canvas: CanvasSize, video: CanvasSize, kind: AssetKind = .video) -> Double {
        var p = Project(type: type, canvas: canvas)
        let a = Asset(kind: kind, name: "v", path: "/v", pixelSize: video, duration: 10, frameRate: 24)
        p.assets = [a]
        let id = p.addClip(assetID: a.id, track: 0, at: 0)!
        return p.videoTracks[0].clips.first { $0.id == id }!.transform.scale
    }

    func testVideoFillsAHorizontalFrame() {
        XCTAssertEqual(scale(.musicVideo, canvas: .init(width: 1920, height: 1080), video: .init(width: 3840, height: 2160)), 1, accuracy: 1e-9)
        // 2.39:1 footage would leave bars top and bottom when fitted.
        XCTAssertEqual(scale(.musicVideo, canvas: .init(width: 1920, height: 1080), video: .init(width: 1920, height: 804)), (1920.0 / 804) / (16.0 / 9), accuracy: 1e-6)
        // 4:3 footage fills the width.
        XCTAssertEqual(scale(.musicVideo, canvas: .init(width: 1920, height: 1080), video: .init(width: 1440, height: 1080)), (16.0 / 9) / (4.0 / 3), accuracy: 1e-6)
    }

    func testVideoFillsAPortraitFrame() {
        // 16:9 footage in 9:16: tall enough to cover the frame top to bottom.
        XCTAssertEqual(scale(.ad, canvas: .init(width: 1080, height: 1920), video: .init(width: 1920, height: 1080)), (16.0 / 9) * (16.0 / 9), accuracy: 1e-6)
        XCTAssertEqual(scale(.social, canvas: .init(width: 1080, height: 1920), video: .init(width: 1080, height: 1920)), 1, accuracy: 1e-9)
    }

    func testImagesStartFitted() {
        XCTAssertEqual(scale(.musicVideo, canvas: .init(width: 1920, height: 1080), video: .init(width: 400, height: 400), kind: .image), 1)
        XCTAssertEqual(scale(.ad, canvas: .init(width: 1080, height: 1920), video: .init(width: 400, height: 900), kind: .image), 1)
    }
}

final class PreviewNudgeTests: XCTestCase {
    func testShiftLocksADragToOneAxis() {
        XCTAssertEqual(PreviewCanvasView.locked(30, 12, shift: true).0, 30)
        XCTAssertEqual(PreviewCanvasView.locked(30, 12, shift: true).1, 0)
        XCTAssertEqual(PreviewCanvasView.locked(-5, 40, shift: true).0, 0)
        XCTAssertEqual(PreviewCanvasView.locked(-5, 40, shift: true).1, 40)
        XCTAssertEqual(PreviewCanvasView.locked(30, 12, shift: false).1, 12, "free without ⇧")
    }

    func testArrowsNudgeOnePixelAndShiftUsesTheStep() {
        let key = NudgeStep.key
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(PreviewCanvasView.nudgeDelta(keyCode: 124, flags: [])?.0, 1)
        XCTAssertEqual(PreviewCanvasView.nudgeDelta(keyCode: 126, flags: [])?.1, 1, "up is +y")
        XCTAssertEqual(PreviewCanvasView.nudgeDelta(keyCode: 123, flags: [.shift])?.0, -10)
        UserDefaults.standard.set(25.0, forKey: key)
        XCTAssertEqual(PreviewCanvasView.nudgeDelta(keyCode: 125, flags: [.shift])?.1, -25)
        XCTAssertNil(PreviewCanvasView.nudgeDelta(keyCode: 124, flags: [.option]))
        XCTAssertNil(PreviewCanvasView.nudgeDelta(keyCode: 49, flags: []))
    }
}
