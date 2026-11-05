import AVFoundation
import Accelerate

/// One zoom level of the waveform: min/max/RMS per bucket of `samplesPerBucket` mono samples.
struct WaveformLevel: Codable, Equatable {
    var samplesPerBucket: Int
    var mins: [Float]
    var maxs: [Float]
    var rms: [Float]
}

struct Waveform: Codable, Equatable {
    var sampleRate: Double
    var levels: [WaveformLevel]

    /// The coarsest level that still gives at least one bucket per `secondsPerPixel`.
    func level(secondsPerPixel: Double) -> WaveformLevel? {
        let samplesPerPixel = secondsPerPixel * sampleRate
        return levels.last { Double($0.samplesPerBucket) <= samplesPerPixel } ?? levels.first
    }
}

enum WaveformBuilder {
    static let bucketSizes = [256, 2048, 16384]

    static func build(url: URL) async throws -> Waveform {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return Waveform(sampleRate: 48000, levels: [])
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                       AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                                       AVNumberOfChannelsKey: 1]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        var sampleRate = 48000.0
        if let desc = try await track.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
            sampleRate = asbd.pointee.mSampleRate
        }
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples.append(contentsOf: chunk)
        }
        if reader.status == .failed, let e = reader.error { throw e }
        return Waveform(sampleRate: sampleRate, levels: bucketSizes.map { level(samples, bucket: $0) })
    }

    static func level(_ samples: [Float], bucket: Int) -> WaveformLevel {
        let count = (samples.count + bucket - 1) / bucket
        var mins = [Float](repeating: 0, count: count), maxs = mins, rms = mins
        samples.withUnsafeBufferPointer { ptr in
            for i in 0..<count {
                let start = i * bucket
                let n = min(bucket, samples.count - start)
                let p = ptr.baseAddress! + start
                vDSP_minv(p, 1, &mins[i], vDSP_Length(n))
                vDSP_maxv(p, 1, &maxs[i], vDSP_Length(n))
                vDSP_rmsqv(p, 1, &rms[i], vDSP_Length(n))
            }
        }
        return WaveformLevel(samplesPerBucket: bucket, mins: mins, maxs: maxs, rms: rms)
    }
}

/// Waveforms per audio asset, cached in `analysis/`.
final class WaveformStore: ObservableObject {
    @Published private(set) var waveforms: [UUID: Waveform] = [:]
    private let folder: () -> URL?
    init(folder: @escaping () -> URL?) { self.folder = folder }

    /// Forget the waveforms in memory (Reset Media Caches rebuilds them).
    @MainActor
    func removeAll() { waveforms = [:] }

    @MainActor
    func ensureWaveform(for asset: Asset) async {
        if waveforms[asset.id] != nil { return }
        let url = folder()?.appendingPathComponent("waveform-\(asset.id.uuidString).plist")
        if let url, let data = try? Data(contentsOf: url), let w = try? PropertyListDecoder().decode(Waveform.self, from: data) {
            waveforms[asset.id] = w; return
        }
        guard let w = try? await WaveformBuilder.build(url: asset.url) else { return }
        if let url {
            let enc = PropertyListEncoder(); enc.outputFormat = .binary
            try? enc.encode(w).write(to: url, options: .atomic)
        }
        waveforms[asset.id] = w
    }
}
