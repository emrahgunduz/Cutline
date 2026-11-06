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

    /// U9: with the master toggle off, or ⌘ held, nothing snaps whatever the groups say.
    func testMasterToggleAndBypassStopAllSnapping() {
        let (p, a) = song()
        let targets = Snapping.targets(in: p, playhead: 100, excluding: [], beats: ResolvedBeats(a, nil), groups: Set(SnapGroup.allCases))
        XCTAssertEqual(Snapping.resolve(4.05, enabled: true, bypass: false, targets: targets, pixelsPerSecond: 100).time, 4)
        XCTAssertEqual(Snapping.resolve(4.05, enabled: false, bypass: false, targets: targets, pixelsPerSecond: 100).time, 4.05)
        XCTAssertNil(Snapping.resolve(4.05, enabled: false, bypass: false, targets: targets, pixelsPerSecond: 100).target)
        XCTAssertEqual(Snapping.resolve(4.05, enabled: true, bypass: true, targets: targets, pixelsPerSecond: 100).time, 4.05)
    }

    /// While the song itself is dragged, its own beats can't be targets.
    func testDraggingTheSongLeavesOutItsBeats() {
        let (p, a) = song()
        let targets = Snapping.targets(in: p, playhead: 100, excluding: [], includeAudio: false, beats: ResolvedBeats(a, nil), groups: Set(SnapGroup.allCases))
        XCTAssertTrue(targets.allSatisfy { $0.group == .clips || $0.group == .lyrics })
        XCTAssertFalse(targets.contains { $0.time == 20 }, "nor the song's own end")
    }

    func testDragNearDownbeatLandsExactlyOnIt() {
        let (p, a) = song()
        XCTAssertEqual(snap(4.05, p, a), 4)
    }

    func testMoreImportantGroupWinsOverACloserTarget() {
        var (p, a) = song()
        a.beats.append(8.03)
        a.beats.sort()
        // Beats are more important than sections: near a beat that isn't a section edge, the beat wins.
        XCTAssertEqual(snap(8.01, p, a), 8, "the section edge at 8 is also a beat")
        XCTAssertEqual(snap(8.04, p, a, groups: [.beats, .sections]), 8.03)
        // A clip edge beats a closer beat.
        let img = Asset(kind: .image, name: "i", path: "/i.png")
        p.assets.append(img)
        p.addClip(assetID: img.id, track: 0, at: 3.1)
        XCTAssertEqual(snap(3.04, p, a), p.videoTracks[0].clips[0].start, "clip edge (3.1) over the nearer beat (3.0)")
    }

    func testRadiusIsInPixels() {
        let (p, a) = song()
        XCTAssertEqual(snap(4.3, p, a, pps: 10), 4.5)    // 2 px from the beat at 4.5 when zoomed out (beats outrank the downbeat at 4)
        XCTAssertNil(snap(4.3, p, a, pps: 100))          // 30 px away zoomed in (beat at 4.5 is 20 px)
    }

    func testGroupTogglesFilterTargets() {
        let (p, a) = song()
        // Beats off, downbeats on: near a plain beat does not snap, near a downbeat does.
        let noBeats: Set<SnapGroup> = [.sections, .downbeats, .clips, .lyrics]
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
        l.snapGroups = [.lyrics, .downbeats]
        let back = try JSONDecoder().decode(LayoutState.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back.snapGroups, [.lyrics, .downbeats])
        XCTAssertNil(try JSONDecoder().decode(LayoutState.self, from: Data(#"{"assetsWidth":280,"inspectorWidth":300,"timelineHeight":320}"#.utf8)).snapGroups)
    }
}

final class BeatCorrectionAnchorTests: XCTestCase {
    /// Beats every 0.5 s, downbeats every 2 s, sections at 0, 8 and 14 s; song at timeline 0.
    private func song() -> (Project, AudioAnalysis) {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        let asset = Asset(kind: .audio, name: "s", path: "/s", duration: 20)
        p.assets = [asset]
        p.setAudio(assetID: asset.id)
        let a = AudioAnalysis(hash: "h", result: .init(duration: 20, tempo: 120, beats: stride(from: 0, to: 20, by: 0.5).map { $0 },
                                                       downbeats: stride(from: 0, to: 20, by: 2).map { $0 }, onsets: [],
                                                       sections: [.init(start: 0, label: "A"), .init(start: 8, label: "B"), .init(start: 14, label: "C")], vocals: ""))
        return (p, a)
    }

    func testDownbeatMovedOntoTheNextBeatReMarksItAndKeepsTheGrid() {
        var (p, a) = song()
        p.moveDownbeat(2, to: 4.5, analysis: a)          // the downbeat at 4 s onto the beat at 4.5 s
        let r = ResolvedBeats(a, p.beatCorrections)
        XCTAssertEqual(r.downbeats[2], 4.5)
        XCTAssertEqual(r.beats, a.beats, "no beat moved, none duplicated, none lost")
    }

    func testDownbeatDroppedNearABeatSnapsOntoIt() {
        var (p, a) = song()
        p.moveDownbeat(2, to: 4.53, analysis: a)
        XCTAssertEqual(ResolvedBeats(a, p.beatCorrections).downbeats[2], 4.5)
    }

    func testDownbeatMovedBetweenBeatsCarriesItsBeat() {
        var (p, a) = song()
        p.moveDownbeat(2, to: 4.25, analysis: a)
        let r = ResolvedBeats(a, p.beatCorrections)
        XCTAssertTrue(r.beats.contains(4.25))
        XCTAssertFalse(r.beats.contains(4))
        XCTAssertEqual(r.beats.count, a.beats.count)
    }

    func testAddingABoundaryKeepsMarkersOnTheirSection() {
        var (p, a) = song()
        p.cinemascope.startMarker = 14; p.cinemascope.endMarker = 16
        p.anchorMarkers(ResolvedBeats(a, nil), hash: "h")
        XCTAssertEqual(p.cinemascope.startAnchor?.kind, .section)
        p.addSectionBoundary(at: 4.25, analysis: a)       // a new section before the marker's
        XCTAssertEqual(p.cinemascope.startMarker, 14, "the marker stays on section C")
        XCTAssertEqual(p.cinemascope.startAnchor?.index, 3)
    }

    func testRemovingABoundaryKeepsOtherMarkersAndReanchorsItsOwn() {
        var (p, a) = song()
        p.cinemascope.startMarker = 8; p.cinemascope.endMarker = 14
        p.anchorMarkers(ResolvedBeats(a, nil), hash: "h")
        p.removeSectionBoundary(1, analysis: a)           // remove B (8 s), where the start marker sits
        XCTAssertEqual(p.cinemascope.startMarker, 8, "the start marker stays put")
        XCTAssertNotEqual(p.cinemascope.startAnchor?.kind, .section)
        XCTAssertEqual(p.cinemascope.endMarker, 14, "the end marker stays on section C")
        XCTAssertEqual(p.cinemascope.endAnchor?.index, 1)
    }
}

final class SnapGroupSplitTests: XCTestCase {
    func testClipsAndLyricsAreSeparateGroups() {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        let img = Asset(kind: .image, name: "i", path: "/i.png")
        p.assets = [img]
        p.addClip(assetID: img.id, track: 0, at: 4)
        p.lyricTracks[0].lines = LyricImport.roughlyTimed(LyricImport.parse("one two"), start: 10, end: 12, fps: 24)
        func snap(_ t: Double, _ g: Set<SnapGroup>) -> Double? {
            Snapping.snap(t, targets: Snapping.targets(in: p, playhead: 50, excluding: [], beats: nil, groups: g), pixelsPerSecond: 100)?.time
        }
        XCTAssertEqual(snap(4.03, [.clips]), 4)
        XCTAssertNil(snap(4.03, [.lyrics]), "lyrics off the clip's edge")
        XCTAssertEqual(snap(10.03, [.lyrics]), 10)
        XCTAssertNil(snap(10.03, [.clips]), "clips don't attract to lyrics")
        XCTAssertEqual(snap(50.02, [.clips]), 50, "the playhead is with clips")
    }

    func testOldSavedGroupsAreMapped() throws {
        let old = #"{"assetsWidth":420,"inspectorWidth":310,"timelineHeight":320,"snapGroups":["sections","beats","edges"]}"#
        let l = try JSONDecoder().decode(LayoutState.self, from: Data(old.utf8))
        XCTAssertEqual(l.snapGroups, [.clips, .lyrics, .beats, .sections], "edges is now clips and lyrics")
        XCTAssertEqual(l.assetsWidth, 420, "the rest of the layout survives")
        let unknown = #"{"assetsWidth":300,"snapGroups":["sections","nonsense"],"snapping":false}"#
        let u = try JSONDecoder().decode(LayoutState.self, from: Data(unknown.utf8))
        XCTAssertEqual(u.snapGroups, [.sections])
        XCTAssertEqual(u.snapping, false)
        XCTAssertEqual(u.inspectorWidth, 300, "missing fields keep their defaults")
    }

    func testTheOrderIsMostToLeastImportant() {
        XCTAssertEqual(SnapGroup.allCases, [.clips, .lyrics, .beats, .downbeats, .sections])
    }
}

