import AVFoundation
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
                // The downbeat is also a beat: move that beat with it.
                if let b = beats.indices.min(by: { abs(beats[$0] - old) < abs(beats[$1] - old) }), abs(beats[b] - old) < 0.05 { beats[b] = m.time }
                downs[m.index] = m.time
            }
        }
        self.beats = beats.sorted()
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
        let t = min(max(time, lo), hi)
        c.movedDownbeats.removeAll { $0.index == index }
        if abs(t - a.downbeats[index]) > 1e-4 { c.movedDownbeats.append(.init(index: index, time: t)) }
        beatCorrections = c
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
    }

    mutating func removeSectionBoundary(_ index: Int, analysis a: AudioAnalysis) {
        var c = corrections(for: a.audioHash)
        var s = ResolvedBeats(a, c).sections
        guard index > 0, s.indices.contains(index) else { return }
        s.remove(at: index)
        c.sections = s
        beatCorrections = c
    }
}

// MARK: - Loud and quiet regions

/// Loud and quiet stretches of the song from the waveform's RMS envelope (R13).
enum Loudness {
    enum Kind: Equatable { case loud, quiet }
    struct Region: Equatable { var start: Double; var end: Double; var kind: Kind }

    /// Smooth the RMS over `window` seconds; above `loud`× the median is loud, below
    /// `quiet`× is quiet. Regions shorter than `minLength` are dropped.
    static func regions(_ wf: Waveform, window: Double = 2, loud: Float = 1.35, quiet: Float = 0.6, minLength: Double = 2) -> [Region] {
        guard let level = wf.levels.last, !level.rms.isEmpty else { return [] }
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
        guard !audible.isEmpty else { return [] }
        let median = audible[audible.count / 2]
        func kind(_ v: Float) -> Kind? { v > median * loud ? .loud : (v < median * quiet ? .quiet : nil) }
        var out: [Region] = []
        var runStart = 0, runKind = kind(smooth[0])
        for i in 1...smooth.count {
            let k = i < smooth.count ? kind(smooth[i]) : nil
            if i == smooth.count || k != runKind {
                if let rk = runKind, Double(i - runStart) * bucket >= minLength {
                    out.append(Region(start: Double(runStart) * bucket, end: min(Double(i) * bucket, Double(rms.count) * bucket), kind: rk))
                }
                runStart = i; runKind = k
            }
        }
        return out
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
                self.analysis = nil
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

    func updateLoudness(_ wf: Waveform?) { loudness = wf.map { Loudness.regions($0) } ?? [] }

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
