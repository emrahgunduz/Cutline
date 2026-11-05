import CoreImage
import XCTest
@testable import Cutline

final class FlipTests: XCTestCase {
    /// A 320×180 picture: white on the left half, black on the right.
    private let halves: CIImage = {
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 180))
        let black = CIImage(color: .black).cropped(to: CGRect(x: 160, y: 0, width: 160, height: 180))
        return white.composited(over: black)
    }()
    private let canvas = CGRect(x: 0, y: 0, width: 320, height: 180)

    private func luma(_ img: CIImage, left: Bool) -> Double {
        FilterChainTests.meanLuma(img.composited(over: CIImage(color: .gray).cropped(to: canvas)),
                                  CGRect(x: left ? 20 : 180, y: 20, width: 120, height: 140))
    }

    func testFlippingMirrorsThePictureInPlace() {
        let normal = FrameRenderer.place(halves, transform: ClipTransform(), canvas: canvas)
        XCTAssertEqual(luma(normal, left: true), 1, accuracy: 0.02)
        XCTAssertEqual(luma(normal, left: false), 0, accuracy: 0.02)
        var t = ClipTransform()
        t.flipH = true
        let flipped = FrameRenderer.place(halves, transform: t, canvas: canvas)
        XCTAssertEqual(luma(flipped, left: true), 0, accuracy: 0.02, "the black half is now on the left")
        XCTAssertEqual(luma(flipped, left: false), 1, accuracy: 0.02)
        XCTAssertEqual(flipped.extent, normal.extent, "same place, same size")
    }

    func testFlipWorksWithScaleAndOffset() {
        var t = ClipTransform(scale: 0.5, offsetX: 40, offsetY: -10)
        let normal = FrameRenderer.place(halves, transform: t, canvas: canvas)
        t.flipH = true
        let flipped = FrameRenderer.place(halves, transform: t, canvas: canvas)
        XCTAssertEqual(flipped.extent, normal.extent)
        let r = normal.extent
        let leftOfClip = CGRect(x: r.minX + 5, y: r.midY - 10, width: r.width / 2 - 10, height: 20)
        XCTAssertEqual(FilterChainTests.meanLuma(flipped, leftOfClip), 0, accuracy: 0.02)
        XCTAssertEqual(FilterChainTests.meanLuma(normal, leftOfClip), 1, accuracy: 0.02)
    }

    func testTheFlipIsSavedAndOlderClipsLoadUnflipped() throws {
        var t = ClipTransform(scale: 2)
        t.flipH = true
        XCTAssertTrue(try JSONDecoder().decode(ClipTransform.self, from: JSONEncoder().encode(t)).isFlippedH)
        XCTAssertFalse(try JSONDecoder().decode(ClipTransform.self, from: Data(#"{"scale":1,"offsetX":0,"offsetY":0}"#.utf8)).isFlippedH)
    }

    func testFlippingChangesTheRenderKeyWhereTheClipIs() {
        var p = Project(type: .musicVideo, canvas: .init(width: 320, height: 180))
        p.fps = 24
        let a = Asset(kind: .image, name: "i", path: "/i.png", pixelSize: .init(width: 320, height: 180))
        p.assets = [a]
        p.videoTracks[0].clips = [Clip(assetID: a.id, start: 0, duration: 2)]
        let here = RenderKey.key(project: p, start: 0, end: 2), later = RenderKey.key(project: p, start: 4, end: 6)
        p.videoTracks[0].clips[0].transform.flipH = true
        XCTAssertNotEqual(RenderKey.key(project: p, start: 0, end: 2), here)
        XCTAssertEqual(RenderKey.key(project: p, start: 4, end: 6), later)
    }

    func testImportKeepsTheFlip() {
        var src = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        let v = Asset(kind: .video, name: "v", path: "/v", pixelSize: .init(width: 1920, height: 1080), duration: 10, frameRate: 24)
        src.assets = [v]
        var c = Clip(assetID: v.id, start: 0, duration: 5)
        c.transform.flipH = true
        src.videoTracks[0].clips = [c]
        let p = ProjectImport.make(from: src, type: .ad, canvas: .init(width: 1080, height: 1920)).project
        XCTAssertTrue(p.videoTracks[0].clips[0].transform.isFlippedH)
    }
}
