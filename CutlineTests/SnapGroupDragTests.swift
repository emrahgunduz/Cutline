import XCTest
@testable import Cutline

/// Snap groups switched off in the timeline's bar must not attract a real drag.
@MainActor
final class SnapGroupDragTests: XCTestCase {
    private func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Drags the right edge of a 2–5 s clip to 6.42 s; a beat sits at 6.5 s (within the snap radius).
    private func dragEdge(groups: Set<SnapGroup>) throws -> Double {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 50
        let song = Asset(kind: .audio, name: "s", path: "/s", duration: 60)
        let img = Asset(kind: .image, name: "i", path: "/i.png")
        p.assets = [song, img]
        p.setAudio(assetID: song.id)
        p.addClip(assetID: img.id, track: 0, at: 2)
        p.videoTracks[0].clips[0].duration = 3
        let doc = ProjectDocument(project: p)
        let e = doc.editor
        e.autoAnalyze = false
        e.audioAnalysis.adopt(AudioAnalysis(hash: "h", result: .init(duration: 60, tempo: 120, beats: [6.5, 7, 7.5], downbeats: [], onsets: [], sections: [], vocals: "")))
        e.setPlayhead(30)
        let view = TimelineView(editor: e)
        view.frame = CGRect(x: 0, y: 0, width: 1200, height: 400)
        view.pixelsPerSecond = 50
        view.scrollTime = 0
        view.snappingEnabled = true
        view.snapGroups = groups
        let l = view.layout
        func viewY(_ wy: CGFloat) -> CGFloat { view.convert(NSPoint(x: 0, y: wy), from: nil).y }
        let rowTop = try XCTUnwrap(stride(from: CGFloat(0), to: 400, by: 1).map(viewY).filter { if case .video(0)? = l.row(atY: $0) { return true }; return false }.min())
        let y = try XCTUnwrap(stride(from: CGFloat(0), to: 400, by: 1).first { abs(viewY($0) - (rowTop + 25)) < 0.5 })
        let edge = l.x(for: 5) - 1
        view.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: edge, y: y)))
        view.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: edge + 71, y: y)))   // 1.42 s later: 6.42 s
        view.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: edge + 71, y: y)))
        return try XCTUnwrap(e.project.videoTracks[0].clips.first).end
    }

    func testBeatsAttractWhenOn() throws {
        XCTAssertEqual(try dragEdge(groups: Set(SnapGroup.allCases)), 6.5, accuracy: 0.001)
    }

    func testBeatsDontAttractWhenOff() throws {
        XCTAssertEqual(try dragEdge(groups: Set(SnapGroup.allCases).subtracting([.beats])), 6.42, accuracy: 0.03)
    }
}
