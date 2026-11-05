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

    private func steppedWaveform() -> Waveform {
        // 30 s at 1 bucket per 0.1 s: quiet 0-10 s, normal 10-20 s, loud 20-30 s.
        let rms = [Float](repeating: 0.05, count: 100) + [Float](repeating: 0.2, count: 100) + [Float](repeating: 0.5, count: 100)
        return Waveform(sampleRate: 48000, levels: [WaveformLevel(samplesPerBucket: 4800, mins: rms.map { -$0 }, maxs: rms, rms: rms)])
    }

    func testTheEnvelopeIsTheCurveThePatchesComeFrom() throws {
        let e = try XCTUnwrap(Loudness.envelope(steppedWaveform()))
        XCTAssertEqual(e.bucket, 0.1, accuracy: 1e-9)
        XCTAssertEqual(e.duration, 30, accuracy: 1e-6)
        XCTAssertEqual(e.value(at: 5), 0.05, accuracy: 1e-6)
        XCTAssertEqual(e.value(at: 25), 0.5, accuracy: 1e-6)
        XCTAssertEqual(e.value(at: 99), 0, "past the end is silent")
        XCTAssertGreaterThan(e.loudLevel, e.quietLevel)
        XCTAssertEqual(e.peak, 0.5, accuracy: 1e-6)
        // Every patch is where the curve is past its line.
        for r in Loudness.regions(e) {
            for t in stride(from: r.start + 0.05, to: r.end, by: 0.1) {
                if r.kind == .loud { XCTAssertGreaterThan(e.value(at: t), e.loudLevel, "\(t)") }
                else { XCTAssertLessThan(e.value(at: t), e.quietLevel, "\(t)") }
            }
        }
        XCTAssertEqual(Loudness.regions(e), Loudness.regions(steppedWaveform()), "same patches either way")
    }

    func testTheCurveIsScaledToTheLoudestMoment() throws {
        let e = try XCTUnwrap(Loudness.envelope(steppedWaveform()))
        XCTAssertEqual(e.height(e.peak), 1)
        XCTAssertEqual(e.height(0), 0)
        XCTAssertEqual(e.height(e.peak * 2), 1, "clamped")
    }

    func testTheCurveAndLevelsUseTheWaveformsScale() throws {
        let e = try XCTUnwrap(Loudness.envelope(steppedWaveform()))
        let wave = CGRect(x: 0, y: 20, width: 100, height: 68)      // centre 54, half 34 - 4 padding = 30
        let loud = SectionLane.amplitudeY(e.loudLevel, in: wave), quiet = SectionLane.amplitudeY(e.quietLevel, in: wave)
        // An amplitude sits where the waveform draws it: centre ± value × half.
        XCTAssertEqual(loud.top, 54 - CGFloat(e.loudLevel) * 30, accuracy: 1e-6)
        XCTAssertEqual(loud.bottom, 54 + CGFloat(e.loudLevel) * 30, accuracy: 1e-6)
        XCTAssertEqual((loud.top + loud.bottom) / 2, wave.midY, accuracy: 1e-6, "mirrored around the waveform's centre")
        XCTAssertEqual((quiet.top + quiet.bottom) / 2, wave.midY, accuracy: 1e-6)
        XCTAssertLessThan(loud.top, quiet.top, "the loud level is further from the centre")
        // The curve at a moment is exactly the RMS the waveform draws there (smoothing aside).
        let rms: Float = 0.5
        XCTAssertEqual(SectionLane.amplitudeY(e.value(at: 25), in: wave).top, SectionLane.amplitudeY(rms, in: wave).top, accuracy: 1e-3)
        XCTAssertEqual(SectionLane.amplitudeY(2, in: wave).top, wave.midY - 30, "clamped to the lane")
    }

    func testTheLoudestAverageLevelFillsTheRow() throws {
        let wf = steppedWaveform()                       // loudest RMS 0.5
        XCTAssertEqual(wf.peakRMS, 0.5, accuracy: 1e-6)
        XCTAssertEqual(wf.displayGain, 1.8, accuracy: 1e-6)
        let wave = CGRect(x: 0, y: 0, width: 100, height: 64)   // half 32 - 4 padding = 28
        XCTAssertEqual(SectionLane.amplitudeY(wf.peakRMS, gain: wf.displayGain, in: wave).top, wave.midY - 28 * 0.9, accuracy: 1e-3,
                       "without a curve, the loudest average level reaches 90% of the row")
        XCTAssertEqual(SectionLane.amplitudeY(0.9, gain: wf.displayGain, in: wave).top, wave.midY - 28, accuracy: 1e-6, "louder peaks stop at the padding")
        // The curve and the levels get the same gain as the waveform.
        let e = try XCTUnwrap(Loudness.envelope(wf))
        XCTAssertEqual(SectionLane.amplitudeY(e.loudLevel, gain: 2, in: wave).top, SectionLane.amplitudeY(e.loudLevel * 2, in: wave).top, accuracy: 1e-6)
    }

    func testTheCurvesLoudestMomentFillsTheRowWithAMargin() throws {
        let e = try XCTUnwrap(Loudness.envelope(steppedWaveform()))
        let wave = CGRect(x: 0, y: 0, width: 100, height: 108)  // half 54 - 4 padding = 50
        let gain = e.displayGain()
        let top = SectionLane.amplitudeY(e.peak, gain: gain, in: wave).top
        XCTAssertEqual(top, wave.midY - 50 * 0.92, accuracy: 1e-3, "the curve's loudest moment reaches 92%")
        XCTAssertGreaterThan(top, wave.minY + SectionLane.wavePadding, "with a margin from the top")
        let quiet = SectionLane.amplitudeY(e.quietLevel, gain: gain, in: wave)
        XCTAssertGreaterThan(quiet.bottom - quiet.top, 10, "the quiet level is spread out, not squeezed at the centre")
        XCTAssertEqual(Loudness.Envelope(bucket: 1, values: [0], loudLevel: 0, quietLevel: 0, peak: 0).displayGain(), 1)
    }

    func testTheWaveformsHighestPeakFitsInsideTheRow() {
        let wf = steppedWaveform()                       // highest peak 0.5
        XCTAssertEqual(wf.peakFitGain, 2, accuracy: 1e-6)
        let wave = CGRect(x: 0, y: 0, width: 100, height: 64)
        let y = SectionLane.amplitudeY(wf.peakAmplitude, gain: wf.peakFitGain, in: wave)
        XCTAssertEqual(y.top, wave.minY + SectionLane.wavePadding, accuracy: 1e-3, "touches the top margin, never past it")
        XCTAssertEqual(y.bottom, wave.maxY - SectionLane.wavePadding, accuracy: 1e-3)
        let full: [Float] = [0.99, 0.5]
        let mastered = Waveform(sampleRate: 48000, levels: [WaveformLevel(samplesPerBucket: 1, mins: full.map { -$0 }, maxs: full, rms: [0.38, 0.2])])
        XCTAssertLessThanOrEqual(mastered.peakFitGain * 0.99, 1.0001, "a loud master isn't pushed out of the row")
        XCTAssertEqual(Waveform(sampleRate: 48000, levels: []).peakFitGain, 1)
    }

    func testTheGainIsCappedAndSilenceIsLeftAlone() {
        let tiny: [Float] = [0.001, 0.002]
        XCTAssertEqual(Waveform(sampleRate: 48000, levels: [WaveformLevel(samplesPerBucket: 1, mins: tiny.map { -$0 }, maxs: tiny, rms: tiny)]).displayGain, 20)
        XCTAssertEqual(Waveform(sampleRate: 48000, levels: []).displayGain, 1)
        let full: [Float] = [1, 0.9]
        XCTAssertEqual(Waveform(sampleRate: 48000, levels: [WaveformLevel(samplesPerBucket: 1, mins: full.map { -$0 }, maxs: full, rms: full)]).displayGain, 0.9, accuracy: 1e-6)
    }

    func testSilenceHasNoEnvelope() {
        let rms = [Float](repeating: 0, count: 50)
        XCTAssertNil(Loudness.envelope(Waveform(sampleRate: 48000, levels: [WaveformLevel(samplesPerBucket: 4800, mins: rms, maxs: rms, rms: rms)])))
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

    func testCancelledReanalysisKeepsTheOldResult() async throws {
        let song = Asset(kind: .audio, name: "song.wav", path: try tone("song.wav").path)
        let calls = Counter()
        let s = store(calls)
        s.ensure(for: song); await s.wait()
        let first = try XCTUnwrap(s.analysis)
        s.ensure(for: song, force: true)
        s.cancel()
        await s.wait()
        XCTAssertEqual(s.analysis, first)
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
