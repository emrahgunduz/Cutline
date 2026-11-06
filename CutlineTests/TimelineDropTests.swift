import XCTest
@testable import Cutline

/// Dropping on the timeline: files from the Finder are imported (or matched to an asset the
/// project has), one song at a time, and one lyrics file for the whole timeline.
@MainActor
final class TimelineDropTests: XCTestCase {
    private func lines(_ text: String) -> [LyricLine] {
        LyricImport.roughlyTimed(LyricImport.parse(text), start: 0, end: 10, fps: 24)
    }

    func testLyricsReplaceEveryLyricsTrack() {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.addLyricTrack()
        p.lyricTracks[0].lines = lines("old one\nold two")
        p.lyricTracks[1].lines = lines("old three")
        XCTAssertEqual(p.lyricLineCounts.lines, 3)
        XCTAssertEqual(p.lyricLineCounts.tracks, 2)
        let target = p.replaceAllLyrics(with: lines("new a\nnew b\nnew c\nnew d"), onTrack: 1)
        XCTAssertEqual(target, 1)
        XCTAssertTrue(p.lyricTracks[0].lines.isEmpty, "the other track is emptied")
        XCTAssertEqual(p.lyricTracks[1].lines.map { $0.words.map(\.text).joined(separator: " ") }, ["new a", "new b", "new c", "new d"])
        XCTAssertEqual(p.lyricTracks.count, 2, "tracks stay")
    }

    func testLyricsDroppedOffALyricsTrackGoOnTheFirstOne() {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.lyricTracks[0].lines = lines("old")
        XCTAssertEqual(p.replaceAllLyrics(with: lines("new"), onTrack: 7), 0)
        XCTAssertEqual(p.lyricTracks[0].lines.count, 1)
        p.lyricTracks = []
        XCTAssertEqual(p.replaceAllLyrics(with: lines("new"), onTrack: 0), 0)
        XCTAssertEqual(p.lyricTracks.count, 1, "a lyrics track is added when there's none")
    }

    func testPlacingALyricsFileReplacesAllLyricsInOneUndoStep() throws {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        let e = doc.editor
        e.autoAnalyze = false
        let um = try XCTUnwrap(doc.undoManager)
        um.groupsByEvent = false  // one undo group per step, as separate user actions would be
        um.beginUndoGrouping()
        e.edit("Setup") { p in
            p.addLyricTrack()
            p.lyricTracks[0].lines = self.lines("old one")
            p.lyricTracks[1].lines = self.lines("old two")
        }
        let txt = TestMedia.tempURL("txt")
        try "first line\nsecond line\n".write(to: txt, atomically: true, encoding: .utf8)
        um.endUndoGrouping()
        let asset = Asset(kind: .lyrics, name: "song.txt", path: txt.path)
        um.beginUndoGrouping()
        e.placeLyrics(asset, track: 0, at: 0, window: nil)
        um.endUndoGrouping()
        XCTAssertEqual(e.project.lyricTracks[0].lines.count, 2)
        XCTAssertTrue(e.project.lyricTracks[1].lines.isEmpty)
        um.undo()
        XCTAssertEqual(e.project.lyricLineCounts.lines, 2, "undo brings both old lines back")
        XCTAssertEqual(e.project.lyricLineCounts.tracks, 2)
    }

    func testFinderFilesAreImportedOnceAndReusedAfterwards() async throws {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        let e = doc.editor
        let png = try TestMedia.halfTransparentPNG()
        let wav = try TestMedia.sineWAV(seconds: 1)
        let first = await e.importAssets([png, wav], reuseExisting: true)
        XCTAssertTrue(first.errors.isEmpty)
        XCTAssertEqual(first.assets.map(\.kind), [.image, .audio])
        XCTAssertEqual(e.project.assets.count, 2)
        // Dropping the same image again places the asset the project already has.
        let again = await e.importAssets([png], reuseExisting: true)
        XCTAssertEqual(again.assets.map(\.id), [first.assets[0].id])
        XCTAssertEqual(e.project.assets.count, 2)
    }

    /// Regression: importing from a background task crashed the app (the edit ran off the main thread).
    func testImportingFromABackgroundTaskEditsOnTheMainThread() async throws {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        let e = doc.editor
        let pngs = [try TestMedia.halfTransparentPNG(), try TestMedia.halfTransparentPNG()]
        let result = await Task.detached { await e.importAssets(pngs, reuseExisting: true) }.value
        XCTAssertEqual(result.assets.count, 2)
        XCTAssertEqual(e.project.assets.filter { $0.kind == .image }.count, 2)
        let viaPanel = await Task.detached { await e.importFiles([try! TestMedia.halfTransparentPNG()]) }.value
        XCTAssertTrue(viaPanel.isEmpty)
        XCTAssertEqual(e.project.assets.count, 3)
    }

    func testASongReplacesTheSong() {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        let a = Asset(kind: .audio, name: "a", path: "/a.wav", duration: 60)
        let b = Asset(kind: .audio, name: "b", path: "/b.wav", duration: 90)
        p.assets = [a, b]
        p.setAudio(assetID: a.id)
        p.setAudio(assetID: b.id)
        XCTAssertEqual(p.audio?.assetID, b.id)
        XCTAssertEqual(p.audio?.duration, 90)
    }
}

/// A drop from the Finder onto the timeline view: file URLs on the pasteboard.
@MainActor
final class TimelineFinderDropTests: XCTestCase {
    func testAFinderImageIsImportedAndPlacedWhereItWasDropped() async throws {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        let e = doc.editor
        e.autoAnalyze = false
        let view = TimelineView(editor: e)
        view.frame = CGRect(x: 0, y: 0, width: 1200, height: 400)
        view.pixelsPerSecond = 20
        view.scrollTime = 0
        let l = view.layout
        let y = try XCTUnwrap(stride(from: CGFloat(0), to: 400, by: 2).first { if case .video(0)? = l.row(atY: $0) { return true }; return false })
        let x = l.x(for: 12)
        let png = try TestMedia.halfTransparentPNG()
        let board = NSPasteboard(name: .init("cutline-drop-\(UUID())"))
        board.clearContents()
        board.writeObjects([png as NSURL])
        XCTAssertTrue(view.performDragOperation(FakeDrop(board, at: NSPoint(x: x, y: y))))
        // The import runs on the main actor; wait for the clip.
        for _ in 0..<100 where e.project.videoTracks[0].clips.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let clip = try XCTUnwrap(e.project.videoTracks[0].clips.first)
        XCTAssertEqual(clip.start, 12, accuracy: 1.0 / 24 + 0.05)
        XCTAssertEqual(e.project.asset(clip.assetID)?.url.standardizedFileURL, png.standardizedFileURL)
        XCTAssertEqual(e.project.assets.count, 1)
        board.releaseGlobally()
    }
}

/// The parts of NSDraggingInfo the timeline reads.
private final class FakeDrop: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    init(_ board: NSPasteboard, at p: NSPoint) { draggingPasteboard = board; draggingLocation = p }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
