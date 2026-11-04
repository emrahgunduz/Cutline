import AVFoundation
import XCTest
@testable import Cutline

/// Renders three overlapping 1440p sample clips into a 1080p canvas through the same
/// compositor the preview uses, and checks the throughput keeps up with real time.
final class PreviewPerformanceTests: XCTestCase {
    func testThreeTrackHDRenderKeepsUpWithRealTime() async throws {
        let footage = try SampleMedia.require(SampleMedia.footage)
        let files = try FileManager.default.contentsOfDirectory(at: footage, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mp4" }.sorted { $0.path < $1.path }.prefix(3)
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.addVideoTrack(); p.addVideoTrack()
        for (i, url) in files.enumerated() {
            let a = try await AssetLibrary.makeAsset(from: url)
            p.assets.append(a)
            let id = p.addClip(assetID: a.id, track: i, at: 0)!
            p.updateClip(id) { c in
                c.duration = min(c.duration, 4)
                c.transform.scale = 1 - Double(i) * 0.25
                c.filters.color.enabled = true
                c.filters.color.saturation = 1.3
            }
        }
        let b = try await CompositionBuilder.build(project: p, mediaURL: { $0.url }, snapshot: RenderSnapshot(project: p, images: [:], lyrics: nil))
        let reader = try AVAssetReader(asset: b.composition)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: b.composition.tracks(withMediaType: .video), videoSettings: nil)
        out.videoComposition = b.videoComposition
        reader.add(out)
        reader.startReading()
        let start = Date()
        var frames = 0
        while out.copyNextSampleBuffer() != nil { frames += 1 }
        let fps = Double(frames) / Date().timeIntervalSince(start)
        print("Three-track HD render: \(frames) frames at \(String(format: "%.1f", fps)) fps")
        XCTAssertGreaterThanOrEqual(frames, 90)
        XCTAssertGreaterThan(fps, 24)
    }
}
