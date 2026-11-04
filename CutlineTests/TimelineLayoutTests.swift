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
