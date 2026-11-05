import CoreImage
import XCTest
@testable import Cutline

final class DummyModelTests: XCTestCase {
    private func project(_ canvas: CanvasSize = .init(width: 1920, height: 1080)) -> Project {
        var p = Project(type: .musicVideo, canvas: canvas)
        p.fps = 24
        return p
    }

    func testAutomaticNamesStartAt0001AndCountUp() {
        var p = project()
        XCTAssertEqual(p.nextDummyName, "Dummy 0001")
        p.addDummy(title: "", fontName: "Helvetica Neue", length: 5, color: .white)
        p.addDummy(title: "  ", fontName: "Helvetica Neue", length: 5, color: .white)
        XCTAssertEqual(p.assets.map(\.name), ["Dummy 0001", "Dummy 0002"], "blank titles take the automatic name")
        XCTAssertEqual(p.nextDummyName, "Dummy 0003")
    }

    func testATitleOverridesTheAutomaticName() {
        var p = project()
        let a = p.addDummy(title: " Chorus wide shot ", fontName: "Helvetica Neue", length: 5, color: .white)
        XCTAssertEqual(a.name, "Chorus wide shot")
        XCTAssertEqual(a.dummy?.title, "Chorus wide shot")
        XCTAssertEqual(p.nextDummyName, "Dummy 0001", "named dummies don't use up numbers")
    }

    func testNumbersFollowTheHighestExistingDummy() {
        var p = project()
        for _ in 0..<3 { p.addDummy(title: "", fontName: "Helvetica Neue", length: 5, color: .white) }
        p.assets.removeAll { $0.name == "Dummy 0002" }
        XCTAssertEqual(p.nextDummyName, "Dummy 0004")
        // An ordinary image that happens to be called "Dummy 0009" isn't a dummy.
        p.assets.append(Asset(kind: .image, name: "Dummy 0009", path: "/x.png"))
        XCTAssertEqual(p.nextDummyName, "Dummy 0004")
    }

    func testADummyIsAnImageAssetAtTheProjectSizeWithNoFile() {
        var p = project(.init(width: 1080, height: 1920))
        let a = p.addDummy(title: "", fontName: "Avenir Next", length: 7.5, color: RGBA(r: 1, g: 0, b: 0, a: 1))
        XCTAssertEqual(a.kind, .image)
        XCTAssertTrue(a.isDummy)
        XCTAssertEqual(a.pixelSize, CanvasSize(width: 1080, height: 1920))
        XCTAssertEqual(a.duration, 7.5)
        XCTAssertEqual(a.path, "")
        XCTAssertTrue(p.videoTracks.flatMap(\.clips).isEmpty, "added to the assets, not the timeline")
        XCTAssertEqual(AssetGroup(a), .dummy, "its own section in the assets panel")
        XCTAssertEqual(AssetGroup(Asset(kind: .image, name: "i", path: "/i.png")), .image)
    }

    func testADroppedDummyLastsItsLength() {
        var p = project()
        let a = p.addDummy(title: "", fontName: "Helvetica Neue", length: 12, color: .white)
        let id = p.addClip(assetID: a.id, track: 0, at: 3)!
        let clip = p.videoTracks[0].clips.first { $0.id == id }!
        XCTAssertEqual(clip.duration, 12)
        XCTAssertEqual(clip.transform.scale, 1, "already the frame's size: it fills it")
    }

    func testTheLengthLine() {
        func text(_ l: Double) -> String { DummyCard(title: "", fontName: "", length: l, color: .white).lengthText }
        XCTAssertEqual(text(12), "12 seconds")
        XCTAssertEqual(text(1), "1 second")
        XCTAssertEqual(text(2.5), "2.5 seconds")
    }

    func testDummiesAndTheSheetsChoicesAreSaved() throws {
        var p = project()
        p.addDummy(title: "", fontName: "Futura", length: 4, color: .black)
        p.dummyDefaults = DummyDefaults(fontName: "Futura", title: "Intro", length: 4, color: .black)
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.assets[0].dummy, p.assets[0].dummy)
        XCTAssertEqual(back.dummyDefaults, p.dummyDefaults)
        let old = try JSONDecoder().decode(Asset.self, from: Data(#"{"id":"5A1F2B3C-0000-0000-0000-000000000005","kind":"image","name":"a","path":"/a.png"}"#.utf8))
        XCTAssertFalse(old.isDummy)
    }

    func testImportKeepsDummies() {
        var src = project()
        src.addDummy(title: "Bridge", fontName: "Futura", length: 6, color: .black)
        let imported = ProjectImport.make(from: src, type: .ad, canvas: .init(width: 1080, height: 1920)).project
        XCTAssertEqual(imported.assets[0].dummy?.title, "Bridge")
    }
}

@MainActor
final class DummyEditorTests: XCTestCase {
    func testCreatingADummyRemembersTheChoicesAndSelectsIt() {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        let e = doc.editor
        let choice = DummyDefaults(fontName: "Futura", title: "", length: 8, color: RGBA(r: 0.9, g: 0.6, b: 0.2, a: 1))
        let a = e.createDummy(choice)
        XCTAssertEqual(a?.name, "Dummy 0001")
        XCTAssertEqual(e.project.dummyDefaults, choice, "the next sheet opens with these")
        XCTAssertEqual(e.selectedAssets, [a!.id])
        XCTAssertTrue(doc.isDocumentEdited)
        doc.undoManager?.undo()
        XCTAssertTrue(e.project.assets.isEmpty, "undo removes the dummy")
        XCTAssertEqual(e.project.dummyDefaults, choice, "but keeps the remembered choices")
    }

    func testChoicesAreRememberedPerProject() {
        let a = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        let b = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        a.editor.rememberDummyDefaults(DummyDefaults(fontName: "Futura", title: "Verse", length: 3, color: .black))
        XCTAssertNil(b.editor.project.dummyDefaults)
    }

    func testTheSheetCleansUpOddValues() {
        let n = NewDummyView.normalize(DummyDefaults(fontName: "Futura", title: "x", length: -4, color: RGBA(r: 1, g: 0, b: 0, a: 0.2)))
        XCTAssertEqual(n.length, 0.1)
        XCTAssertEqual(n.color.a, 1, "the background is always solid")
        XCTAssertEqual(NewDummyView.normalize(DummyDefaults(length: 99_999)).length, 3600)
    }
}

final class DummyRendererTests: XCTestCase {
    private let card = DummyCard(title: "Dummy 0001", fontName: "Helvetica Neue", length: 5, color: RGBA(r: 0.2, g: 0.4, b: 0.8, a: 1))

    private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (Double, Double, Double) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    func testTheCardIsTheFramesSizeFilledWithTheColor() throws {
        let img = try XCTUnwrap(DummyRenderer.image(card, size: CGSize(width: 1920, height: 1080)))
        XCTAssertEqual(img.width, 1920); XCTAssertEqual(img.height, 1080)
        let c = pixel(img, 5, 5)
        XCTAssertEqual(c.0, 0.2, accuracy: 0.02); XCTAssertEqual(c.1, 0.4, accuracy: 0.02); XCTAssertEqual(c.2, 0.8, accuracy: 0.02)
    }

    func testTheTitleIsCentredAndTheLengthHangsUnderItsLeftEdge() {
        let size = CGSize(width: 1920, height: 1080)
        let l = DummyRenderer.layout(card, size: size)
        XCTAssertEqual(l.titleOrigin.x + l.titleWidth / 2, size.width / 2, accuracy: 0.5, "centred across")
        XCTAssertEqual(l.titleOrigin.y, size.height / 2, accuracy: l.titleSize * 0.5, "around the middle")
        XCTAssertEqual(l.subtitleOrigin.x, l.titleOrigin.x, "the length line starts where the title starts")
        XCTAssertLessThan(l.subtitleOrigin.y, l.titleOrigin.y, "and sits under it")
        XCTAssertLessThan(l.subtitleSize, l.titleSize)
    }

    func testTheTitleIsNeitherTooBigNorTooSmall() {
        let l = DummyRenderer.layout(card, size: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(l.titleSize, 1080 * DummyRenderer.titleFraction, accuracy: 0.5)
        XCTAssertGreaterThan(l.titleSize, 60); XCTAssertLessThan(l.titleSize, 140)
        // The same card at 4K is laid out the same, twice as large.
        let big = DummyRenderer.layout(card, size: CGSize(width: 3840, height: 2160))
        XCTAssertEqual(big.titleSize / l.titleSize, 2, accuracy: 0.01)
    }

    func testALongTitleShrinksToFitTheFrame() {
        var long = card
        long.title = String(repeating: "Çok uzun bir başlık ", count: 4)
        let size = CGSize(width: 1080, height: 1920)
        let l = DummyRenderer.layout(long, size: size)
        XCTAssertLessThanOrEqual(l.titleWidth, size.width * DummyRenderer.maxWidth + 1)
        XCTAssertGreaterThanOrEqual(l.titleOrigin.x, size.width * (1 - DummyRenderer.maxWidth) / 2 - 1)
    }

    func testTextIsReadableOnAnyColor() {
        XCTAssertEqual(DummyRenderer.textColor(on: RGBA(r: 0.1, g: 0.1, b: 0.2, a: 1)), .white)
        XCTAssertNotEqual(DummyRenderer.textColor(on: RGBA(r: 0.96, g: 0.85, b: 0.35, a: 1)), .white)
    }

    func testAnUnknownFontFallsBackToTheSystemFont() {
        var c = card
        c.fontName = "No Such Font 123"
        XCTAssertNotNil(DummyRenderer.image(c, size: CGSize(width: 640, height: 360)))
    }

    func testTheTitleIsActuallyDrawnInTheMiddle() throws {
        let img = try XCTUnwrap(DummyRenderer.image(card, size: CGSize(width: 1920, height: 1080)))
        let ci = CIImage(cgImage: img)
        let middle = FilterChainTests.meanLuma(ci, CGRect(x: 760, y: 520, width: 400, height: 60))
        let corner = FilterChainTests.meanLuma(ci, CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertGreaterThan(middle, corner + 0.05, "white letters in the middle, plain color in the corner")
    }

    // MARK: In the project

    func testPreviewAndExportDrawTheCard() {
        var p = Project(type: .musicVideo, canvas: .init(width: 640, height: 360))
        p.fps = 24
        let a = p.addDummy(title: "", fontName: "Helvetica Neue", length: 4, color: RGBA(r: 1, g: 1, b: 1, a: 1))
        _ = p.addClip(assetID: a.id, track: 0, at: 0)
        let images = FrameRenderer.loadImages(p)
        XCTAssertNotNil(images[a.id])
        let frame = FrameRenderer.render(RenderSnapshot(project: p, images: images, lyrics: nil), at: 1) { _ in nil }
        XCTAssertGreaterThan(FilterChainTests.meanLuma(frame, CGRect(x: 0, y: 0, width: 80, height: 40)), 0.9, "the card's white background")
    }

    func testThumbnailsAreDrawnSmall() async throws {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        let a = p.addDummy(title: "", fontName: "Helvetica Neue", length: 4, color: .black)
        let thumb = try await ThumbnailGenerator.render(a)
        XCTAssertEqual(thumb?.width, 320)
        XCTAssertEqual(thumb?.height, 180)
    }

    func testEachDummyHasItsOwnRenderKey() {
        var p = Project(type: .musicVideo, canvas: .init(width: 640, height: 360))
        p.fps = 24
        let a = p.addDummy(title: "", fontName: "Helvetica Neue", length: 4, color: .black)
        let id = p.addClip(assetID: a.id, track: 0, at: 0)!
        let key = RenderKey.key(project: p, start: 0, end: 2)
        XCTAssertEqual(RenderKey.key(project: p, start: 0, end: 2), key, "stable")
        var q = p
        let b = q.addDummy(title: "", fontName: "Helvetica Neue", length: 4, color: .white)
        q.videoTracks[0].clips[0].assetID = b.id
        _ = id
        XCTAssertNotEqual(RenderKey.key(project: q, start: 0, end: 2), key, "another card, another key")
    }
}
