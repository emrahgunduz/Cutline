import AVFoundation
import CoreImage
import XCTest
@testable import Cutline

final class TrackMuteHideTests: XCTestCase {
    private func project() -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 320, height: 180))
        p.fps = 24
        let song = Asset(kind: .audio, name: "s", path: "/s", duration: 10)
        let image = Asset(kind: .image, name: "white", path: "/w", pixelSize: .init(width: 320, height: 180))
        p.assets = [song, image]
        p.audio = AudioClip(assetID: song.id, duration: 10)
        p.videoTracks[0].clips = [Clip(assetID: image.id, start: 0, duration: 10)]
        p.lyricTracks[0].lines = [LyricLine(start: 1, end: 3, words: [LyricWord(text: "hi", start: 1, end: 3)])]
        return p
    }

    // MARK: Model

    func testTogglesSwitchOnAndBackOff() {
        var p = project()
        p.toggleAudioMuted(); XCTAssertTrue(p.audio!.isMuted)
        p.toggleAudioMuted(); XCTAssertFalse(p.audio!.isMuted); XCTAssertNil(p.audio!.muted, "back to the default stores nothing")
        p.toggleVideoTrackHidden(0); XCTAssertTrue(p.videoTracks[0].isHidden)
        p.toggleLyricTrackHidden(0); XCTAssertTrue(p.lyricTracks[0].isHidden)
        p.toggleLyricTrackHidden(0); XCTAssertNil(p.lyricTracks[0].hidden)
        p.toggleVideoTrackHidden(9)         // out of range: nothing happens
        var silent = Project(type: .musicVideo, canvas: .init(width: 320, height: 180))
        silent.toggleAudioMuted()
        XCTAssertNil(silent.audio, "no song, nothing to mute")
    }

    func testTheSwitchesAreSavedAndOlderProjectsLoadWithThemOff() throws {
        var p = project()
        p.toggleAudioMuted(); p.toggleVideoTrackHidden(0); p.toggleLyricTrackHidden(0)
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertTrue(back.audio!.isMuted && back.videoTracks[0].isHidden && back.lyricTracks[0].isHidden)
        let old = try JSONDecoder().decode(VideoTrack.self, from: Data(#"{"id":"5A1F2B3C-0000-0000-0000-000000000004","clips":[]}"#.utf8))
        XCTAssertFalse(old.isHidden)
    }

    func testHiddenTracksStillCountForTheLength() {
        var p = project()
        p.videoTracks.append(VideoTrack(clips: [Clip(assetID: p.assets[1].id, start: 0, duration: 30)]))
        p.toggleVideoTrackHidden(1)
        XCTAssertEqual(p.duration, 30)
    }

    func testTheExportSheetSaysWhatIsLeftOut() {
        var p = project()
        XCTAssertEqual(p.exportOmissions, [])
        p.toggleAudioMuted()
        p.addLyricTrack()
        p.toggleLyricTrackHidden(1)
        XCTAssertEqual(p.exportOmissions, ["the song is muted", "Lyrics 2 is hidden"])
        p.toggleVideoTrackHidden(0)
        XCTAssertEqual(p.exportOmissions.last, "Video 1, Lyrics 2 are hidden")
    }

    // MARK: Rendering

    private func render(_ p: Project) -> CIImage {
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let snap = RenderSnapshot(project: p, images: [p.assets[1].id: white], lyrics: LyricRenderer(project: p))
        return FrameRenderer.render(snap, at: 5) { _ in nil }
    }

    func testAHiddenVideoTrackIsNotDrawn() {
        var p = project()
        XCTAssertEqual(FilterChainTests.meanLuma(render(p)), 1, accuracy: 0.02)
        p.toggleVideoTrackHidden(0)
        XCTAssertEqual(FilterChainTests.meanLuma(render(p)), 0, accuracy: 0.02, "black where the hidden clip was")
    }

    func testAHiddenLyricTrackIsNotDrawn() {
        var p = project()
        p.addLyricTrack()
        p.lyricTracks[1].lines = [LyricLine(start: 1, end: 3, words: [LyricWord(text: "two", start: 1, end: 3)])]
        p.toggleLyricTrackHidden(0)
        XCTAssertEqual(LyricRenderer(project: p).drawnLines(at: 2).map(\.text), ["two"])
        p.toggleLyricTrackHidden(1)
        XCTAssertTrue(LyricRenderer(project: p).placedLines(at: 2).isEmpty)
    }

    func testHidingChangesTheRenderKeyOnlyWhereTheTrackHasSomething() {
        var p = project()
        p.videoTracks.append(VideoTrack(clips: [Clip(assetID: p.assets[1].id, start: 0, duration: 2)]))
        let early = RenderKey.key(project: p, start: 0, end: 2), late = RenderKey.key(project: p, start: 6, end: 8)
        p.toggleVideoTrackHidden(1)
        XCTAssertNotEqual(RenderKey.key(project: p, start: 0, end: 2), early)
        XCTAssertEqual(RenderKey.key(project: p, start: 6, end: 8), late, "the track is empty there")
        var q = project()
        let lyricsHere = RenderKey.key(project: q, start: 0, end: 2)
        q.toggleLyricTrackHidden(0)
        XCTAssertNotEqual(RenderKey.key(project: q, start: 0, end: 2), lyricsHere)
    }

    func testMutingTheSongDoesNotTouchTheVideoKeys() {
        var p = project()
        let key = RenderKey.key(project: p, start: 0, end: 2)
        p.toggleAudioMuted()
        XCTAssertEqual(RenderKey.key(project: p, start: 0, end: 2), key, "video segments are reused; only the audio changes")
    }

    // MARK: Audio

    func testAMutedSongIsLeftOutOfThePreviewComposition() async throws {
        let wav = try TestMedia.sineWAV(seconds: 2)
        defer { try? FileManager.default.removeItem(at: wav) }
        var p = Project(type: .musicVideo, canvas: .init(width: 320, height: 180))
        let a = try await AssetLibrary.makeAsset(from: wav)
        p.assets = [a]
        p.setAudio(assetID: a.id)
        let snap = RenderSnapshot(project: p, images: [:], lyrics: nil)
        let audible = try await CompositionBuilder.build(project: p, mediaURL: { $0.url }, snapshot: snap)
        XCTAssertEqual(audible.composition.tracks(withMediaType: .audio).count, 1)
        p.toggleAudioMuted()
        let muted = try await CompositionBuilder.build(project: p, mediaURL: { $0.url }, snapshot: RenderSnapshot(project: p, images: [:], lyrics: nil))
        XCTAssertTrue(muted.composition.tracks(withMediaType: .audio).isEmpty)
        XCTAssertEqual(muted.duration.seconds, audible.duration.seconds, accuracy: 0.01, "still as long as the song")
    }

    @MainActor
    func testAMutedSongIsSilentInTheExport() async throws {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 320, height: 180)))
        let video = try await TestMedia.video(width: 320, height: 180, fps: 24, frames: 48)
        let wav = try TestMedia.sineWAV(seconds: 2)
        defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: wav) }
        _ = await doc.editor.importFiles([video, wav])
        let v = doc.editor.project.assets.first { $0.kind == .video }!.id, s = doc.editor.project.assets.first { $0.kind == .audio }!.id
        doc.editor.edit("setup") { p in _ = p.addClip(assetID: v, track: 0, at: 0); p.setAudio(assetID: s); p.toggleAudioMuted() }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("mute-\(UUID())")
        let out = TestMedia.tempURL("mp4")
        defer { try? FileManager.default.removeItem(at: cache); try? FileManager.default.removeItem(at: out) }
        var settings = ExportSettings.defaults(for: doc.editor.project)
        settings.rateMode = .bitrate; settings.bitrateMbps = 2
        try await SegmentExporter(cacheDir: cache).export(project: doc.editor.project, settings: settings, to: out) { _ in }
        let asset = AVURLAsset(url: out)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertTrue(audioTracks.isEmpty, "no sound")
        XCTAssertEqual(videoTracks.count, 1)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.1)
    }
}
