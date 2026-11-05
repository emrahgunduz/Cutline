import AVFoundation
import CryptoKit

/// Export through reusable segments (KTD11, R34): the video is cut into ~2 s segments, each
/// encoded on its own (closed GOP, a keyframe at its start) into `cache/segments/` under its
/// content key. A re-export reuses every segment whose key is unchanged and a cancelled export
/// keeps the finished ones. The audio is encoded once for the whole length, then video and
/// audio are joined without re-encoding.
final class SegmentExporter {
    static let segmentSeconds = 2.0

    struct Segment: Equatable {
        var index: Int
        var start: Double
        var end: Double
        var key: String
        var fileName: String { "\(index)-\(key).mov" }
    }

    struct Stats: Equatable { var encoded: Int; var reused: Int }

    let cacheDir: URL
    /// Segments encoded at the same time. Each runs its own decode, render and hardware
    /// encode, so several keep the CPU, GPU and media engine busy together.
    let concurrency: Int
    private let lock = NSLock()
    private var exporters: [Exporter] = []
    private var cancelled = false

    init(cacheDir: URL, concurrency: Int = SegmentExporter.defaultConcurrency) {
        self.cacheDir = cacheDir
        self.concurrency = max(1, concurrency)
    }

    static var defaultConcurrency: Int { min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)) }

    func cancel() {
        lock.lock(); cancelled = true; let running = exporters; lock.unlock()
        running.forEach { $0.cancel() }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Segment boundaries on whole frames (2 s = 48 frames at 24 fps, 60 at 29.97 ...).
    static func segments(project p: Project, settings: ExportSettings) -> [Segment] {
        let framesPer = max(1, Int((segmentSeconds * p.fps).rounded()))
        let total = max(1, Int((p.duration * p.fps).rounded(.up)))
        let encoder = RenderKey.encoder(settings)
        return stride(from: 0, to: total, by: framesPer).enumerated().map { i, f in
            let s = Double(f) / p.fps, e = Double(min(total, f + framesPer)) / p.fps
            return Segment(index: i, start: s, end: e, key: RenderKey.key(project: p, start: s, end: e, encoder: encoder))
        }
    }

    /// Export `project` to `url`. `progress` runs 0...1 over the segments still to encode.
    @discardableResult
    func export(project: Project, settings: ExportSettings, to url: URL, progress: @escaping (Double) -> Void) async throws -> Stats {
        guard project.duration > 0 else { throw ExportError.empty }
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let segs = Self.segments(project: project, settings: settings)
        let todo = segs.filter { !fm.fileExists(atPath: cacheDir.appendingPathComponent($0.fileName).path) }
        var encoder = settings
        encoder.container = .mov

        // Progress of each segment being encoded, summed over all of them.
        let shares = Shares(count: todo.count)
        let report: (Int, Double) -> Void = { i, p in progress(shares.set(i, p) / Double(max(1, todo.count)) * 0.95) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func start() {
                guard next < todo.count else { return }
                let i = next, seg = todo[i]
                next += 1
                group.addTask { [self] in
                    if isCancelled || Task.isCancelled { throw ExportError.cancelled }
                    let exporter = Exporter()
                    lock.lock(); exporters.append(exporter); let stop = cancelled; lock.unlock()
                    defer { lock.lock(); exporters.removeAll { $0 === exporter }; lock.unlock() }
                    if stop { throw ExportError.cancelled }
                    let part = project.excerpt(from: seg.start, to: seg.end)
                    let dest = cacheDir.appendingPathComponent(seg.fileName)
                    try await exporter.export(project: part, settings: encoder, to: dest, includeAudio: false) { p in report(i, p) }
                    report(i, 1)
                    // An older segment for the same slot is now stale; keep the folder small.
                    removeOtherVersions(of: seg)
                }
            }
            for _ in 0..<concurrency { start() }
            do {
                while try await group.next() != nil { start() }
            } catch {
                cancel()
                group.cancelAll()
                throw error
            }
        }
        if isCancelled || Task.isCancelled { throw ExportError.cancelled }
        let audio = try await audioFile(project: project, settings: settings)
        try await join(segments: segs, audio: audio, duration: project.duration, container: settings.container, to: url)
        progress(1)
        return Stats(encoded: todo.count, reused: segs.count - todo.count)
    }

    /// Thread-safe per-segment progress.
    private final class Shares: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double]
        init(count: Int) { values = Array(repeating: 0, count: count) }
        func set(_ i: Int, _ v: Double) -> Double {
            lock.lock(); defer { lock.unlock() }
            values[i] = max(values[i], min(1, v))
            return values.reduce(0, +)
        }
    }

    private func removeOtherVersions(of seg: Segment) {
        let prefix = "\(seg.index)-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []
        where name.hasPrefix(prefix) && name.hasSuffix(".mov") && name != seg.fileName {
            try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(name))
        }
    }

    // MARK: Audio (encoded once for the whole length, so there are no gaps at joins)

    private func audioFile(project p: Project, settings: ExportSettings) async throws -> URL? {
        guard let audio = p.audio, !audio.isMuted, let asset = p.asset(audio.assetID) else { return nil }
        let stamp = "\(asset.path)|\(audio.start)|\(audio.duration)|\(p.duration)|\(settings.audioBitrateKbps)"
        let name = "audio-" + SHA256.hash(data: Data(stamp.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() + ".m4a"
        let url = cacheDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let comp = AVMutableComposition()
        let src = AVURLAsset(url: asset.url)
        guard let srcTrack = try await src.loadTracks(withMediaType: .audio).first,
              let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let len = min(audio.duration, p.duration - audio.start)
        guard len > 0 else { return nil }
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: CompositionBuilder.time(len)), of: srcTrack, at: CompositionBuilder.time(audio.start))

        let temp = cacheDir.appendingPathComponent(".\(name)-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        let reader = try AVAssetReader(asset: comp)
        reader.timeRange = CMTimeRange(start: .zero, duration: CompositionBuilder.time(p.duration))
        let out = AVAssetReaderAudioMixOutput(audioTracks: comp.tracks(withMediaType: .audio), audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(out)
        let writer = try AVAssetWriter(outputURL: temp, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings.audioOutputSettings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { throw ExportError.failed("audio") }
        writer.startSession(atSourceTime: .zero)
        let queue = DispatchQueue(label: "cutline.segment.audio")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !finished {
                    guard !self.isCancelled, let buf = out.copyNextSampleBuffer(), input.append(buf) else {
                        finished = true; input.markAsFinished(); cont.resume(); return
                    }
                }
            }
        }
        if isCancelled { writer.cancelWriting(); throw ExportError.cancelled }
        await writer.finishWriting()
        guard writer.status == .completed, reader.status != .failed else { throw ExportError.failed(writer.error?.localizedDescription ?? "audio") }
        try FileManager.default.moveItem(at: temp, to: url)
        return url
    }

    // MARK: Join

    /// Lay the segments end to end (and the audio under them) and write the file without
    /// re-encoding. Written next to `url` and moved into place only when complete.
    private func join(segments: [Segment], audio: URL?, duration: Double, container: ExportSettings.Container, to url: URL) async throws {
        let comp = AVMutableComposition()
        guard let video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ExportError.failed("join") }
        for seg in segments {
            let asset = AVURLAsset(url: cacheDir.appendingPathComponent(seg.fileName), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let t = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.failed("segment \(seg.index) is unreadable") }
            let length = CompositionBuilder.time(seg.end - seg.start)
            try video.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: t, at: CompositionBuilder.time(seg.start))
        }
        if let audio {
            let a = AVURLAsset(url: audio)
            if let t = try await a.loadTracks(withMediaType: .audio).first,
               let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let len = min(try await a.load(.duration), CompositionBuilder.time(duration))
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: len), of: t, at: .zero)
            }
        }
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw ExportError.failed("join") }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await session.export(to: temp, as: container.fileType)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }
}
