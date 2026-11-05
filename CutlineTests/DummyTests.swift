import CoreImage
import CoreText
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
    func testTheDescriptionGoesOnTheCardButIsNotRemembered() {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        let e = doc.editor
        let a = e.createDummy(DummyDefaults(), description: "  Close-up on the hands.\n")
        XCTAssertEqual(a?.dummy?.sceneDescription, "Close-up on the hands.", "trimmed")
        XCTAssertEqual(e.project.dummyDefaults, DummyDefaults(), "each scene has its own description")
    }

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

    private var described: DummyCard {
        var c = card
        c.sceneDescription = "Wide shot of the empty street at dawn. The singer walks in from the left, stops under the lamp and looks up."
        return c
    }

    func testTheTitleSitsTopLeftInsideThePadding() {
        let size = CGSize(width: 1920, height: 1080)
        let l = DummyRenderer.layout(card, size: size)
        XCTAssertEqual(l.padding, 100)
        XCTAssertEqual(l.titleOrigin.x, 100, "left aligned at the left padding")
        let titleTop = l.titleOrigin.y + CTFontGetAscent(DummyRenderer.font(card.fontName, size: l.titleSize, bold: true))
        XCTAssertEqual(titleTop, 1080 - 100, accuracy: 0.5, "its top on the top padding")
    }

    func testTheTimeSitsBottomRightInsideThePadding() {
        let size = CGSize(width: 1920, height: 1080)
        let l = DummyRenderer.layout(card, size: size)
        XCTAssertEqual(l.timeOrigin.x + l.timeWidth, 1920 - 100, accuracy: 0.5, "right aligned at the right padding")
        let bottom = l.timeOrigin.y - CTFontGetDescent(DummyRenderer.font(card.fontName, size: l.timeSize, bold: true))
        XCTAssertEqual(bottom, 100, accuracy: 0.5, "its bottom on the bottom padding")
    }

    func testTheDescriptionFillsTheWidthUnderTheTitle() {
        let size = CGSize(width: 1920, height: 1080)
        let l = DummyRenderer.layout(described, size: size)
        XCTAssertEqual(l.descriptionRect.minX, 100)
        XCTAssertEqual(l.descriptionRect.width, 1920 - 200, "the frame's width minus both paddings")
        XCTAssertLessThan(l.descriptionRect.maxY, l.titleOrigin.y, "under the title")
        XCTAssertGreaterThan(l.descriptionRect.minY, l.timeOrigin.y, "above the time")
        XCTAssertGreaterThanOrEqual(DummyRenderer.descriptionLineCount(described, size: size), 2, "long text wraps onto more lines")
        XCTAssertEqual(DummyRenderer.layout(card, size: size).descriptionRect, .zero, "no description, no box")
    }

    func testTheDescriptionKeepsItsOwnLineBreaks() {
        var c = card
        c.sceneDescription = "One\nTwo\nThree"
        XCTAssertEqual(DummyRenderer.descriptionLineCount(c, size: CGSize(width: 1920, height: 1080)), 3)
    }

    func testSizesAreBigAndReadableInHD() {
        let l = DummyRenderer.layout(described, size: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(l.titleSize, 110, "bigger than before (92)")
        XCTAssertEqual(l.descriptionSize, 44, "readable in HD")
        XCTAssertEqual(l.timeSize, 56, "bigger than before (39)")
        XCTAssertGreaterThan(l.titleSize, l.timeSize)
        XCTAssertGreaterThan(l.timeSize, l.descriptionSize)
    }

    func testEverythingScalesWithTheFrame() {
        let hd = DummyRenderer.layout(described, size: CGSize(width: 1920, height: 1080))
        let uhd = DummyRenderer.layout(described, size: CGSize(width: 3840, height: 2160))
        XCTAssertEqual(uhd.padding, 200)
        XCTAssertEqual(uhd.titleSize / hd.titleSize, 2, accuracy: 0.01)
        XCTAssertEqual(uhd.descriptionSize, 88)
        // Portrait 1080×1920: the short side is 1080, so the HD sizes and paddings apply.
        let portrait = DummyRenderer.layout(described, size: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(portrait.padding, 100)
        XCTAssertEqual(portrait.descriptionRect.width, 880)
    }

    func testALongTitleShrinksToFitBetweenThePaddings() {
        var long = card
        long.title = String(repeating: "Çok uzun bir başlık ", count: 4)
        let size = CGSize(width: 1080, height: 1920)
        let l = DummyRenderer.layout(long, size: size)
        XCTAssertLessThanOrEqual(l.titleOrigin.x + l.titleWidth, size.width - l.padding + 1)
        XCTAssertLessThan(l.titleSize, 110)
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

    func testTheTextIsActuallyDrawnWhereTheLayoutSays() throws {
        let img = try XCTUnwrap(DummyRenderer.image(described, size: CGSize(width: 1920, height: 1080)))
        let ci = CIImage(cgImage: img)
        func luma(_ r: CGRect) -> Double { FilterChainTests.meanLuma(ci, r) }
        let empty = luma(CGRect(x: 1700, y: 900, width: 150, height: 80))           // top right: nothing there
        XCTAssertGreaterThan(luma(CGRect(x: 100, y: 870, width: 500, height: 100)), empty + 0.05, "title at the top left")
        XCTAssertGreaterThan(luma(CGRect(x: 100, y: 650, width: 1700, height: 120)), empty + 0.03, "description under it")
        XCTAssertGreaterThan(luma(CGRect(x: 1560, y: 100, width: 260, height: 60)), empty + 0.05, "time at the bottom right")
    }

    func testOlderDummiesLoadWithoutADescription() throws {
        let json = #"{"title":"Dummy 0001","fontName":"Futura","length":5,"color":{"r":0,"g":0,"b":0,"a":1}}"#
        let c = try JSONDecoder().decode(DummyCard.self, from: Data(json.utf8))
        XCTAssertEqual(c.sceneDescription, "")
        let back = try JSONDecoder().decode(DummyCard.self, from: JSONEncoder().encode(described))
        XCTAssertEqual(back, described)
    }

    // MARK: Cinemascope

    func testTheBarsAreLeftOutOnlyWhenTheProjectDrawsThem() {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        XCTAssertEqual(DummyRenderer.barFraction(for: p), 0, "cinemascope off")
        p.cinemascope.enabled = true
        XCTAssertEqual(DummyRenderer.barFraction(for: p) * 1080, CGFloat(Letterbox.fullBarHeight(p.canvas)), accuracy: 0.01)
        var social = Project(type: .social, canvas: .init(width: 1080, height: 1920))
        social.cinemascope.enabled = true
        XCTAssertEqual(DummyRenderer.barFraction(for: social), 0, "no bars outside music videos")
    }

    func testWithBarsTheTextStaysInsideThePicture() {
        let size = CGSize(width: 1920, height: 1080)
        let bar = CGFloat(Letterbox.fullBarHeight(CanvasSize(width: 1920, height: 1080)))     // ≈ 131 px
        let l = DummyRenderer.layout(described, size: size, barFraction: bar / 1080)
        let titleTop = l.titleOrigin.y + CTFontGetAscent(DummyRenderer.font(card.fontName, size: l.titleSize, bold: true))
        XCTAssertEqual(titleTop, 1080 - bar - 100, accuracy: 0.5, "100 px under the top bar")
        let timeBottom = l.timeOrigin.y - CTFontGetDescent(DummyRenderer.font(card.fontName, size: l.timeSize, bold: true))
        XCTAssertEqual(timeBottom, bar + 100, accuracy: 0.5, "100 px above the bottom bar")
        XCTAssertGreaterThan(l.descriptionRect.minY, bar + 100)
        XCTAssertLessThan(l.descriptionRect.maxY, 1080 - bar - 100)
        XCTAssertEqual(l.titleOrigin.x, 100, "left and right paddings don't change")
    }

    func testNothingIsDrawnUnderTheBars() throws {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.cinemascope = Cinemascope(enabled: true, startMarker: 0, endMarker: 0.5)
        let img = try XCTUnwrap(DummyRenderer.image(described, size: CGSize(width: 1920, height: 1080), barFraction: DummyRenderer.barFraction(for: p)))
        let ci = CIImage(cgImage: img)
        let bar = CGFloat(Letterbox.fullBarHeight(p.canvas))
        let plain = FilterChainTests.meanLuma(ci, CGRect(x: 1700, y: 540, width: 150, height: 60))
        // The top and bottom bands the bars will cover hold only the background.
        XCTAssertEqual(FilterChainTests.meanLuma(ci, CGRect(x: 0, y: 1080 - bar, width: 1920, height: bar)), plain, accuracy: 0.005)
        XCTAssertEqual(FilterChainTests.meanLuma(ci, CGRect(x: 0, y: 0, width: 1920, height: bar)), plain, accuracy: 0.005)
        // And the title is there, just under the top bar.
        XCTAssertGreaterThan(FilterChainTests.meanLuma(ci, CGRect(x: 100, y: 1080 - bar - 200, width: 500, height: 100)), plain + 0.05)
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
