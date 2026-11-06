import XCTest
@testable import Cutline

final class TimelineLayoutTests: XCTestCase {
    private func layout(videos: Int = 2, lyrics: Int = 2) -> TimelineLayout {
        TimelineLayout(pixelsPerSecond: 100, scrollTime: 0, videoTrackCount: videos, lyricTrackCount: lyrics, viewWidth: 1132)
    }

    func testRowOrderIsAudioThenLyricsThenVideoTopLayerFirst() {
        XCTAssertEqual(layout().orderedRows, [.audio, .lyric(0), .lyric(1), .video(1), .video(0)])
    }

    func testCustomHeightsShiftRowsAndClampElsewhere() {
        var l = layout()
        l.height = { $0 == .audio ? 30 : TimelineLayout.defaultHeight($0) }
        XCTAssertEqual(l.frame(of: .lyric(0))?.minY, TimelineLayout.rulerHeight + 30)
    }

    func testPlaybackScrollsContinuouslyNotByPage() {
        let l = layout()   // 10 s visible
        XCTAssertEqual(l.scrollTimeFollowing(5, playing: true), 0)
        XCTAssertEqual(l.scrollTimeFollowing(7.5, playing: true), 0.5, accuracy: 1e-9)
        XCTAssertEqual(l.scrollTimeFollowing(30, playing: true), 23, accuracy: 1e-9)
    }

    func testJumpOutsideViewRecentersPlayhead() {
        let l = layout()
        XCTAssertEqual(l.scrollTimeFollowing(100, playing: false), 95, accuracy: 1e-9)
        XCTAssertEqual(l.scrollTimeFollowing(3, playing: false), 0)
    }

    func testSnapsWithinRadiusOnly() {
        XCTAssertEqual(Snapping.snap(10.05, targets: [10, 20], pixelsPerSecond: 100), 10)
        XCTAssertNil(Snapping.snap(10.2, targets: [10, 20], pixelsPerSecond: 100))
    }

    func testSnapTargetsExcludeDraggedItem() {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        let a = Asset(kind: .image, name: "i", path: "/i")
        p.assets = [a]
        let id = p.addClip(assetID: a.id, track: 0, at: 3)!
        XCTAssertFalse(Snapping.targets(in: p, playhead: 0, excluding: [id]).contains(3))
        XCTAssertTrue(Snapping.targets(in: p, playhead: 0, excluding: []).contains(3))
    }

    func testFilmstripGridCoarsensWithZoomAndNeverGoesBelowAFrame() {
        XCTAssertEqual(Filmstrip.gridStep(tileSeconds: 0.001, fps: 24), 1 / 24.0)
        XCTAssertEqual(Filmstrip.gridStep(tileSeconds: 3, fps: 24), 4)
        XCTAssertEqual(Filmstrip.snapped(5.3, step: 2), 4)
    }

    func testReorderTracks() {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.addVideoTrack(); p.addVideoTrack()
        let ids = p.videoTracks.map(\.id)
        p.moveVideoTrack(from: 0, to: 2)
        XCTAssertEqual(p.videoTracks.map(\.id), [ids[1], ids[2], ids[0]])
        p.addLyricTrack()
        let lids = p.lyricTracks.map(\.id)
        p.moveLyricTrack(from: 1, to: 0)
        XCTAssertEqual(p.lyricTracks.map(\.id), [lids[1], lids[0]])
    }
}

@MainActor
final class TimelineClampTests: XCTestCase {
    func testRemovingTheLastClipShrinksScrollableWidth() {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        let e = doc.editor
        let img = Asset(kind: .image, name: "i", path: "/i")
        e.edit("a") { p in p.assets = [img]; for i in 0..<20 { p.addClip(assetID: img.id, track: 0, at: Double(i) * 5) } }
        let view = TimelineView(editor: e)
        view.frame = CGRect(x: 0, y: 0, width: 1132, height: 300)
        view.pixelsPerSecond = 10
        view.scrollTime = 80
        e.edit("b") { p in p.videoTracks[0].clips.removeLast(10) }   // now 50 s long
        view.clampToContent()
        XCTAssertLessThanOrEqual(view.scrollTime, max(0, view.contentDuration - view.layout.visibleDuration) + 1e-9)
        XCTAssertLessThan(view.contentDuration, 80)
    }
}

final class LyricRowTests: XCTestCase {
    func testOneRowPerWordWithCappedHeight() {
        let rect = CGRect(x: 0, y: 0, width: 500, height: 200)
        let two = TimelineView.lyricParts(rect, wordCount: 2)
        let five = TimelineView.lyricParts(rect, wordCount: 5)
        XCTAssertEqual(two.words.count, 2)
        XCTAssertEqual(five.words.count, 5)
        XCTAssertEqual(two.words[0].height, TimelineView.maxWordRowHeight)
        XCTAssertEqual(five.words[0].height, two.words[0].height)          // same look
        XCTAssertTrue(zip(five.words, five.words.dropFirst()).allSatisfy { $0.maxY < $1.minY })
    }

    func testRowsShrinkInShortTracksAndHideWhenTooSmall() {
        let short = TimelineView.lyricParts(CGRect(x: 0, y: 0, width: 500, height: 60), wordCount: 5)
        XCTAssertTrue(short.words.isEmpty || short.words[0].height < TimelineView.maxWordRowHeight)
        XCTAssertTrue(TimelineView.lyricParts(CGRect(x: 0, y: 0, width: 500, height: 22), wordCount: 3).words.isEmpty)
    }
}

final class WheelZoomTests: XCTestCase {
    func testAMouseWheelZoomsAtThePointer() {
        XCTAssertEqual(TimelineView.wheelAction(dx: 0, dy: 1, precise: false, flags: [], overHeader: false), .zoom(1.15))
        guard case .zoom(let out) = TimelineView.wheelAction(dx: 0, dy: -2, precise: false, flags: [], overHeader: false) else { return XCTFail() }
        XCTAssertLessThan(out, 1, "wheel down zooms out")
    }

    func testShiftWheelAndTheHeaderScroll() {
        XCTAssertEqual(TimelineView.wheelAction(dx: 0, dy: 1, precise: false, flags: [.shift], overHeader: false), .pan(dx: 8, dy: 0))
        XCTAssertEqual(TimelineView.wheelAction(dx: 0, dy: 1, precise: false, flags: [], overHeader: true), .pan(dx: 0, dy: 8))
    }

    func testTrackpadScrollingStillPans() {
        XCTAssertEqual(TimelineView.wheelAction(dx: 3, dy: 4, precise: true, flags: [], overHeader: false), .pan(dx: 3, dy: 4))
        XCTAssertEqual(TimelineView.wheelAction(dx: 0, dy: 10, precise: true, flags: [.option], overHeader: false), .zoom(1.1))
    }
}

final class ClipLengthLabelTests: XCTestCase {
    func testLengthIsMinutesSecondsAndFramesAtTheProjectRate() {
        XCTAssertEqual(TimelineView.clipLength(6, fps: 30), "00:06:00")
        XCTAssertEqual(TimelineView.clipLength(6.792, fps: 24), "00:06:19")   // 163 frames
        XCTAssertEqual(TimelineView.clipLength(5 + 29.0 / 30, fps: 30), "00:05:29", "the last frame before a second")
        XCTAssertEqual(TimelineView.clipLength(6, fps: 30 - 0.000001), "00:06:00", "30 frames make a second, not :30")
        XCTAssertEqual(TimelineView.clipLength(65.48, fps: 25), "01:05:12")   // 1637 frames
        XCTAssertEqual(TimelineView.clipLength(-1, fps: 30), "00:00:00")
    }
}
