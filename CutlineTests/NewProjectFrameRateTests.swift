import XCTest
@testable import Cutline

/// New Project picks the frame rate (24 by default); videos added later don't change it.
final class NewProjectFrameRateTests: XCTestCase {
    func testRateLabels() {
        XCTAssertEqual(Project.standardRates.map(NewProjectView.rateLabel), ["23.976", "24", "25", "29.97", "30", "50", "59.94", "60"])
    }

    func testAChosenRateIsKeptWhenAVideoIsAdded() {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        p.fpsLocked = true
        var v = Asset(kind: .video, name: "v", path: "/v.mov", duration: 10)
        v.frameRate = 30
        p.assets = [v]
        p.addClip(assetID: v.id, track: 0, at: 0)
        XCTAssertEqual(p.fps, 24)
    }

    func testImportRunsAtTheChosenRateOnItsFrameGrid() {
        var src = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        src.fps = 30
        src.fpsLocked = true
        let img = Asset(kind: .image, name: "i", path: "/i.png")
        src.assets = [img]
        src.addClip(assetID: img.id, track: 0, at: 1 + 1.0 / 30)   // a 30 fps frame, not on the 24 fps grid
        let p = ProjectImport.make(from: src, type: .musicVideo, canvas: .init(width: 1920, height: 1080), fps: 24).project
        XCTAssertEqual(p.fps, 24)
        XCTAssertTrue(p.fpsLocked)
        let start = p.videoTracks[0].clips[0].start
        XCTAssertEqual((start * 24).rounded(), start * 24, accuracy: 1e-9, "on the 24 fps grid")
        let kept = ProjectImport.make(from: src, type: .musicVideo, canvas: .init(width: 1920, height: 1080)).project
        XCTAssertEqual(kept.fps, 30, "without a rate, the source's is kept")
    }
}
