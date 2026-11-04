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
}
