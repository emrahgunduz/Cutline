import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation

// MARK: - Model

struct SongSection: Codable, Equatable {
    var start: Double
    var label: String
}

/// Raw analysis of one song file, stored as `analysis/audio-<hash>.json` (KTD6).
/// Times are seconds into the audio file, not timeline time.
struct AudioAnalysis: Codable, Equatable {
    static let currentVersion = 1
    var version = AudioAnalysis.currentVersion
    var audioHash: String
    var duration: Double
    var tempo: Double
    var beats: [Double]
    var downbeats: [Double]
    /// Vocal onsets, for tap snapping (U11).
    var onsets: [Double]
    var sections: [SongSection]

    /// The helper's `analyze_audio` result.
    struct HelperResult: Decodable {
        var duration: Double
        var tempo: Double
        var beats: [Double]
        var downbeats: [Double]
        var onsets: [Double]
        var sections: [SongSection]
        var vocals: String
    }

    init(hash: String, result r: HelperResult) {
        audioHash = hash; duration = r.duration; tempo = r.tempo
        beats = r.beats; downbeats = r.downbeats; onsets = r.onsets; sections = r.sections
    }
}

/// The user's fixes to the analysis, kept apart from it in `project.json` (undoable).
/// They belong to one audio file; a different song ignores them.
struct BeatCorrections: Codable, Equatable {
    struct MovedDownbeat: Codable, Equatable { var index: Int; var time: Double }
    var audioHash: String
    var movedDownbeats: [MovedDownbeat] = []
    /// When set, replaces the analysed section list (boundaries added, moved or removed).
    var sections: [SongSection]?
}

/// Analysis with corrections applied: what the timeline draws and snaps to.
struct ResolvedBeats: Equatable {
    var beats: [Double]
    var downbeats: [Double]
    var sections: [SongSection]
    var onsets: [Double]

    init(_ a: AudioAnalysis, _ c: BeatCorrections?) {
        var beats = a.beats, downs = a.downbeats
        if let c, c.audioHash == a.audioHash {
            for m in c.movedDownbeats where downs.indices.contains(m.index) {
                let old = downs[m.index]
                // Landing on an existing beat re-marks that beat as the downbeat and leaves the
                // beat grid alone. Landing between beats moves the downbeat's own beat with it.
                let landsOnBeat = beats.contains { abs($0 - m.time) < 0.001 }
                if !landsOnBeat, let b = beats.indices.min(by: { abs(beats[$0] - old) < abs(beats[$1] - old) }), abs(beats[b] - old) < 0.05 {
                    beats[b] = m.time
                }
                downs[m.index] = m.time
            }
        }
        beats.sort()
        // Never two beats at the same moment.
        self.beats = beats.enumerated().filter { $0.offset == 0 || $0.element - beats[$0.offset - 1] > 0.001 }.map(\.element)
        self.downbeats = downs
        if let c, c.audioHash == a.audioHash, let s = c.sections { sections = s } else { sections = a.sections }
        onsets = a.onsets
    }
}

extension Project {
    /// Corrections for the current song (nil when they belong to another file).
    func corrections(for hash: String) -> BeatCorrections {
        if let c = beatCorrections, c.audioHash == hash { return c }
        return BeatCorrections(audioHash: hash)
    }

    mutating func moveDownbeat(_ index: Int, to time: Double, analysis a: AudioAnalysis) {
        var c = corrections(for: a.audioHash)
        let lo = index > 0 ? ResolvedBeats(a, c).downbeats[index - 1] + 0.05 : 0
        let hi = index < a.downbeats.count - 1 ? ResolvedBeats(a, c).downbeats[index + 1] - 0.05 : a.duration
        var t = min(max(time, lo), hi)
        c.movedDownbeats.removeAll { $0.index == index }
        // Within 50 ms of a beat: land exactly on it (that beat becomes the downbeat).
        let grid = ResolvedBeats(a, c).beats
        if let near = grid.min(by: { abs($0 - t) < abs($1 - t) }), abs(near - t) < 0.05, near >= lo, near <= hi { t = near }
        if abs(t - a.downbeats[index]) > 1e-4 { c.movedDownbeats.append(.init(index: index, time: t)) }
        beatCorrections = c
        followAnchors(ResolvedBeats(a, c), hash: a.audioHash)
    }

    /// Move boundary `index` (1...count-1; section 0 always starts at 0) between its neighbours.
    mutating func moveSectionBoundary(_ index: Int, to time: Double, analysis a: AudioAnalysis) {
        var c = corrections(for: a.audioHash)
        var s = ResolvedBeats(a, c).sections
        guard index > 0, s.indices.contains(index) else { return }
        let lo = s[index - 1].start + 0.5
        let hi = index + 1 < s.count ? s[index + 1].start - 0.5 : a.duration - 0.5
        s[index].start = min(max(time, lo), hi)
        c.sections = s
        beatCorrections = c
        followAnchors(ResolvedBeats(a, c), hash: a.audioHash)
    }

    mutating func addSectionBoundary(at time: Double, analysis a: AudioAnalysis) {
        var c = corrections(for: a.audioHash)
        var s = ResolvedBeats(a, c).sections
        guard time > 0.5, time < a.duration - 0.5, !s.contains(where: { abs($0.start - time) < 0.5 }) else { return }
        let used = Set(s.map(\.label))
        let label = (0..<26).map { String(UnicodeScalar(UInt8(65 + $0))) }.first { !used.contains($0) } ?? "?"
        s.append(SongSection(start: time, label: label))
        s.sort { $0.start < $1.start }
        c.sections = s
        beatCorrections = c
        // Markers anchored to later sections keep pointing at the same section.
        if let inserted = s.firstIndex(where: { $0.start == time }) { shiftSectionAnchors(from: inserted, by: 1) }
        followAnchors(ResolvedBeats(a, c), hash: a.audioHash)
    }

    /// Section anchors at `index` or later move by `delta` after a boundary is added or removed.
    private mutating func shiftSectionAnchors(from index: Int, by delta: Int) {
        if var s = cinemascope.startAnchor, s.kind == .section, s.index >= index { s.index += delta; cinemascope.startAnchor = s }
        if var e = cinemascope.endAnchor, e.kind == .section, e.index >= index { e.index += delta; cinemascope.endAnchor = e }
    }

    mutating func removeSectionBoundary(_ index: Int, analysis a: AudioAnalysis) {
        var c = corrections(for: a.audioHash)
        var s = ResolvedBeats(a, c).sections
        guard index > 0, s.indices.contains(index) else { return }
        s.remove(at: index)
        c.sections = s
        beatCorrections = c
        // A marker on the removed boundary stays where it is, tied to the nearest beat now;
        // markers on later sections keep pointing at the same section.
        let resolved = ResolvedBeats(a, c)
        if let audio {
            if cinemascope.startAnchor?.kind == .section, cinemascope.startAnchor?.index == index {
                cinemascope.startAnchor = resolved.anchor(at: cinemascope.startMarker - audio.start, hash: a.audioHash)
            }
            if cinemascope.endAnchor?.kind == .section, cinemascope.endAnchor?.index == index {
                cinemascope.endAnchor = resolved.anchor(at: cinemascope.endMarker - audio.start, hash: a.audioHash)
            }
        }
        shiftSectionAnchors(from: index + 1, by: -1)
        followAnchors(resolved, hash: a.audioHash)
    }
}

// MARK: - Loud and quiet regions

/// Loud and quiet stretches of the song from the waveform's RMS envelope (R13).
enum Loudness {
    enum Kind: Equatable { case loud, quiet }
    struct Region: Equatable { var start: Double; var end: Double; var kind: Kind }

    /// The song's loudness over time (RMS smoothed over a couple of seconds) and the two
    /// levels that define the patches: above `loudLevel` is loud, below `quietLevel` quiet.
    struct Envelope: Equatable {
        /// Seconds per value (audio-file time).
        var bucket: Double
        var values: [Float]
        var loudLevel: Float
        var quietLevel: Float
        /// The highest value, for scaling the curve.
        var peak: Float

        var duration: Double { Double(values.count) * bucket }

        /// The loudness at `t` seconds into the audio file (0 outside it).
        func value(at t: Double) -> Float {
            guard bucket > 0, t >= 0 else { return 0 }
            let i = Int(t / bucket)
            return i < values.count ? values[i] : 0
        }

        /// Fraction of the lane's height (0 = silent, 1 = the loudest moment) for a value.
        func height(_ v: Float) -> CGFloat { peak > 0 ? CGFloat(min(1, max(0, v / peak))) : 0 }
    }

    /// Smooth the RMS over `window` seconds; above `loud`× the median is loud, below
    /// `quiet`× is quiet.
    static func envelope(_ wf: Waveform, window: Double = 2, loud: Float = 1.35, quiet: Float = 0.6) -> Envelope? {
        guard let level = wf.levels.last, !level.rms.isEmpty else { return nil }
        let bucket = Double(level.samplesPerBucket) / wf.sampleRate
        let rms = level.rms
        let half = max(1, Int(window / bucket / 2))
        var smooth = [Float](repeating: 0, count: rms.count)
        var sum: Float = 0
        var lo = 0, hi = -1
        for i in rms.indices {
            while hi < min(rms.count - 1, i + half) { hi += 1; sum += rms[hi] }
            while lo < i - half { sum -= rms[lo]; lo += 1 }
            smooth[i] = sum / Float(hi - lo + 1)
        }
        let audible = smooth.filter { $0 > 1e-4 }.sorted()
        guard !audible.isEmpty else { return nil }
        let median = audible[audible.count / 2]
        return Envelope(bucket: bucket, values: smooth, loudLevel: median * loud, quietLevel: median * quiet, peak: smooth.max() ?? 0)
    }

    /// Stretches where the envelope stays above the loud level or below the quiet level for
    /// at least `minLength` seconds.
    static func regions(_ e: Envelope, minLength: Double = 2) -> [Region] {
        let smooth = e.values, bucket = e.bucket
        guard !smooth.isEmpty else { return [] }
        func kind(_ v: Float) -> Kind? { v > e.loudLevel ? .loud : (v < e.quietLevel ? .quiet : nil) }
        var out: [Region] = []
        var runStart = 0, runKind = kind(smooth[0])
        for i in 1...smooth.count {
            let k = i < smooth.count ? kind(smooth[i]) : nil
            if i == smooth.count || k != runKind {
                if let rk = runKind, Double(i - runStart) * bucket >= minLength {
                    out.append(Region(start: Double(runStart) * bucket, end: min(Double(i) * bucket, e.duration), kind: rk))
                }
                runStart = i; runKind = k
            }
        }
        return out
    }

    static func regions(_ wf: Waveform, window: Double = 2, loud: Float = 1.35, quiet: Float = 0.6, minLength: Double = 2) -> [Region] {
        envelope(wf, window: window, loud: loud, quiet: quiet).map { regions($0, minLength: minLength) } ?? []
    }
}

// MARK: - Store

/// Analysis for the project's song: loads it from `analysis/` when the file is unchanged,
/// otherwise runs the helper once and saves the result there (keyed by file hash).
@MainActor
final class AudioAnalysisStore: ObservableObject {
    enum State: Equatable { case idle, running, failed(String), unavailable }

    @Published private(set) var analysis: AudioAnalysis?
    @Published private(set) var loudness: [Loudness.Region] = []
    /// The loudness curve the regions come from (drawn over the waveform).
    @Published private(set) var loudnessEnvelope: Loudness.Envelope?
    @Published private(set) var state: State = .idle

    /// Runs the helper on a decoded WAV; `keep` receives the result JSON and output folder.
    typealias Analyzer = (_ wav: URL, _ stanzaStarts: [Double], _ keep: (Data, URL) throws -> Void) async throws -> Void

    private let folder: () -> URL?
    private let analyzer: Analyzer
    private var task: Task<Void, Never>?
    private var currentAssetID: UUID?
    /// Number of helper runs started (for tests).
    private(set) var jobsStarted = 0

    nonisolated init(folder: @escaping () -> URL?, analyzer: @escaping Analyzer) {
        self.folder = folder
        self.analyzer = analyzer
    }

    /// The helper-backed analyzer.
    nonisolated static func helperAnalyzer(_ jobs: JobRunner) -> Analyzer {
        { wav, stanzas, keep in
            try await jobs.run("Analyzing song", command: "analyze_audio", args: ["audio": wav.path, "stanza_starts": stanzas]) { data, out in
                try keep(data, out)
            }
        }
    }

    /// Show the analysis for `asset` (nil clears it), running the helper if needed.
    func ensure(for asset: Asset?, stanzaStarts: [Double] = [], force: Bool = false) {
        guard let asset else { task?.cancel(); task = nil; currentAssetID = nil; analysis = nil; state = .idle; return }
        if !force, asset.id == currentAssetID, analysis != nil || state == .running { return }
        task?.cancel()
        if asset.id != currentAssetID { analysis = nil }
        currentAssetID = asset.id
        let url = asset.url
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let hash = try await Task.detached(priority: .utility) { try Self.hash(of: url) }.value
                try Task.checkCancellation()
                if !force, let cached = self.load(hash: hash) { self.analysis = cached; self.state = .idle; return }
                // Re-analysing the same song keeps the old result on screen until the new one
                // lands (or the run is cancelled).
                if !force || self.analysis?.audioHash != hash { self.analysis = nil }
                self.state = .running
                self.jobsStarted += 1
                let wav = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-decode-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: wav) }
                try await Task.detached(priority: .utility) { try await Self.decode(url, to: wav) }.value
                var result: AudioAnalysis?
                try await self.analyzer(wav, stanzaStarts) { data, out in
                    result = try self.save(data, outputDir: out, hash: hash)
                }
                try Task.checkCancellation()
                self.analysis = result
                self.state = .idle
            } catch is CancellationError {
                if self.currentAssetID == asset.id { self.state = .idle }
            } catch HelperError.notInstalled {
                self.state = .unavailable
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { task?.cancel(); task = nil; if state == .running { state = .idle } }

    /// Show an analysis directly (tests and previews; normal use goes through ensure).
    func adopt(_ a: AudioAnalysis) { analysis = a; state = .idle }

    func updateLoudness(_ wf: Waveform?) {
        loudnessEnvelope = wf.flatMap { Loudness.envelope($0) }
        loudness = loudnessEnvelope.map { Loudness.regions($0) } ?? []
    }

    /// Wait for the current load or job (tests).
    func wait() async { await task?.value }

    // MARK: Files

    private func jsonURL(_ hash: String) -> URL? { folder()?.appendingPathComponent("audio-\(hash).json") }
    func vocalsURL(_ hash: String) -> URL? { folder()?.appendingPathComponent("vocals-\(hash).flac") }

    private func load(hash: String) -> AudioAnalysis? {
        guard let url = jsonURL(hash), let data = try? Data(contentsOf: url),
              let a = try? JSONDecoder().decode(AudioAnalysis.self, from: data),
              a.version == AudioAnalysis.currentVersion, a.audioHash == hash else { return nil }
        return a
    }

    private func save(_ data: Data, outputDir: URL, hash: String) throws -> AudioAnalysis {
        let r = try JSONDecoder().decode(AudioAnalysis.HelperResult.self, from: data)
        let a = AudioAnalysis(hash: hash, result: r)
        guard let json = jsonURL(hash), let vocals = vocalsURL(hash) else { return a }
        let fm = FileManager.default
        let stem = outputDir.appendingPathComponent(r.vocals)
        if fm.fileExists(atPath: stem.path) {
            try? fm.removeItem(at: vocals)
            try fm.moveItem(at: stem, to: vocals)
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        try enc.encode(a).write(to: json, options: .atomic)
        return a
    }

    // MARK: Helpers

    /// SHA-256 of the file's bytes (first 16 hex digits are plenty for a cache key).
    nonisolated static func hash(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var sha = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Decode any audio AVFoundation reads into a 44.1 kHz stereo float WAV the helper can load.
    nonisolated static func decode(_ url: URL, to wav: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                       AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                                       AVLinearPCMIsBigEndianKey: false,
                                       AVNumberOfChannelsKey: 2, AVSampleRateKey: 44100]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: true)!
        let file = try AVAudioFile(forWriting: wav, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let frames = AVAudioFrameCount(length / 8)
            guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            buf.frameLength = frames
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buf.audioBufferList.pointee.mBuffers.mData!)
            try file.write(from: buf)
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
    }
}
