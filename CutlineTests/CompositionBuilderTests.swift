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
