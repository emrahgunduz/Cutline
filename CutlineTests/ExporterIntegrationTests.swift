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

@MainActor
final class ExportOptionsTests: XCTestCase {
    func testContainerChoiceControlsFileType() async throws {
        let doc = ProjectDocument(project: Project(type: .social, canvas: .init(width: 1080, height: 1920)))
        let src = try await TestMedia.video(width: 320, height: 180, fps: 24, frames: 24)
        defer { try? FileManager.default.removeItem(at: src) }
        _ = await doc.editor.importFiles([src])
        let v = doc.editor.project.assets[0].id
        doc.editor.edit("s") { $0.addClip(assetID: v, track: 0, at: 0) }
        var s = ExportSettings.defaults(for: doc.editor.project)
        s.container = .mov
        let out = TestMedia.tempURL("mov")
        defer { try? FileManager.default.removeItem(at: out) }
        try await Exporter().export(project: doc.editor.project, settings: s, to: out) { _ in }
        let header = try FileHandle(forReadingFrom: out).readData(ofLength: 12)
        XCTAssertEqual(String(data: header.subdata(in: 8..<12), encoding: .ascii), "qt  ")
    }

    func testQualityEstimateComesFromProbe() async throws {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 640, height: 360)))
        let src = try await TestMedia.video(width: 320, height: 180, fps: 24, frames: 96)
        defer { try? FileManager.default.removeItem(at: src) }
        _ = await doc.editor.importFiles([src])
        let v = doc.editor.project.assets[0].id
        doc.editor.edit("s") { $0.addClip(assetID: v, track: 0, at: 0) }
        let est = try await SizeEstimator.estimateBytes(project: doc.editor.project, settings: .defaults(for: doc.editor.project))
        XCTAssertGreaterThan(est, 0)
    }

    func testDefaultNameDropsPackageExtension() {
        let doc = ProjectDocument(project: Project(type: .ad, canvas: .init(width: 1080, height: 1920)))
        XCTAssertFalse(ExportSheet.defaultName(doc.editor).lowercased().hasSuffix(".cutline"))
    }
}

final class SizeEstimatorSamplingTests: XCTestCase {
    func testSamplesComeFromClipsNotGaps() {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        let a = Asset(kind: .image, name: "i", path: "/i")
        p.assets = [a]
        p.audio = AudioClip(assetID: UUID(), duration: 200)
        p.addClip(assetID: a.id, track: 0, at: 0)      // 0-5
        p.addClip(assetID: a.id, track: 0, at: 10)     // 10-15
        p.addVideoTrack()
        p.addClip(assetID: a.id, track: 1, at: 11)     // 11-16 overlaps: the busiest part
        let starts = SizeEstimator.sampleStarts(p)
        XCTAssertFalse(starts.isEmpty)
        XCTAssertTrue(starts.contains { $0 + 1 >= 10 && $0 + 1 <= 16 }, "\(starts)")
        for s in starts { XCTAssertGreaterThan(SizeEstimator.busyness(p, at: s + 1), 0, "\(s)") }
    }
}
