import AVFoundation
import VideoToolbox

enum ExportError: LocalizedError {
    case cancelled, failed(String), empty
    var errorDescription: String? {
        switch self {
        case .cancelled: "Export cancelled."
        case .failed(let m): "Export failed: \(m)"
        case .empty: "The project is empty."
        }
    }
}

/// Renders the project at full quality from the original media (never proxies)
/// through the same compositor as the preview, and encodes it.
final class Exporter {
    private(set) var isCancelled = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?

    /// Stops reading; the pumps then drain and `export` discards the partial file.
    /// (Cancelling the writer here would stop input callbacks and strand the pumps.)
    func cancel() {
        isCancelled = true
        reader?.cancelReading()
    }

    /// Export the whole project. Size probes pass an excerpt project and `includeAudio: false`.
    /// Cancelling the calling task cancels the export like `cancel()`.
    /// Renders into a temporary file next to `url` and replaces `url` only on success,
    /// so a cancelled or failed re-export keeps the previous file.
    func export(project: Project, settings: ExportSettings, to url: URL,
                includeAudio: Bool = true, progress: @escaping (Double) -> Void) async throws {
        try await withTaskCancellationHandler {
            let temp = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).\(url.pathExtension)")
            defer { try? FileManager.default.removeItem(at: temp) }
            try await render(project: project, settings: settings, to: temp, includeAudio: includeAudio, progress: progress)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
            progress(1)
        } onCancel: {
            self.cancel()
        }
    }

    private func render(project: Project, settings: ExportSettings, to url: URL,
                        includeAudio: Bool, progress: @escaping (Double) -> Void) async throws {
        guard project.duration > 0 else { throw ExportError.empty }
        let snapshot = RenderSnapshot(project: project, images: FrameRenderer.loadImages(project), lyrics: LyricRenderer(project: project))
        let built = try await CompositionBuilder.build(project: project, mediaURL: { $0.url }, snapshot: snapshot)
        if isCancelled { throw ExportError.cancelled }
        try? FileManager.default.removeItem(at: url)

        let reader = try AVAssetReader(asset: built.composition)
        let span = CMTimeRange(start: .zero, duration: built.duration)
        reader.timeRange = span
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: built.composition.tracks(withMediaType: .video), videoSettings: nil)
        videoOut.videoComposition = built.videoComposition
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        let audioTracks = includeAudio ? built.composition.tracks(withMediaType: .audio) : []
        var audioOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(o)
            audioOut = o
        }

        let fileType = settings.container.fileType
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings.videoOutputSettings(canvas: project.canvas, fps: project.fps))
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: settings.audioOutputSettings)
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            audioIn = a
        }
        self.reader = reader
        self.writer = writer

        guard reader.startReading() else { throw ExportError.failed(reader.error?.localizedDescription ?? "reader") }
        guard writer.startWriting() else { throw ExportError.failed(writer.error?.localizedDescription ?? "writer") }
        writer.startSession(atSourceTime: span.start)

        let total = span.duration.seconds, offset = span.start.seconds
        async let v: Void = pump(output: videoOut, input: videoIn, label: "video") { progress(min(1, ($0 - offset) / total)) }
        async let a: Void = {
            if let audioOut, let audioIn { await self.pump(output: audioOut, input: audioIn, label: "audio", progress: nil) }
        }()
        _ = await (v, a)

        if isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw ExportError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw ExportError.failed(reader.error?.localizedDescription ?? "read")
        }
        writer.endSession(atSourceTime: span.end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.failed(writer.error?.localizedDescription ?? "write")
        }
    }

    private func pump(output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String, progress: ((Double) -> Void)?) async {
        let queue = DispatchQueue(label: "cutline.export.\(label)")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !finished {
                    if self.isCancelled {
                        finished = true; input.markAsFinished(); cont.resume(); return
                    }
                    guard let buffer = output.copyNextSampleBuffer() else {
                        finished = true; input.markAsFinished(); cont.resume(); return
                    }
                    progress?(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
                    if !input.append(buffer) {
                        finished = true; input.markAsFinished(); cont.resume(); return
                    }
                }
            }
        }
    }
}
