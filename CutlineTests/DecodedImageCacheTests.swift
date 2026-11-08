import CoreImage
import XCTest
@testable import Cutline

/// Image files are decoded once and reused while unchanged; the preview rebuilds after every
/// drag step, and decoding every PNG each time made dragging slow.
final class DecodedImageCacheTests: XCTestCase {
    private func project(using png: URL) -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        let img = Asset(kind: .image, name: "i.png", path: png.path)
        p.assets = [img]
        p.addClip(assetID: img.id, track: 0, at: 0)
        return p
    }

    func testRebuildingSnapshotsDecodesEachImageOnce() throws {
        let cache = DecodedImageCache()
        let png = try TestMedia.halfTransparentPNG()
        var p = project(using: png)
        let first = FrameRenderer.loadImages(p, cache: cache)
        for i in 1...20 {
            // What a drag does: the project changes, the snapshot is rebuilt.
            p.videoTracks[0].clips[0].start = Double(i) / 10
            XCTAssertEqual(FrameRenderer.loadImages(p, cache: cache).count, 1)
        }
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(cache.decodeCount, 1)
    }

    func testAnImageChangedOnDiskIsDecodedAgain() throws {
        let cache = DecodedImageCache()
        let png = try TestMedia.halfTransparentPNG(size: 64)
        let a = try XCTUnwrap(cache.image(at: png))
        XCTAssertEqual(a.extent.width, 64)
        // Replace the file with a bigger image (new size and modification date).
        let other = try TestMedia.halfTransparentPNG(size: 96)
        try FileManager.default.removeItem(at: png)
        try FileManager.default.copyItem(at: other, to: png)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: png.path)
        let b = try XCTUnwrap(cache.image(at: png))
        XCTAssertEqual(b.extent.width, 96)
        XCTAssertEqual(cache.decodeCount, 2)
    }

    /// The app's cache trusts a file's size and date for a moment (the preview asks for every
    /// image after each edit); a change on disk shows once that has passed.
    func testFileChecksAreTrustedForTheRecheckInterval() throws {
        let cache = DecodedImageCache(recheckInterval: 0.3)
        let png = try TestMedia.halfTransparentPNG(size: 64)
        XCTAssertEqual(try XCTUnwrap(cache.image(at: png)).extent.width, 64)
        let other = try TestMedia.halfTransparentPNG(size: 96)
        try FileManager.default.removeItem(at: png)
        try FileManager.default.copyItem(at: other, to: png)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: png.path)
        XCTAssertEqual(try XCTUnwrap(cache.image(at: png)).extent.width, 64, "within the interval: no file system check")
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertEqual(try XCTUnwrap(cache.image(at: png)).extent.width, 96, "after it: checked again and decoded")
        XCTAssertEqual(cache.decodeCount, 2)
    }

    func testAMissingFileGivesNoImage() {
        XCTAssertNil(DecodedImageCache().image(at: URL(fileURLWithPath: "/nonexistent-\(UUID()).png")))
    }
}
