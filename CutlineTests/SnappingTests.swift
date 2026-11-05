import XCTest
@testable import Cutline

final class SnappingTests: XCTestCase {
    /// 120 BPM song starting at timeline 0: beats every 0.5 s, downbeats every 2 s, section at 8 s.
    private func song() -> (Project, AudioAnalysis) {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        let asset = Asset(kind: .audio, name: "s", path: "/s", duration: 20)
        p.assets = [asset]
        p.setAudio(assetID: asset.id)
        let a = AudioAnalysis(hash: "h", result: .init(duration: 20, tempo: 120, beats: stride(from: 0, to: 20, by: 0.5).map { $0 },
                                                       downbeats: stride(from: 0, to: 20, by: 2).map { $0 }, onsets: [],
                                                       sections: [.init(start: 0, label: "A"), .init(start: 8, label: "B")], vocals: ""))
        return (p, a)
    }

    private func snap(_ t: Double, _ p: Project, _ a: AudioAnalysis, groups: Set<SnapGroup> = Set(SnapGroup.allCases), pps: Double = 100) -> Double? {
        let targets = Snapping.targets(in: p, playhead: 100, excluding: [], beats: ResolvedBeats(a, p.beatCorrections), groups: groups)
        return Snapping.snap(t, targets: targets, pixelsPerSecond: pps)?.time
    }

    func testDragNearDownbeatLandsExactlyOnIt() {
        let (p, a) = song()
        XCTAssertEqual(snap(4.05, p, a), 4)
    }

    func testSectionEdgeWinsOverCloserBeat() {
        var (p, a) = song()
        a.beats.append(8.03)
        a.beats.sort()
        // 8.04 is closer to the 8.03 beat, but the section edge at 8 has priority.
        XCTAssertEqual(snap(8.04, p, a), 8)
        p.beatCorrections = nil
    }

    func testRadiusIsInPixels() {
        let (p, a) = song()
        XCTAssertEqual(snap(4.3, p, a, pps: 10), 4)      // 3 px away when zoomed out
        XCTAssertNil(snap(4.3, p, a, pps: 100))          // 30 px away zoomed in (beat at 4.5 is 20 px)
    }

    func testGroupTogglesFilterTargets() {
        let (p, a) = song()
        // Beats off, downbeats on: near a plain beat does not snap, near a downbeat does.
        let noBeats: Set<SnapGroup> = [.sections, .downbeats]
        XCTAssertNil(snap(2.55, p, a, groups: noBeats))
        XCTAssertEqual(snap(2.05, p, a, groups: noBeats), 2)
        XCTAssertEqual(snap(2.55, p, a, groups: [.beats]), 2.5)
        XCTAssertTrue(Snapping.targets(in: p, playhead: 0, excluding: [], beats: nil, groups: []).isEmpty)
    }

    func testBeatTargetsFollowTheAudioStart() {
        var (p, a) = song()
        p.moveAudio(start: 1)
        XCTAssertEqual(snap(5.04, p, a, groups: [.downbeats]), 5)
    }

    func testMarkerAnchoredToDownbeatFollowsCorrection() {
        var (p, a) = song()
        p.cinemascope.enabled = true
        p.cinemascope.startMarker = 4
        p.cinemascope.endMarker = 6.25
        p.anchorMarkers(ResolvedBeats(a, nil), hash: a.audioHash)
        XCTAssertEqual(p.cinemascope.startAnchor?.kind, .downbeat)
        XCTAssertEqual(p.cinemascope.endAnchor?.kind, .beat)
        XCTAssertEqual(p.cinemascope.endAnchor?.offset ?? 0, 0.25, accuracy: 1e-9)

        p.moveDownbeat(2, to: 4.25, analysis: a)   // downbeat at 4 s corrected
        XCTAssertEqual(p.cinemascope.startMarker, p.quantize(4.25))
        XCTAssertEqual(p.cinemascope.endMarker, p.quantize(6.25), "the end marker's beat did not move")
    }

    func testAnchoredMarkersMoveWithTheAudio() {
        var (p, a) = song()
        p.cinemascope.startMarker = 4; p.cinemascope.endMarker = 6
        p.anchorMarkers(ResolvedBeats(a, nil), hash: a.audioHash)
        p.moveAudio(start: 2)
        XCTAssertEqual(p.cinemascope.startMarker, 6)
        XCTAssertEqual(p.cinemascope.endMarker, 8)
    }

    func testAnchorsForAnotherSongAreIgnored() {
        var (p, a) = song()
        p.cinemascope.startMarker = 4; p.cinemascope.endMarker = 6
        p.anchorMarkers(ResolvedBeats(a, nil), hash: "other-song")
        p.moveDownbeat(2, to: 4.25, analysis: a)
        XCTAssertEqual(p.cinemascope.startMarker, 4)
    }

    func testSnapGroupsAreSavedInLayout() throws {
        var l = LayoutState()
        l.snapGroups = [.downbeats, .edges]
        let back = try JSONDecoder().decode(LayoutState.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back.snapGroups, [.downbeats, .edges])
        XCTAssertNil(try JSONDecoder().decode(LayoutState.self, from: Data(#"{"assetsWidth":280,"inspectorWidth":300,"timelineHeight":320}"#.utf8)).snapGroups)
    }
}
