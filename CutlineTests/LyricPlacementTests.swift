import XCTest
@testable import Cutline

final class LyricPlacementTests: XCTestCase {
    let canvas = CGSize(width: 1920, height: 1080)
    /// A 400×100 box whose letters are inset 10 px left/right, 20 px below and 15 px above.
    let box = LyricPlacement.Box(size: CGSize(width: 400, height: 100), ink: CGRect(x: 10, y: 20, width: 380, height: 65))

    func testHorizontalPaddingIsMeasuredToTheLetters() {
        XCTAssertEqual(LyricPlacement.x(for: .left, box: box, canvasWidth: 1920, padding: 60), 60 + 200 - 10)
        XCTAssertEqual(LyricPlacement.x(for: .center, box: box, canvasWidth: 1920, padding: 60), 960)
        XCTAssertEqual(LyricPlacement.x(for: .right, box: box, canvasWidth: 1920, padding: 60), 1920 - 60 - 190)
    }

    func testVerticalPaddingIsMeasuredToTheLetters() {
        let bottom = LyricPlacement.stackedY(.bottom, boxes: [box], frame: 0...1080, padding: 40, gap: 0)[0]
        XCTAssertEqual(bottom - 50 + 20, 40, "the letters' bottom is 40 px over the frame's bottom edge")
        let top = LyricPlacement.stackedY(.top, boxes: [box], frame: 0...1080, padding: 40, gap: 0)[0]
        XCTAssertEqual(top - 50 + 85, 1080 - 40, "the letters' top is 40 px under the frame's top edge")
    }

    func testStackedLinesSitUnderEachOtherWithGap() {
        let plain = LyricPlacement.Box(size: CGSize(width: 300, height: 80))
        let ys = LyricPlacement.stackedY(.bottom, boxes: [plain, plain], frame: 0...1080, padding: 60, gap: 20)
        // Block = 180 tall, bottom edge at 60: top line center 200, second line center 100.
        XCTAssertEqual(ys, [200, 100])
        XCTAssertEqual(LyricPlacement.stackedY(.top, boxes: [plain], frame: 0...1080, padding: 60, gap: 0), [980])
        XCTAssertEqual(LyricPlacement.stackedY(.center, boxes: [plain], frame: 100...980, padding: 60, gap: 0), [540])
    }

    @MainActor
    func testSeveralLinesAlignAsOneBlockWithSeparatePaddings() throws {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        p.cinemascope = Cinemascope(enabled: true, startMarker: 0, endMarker: 0.5)
        p.addLyricTrack()
        p.lyricTracks[0].lines = [LyricLine(start: 1, end: 3, words: [LyricWord(text: "Kör", start: 1, end: 3)])]
        p.lyricTracks[1].lines = [LyricLine(start: 1, end: 3, words: [LyricWord(text: "aynalarda", start: 1, end: 3)])]
        let doc = ProjectDocument(project: p)
        let e = doc.editor
        e.setSelection([.lyricLine(p.lyricTracks[0].lines[0].id), .lyricLine(p.lyricTracks[1].lines[0].id)])
        e.alignLines(horizontal: .left, vertical: .bottom, paddingX: 80, paddingY: 30, gap: 10)
        let r = LyricRenderer(project: e.project)
        let placed = r.placedLines(at: 2)
        XCTAssertEqual(placed.count, 2)
        let bar = CGFloat(Letterbox.defaultBarHeight(p.canvas))
        for pl in placed {
            let ink = pl.raster.ink.applying(CGAffineTransform(scaleX: pl.fit, y: pl.fit)).offsetBy(dx: pl.rect.minX, dy: pl.rect.minY)
            XCTAssertEqual(ink.minX, 80, accuracy: 1, "each line's letters start 80 px from the left")
        }
        let lower = try XCTUnwrap(placed.last)
        let lowerInk = lower.raster.ink.applying(CGAffineTransform(scaleX: lower.fit, y: lower.fit)).offsetBy(dx: lower.rect.minX, dy: lower.rect.minY)
        XCTAssertEqual(lowerInk.minY, 30, accuracy: 1, "measured from the frame's bottom edge, not the bar (\(bar) px)")
        XCTAssertGreaterThan(placed[0].rect.minY, placed[1].rect.maxY - 1)       // first line above the second
        e.resetLinePositions()
        XCTAssertFalse(e.project.lyricTracks.flatMap(\.lines).contains { $0.hasPosition })
    }
}

@MainActor
final class AutoPositionTests: XCTestCase {
    private func line(_ text: String, _ start: Double, _ end: Double) -> LyricLine {
        LyricLine(start: start, end: end, words: [LyricWord(text: text, start: start, end: end)])
    }

    /// Letters of every line on screen at `t`, in canvas pixels.
    private func inks(_ p: Project, at t: Double) -> [UUID: CGRect] {
        Dictionary(uniqueKeysWithValues: LyricRenderer(project: p).placedLines(at: t).map { pl in
            (pl.line.id, pl.raster.ink.applying(CGAffineTransform(scaleX: pl.fit, y: pl.fit)).offsetBy(dx: pl.rect.minX, dy: pl.rect.minY))
        })
    }

    func testSelectedLinesGoToTheSpotAsOneBlock() throws {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.addLyricTrack()
        p.lyricTracks[0].lines = [line("Kör", 1, 3)]
        p.lyricTracks[1].lines = [line("aynalarda", 1, 3)]
        let e = ProjectDocument(project: p).editor
        let (a, b) = (p.lyricTracks[0].lines[0].id, p.lyricTracks[1].lines[0].id)
        e.setSelection([.lyricLine(a), .lyricLine(b)])
        e.autoPosition(.topRight, allLines: false, paddingX: 80, paddingY: 30, gap: 10)
        let ink = inks(e.project, at: 2)
        for id in [a, b] { XCTAssertEqual(try XCTUnwrap(ink[id]).maxX, 1920 - 80, accuracy: 1, "letters end 80 px from the right") }
        XCTAssertEqual(try XCTUnwrap(ink[a]).maxY, 1080 - 30, accuracy: 1, "the block's top letters are 30 px under the top")
        XCTAssertGreaterThan(try XCTUnwrap(ink[a]).minY, try XCTUnwrap(ink[b]).maxY, "the first track is above the second")
    }

    func testApplyToAllPutsEveryLineInTheSameSpotWithNoPaddingAndStacksLinesShownTogether() throws {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.addLyricTrack()
        p.lyricTracks[0].lines = [line("gece", 0, 2), line("Kör", 4, 6), line("yalnız", 8, 10)]
        p.lyricTracks[1].lines = [line("gece", 4, 6)]
        let e = ProjectDocument(project: p).editor
        let lines0 = p.lyricTracks[0].lines, shared = p.lyricTracks[1].lines[0]
        e.setSelection(Set(lines0.map { Selection.lyricLine($0.id) }))   // selected or not, every line moves
        e.autoPosition(.bottomRight, allLines: true, paddingX: 60, paddingY: 40, gap: 10)
        XCTAssertTrue(e.project.lyricTracks.flatMap(\.lines).allSatisfy(\.hasPosition))
        let alone = try XCTUnwrap(inks(e.project, at: 1)[lines0[0].id])
        XCTAssertEqual(alone.maxX, 1920, accuracy: 1, "no padding: the letters end at the right edge")
        XCTAssertEqual(alone.minY, 0, accuracy: 1, "no padding: the letters sit on the bottom edge")
        XCTAssertEqual(try XCTUnwrap(inks(e.project, at: 9)[lines0[2].id]).maxX, 1920, accuracy: 1)
        let together = inks(e.project, at: 5)
        let lower = try XCTUnwrap(together[shared.id]), upper = try XCTUnwrap(together[lines0[1].id])
        XCTAssertEqual(lower.minY, alone.minY, accuracy: 1, "the bottom track's line takes the same spot")
        XCTAssertGreaterThan(upper.minY, lower.maxY, "the line shown with it stacks above, in track order")
        XCTAssertEqual(upper.maxX, 1920, accuracy: 1)
    }

    func testTheSpotIsSavedWithTheProject() throws {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        XCTAssertEqual(p.lyricAutoSpot, .bottomCenter, "one spot is always chosen")
        p.lyricAutoSpot = .topLeft
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.lyricAutoSpot, .topLeft)
    }

    func testAutoPositionIsOneUndoStep() throws {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.lyricTracks[0].lines = [line("a", 0, 2), line("b", 3, 5)]
        let doc = ProjectDocument(project: p)
        let e = doc.editor
        let um = try XCTUnwrap(doc.undoManager)
        um.groupsByEvent = false
        e.selection = .lyricLine(p.lyricTracks[0].lines[0].id)
        um.beginUndoGrouping()
        e.autoPosition(.topCenter, allLines: true, paddingX: 60, paddingY: 60, gap: 0)
        um.endUndoGrouping()
        XCTAssertTrue(e.project.lyricTracks[0].lines.allSatisfy(\.hasPosition))
        um.undo()
        XCTAssertFalse(e.project.lyricTracks[0].lines.contains(where: \.hasPosition))
    }
}

final class NegativeGapTests: XCTestCase {
    func testNegativeGapOverlapsLines() {
        let plain = LyricPlacement.Box(size: CGSize(width: 300, height: 80))
        let ys = LyricPlacement.stackedY(.bottom, boxes: [plain, plain], frame: 0...1080, padding: 60, gap: -20)
        XCTAssertEqual(ys[0] - ys[1], 60)      // 80 tall lines, 20 px closer than touching
    }
}
