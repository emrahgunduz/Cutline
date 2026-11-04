import AVFoundation
import XCTest
@testable import Cutline

@MainActor
final class ExporterIntegrationTests: XCTestCase {
    private func editor(type: ProjectType, canvas: CanvasSize, seconds: Int = 2) async throws -> (EditorModel, URL) {
        let doc = ProjectDocument(project: Project(type: type, canvas: canvas))
        let src = try await TestMedia.video(width: 640, height: 360, fps: 24, frames: 24 * seconds)
        let wav = try TestMedia.sineWAV(seconds: Double(seconds))
        _ = await doc.editor.importFiles([src, wav])
        let v = doc.editor.project.assets.first { $0.kind == .video }!.id
        let a = doc.editor.project.assets.first { $0.kind == .audio }!.id
        doc.editor.edit("setup") { $0.addClip(assetID: v, track: 0, at: 0); $0.setAudio(assetID: a) }
        return (doc.editor, src)
    }

    private func videoInfo(_ url: URL) async throws -> (codec: FourCharCode, size: CGSize, duration: Double, bits: Int?) {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let desc = try await track.load(.formatDescriptions).first!
        let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any]
        let bits = ext?[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int
        return (CMFormatDescriptionGetMediaSubType(desc), try await track.load(.naturalSize), try await asset.load(.duration).seconds, bits)
    }

    func testMusicVideoExportsHEVC10BitWithProjectDuration() async throws {
        let (editor, src) = try await editor(type: .musicVideo, canvas: .init(width: 1280, height: 720))
        defer { try? FileManager.default.removeItem(at: src) }
        let out = TestMedia.tempURL("mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        try await Exporter().export(project: editor.project, settings: .defaults(for: editor.project), to: out) { _ in }
        let info = try await videoInfo(out)
        XCTAssertEqual(info.codec, kCMVideoCodecType_HEVC)
        XCTAssertEqual(info.size, CGSize(width: 1280, height: 720))
        XCTAssertEqual(info.duration, editor.project.duration, accuracy: 0.1)
        XCTAssertEqual(info.bits, 10)
        let audio = try await AVURLAsset(url: out).loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
    }

    func testSocialExportsPortraitH264() async throws {
        let (editor, src) = try await editor(type: .social, canvas: .init(width: 1080, height: 1920), seconds: 1)
        defer { try? FileManager.default.removeItem(at: src) }
        let out = TestMedia.tempURL("mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        try await Exporter().export(project: editor.project, settings: .defaults(for: editor.project), to: out) { _ in }
        let info = try await videoInfo(out)
        XCTAssertEqual(info.codec, kCMVideoCodecType_H264)
        XCTAssertEqual(info.size, CGSize(width: 1080, height: 1920))
    }

    func testExportReadsOriginalNotProxy() async throws {
        let (editor, src) = try await editor(type: .social, canvas: .init(width: 1080, height: 1920), seconds: 1)
        defer { try? FileManager.default.removeItem(at: src) }
        let id = editor.project.assets.first { $0.kind == .video }!.id
        try await editor.createProxy(assetID: id, scale: .quarter)
        // Corrupt the proxy: an export that touched it would fail.
        try Data("not a movie".utf8).write(to: editor.proxyURL(for: editor.project.asset(id)!)!)
        let out = TestMedia.tempURL("mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        try await Exporter().export(project: editor.project, settings: .defaults(for: editor.project), to: out) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }

    func testCancelLeavesNoFile() async throws {
        let (editor, src) = try await editor(type: .musicVideo, canvas: .init(width: 1920, height: 1080), seconds: 6)
        defer { try? FileManager.default.removeItem(at: src) }
        let out = TestMedia.tempURL("mp4")
        let ex = Exporter()
        var cancelled = false
        do {
            try await ex.export(project: editor.project, settings: .defaults(for: editor.project), to: out) { p in
                if p > 0.1 && !cancelled { cancelled = true; ex.cancel() }
            }
            XCTFail("expected cancellation")
        } catch ExportError.cancelled {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }
}
