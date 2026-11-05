import XCTest
@testable import Cutline

final class RenderKeyTests: XCTestCase {
    private func project() -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.fps = 24
        let img = Asset(kind: .image, name: "i", path: "/tmp/i.png")
        p.assets = [img]
        _ = p.addClip(assetID: img.id, track: 0, at: 4)        // 4 s ...
        p.videoTracks[0].clips[0].duration = 2                  // ... to 6 s
        p.lyricTracks[0].lines = [LyricLine(start: 10, end: 12, words: [LyricWord(text: "a", start: 10, end: 11), LyricWord(text: "b", start: 11, end: 12)])]
        return p
    }

    private func keys(_ p: Project) -> [String] {
        stride(from: 0.0, to: 16, by: 2).map { RenderKey.key(project: p, start: $0, end: $0 + 2) }
    }

    private func changed(_ a: [String], _ b: [String]) -> [Int] { zip(a, b).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset) }

    func testBrightnessChangesOnlyTheClipsRange() {
        var p = project()
        let before = keys(p)
        p.videoTracks[0].clips[0].filters.color.enabled = true
        p.videoTracks[0].clips[0].filters.color.brightness = 0.2
        XCTAssertEqual(changed(before, keys(p)), [2], "only 4-6 s")
    }

    func testMovingAWordChangesOnlyWhereItWasOrIsVisible() {
        var p = project()
        let before = keys(p)
        p.lyricTracks[0].lines[0].words[1].start = 11.5         // inside 10-12 s
        // The word is visible 11.5-12 s plus its fade-out, which reaches into 12-14 s.
        XCTAssertEqual(changed(before, keys(p)), [5, 6])
    }

    func testEncoderSettingsAreInTheSegmentKey() {
        let p = project()
        var s = ExportSettings.defaults(for: p)
        let a = RenderKey.key(project: p, start: 0, end: 2, encoder: RenderKey.encoder(s))
        s.rateMode = .bitrate; s.bitrateMbps = 10
        XCTAssertNotEqual(a, RenderKey.key(project: p, start: 0, end: 2, encoder: RenderKey.encoder(s)))
        XCTAssertNotEqual(a, RenderKey.key(project: p, start: 0, end: 2), "preview frames don't share segment keys")
    }

    func testKeysAreStableAcrossCalls() {
        XCTAssertEqual(keys(project()).count, Set(keys(project())).count)
        let p = project()
        XCTAssertEqual(keys(p), keys(p))
    }
}
