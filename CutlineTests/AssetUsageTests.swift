import XCTest
@testable import Cutline

@MainActor
final class AssetUsageTests: XCTestCase {
    private func project() -> (Project, Asset, Asset, Asset) {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        let v = Asset(kind: .video, name: "v", path: "/v", duration: 10, frameRate: 24)
        let i = Asset(kind: .image, name: "i", path: "/i")
        let a = Asset(kind: .audio, name: "a", path: "/a", duration: 100)
        p.assets = [v, i, a]
        p.addClip(assetID: v.id, track: 0, at: 0)
        p.addClip(assetID: v.id, track: 0, at: 20)
        p.setAudio(assetID: a.id)
        return (p, v, i, a)
    }

    func testUsageCounts() {
        let (p, v, i, a) = project()
        XCTAssertEqual(p.usageCount(of: v.id), 2)
        XCTAssertEqual(p.usageCount(of: i.id), 0)
        XCTAssertEqual(p.usageCount(of: a.id), 1)
    }

    func testRemovingAssetsRemovesTheirPlacements() {
        var (p, v, i, a) = project()
        p.removeAssets([v.id, a.id])
        XCTAssertEqual(p.assets.map(\.id), [i.id])
        XCTAssertTrue(p.videoTracks.flatMap(\.clips).isEmpty)
        XCTAssertNil(p.audio)
    }

    func testSelectingClipSelectsItsAsset() {
        let doc = ProjectDocument(project: project().0)
        let clip = doc.editor.project.videoTracks[0].clips[0]
        doc.editor.selection = .clip(clip.id)
        XCTAssertEqual(doc.editor.selectedAssets, [clip.assetID])
        doc.editor.selection = .audio
        XCTAssertEqual(doc.editor.selectedAssets, [doc.editor.project.audio!.assetID])
    }

    func testDeleteIsUndoable() {
        let doc = ProjectDocument(project: project().0)
        let v = doc.editor.project.assets[0].id
        doc.editor.deleteAssets([v])
        XCTAssertNil(doc.editor.project.asset(v))
        doc.undoManager?.undo()
        XCTAssertNotNil(doc.editor.project.asset(v))
        XCTAssertEqual(doc.editor.project.usageCount(of: v), 2)
    }

    func testDeletingTheSongClearsItsAnalysisAndFixes() throws {
        var (p, _, _, a) = project()
        p.beatCorrections = BeatCorrections(audioHash: "x")
        p.cinemascope.startAnchor = BeatAnchor(kind: .downbeat, index: 2, offset: 0, audioHash: "x")
        let doc = ProjectDocument(project: p)
        let dir = try XCTUnwrap(doc.editor.folder("analysis"))
        let wave = dir.appendingPathComponent("waveform-\(a.id.uuidString).plist")
        try Data("w".utf8).write(to: wave)
        doc.editor.deleteAssets([a.id])
        XCTAssertNil(doc.editor.project.audio)
        XCTAssertNil(doc.editor.project.beatCorrections)
        XCTAssertNil(doc.editor.project.cinemascope.startAnchor)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wave.path))
    }

    func testDeletingTheLyricsClearsEveryLyricTrack() {
        var (p, _, _, _) = project()
        let txt = Asset(kind: .lyrics, name: "l.txt", path: "/l.txt")
        p.assets.append(txt)
        p.lyricTracks = [LyricTrack(lines: [LyricLine(start: 1, end: 2, words: [LyricWord(text: "a", start: 1, end: 2, confidence: 0.3)])]),
                         LyricTrack(lines: [LyricLine(start: 1, end: 2, words: [LyricWord(text: "b", start: 1, end: 2)])])]
        p.lyricsLanguage = "tr"
        p.removeAssets([txt.id])
        XCTAssertEqual(p.lyricTracks.count, 1)
        XCTAssertTrue(p.lyricTracks[0].lines.isEmpty)
        XCTAssertNil(p.lyricsLanguage)
    }
}
