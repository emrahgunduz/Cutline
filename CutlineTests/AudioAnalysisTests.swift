import AVFoundation
import XCTest
@testable import Cutline

@MainActor
final class AudioAnalysisTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("analysis"), withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func analysis(hash: String = "abc") -> AudioAnalysis {
        AudioAnalysis(hash: hash, result: .init(duration: 20, tempo: 120, beats: stride(from: 0.5, to: 19.6, by: 0.5).map { $0 },
                                                downbeats: stride(from: 0.5, to: 19.6, by: 2).map { $0 }, onsets: [],
                                                sections: [.init(start: 0, label: "A"), .init(start: 8.5, label: "B")], vocals: "vocals.flac"))
    }

    /// A 2 s sine tone WAV; `frequency` changes the bytes (and so the hash).
    private func tone(_ name: String, frequency: Double = 440) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000)!
        buf.frameLength = 96000
        for i in 0..<96000 { buf.floatChannelData![0][i] = Float(sin(2 * .pi * frequency * Double(i) / 48000) * 0.5) }
        try file.write(from: buf)
        return url
    }

    // MARK: Corrections

    func testMovedDownbeatMovesItsBeat() {
        let a = analysis()
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.moveDownbeat(1, to: 2.6, analysis: a)
        let r = ResolvedBeats(a, p.beatCorrections)
        XCTAssertEqual(r.downbeats[1], 2.6, accuracy: 1e-9)
        XCTAssertTrue(r.beats.contains(2.6))
        XCTAssertFalse(r.beats.contains(2.5))
        XCTAssertEqual(a.downbeats[1], 2.5, "raw analysis is untouched")
    }

    func testDownbeatStaysBetweenNeighbours() {
        let a = analysis()
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.moveDownbeat(1, to: 100, analysis: a)
        XCTAssertLessThan(ResolvedBeats(a, p.beatCorrections).downbeats[1], a.downbeats[2])
    }

    func testCorrectionsForAnotherSongAreIgnored() {
        let a = analysis()
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.moveSectionBoundary(1, to: 10, analysis: a)
        XCTAssertEqual(ResolvedBeats(a, p.beatCorrections).sections[1].start, 10)
        let other = analysis(hash: "other")
        XCTAssertEqual(ResolvedBeats(other, p.beatCorrections).sections[1].start, 8.5)
    }

    func testAddAndRemoveSectionBoundary() {
        let a = analysis()
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.addSectionBoundary(at: 14, analysis: a)
        var s = ResolvedBeats(a, p.beatCorrections).sections
        XCTAssertEqual(s.map(\.start), [0, 8.5, 14])
        XCTAssertEqual(s[2].label, "C")
        p.removeSectionBoundary(1, analysis: a)
        s = ResolvedBeats(a, p.beatCorrections).sections
        XCTAssertEqual(s.map(\.start), [0, 14])
        p.removeSectionBoundary(0, analysis: a)   // the first section can't be removed
        XCTAssertEqual(ResolvedBeats(a, p.beatCorrections).sections.count, 2)
    }

    func testCorrectionsRoundTripInProjectJSON() throws {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.moveDownbeat(2, to: 4.6, analysis: analysis())
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.beatCorrections, p.beatCorrections)
    }

    // MARK: Loudness

    func testLoudAndQuietRegions() {
        // 30 s at 1 bucket per 0.1 s: quiet 0-10 s, normal 10-20 s, loud 20-30 s.
        var rms = [Float](repeating: 0.05, count: 100) + [Float](repeating: 0.2, count: 100) + [Float](repeating: 0.5, count: 100)
        rms[0] = 0.05
        let level = WaveformLevel(samplesPerBucket: 4800, mins: rms.map { -$0 }, maxs: rms, rms: rms)
        let regions = Loudness.regions(Waveform(sampleRate: 48000, levels: [level]))
        XCTAssertEqual(regions.map(\.kind), [.quiet, .loud])
        XCTAssertEqual(regions[0].start, 0, accuracy: 0.01)
        XCTAssertEqual(regions[0].end, 10, accuracy: 1.1)
        XCTAssertEqual(regions[1].start, 20, accuracy: 1.1)
        XCTAssertEqual(regions[1].end, 30, accuracy: 0.01)
    }

    // MARK: Store

    private func store(_ calls: Counter) -> AudioAnalysisStore {
        let folder = dir.appendingPathComponent("analysis")
        return AudioAnalysisStore(folder: { folder }) { wav, _, keep in
            calls.count += 1
            XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path), "decoded WAV is handed to the helper")
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("fake-job-\(UUID())")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try Data("stem".utf8).write(to: out.appendingPathComponent("vocals.flac"))
            let json = #"{"duration":2,"tempo":120,"beats":[0.5,1.0,1.5],"downbeats":[0.5],"onsets":[0.5],"sections":[{"start":0,"label":"A"}],"vocals":"vocals.flac"}"#
            try keep(Data(json.utf8), out)
        }
    }

    final class Counter { var count = 0 }

    func testReopeningWithUnchangedAudioRunsNoJob() async throws {
        let song = Asset(kind: .audio, name: "song.wav", path: try tone("song.wav").path)
        let calls = Counter()
        let first = store(calls)
        first.ensure(for: song)
        await first.wait()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(first.analysis?.beats, [0.5, 1.0, 1.5])
        let hash = try XCTUnwrap(first.analysis?.audioHash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.vocalsURL(hash)!.path), "the stem is kept in analysis/")

        let reopened = store(calls)
        reopened.ensure(for: song)
        await reopened.wait()
        XCTAssertEqual(calls.count, 1, "cached analysis is reused")
        XCTAssertEqual(reopened.analysis, first.analysis)
    }

    func testReplacingTheSongRunsAnalysisAgain() async throws {
        let calls = Counter()
        let s = store(calls)
        let a = Asset(kind: .audio, name: "a.wav", path: try tone("a.wav", frequency: 440).path)
        let b = Asset(kind: .audio, name: "b.wav", path: try tone("b.wav", frequency: 660).path)
        s.ensure(for: a); await s.wait()
        let hashA = s.analysis?.audioHash
        s.ensure(for: b); await s.wait()
        XCTAssertEqual(calls.count, 2)
        XCTAssertNotEqual(s.analysis?.audioHash, hashA)
        s.ensure(for: nil)
        XCTAssertNil(s.analysis)
    }

    func testDecodeWritesStereo44k() async throws {
        let src = try tone("src.wav")
        let wav = dir.appendingPathComponent("decoded.wav")
        try await AudioAnalysisStore.decode(src, to: wav)
        let f = try AVAudioFile(forReading: wav)
        XCTAssertEqual(f.fileFormat.sampleRate, 44100)
        XCTAssertEqual(f.fileFormat.channelCount, 2)
        XCTAssertEqual(Double(f.length) / 44100, 2, accuracy: 0.05)
    }

    /// The real helper on the sample song (slow; runs only with the bundled runtime and sample).
    func testSampleSongAnalysisWithBundledHelper() async throws {
        let wav = JobRunnerTests.repo.appendingPathComponent("Example_Music_Video/Zamansız Yazgılar.wav")
        guard let config = HelperConfig.bundled, FileManager.default.fileExists(atPath: wav.path),
              ProcessInfo.processInfo.environment["CUTLINE_SLOW_TESTS"] != nil else {
            throw XCTSkip("set CUTLINE_SLOW_TESTS=1 with the bundled runtime and sample song")
        }
        let folder = dir.appendingPathComponent("analysis")
        let s = AudioAnalysisStore(folder: { folder }, analyzer: AudioAnalysisStore.helperAnalyzer(JobRunner(config: config)))
        s.ensure(for: Asset(kind: .audio, name: "song", path: wav.path))
        await s.wait()
        let a = try XCTUnwrap(s.analysis, "\(s.state)")
        XCTAssertEqual(a.duration, 225, accuracy: 1)
        XCTAssertGreaterThan(a.beats.count, 300)
        XCTAssertGreaterThan(a.sections.count, 3)
    }
}
