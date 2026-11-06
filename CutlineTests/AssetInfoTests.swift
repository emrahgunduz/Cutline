import XCTest
@testable import Cutline

/// The details under an asset's name, by kind.
final class AssetInfoTests: XCTestCase {
    private let canvas = CanvasSize(width: 1920, height: 1080)

    func testVideoShowsSizeLengthAndFrameRate() {
        var v = Asset(kind: .video, name: "v.mov", path: "/v.mov", duration: 6.4)
        v.pixelSize = CanvasSize(width: 3840, height: 2160)
        v.frameRate = 24000.0 / 1001
        XCTAssertEqual(AssetInfo.text(for: v, canvas: canvas), "3840×2160 · 0:06 · 23.976 fps")
        v.frameRate = 29.97
        XCTAssertEqual(AssetInfo.text(for: v, canvas: canvas), "3840×2160 · 0:06 · 29.97 fps")
        v.frameRate = 25
        XCTAssertEqual(AssetInfo.text(for: v, canvas: canvas), "3840×2160 · 0:06 · 25 fps")
    }

    func testImageShowsItsSize() {
        var i = Asset(kind: .image, name: "i.png", path: "/i.png")
        i.pixelSize = CanvasSize(width: 1024, height: 768)
        XCTAssertEqual(AssetInfo.text(for: i, canvas: canvas), "1024×768")
        XCTAssertFalse(AssetInfo.includesLength(i))
    }

    func testDummyShowsTheProjectsSizeAndItsLength() {
        var p = Project(type: .musicVideo, canvas: canvas)
        let d = p.addDummy(title: "Scene", fontName: "Helvetica", length: 65, color: RGBA(r: 0.2, g: 0.2, b: 0.3, a: 1))
        XCTAssertEqual(AssetInfo.text(for: d, canvas: CanvasSize(width: 1080, height: 1920)), "1080×1920 · 1:05")
    }

    func testSongShowsItsLengthAndLyricsShowNothing() {
        XCTAssertEqual(AssetInfo.text(for: Asset(kind: .audio, name: "s", path: "/s", duration: 3725), canvas: canvas), "1:02:05")
        XCTAssertNil(AssetInfo.text(for: Asset(kind: .lyrics, name: "l.txt", path: "/l.txt"), canvas: canvas))
    }

    func testTheBarNeedsAWideEnoughTile() {
        XCTAssertFalse(AssetTileMetrics.showsInfo(104))
        XCTAssertTrue(AssetTileMetrics.showsInfo(150))
    }
}
