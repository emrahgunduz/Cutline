import XCTest
@testable import Cutline

// MARK: - Model

final class LineLayoutModelTests: XCTestCase {
    func testDefaultsAreSingleLineLeftAligned() {
        let l = LineLayout()
        XCTAssertEqual(l.mode, .singleLine)
        XCTAssertEqual(l.align, .left)
        XCTAssertNil(l.wrapWidth, "a single line never wraps")
        let line = LyricLine(start: 0, end: 1, words: [LyricWord(text: "a", start: 0, end: 1)])
        XCTAssertEqual(line.layout, LineLayout())
        XCTAssertNil(line.layoutValue)
    }

    func testOnlyNonDefaultLayoutsAreStored() {
        var line = LyricLine(start: 0, end: 1, words: [])
        line.layout = LineLayout(mode: .wrapped, width: 500)
        XCTAssertEqual(line.layoutValue?.width, 500)
        XCTAssertEqual(line.layout.wrapWidth, 500)
        line.layout = LineLayout()
        XCTAssertNil(line.layoutValue, "back to the defaults stores nothing")
    }

    func testWidthIsNeverNegative() {
        XCTAssertEqual(LineLayout(mode: .wrapped, width: -40).width, 0)
    }

    func testLayoutRoundTripsThroughJSONUnderTheLayoutKey() throws {
        var line = LyricLine(start: 1, end: 2, words: [LyricWord(text: "x", start: 1, end: 2)])
        line.layout = LineLayout(mode: .wrapped, width: 640, align: .right)
        let data = try JSONEncoder().encode(line)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["layout"])
        XCTAssertEqual(try JSONDecoder().decode(LyricLine.self, from: data), line)
    }

    func testALineSavedWithoutALayoutLoadsWithTheDefaults() throws {
        let json = #"{"id":"5A1F2B3C-0000-0000-0000-000000000001","start":1,"end":2,"words":[],"stanza":0}"#
        let line = try JSONDecoder().decode(LyricLine.self, from: Data(json.utf8))
        XCTAssertEqual(line.layout, LineLayout())
    }

    func testAnchorAndBoxEdgeConvertBothWays() {
        for align in LineLayout.Align.allCases {
            let a = LineLayout.anchor(boxMidX: 500, width: 300, align: align)
            XCTAssertEqual(LineLayout.boxMinX(anchor: a, width: 300, align: align) + 150, 500, "\(align)")
        }
        XCTAssertEqual(LineLayout.anchor(boxMidX: 500, width: 300, align: .left), 350)
        XCTAssertEqual(LineLayout.anchor(boxMidX: 500, width: 300, align: .center), 500)
        XCTAssertEqual(LineLayout.anchor(boxMidX: 500, width: 300, align: .right), 650)
    }
}

// MARK: - Migration

final class LineLayoutMigrationTests: XCTestCase {
    private func legacy() -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.schemaVersion = 1
        var placed = LyricLine(start: 0, end: 2, words: [LyricWord(text: "placed", start: 0, end: 2)])
        placed.centerX = 900; placed.centerY = 300
        p.lyricTracks[0].lines = [placed, LyricLine(start: 3, end: 4, words: [LyricWord(text: "auto", start: 3, end: 4)])]
        return p
    }

    func testOldPositionedLinesBecomeCentredSoTheyStayPut() {
        var p = legacy()
        p.migrateLineLayouts()
        XCTAssertEqual(p.lyricTracks[0].lines[0].layout.align, .center, "x was the box middle before")
        XCTAssertEqual(p.lyricTracks[0].lines[0].centerX, 900)
        XCTAssertNil(p.lyricTracks[0].lines[1].layoutValue, "automatic lines take the new defaults")
        XCTAssertEqual(p.schemaVersion, projectSchemaVersion)
    }

    func testCurrentProjectsAreNotMigratedAgain() {
        var p = legacy()
        p.schemaVersion = projectSchemaVersion
        p.migrateLineLayouts()
        XCTAssertNil(p.lyricTracks[0].lines[0].layoutValue, "a new left-aligned line keeps its alignment")
    }

    func testLoadingAnOldPackageMigratesIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID()).cutline")
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try ProjectDocument.save(project: legacy(), layout: LayoutState(), to: url)
        let (p, _) = try ProjectDocument.load(from: url)
        XCTAssertEqual(p.lyricTracks[0].lines[0].layout.align, .center)
        XCTAssertEqual(p.schemaVersion, projectSchemaVersion)
        // The same box: before, x was its middle; now the centred anchor is its middle.
        let rect = try XCTUnwrap(LyricRenderer(project: p).placedLines(at: 1).first { $0.line.centerX != nil }?.rect)
        XCTAssertEqual(rect.midX, 900, accuracy: 0.5)
    }
}

// MARK: - Wrapping

final class LineWrapTests: XCTestCase {
    /// Every character is 10 px, spaces included.
    private func measure(_ words: [String]) -> CGFloat { CGFloat(words.joined(separator: " ").count) * 10 }

    func testNoWidthMeansOneRow() {
        XCTAssertEqual(LineRasterizer.wrap(["a", "bb", "ccc"], width: nil, measure: measure), [["a", "bb", "ccc"]])
    }

    func testRowsFillUpToTheWidth() {
        // "aaa bbb" = 70 px fits 75; adding " ccc" would be 110.
        XCTAssertEqual(LineRasterizer.wrap(["aaa", "bbb", "ccc", "d"], width: 75, measure: measure), [["aaa", "bbb"], ["ccc", "d"]])
    }

    func testAWordWiderThanTheWidthGetsItsOwnRow() {
        XCTAssertEqual(LineRasterizer.wrap(["a", "longword", "b"], width: 30, measure: measure), [["a"], ["longword"], ["b"]])
    }

    func testZeroWidthPutsEveryWordOnItsOwnRow() {
        XCTAssertEqual(LineRasterizer.wrap(["a", "b", "c"], width: 0, measure: measure), [["a"], ["b"], ["c"]])
    }

    func testASingleWordIsOneRow() {
        XCTAssertEqual(LineRasterizer.wrap(["word"], width: 5, measure: measure), [["word"]])
    }
}

// MARK: - Rasterizing

final class LineRasterLayoutTests: XCTestCase {
    let words = "Depremlerin yeri göğü inletse de".split(separator: " ").map(String.init)
    let style = LyricStyle()
    let font: CGFloat = 60
    var pad: CGFloat { ceil(font * 0.15) }

    private func raster(_ wrap: CGFloat? = nil, _ align: LineLayout.Align = .left) throws -> LineRaster {
        try XCTUnwrap(LineRasterizer.rasterize(words: words, style: style, fontSize: font, wrapWidth: wrap, align: align))
    }

    func testASingleLineIsOneRowAsWideAsItsText() throws {
        let r = try raster()
        XCTAssertEqual(r.rows, 1)
        XCTAssertEqual(r.wordRects.count, words.count)
        XCTAssertGreaterThan(r.size.width, 700, "the whole line on one row")
        XCTAssertTrue(r.wordRects.allSatisfy { $0.minY == r.wordRects[0].minY }, "every word on the same row")
    }

    func testASingleLineIsNeverLimitedByTheFrame() throws {
        let long = Array(repeating: "kaldırımlara", count: 20)
        let r = try XCTUnwrap(LineRasterizer.rasterize(words: long, style: style, fontSize: font))
        XCTAssertEqual(r.rows, 1)
        XCTAssertGreaterThan(r.size.width, 3840, "wider than any canvas")
    }

    func testWrappedLinesAreAsWideAsTheWidthAndAsTallAsTheirRows() throws {
        let single = try raster()
        let wrapped = try raster(400)
        XCTAssertGreaterThan(wrapped.rows, 1)
        XCTAssertEqual(wrapped.size.width, 400 + pad * 2, accuracy: 1, "the box is the wrap width")
        XCTAssertGreaterThan(wrapped.size.height, single.size.height * CGFloat(wrapped.rows) * 0.8)
        let rowStep = (wrapped.size.height - pad) / CGFloat(wrapped.rows)
        XCTAssertEqual(wrapped.size.height, ceil(rowStep * CGFloat(wrapped.rows) + pad), accuracy: 1)
    }

    func testMoreWidthMeansFewerRows() throws {
        XCTAssertGreaterThan(try raster(250).rows, try raster(600).rows)
        XCTAssertEqual(try raster(5000).rows, 1)
    }

    func testAWidthSmallerThanALongWordWidensTheBoxToThatWord() throws {
        let r = try raster(10)
        XCTAssertEqual(r.rows, words.count, "one word per row")
        let widest = r.wordRects.map(\.width).max()!
        XCTAssertGreaterThanOrEqual(r.size.width, widest)
    }

    /// The words on the raster's bottom row (y grows upwards, so it has the lowest minY).
    private func lastRow(_ r: LineRaster) -> [CGRect] {
        let y = r.wordRects.map(\.minY).min()!
        return r.wordRects.filter { $0.minY == y }
    }

    func testRowsAlignInsideTheBox() throws {
        let left = try raster(500, .left), center = try raster(500, .center), right = try raster(500, .right)
        XCTAssertGreaterThan(left.rows, 1)
        let l = lastRow(left), c = lastRow(center), r = lastRow(right)
        XCTAssertEqual(l.first!.minX, pad / 2, accuracy: 1, "left: at the box's left edge")
        XCTAssertEqual(r.last!.maxX, right.size.width - pad / 2, accuracy: 2, "right: at the box's right edge")
        XCTAssertEqual((c.first!.minX + c.last!.maxX) / 2, center.size.width / 2, accuracy: 2, "center: in the middle")
        XCTAssertEqual(left.size, right.size, "alignment doesn't change the box")
    }

    func testInkStaysInsideTheRaster() throws {
        for r in [try raster(), try raster(300, .center), try raster(300, .right)] {
            XCTAssertTrue(CGRect(origin: .zero, size: r.size).insetBy(dx: -1, dy: -1).contains(r.ink))
            XCTAssertFalse(r.ink.isEmpty)
        }
    }
}

// MARK: - Placement in the frame

final class LineLayoutPlacementTests: XCTestCase {
    private func project(_ text: String = "Depremlerin yeri göğü inletse de", type: ProjectType = .musicVideo,
                         canvas: CanvasSize = .init(width: 1920, height: 1080)) -> Project {
        var p = Project(type: type, canvas: canvas)
        p.fps = 24
        let words = text.split(separator: " ").map { LyricWord(text: String($0), start: 0, end: 5) }
        p.lyricTracks[0].lines = [LyricLine(start: 0, end: 5, words: words)]
        return p
    }

    private func rect(_ p: Project) throws -> CGRect { try XCTUnwrap(LyricRenderer(project: p).placedLines(at: 1).first?.rect) }

    func testLyricsAreNeverScaledToFit() throws {
        // The screenshot's portrait case: a line wider than 1080 px stays one row at full size.
        let p = project(type: .social, canvas: .init(width: 1080, height: 1920))
        let placed = try XCTUnwrap(LyricRenderer(project: p).placedLines(at: 1).first)
        XCTAssertEqual(placed.fit, 1)
        XCTAssertEqual(placed.raster.rows, 1)
        XCTAssertGreaterThan(placed.rect.width, 1080, "wider than the frame, as asked")
        XCTAssertEqual(placed.rect.midX, try XCTUnwrap(SafeArea.rect(for: p)).midX, accuracy: 0.5, "automatic lines are centred")
    }

    func testAPositionedLineHangsFromItsAnchor() throws {
        var p = project()
        p.lyricTracks[0].lines[0].centerX = 300
        p.lyricTracks[0].lines[0].centerY = 200
        XCTAssertEqual(try rect(p).minX, 300, accuracy: 0.5, "left: the anchor is the left edge")
        XCTAssertEqual(try rect(p).midY, 200, accuracy: 0.5)
        p.lyricTracks[0].lines[0].layout.align = .center
        XCTAssertEqual(try rect(p).midX, 300, accuracy: 0.5, "center: the middle")
        p.lyricTracks[0].lines[0].layout.align = .right
        XCTAssertEqual(try rect(p).maxX, 300, accuracy: 0.5, "right: the right edge")
    }

    func testALeftAlignedLineGrowsToTheRightWhenTheTextGetsLonger() throws {
        var p = project("kısa")
        p.lyricTracks[0].lines[0].centerX = 200
        p.lyricTracks[0].lines[0].centerY = 500
        let before = try rect(p)
        p.lyricTracks[0].lines[0].words.append(LyricWord(text: "çok daha uzun", start: 0, end: 5))
        let after = try rect(p)
        XCTAssertEqual(after.minX, before.minX, accuracy: 0.5)
        XCTAssertGreaterThan(after.maxX, before.maxX)
        p.lyricStyle.sizeFraction *= 1.5
        XCTAssertEqual(try rect(p).minX, before.minX, accuracy: 0.5, "a bigger font grows away from the anchor too")
    }

    func testARightAlignedLineGrowsToTheLeft() throws {
        var p = project("kısa")
        p.lyricTracks[0].lines[0].layout.align = .right
        p.lyricTracks[0].lines[0].centerX = 1700
        p.lyricTracks[0].lines[0].centerY = 500
        let before = try rect(p)
        p.lyricTracks[0].lines[0].words.append(LyricWord(text: "uzun", start: 0, end: 5))
        XCTAssertEqual(try rect(p).maxX, before.maxX, accuracy: 0.5)
    }

    func testAWrappedLineIsAsWideAsItsWidth() throws {
        var p = project()
        p.lyricTracks[0].lines[0].layout = LineLayout(mode: .wrapped, width: 420)
        let placed = try XCTUnwrap(LyricRenderer(project: p).placedLines(at: 1).first)
        XCTAssertGreaterThan(placed.raster.rows, 1)
        let pad = ceil(LyricLayout.fontSize(p.lyricStyle, canvas: p.canvas) * 0.15)
        XCTAssertEqual(placed.rect.width, 420 + pad * 2, accuracy: 1)
    }

    func testAWrappedLineTakesATallerSlotInTheStack() throws {
        var p = project()
        p.lyricTracks[0].lines[0].layout = LineLayout(mode: .wrapped, width: 300)
        p.addLyricTrack()
        p.lyricTracks[1].lines = [LyricLine(start: 0, end: 5, words: [LyricWord(text: "altında", start: 0, end: 5)])]
        let placed = LyricRenderer(project: p).placedLines(at: 1)
        XCTAssertEqual(placed.count, 2)
        XCTAssertGreaterThanOrEqual(placed[0].rect.minY, placed[1].rect.maxY - placed[1].rect.height * 0.25,
                                    "the wrapped line sits above the next one instead of over it")
    }

    func testEachLineHasItsOwnLayout() throws {
        var p = project()
        p.addLyricTrack()
        p.lyricTracks[1].lines = [LyricLine(start: 0, end: 5, words: "Depremlerin yeri göğü inletse de".split(separator: " ").map { LyricWord(text: String($0), start: 0, end: 5) })]
        p.lyricTracks[0].lines[0].layout = LineLayout(mode: .wrapped, width: 300)
        let placed = LyricRenderer(project: p).placedLines(at: 1)
        XCTAssertGreaterThan(placed[0].raster.rows, 1)
        XCTAssertEqual(placed[1].raster.rows, 1, "the other line keeps the default")
    }

    func testTheAnchorOfADrawnLine() {
        var line = LyricLine(start: 0, end: 1, words: [])
        let r = CGRect(x: 100, y: 0, width: 200, height: 50)
        XCTAssertEqual(LyricRenderer.anchor(of: line, rect: r), 100)
        line.layout.align = .center
        XCTAssertEqual(LyricRenderer.anchor(of: line, rect: r), 200)
        line.layout.align = .right
        XCTAssertEqual(LyricRenderer.anchor(of: line, rect: r), 300)
    }
}

// MARK: - Editing from the inspector

@MainActor
final class LineLayoutEditTests: XCTestCase {
    private func editor(lines: Int = 2) -> (ProjectDocument, EditorModel) {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        p.lyricTracks = (0..<lines).map { i in
            var l = LyricLine(start: Double(i) * 2, end: Double(i) * 2 + 1.5,
                              words: "Kumlar kaldırımlara dönüşüyor".split(separator: " ").map { LyricWord(text: String($0), start: Double(i) * 2, end: Double(i) * 2 + 1.5) })
            l.centerX = 400; l.centerY = 300 + Double(i) * 200
            return LyricTrack(lines: [l])
        }
        let doc = ProjectDocument(project: p)
        return (doc, doc.editor)
    }

    private func rect(_ e: EditorModel, _ track: Int) -> CGRect {
        let l = e.project.lyricTracks[track].lines[0]
        return LyricRenderer(project: e.project).placedLines(at: l.start + 0.5).first { $0.line.id == l.id }!.rect
    }

    func testChangingTheAlignmentKeepsTheLineWhereItIs() {
        let (_, e) = editor()
        e.selection = .lyricLine(e.project.lyricTracks[0].lines[0].id)
        let before = rect(e, 0)
        for align in [LineLayout.Align.center, .right, .left] {
            e.setLineLayout("Text Alignment") { $0.align = align }
            XCTAssertEqual(e.project.lyricTracks[0].lines[0].layout.align, align)
            XCTAssertEqual(rect(e, 0).minX, before.minX, accuracy: 1, "\(align): the box doesn't move")
        }
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].centerX, 400, "and back to the same anchor")
    }

    func testAlignmentChangesMoveTheAnchorToTheNewEdge() {
        let (_, e) = editor()
        e.selection = .lyricLine(e.project.lyricTracks[0].lines[0].id)
        let w = rect(e, 0).width
        e.setLineLayout("Text Alignment") { $0.align = .right }
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].centerX!, (400 + w).rounded(), accuracy: 1)
    }

    func testWrappingStartsAtTheCurrentTextWidthAndKeepsTheAnchor() {
        let (_, e) = editor()
        e.selection = .lyricLine(e.project.lyricTracks[0].lines[0].id)
        let before = rect(e, 0)
        e.setLineMode(.wrapped)
        let line = e.project.lyricTracks[0].lines[0]
        XCTAssertEqual(line.layout.mode, .wrapped)
        let pad = ceil(LyricLayout.fontSize(e.project.lyricStyle, canvas: e.project.canvas) * 0.15)
        XCTAssertEqual(line.layout.width, Double(before.width - pad * 2).rounded(), accuracy: 1, "no jump when switching")
        XCTAssertEqual(rect(e, 0).minX, before.minX, accuracy: 1)
        XCTAssertEqual(LyricRenderer(project: e.project).placedLines(at: 0.5).first?.raster.rows, 1, "fits on one row at its own width")
    }

    func testAVeryLongLineWrapsAtMostAtNinetyPercentOfTheFrame() {
        let (_, e) = editor(lines: 1)
        e.edit("long") { p in
            p.lyricTracks[0].lines[0].words = Array(repeating: "kaldırımlara", count: 12).map { LyricWord(text: $0, start: 0, end: 1.5) }
        }
        e.selection = .lyricLine(e.project.lyricTracks[0].lines[0].id)
        e.setLineMode(.wrapped)
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].layout.width, 1920 * 0.9, accuracy: 1)
    }

    func testAWidthSetBeforeIsKeptWhenWrappingAgain() {
        let (_, e) = editor()
        e.selection = .lyricLine(e.project.lyricTracks[0].lines[0].id)
        e.setLineMode(.wrapped)
        e.setLineLayout("Line Width") { $0.width = 333 }
        e.setLineMode(.singleLine)
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].layout.mode, .singleLine)
        e.setLineMode(.wrapped)
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].layout.width, 333)
    }

    func testOnlyTheSelectedLinesChange() {
        let (_, e) = editor(lines: 3)
        let ids = e.project.lyricTracks.map { $0.lines[0].id }
        e.setSelection([.lyricLine(ids[0]), .lyricLine(ids[2])])
        e.setLineLayout("Text Alignment") { $0.align = .center }
        e.setLineMode(.wrapped)
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].layout.align, .center)
        XCTAssertEqual(e.project.lyricTracks[2].lines[0].layout.mode, .wrapped)
        XCTAssertEqual(e.project.lyricTracks[1].lines[0].layout, LineLayout(), "the unselected line is untouched")
    }

    func testASelectedWordEditsItsLine() {
        let (_, e) = editor(lines: 1)
        e.selection = .lyricWord(e.project.lyricTracks[0].lines[0].words[1].id)
        e.setLineLayout("Text Alignment") { $0.align = .right }
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].layout.align, .right)
    }

    /// Each call its own undo step (the app groups by event; tests have no event loop).
    private func step(_ doc: ProjectDocument, _ body: () -> Void) {
        let um = doc.undoManager!
        um.groupsByEvent = false
        um.beginUndoGrouping(); body(); um.endUndoGrouping()
    }

    func testLayoutChangesUndo() {
        let (doc, e) = editor(lines: 1)
        e.selection = .lyricLine(e.project.lyricTracks[0].lines[0].id)
        step(doc) { e.setLineMode(.wrapped) }
        step(doc) { e.setLineLayout("Text Alignment") { $0.align = .center } }
        doc.undoManager?.undo()
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].layout.mode, .wrapped, "one step back")
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].layout.align, .left)
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].centerX, 400)
        doc.undoManager?.undo()
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].layout, LineLayout())
    }

    func testDraggingTheWidthIsOneUndoStep() {
        let (doc, e) = editor(lines: 1)
        e.selection = .lyricLine(e.project.lyricTracks[0].lines[0].id)
        step(doc) { e.setLineMode(.wrapped) }
        let start = e.project.lyricTracks[0].lines[0].layout.width
        step(doc) {
            for w in stride(from: 300.0, through: 600, by: 50) { e.setLineLayout("Line Width", live: true) { $0.width = w } }
            e.endLiveEdit("Line Width")
        }
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].layout.width, 600)
        doc.undoManager?.undo()
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].layout.width, start)
    }

    func testNegativeWidthsBecomeZero() {
        let (_, e) = editor(lines: 1)
        e.selection = .lyricLine(e.project.lyricTracks[0].lines[0].id)
        e.setLineMode(.wrapped)
        e.setLineLayout("Line Width") { $0.width = -50 }
        XCTAssertEqual(e.project.lyricTracks[0].lines[0].layout.width, 0)
    }

    func testAlignButtonsPlaceTheLettersWhateverTheTextAlignment() {
        for align in LineLayout.Align.allCases {
            let (_, e) = editor(lines: 1)
            e.selection = .lyricLine(e.project.lyricTracks[0].lines[0].id)
            e.setLineLayout("Text Alignment") { $0.align = align }
            e.alignLines(horizontal: .left, vertical: .bottom, paddingX: 70, paddingY: 40, gap: 0)
            let placed = LyricRenderer(project: e.project).placedLines(at: 0.5)[0]
            let ink = placed.raster.ink.offsetBy(dx: placed.rect.minX, dy: placed.rect.minY)
            XCTAssertEqual(ink.minX, 70, accuracy: 1, "\(align)")
            XCTAssertEqual(ink.minY, 40, accuracy: 1, "\(align)")
            e.alignLines(horizontal: .right, vertical: nil, paddingX: 70, paddingY: 40, gap: 0)
            let right = LyricRenderer(project: e.project).placedLines(at: 0.5)[0]
            XCTAssertEqual(right.raster.ink.offsetBy(dx: right.rect.minX, dy: 0).maxX, 1920 - 70, accuracy: 1, "\(align)")
        }
    }

    func testAlignedWrappedLinesStillLineUp() {
        let (_, e) = editor()
        let ids = e.project.lyricTracks.map { $0.lines[0].id }
        e.setSelection([.lyricLine(ids[0]), .lyricLine(ids[1])])
        e.setLineMode(.wrapped)
        e.setLineLayout("Line Width") { $0.width = 260 }
        e.alignLines(horizontal: .left, vertical: nil, paddingX: 50, paddingY: 0, gap: 0)
        for track in 0..<2 {
            let l = e.project.lyricTracks[track].lines[0]
            let placed = LyricRenderer(project: e.project).placedLines(at: l.start + 0.5).first { $0.line.id == l.id }!
            XCTAssertEqual(placed.raster.ink.offsetBy(dx: placed.rect.minX, dy: 0).minX, 50, accuracy: 1)
        }
    }
}

// MARK: - Render cache and import

final class LineLayoutKeyTests: XCTestCase {
    func testALayoutChangeInvalidatesOnlyWhereTheLineIsDrawn() {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        p.lyricTracks[0].lines = [LyricLine(start: 1, end: 2, words: [LyricWord(text: "a b c", start: 1, end: 2)])]
        let here = RenderKey.key(project: p, start: 0, end: 2), there = RenderKey.key(project: p, start: 6, end: 8)
        p.lyricTracks[0].lines[0].layout = LineLayout(mode: .wrapped, width: 10)
        XCTAssertNotEqual(RenderKey.key(project: p, start: 0, end: 2), here)
        XCTAssertEqual(RenderKey.key(project: p, start: 6, end: 8), there)
        var q = p
        q.lyricTracks[0].lines[0].layout.align = .right
        XCTAssertNotEqual(RenderKey.key(project: q, start: 0, end: 2), RenderKey.key(project: p, start: 0, end: 2))
    }

    func testImportKeepsEachLinesLayoutAndResetsItsPosition() {
        var src = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        var line = LyricLine(start: 1, end: 2, words: [LyricWord(text: "a", start: 1, end: 2)])
        line.layout = LineLayout(mode: .wrapped, width: 512, align: .center)
        line.centerX = 100; line.centerY = 100
        src.lyricTracks[0].lines = [line]
        let imported = ProjectImport.make(from: src, type: .ad, canvas: .init(width: 1080, height: 1920)).project.lyricTracks[0].lines[0]
        XCTAssertEqual(imported.layout, line.layout)
        XCTAssertFalse(imported.hasPosition)
    }
}
