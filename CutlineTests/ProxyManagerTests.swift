import AVFoundation
import XCTest
@testable import Cutline

@MainActor
final class ProxyManagerTests: XCTestCase {
    private func editorWithVideo() async throws -> (EditorModel, UUID, URL) {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        let src = try await TestMedia.video(width: 640, height: 360)
        _ = await doc.editor.importFiles([src])
        let id = try XCTUnwrap(doc.editor.project.assets.first?.id)
        return (doc.editor, id, src)
    }

    private func videoSize(_ url: URL) async throws -> CGSize {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first!
        return try await track.load(.naturalSize)
    }

    func testReplacingProxyLeavesOneFileAtNewSize() async throws {
        let (editor, id, src) = try await editorWithVideo()
        defer { try? FileManager.default.removeItem(at: src) }
        try await editor.createProxy(assetID: id, scale: .quarter)
        try await editor.createProxy(assetID: id, scale: .half)
        let asset = try XCTUnwrap(editor.project.asset(id))
        XCTAssertEqual(asset.proxy?.scale, .half)
        let files = try FileManager.default.contentsOfDirectory(atPath: editor.folder("proxies")!.path)
        XCTAssertEqual(files, [ProxyManager.fileName(for: id)])
        let size = try await videoSize(editor.proxyURL(for: asset)!)
        XCTAssertEqual(size, CGSize(width: 320, height: 180))
    }

    func testDeletingProxyRemovesFileAndBadge() async throws {
        let (editor, id, src) = try await editorWithVideo()
        defer { try? FileManager.default.removeItem(at: src) }
        try await editor.createProxy(assetID: id, scale: .eighth)
        let url = try XCTUnwrap(editor.proxyURL(for: editor.project.asset(id)!))
        editor.deleteProxy(assetID: id)
        XCTAssertNil(editor.project.asset(id)?.proxy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMediaURLUsesProxyOnlyForPreview() async throws {
        let (editor, id, src) = try await editorWithVideo()
        defer { try? FileManager.default.removeItem(at: src) }
        try await editor.createProxy(assetID: id, scale: .quarter)
        let asset = editor.project.asset(id)!
        XCTAssertEqual(editor.mediaURL(for: asset, useProxies: true), editor.proxyURL(for: asset))
        XCTAssertEqual(editor.mediaURL(for: asset, useProxies: false).standardizedFileURL, src.standardizedFileURL)
    }

    func testPNGThumbnailKeepsAlpha() async throws {
        let url = try TestMedia.halfTransparentPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = try await AssetLibrary.makeAsset(from: url)
        XCTAssertEqual(asset.kind, .image)
        let img = try await XCTUnwrapAsync(await ThumbnailGenerator.render(asset))
        XCTAssertTrue([.premultipliedLast, .premultipliedFirst, .last, .first].contains(img.alphaInfo))
        let data = img.dataProvider!.data! as Data
        let bpr = img.bytesPerRow
        let alphaIndex = img.alphaInfo == .premultipliedFirst || img.alphaInfo == .first ? 0 : 3
        XCTAssertEqual(data[bpr * (img.height / 2) + alphaIndex], 0, "left half should be transparent")
    }

    func testSecondLyricsFileReplacesFirst() async throws {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        let a = TestMedia.tempURL("txt"), b = TestMedia.tempURL("txt")
        try "one".write(to: a, atomically: true, encoding: .utf8)
        try "two".write(to: b, atomically: true, encoding: .utf8)
        _ = await doc.editor.importFiles([a])
        _ = await doc.editor.importFiles([b])
        let lyrics = doc.editor.project.assets.filter { $0.kind == .lyrics }
        XCTAssertEqual(lyrics.map(\.path), [b.path])
    }
}

func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
