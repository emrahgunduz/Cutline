import XCTest
@testable import Cutline

@MainActor
final class SampleMediaImportTests: XCTestCase {
    func testImportsFootageAndBuildsSongWaveform() async throws {
        let footage = try SampleMedia.require(SampleMedia.footage)
        let song = try SampleMedia.require(SampleMedia.song)
        let clips = try FileManager.default.contentsOfDirectory(at: footage, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mp4" }
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        let errors = await doc.editor.importFiles(clips + [song])
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        let videos = doc.editor.project.assets.filter { $0.kind == .video }
        XCTAssertEqual(videos.count, clips.count)
        XCTAssertTrue(videos.allSatisfy { abs(($0.frameRate ?? 0) - 24) < 0.5 && $0.pixelSize != nil })

        let first = try XCTUnwrap(videos.first)
        let thumb = try await ThumbnailGenerator.render(first)
        XCTAssertNotNil(thumb)

        let start = Date()
        let wf = try await WaveformBuilder.build(url: song)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertEqual(Double(wf.levels[0].maxs.count) * 256 / wf.sampleRate, 225, accuracy: 0.1)
    }
}
