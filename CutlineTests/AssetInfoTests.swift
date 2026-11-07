import XCTest
@testable import Cutline

/// The detail boxes under an asset's name, by kind: the size, and the length as MM:SS (FF)
/// with the frame rate.
final class AssetInfoTests: XCTestCase {
    private let canvas = CanvasSize(width: 1920, height: 1080)

    func testVideoShowsItsSizeAndItsLengthAtItsOwnRate() {
        var v = Asset(kind: .video, name: "v.mov", path: "/v.mov", duration: 6.5)
        v.pixelSize = CanvasSize(width: 3840, height: 2160)
        v.frameRate = 24000.0 / 1001
        XCTAssertEqual(AssetInfo.details(for: v, canvas: canvas, fps: 30),
                       .init(size: "3840×2160", length: "00:06 (12)", rate: "23.976 fps"), "frames counted at the video's rate, not the project's")
        v.frameRate = 29.97
        XCTAssertEqual(AssetInfo.details(for: v, canvas: canvas, fps: 24).rate, "29.97 fps")
        v.frameRate = 25
        XCTAssertEqual(AssetInfo.details(for: v, canvas: canvas, fps: 24), .init(size: "3840×2160", length: "00:06 (13)", rate: "25 fps"), "162.5 frames at 25 fps")
        v.frameRate = nil
        XCTAssertEqual(AssetInfo.details(for: v, canvas: canvas, fps: 24), .init(size: "3840×2160", length: "00:06 (12)", rate: nil),
                       "no rate of its own: frames at the project's rate, no rate shown")
    }

    func testImageShowsOnlyItsSize() {
        var i = Asset(kind: .image, name: "i.png", path: "/i.png")
        i.pixelSize = CanvasSize(width: 1024, height: 768)
        XCTAssertEqual(AssetInfo.details(for: i, canvas: canvas, fps: 24), .init(size: "1024×768"))
    }

    func testDummyShowsTheProjectsSizeRateAndItsLength() {
        var p = Project(type: .musicVideo, canvas: canvas)
        let d = p.addDummy(title: "Scene", fontName: "Helvetica", length: 65.5, color: RGBA(r: 0.2, g: 0.2, b: 0.3, a: 1))
        XCTAssertEqual(AssetInfo.details(for: d, canvas: CanvasSize(width: 1080, height: 1920), fps: 24),
                       .init(size: "1080×1920", length: "01:05 (12)", rate: "24 fps"))
    }

    func testSongShowsItsLengthAndLyricsShowNothing() {
        XCTAssertEqual(AssetInfo.details(for: Asset(kind: .audio, name: "s", path: "/s", duration: 3725), canvas: canvas, fps: 30),
                       .init(length: "62:05 (00)"))
        XCTAssertEqual(AssetInfo.details(for: Asset(kind: .lyrics, name: "l.txt", path: "/l.txt"), canvas: canvas, fps: 30), .init())
    }
}
