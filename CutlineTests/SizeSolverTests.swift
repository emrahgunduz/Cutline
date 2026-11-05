import XCTest
@testable import Cutline

final class SizeSolverTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/x.mp4")

    func testBitrateForA20MBThirtySecondAd() {
        // (20 MB × 8 − 320 kbit/s × 30 s) / 30 s × 0.95
        let b = SizeSolver.videoBitrate(targetBytes: 20_000_000, duration: 30, audioKbps: 320)
        XCTAssertEqual(b, (160_000_000 - 9_600_000) / 30 * 0.95, accuracy: 1)
        XCTAssertEqual(b / 1_000_000, 4.76, accuracy: 0.01)
    }

    /// AE4: a first result 3% over triggers one corrected re-encode without user action.
    func testOvershootTriggersOneCorrectedPass() async throws {
        var bitrates: [Double] = []
        let outcome = try await SizeSolver.run(targetBytes: 20_000_000, duration: 30, audioKbps: 320) { bitrate, pass in
            bitrates.append(bitrate)
            return SizeSolver.Attempt(bitrate: bitrate, bytes: pass == 0 ? 20_600_000 : 19_400_000, url: self.url)
        }
        XCTAssertEqual(outcome.attempts.count, 2)
        XCTAssertTrue(outcome.met)
        XCTAssertEqual(outcome.best.bytes, 19_400_000)
        XCTAssertEqual(bitrates[1], bitrates[0] * 20_000_000 / 20_600_000 * 0.97, accuracy: 1)
    }

    func testFirstPassThatFitsStops() async throws {
        let outcome = try await SizeSolver.run(targetBytes: 20_000_000, duration: 30, audioKbps: 320) { b, _ in
            SizeSolver.Attempt(bitrate: b, bytes: 18_900_000, url: self.url)
        }
        XCTAssertEqual(outcome.attempts.count, 1)
        XCTAssertTrue(outcome.met)
    }

    func testStillOverAfterTwoRetriesReportsFailureAndKeepsTheSmallest() async throws {
        let sizes: [Int64] = [22_000_000, 21_000_000, 20_400_000]
        let outcome = try await SizeSolver.run(targetBytes: 20_000_000, duration: 30, audioKbps: 320) { b, pass in
            SizeSolver.Attempt(bitrate: b, bytes: sizes[pass], url: URL(fileURLWithPath: "/tmp/\(pass).mp4"))
        }
        XCTAssertEqual(outcome.attempts.count, 3, "first pass plus two retries")
        XCTAssertFalse(outcome.met)
        XCTAssertEqual(outcome.best.bytes, 20_400_000)
    }

    func testTargetTooSmallForTheLengthIsRefused() async {
        do {
            _ = try await SizeSolver.run(targetBytes: 1_000_000, duration: 30, audioKbps: 320) { b, _ in
                SizeSolver.Attempt(bitrate: b, bytes: 1, url: self.url)
            }
            XCTFail("expected targetTooSmall")
        } catch let e as SizeSolver.Failure {
            guard case .targetTooSmall(let mb) = e else { return XCTFail() }
            XCTAssertGreaterThan(mb, 1)
        } catch { XCTFail("\(error)") }
    }

    func testAdDefaultsToTheSizeTargetAndSettingsAreRemembered() throws {
        var p = Project(type: .ad, canvas: .init(width: 1080, height: 1920))
        let d = ExportSettings.defaults(for: p)
        XCTAssertEqual(d.rateMode, .size)
        XCTAssertEqual(d.sizeTargetMB, Presets.preset(for: .ad).defaultSizeTargetMB)
        var mine = d
        mine.sizeTargetMB = 20
        p.exportSettings = mine
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(ExportSettings.defaults(for: back).sizeTargetMB, 20)
        XCTAssertEqual(ExportSettings.defaults(for: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))).rateMode, .quality)
    }
}

final class LengthLimitTests: XCTestCase {
    /// An ad whose content ends at 31.4 s: song from 0, downbeats every 2 s, a lyric line ending at 29.3 s.
    private func overlongAd() -> (Project, ResolvedBeats) {
        var p = Project(type: .ad, canvas: .init(width: 1080, height: 1920))
        p.fps = 24
        let song = Asset(kind: .audio, name: "s", path: "/s", duration: 31.4)
        let img = Asset(kind: .image, name: "i", path: "/i")
        p.assets = [song, img]
        p.setAudio(assetID: song.id)
        _ = p.addClip(assetID: img.id, track: 0, at: 25)
        p.videoTracks[0].clips[0].duration = 6.4
        p.lyricTracks[0].lines = [
            LyricLine(start: 20, end: 29.3, words: [LyricWord(text: "a", start: 20, end: 29.3)]),
            LyricLine(start: 30.5, end: 31.2, words: [LyricWord(text: "b", start: 30.5, end: 31.2)]),
        ]
        let a = AudioAnalysis(hash: "h", result: .init(duration: 31.4, tempo: 120, beats: [], downbeats: stride(from: 0, to: 31.4, by: 2).map { $0 },
                                                       onsets: [], sections: [], vocals: ""))
        return (p, ResolvedBeats(a, nil))
    }

    /// AE3: the trim ends on the last downbeat or lyric-line end at or before 30 s.
    func testTrimLandsOnTheLastDownbeatOrLineEndBeforeTheLimit() {
        var (p, beats) = overlongAd()
        XCTAssertTrue(p.isOverLimit)
        let end = p.trimPoint(limit: 30, beats: beats)
        XCTAssertEqual(end, 30)                                   // the downbeat at 30 s beats the line end at 29.3 s
        p.trim(to: end)
        XCTAssertEqual(p.duration, 30, accuracy: 1e-9)
        XCTAssertFalse(p.isOverLimit)
        XCTAssertEqual(p.lyricTracks[0].lines.count, 1, "the line after the limit is gone")
        XCTAssertEqual(p.videoTracks[0].clips[0].end, 30, accuracy: 1e-9, "the crossing clip is shortened")
    }

    func testWithoutDownbeatsTheLastLineEndWins() {
        let (p, _) = overlongAd()
        XCTAssertEqual(p.trimPoint(limit: 30, beats: nil), p.quantize(29.3))
    }

    func testMusicVideosHaveNoLimit() {
        let p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        XCTAssertNil(p.lengthLimit)
        XCTAssertFalse(p.isOverLimit)
    }
}
