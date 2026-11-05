import CoreMedia
import AVFoundation
import CoreImage
import XCTest
@testable import Cutline

final class CompositionBuilderTests: XCTestCase {
    private func makeProject(videoURL: URL) async throws -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 320, height: 180))
        let a = try await AssetLibrary.makeAsset(from: videoURL)
        p.assets = [a]
        p.addClip(assetID: a.id, track: 0, at: 1)   // 1 s of gray from t = 1
        return p
    }

    private func frame(_ b: BuiltComposition, at t: Double) async throws -> CIImage {
        let gen = AVAssetImageGenerator(asset: b.composition)
        gen.videoComposition = b.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        return CIImage(cgImage: try await gen.image(at: CompositionBuilder.time(t)).image)
    }

    func testRendersGapAsBlackAndClipAsVideo() async throws {
        let src = try await TestMedia.video(width: 320, height: 180, fps: 24, frames: 24)
        defer { try? FileManager.default.removeItem(at: src) }
        let p = try await makeProject(videoURL: src)
        let snap = RenderSnapshot(project: p, images: [:], lyrics: nil)
        let b = try await CompositionBuilder.build(project: p, mediaURL: { $0.url }, snapshot: snap)
        XCTAssertEqual(b.duration.seconds, 2, accuracy: 0.01)
        let gap = try await frame(b, at: 0.5), clip = try await frame(b, at: 1.5)
        XCTAssertEqual(FilterChainTests.meanLuma(gap), 0, accuracy: 0.02)
        XCTAssertEqual(FilterChainTests.meanLuma(clip), 0.5, accuracy: 0.08)
    }

    func testNonOverlappingClipsShareOneCompositionTrack() async throws {
        let src = try await TestMedia.video(width: 320, height: 180, fps: 24, frames: 24)
        defer { try? FileManager.default.removeItem(at: src) }
        var p = try await makeProject(videoURL: src)
        p.addClip(assetID: p.assets[0].id, track: 0, at: 3)
        p.addVideoTrack()
        p.addClip(assetID: p.assets[0].id, track: 1, at: 1.5)   // overlaps the first clip
        let b = try await CompositionBuilder.build(project: p, mediaURL: { $0.url }, snapshot: RenderSnapshot(project: p, images: [:], lyrics: nil))
        // base + two clip tracks for three clips
        XCTAssertEqual(b.composition.tracks(withMediaType: .video).count, 3)
        XCTAssertEqual(Set(b.clipTracks.values.map(\.trackID)).count, 2)
    }

    func testFrameStepLandsOnExactFrameTimes() {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        var p = doc.editor.project
        p.fps = 24
        p.assets = [Asset(kind: .image, name: "i", path: "/i")]
        p.addClip(assetID: p.assets[0].id, track: 0, at: 0)
        doc.editor.replaceWithoutUndo(p)
        for _ in 0..<5 { doc.editor.stepFrame(1) }
        XCTAssertEqual(doc.editor.playhead, 5.0 / 24, accuracy: 1e-9)
        doc.editor.stepFrame(-1)
        XCTAssertEqual(doc.editor.playhead * 24, 4, accuracy: 1e-9)
    }
}

final class FrameGridTests: XCTestCase {
    private func project(fps: Double) -> (Project, Asset) {
        var p = Project(type: .musicVideo, canvas: .init(width: 64, height: 36))
        p.fps = fps
        p.fpsLocked = true
        let a = Asset(kind: .image, name: "white", path: "/w")
        p.assets = [a]
        return (p, a)
    }

    func testNTSCClipAppearsOnItsOwnFirstFrameAndLeavesOnTime() throws {
        for (fps, value, scale) in [(30000.0 / 1001, Int64(1001), Int32(30000)), (24000.0 / 1001, 1001, 24000), (60000.0 / 1001, 1001, 60000), (25.0, 1, 25)] {
            var (p, a) = project(fps: fps)
            let id = try XCTUnwrap(p.addClip(assetID: a.id, track: 0, at: 10 / fps))     // starts at frame 10
            p.trimEnd(id, to: 20 / fps)                                                    // ends before frame 20
            let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 36))
            let snap = RenderSnapshot(project: p, images: [a.id: white], lyrics: nil)
            // Compositor frame times are exact rationals, as AVFoundation hands them over.
            func luma(_ m: Int64) -> Double {
                FilterChainTests.meanLuma(FrameRenderer.render(snap, at: CMTime(value: m * value, timescale: scale).seconds) { _ in nil })
            }
            XCTAssertEqual(luma(9), 0, accuracy: 0.01, "\(fps)")
            XCTAssertEqual(luma(10), 1, accuracy: 0.01, "\(fps)")
            XCTAssertEqual(luma(19), 1, accuracy: 0.01, "\(fps)")
            XCTAssertEqual(luma(20), 0, accuracy: 0.01, "\(fps)")
            XCTAssertEqual(p.frameTime, CMTime(value: value, timescale: scale))
        }
    }

    func testCompositionTimesLandExactlyOnNTSCFrames() {
        let fps = 30000.0 / 1001
        for m in [1, 7, 1799, 107_892] {   // up to an hour
            let t = CompositionBuilder.time(Double(m) / fps)
            XCTAssertEqual(t, CMTime(value: Int64(m) * 4004, timescale: 120_000))
        }
    }

    func testOldDecimalRateMigratesAndResnaps() {
        var (p, a) = project(fps: 29.97)
        p.addClip(assetID: a.id, track: 0, at: 10 / 29.97)
        XCTAssertTrue(p.migrateFrameRate())
        XCTAssertEqual(p.fps, 30000.0 / 1001)
        XCTAssertEqual(p.frameIndex(p.videoTracks[0].clips[0].start), 10)
        var q = project(fps: 24).0
        XCTAssertFalse(q.migrateFrameRate())
    }
}
