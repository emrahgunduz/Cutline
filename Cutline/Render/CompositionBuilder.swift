import AVFoundation
import CoreImage

/// Builds the AVFoundation composition for the project. Each video clip is placed on a
/// composition track; clips that don't overlap share tracks so decoder count stays low.
/// A black base track spans the whole project so the compositor runs even over gaps
/// and image-only stretches.
struct BuiltComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    /// Composition track for each clip, plus the source transform to apply.
    let clipTracks: [UUID: (trackID: CMPersistentTrackID, transform: CGAffineTransform)]
    let duration: CMTime
}

enum CompositionBuilder {
    /// Divides every supported frame duration exactly (1/24 … 1001/60000), so frame times
    /// never round onto the wrong frame.
    static let timescale: CMTimeScale = 120_000

    static func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: timescale) }

    static func build(project: Project, mediaURL: (Asset) -> URL, snapshot: RenderSnapshot) async throws -> BuiltComposition {
        let comp = AVMutableComposition()
        let duration = max(project.duration, project.frameDuration)
        let total = time(duration)

        // Black base so every frame gets composited.
        let baseAsset = AVURLAsset(url: try BlackClip.url())
        let base = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        if let src = try await baseAsset.loadTracks(withMediaType: .video).first {
            let srcRange = CMTimeRange(start: .zero, duration: try await baseAsset.load(.duration))
            try base.insertTimeRange(srcRange, of: src, at: .zero)
            base.scaleTimeRange(CMTimeRange(start: .zero, duration: srcRange.duration), toDuration: total)
        }

        // Greedy track assignment: reuse a composition track when the clip starts after its last end.
        var pool: [(track: AVMutableCompositionTrack, end: Double)] = []
        var clipTracks: [UUID: (CMPersistentTrackID, CGAffineTransform)] = [:]
        // Hidden tracks' clips stay in the composition: the compositor skips them, so showing a
        // track again is instant (no rebuild) in the preview.
        let videoClips = project.videoTracks.flatMap(\.clips)
            .filter { project.asset($0.assetID)?.kind == .video }
            .sorted { $0.start < $1.start }
        var loaded: [URL: (AVURLAsset, AVAssetTrack, CGAffineTransform)] = [:]   // asset kept alive while its track is used
        for clip in videoClips {
            try Task.checkCancellation()   // a superseded preview rebuild stops here
            guard let asset = project.asset(clip.assetID) else { continue }
            let url = mediaURL(asset)
            if loaded[url] == nil {
                let av = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                guard let t = try await av.loadTracks(withMediaType: .video).first else { continue }
                loaded[url] = (av, t, try await t.load(.preferredTransform))
            }
            guard let (_, srcTrack, transform) = loaded[url] else { continue }
            let slot: Int
            if let i = pool.firstIndex(where: { $0.end <= clip.start + 1e-6 }) { slot = i }
            else {
                pool.append((comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!, 0))
                slot = pool.count - 1
            }
            let range = CMTimeRange(start: time(clip.sourceIn), duration: time(clip.duration))
            try pool[slot].track.insertTimeRange(range, of: srcTrack, at: time(clip.start))
            pool[slot].end = clip.end
            clipTracks[clip.id] = (pool[slot].track.trackID, transform)
        }

        var audioAsset: AVURLAsset?
        // The song is always in the composition; the preview mutes the player and the export
        // leaves the audio out when it's muted.
        if let audio = project.audio, let asset = project.asset(audio.assetID) {
            let av = AVURLAsset(url: asset.url)
            audioAsset = av
            if let src = try await av.loadTracks(withMediaType: .audio).first {
                let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                let len = min(audio.duration, duration - audio.start)
                if len > 0 { try track.insertTimeRange(CMTimeRange(start: .zero, duration: time(len)), of: src, at: time(audio.start)) }
            }
        }

        withExtendedLifetime((baseAsset, loaded, audioAsset)) {}
        let vc = makeVideoComposition(project: project, snapshot: snapshot, baseTrackID: base.trackID,
                                      clipTracks: clipTracks, duration: total)
        return BuiltComposition(composition: comp, videoComposition: vc,
                                clipTracks: clipTracks.mapValues { (trackID: $0.0, transform: $0.1) }, duration: total)
    }

    static func makeVideoComposition(project: Project, snapshot: RenderSnapshot, baseTrackID: CMPersistentTrackID,
                                     clipTracks: [UUID: (CMPersistentTrackID, CGAffineTransform)], duration: CMTime) -> AVMutableVideoComposition {
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = CutlineCompositor.self
        vc.renderSize = project.canvas.cgSize
        vc.frameDuration = project.frameTime
        let instruction = CutlineInstruction(timeRange: CMTimeRange(start: .zero, duration: duration),
                                             snapshot: snapshot, baseTrackID: baseTrackID,
                                             clipTracks: clipTracks.mapValues { (trackID: $0.0, transform: $0.1) })
        vc.instructions = [instruction]
        return vc
    }
}

/// A one-second black H.264 clip, generated once per launch.
enum BlackClip {
    private static var cached: URL?
    private static let lock = NSLock()

    static func url() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        if let cached, FileManager.default.fileExists(atPath: cached.path) { return cached }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-black-\(ProcessInfo.processInfo.processIdentifier).mov")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        let failure = { writer.error ?? CocoaError(.fileWriteUnknown) }
        guard writer.startWriting() else { throw failure() }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<2 {
            // Bounded wait: a failed writer never becomes ready, and we hold `lock`.
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { writer.cancelWriting(); throw failure() }
                usleep(1000)
            }
            var pb: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else {
                writer.cancelWriting(); throw failure()
            }
            CVPixelBufferLockBaseAddress(pb, [])
            memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetDataSize(pb))
            CVPixelBufferUnlockBaseAddress(pb, [])
            guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 1)) else {
                writer.cancelWriting(); throw failure()
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        cached = url
        return url
    }
}
