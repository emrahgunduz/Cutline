import AVFoundation

enum ProxyError: LocalizedError {
    case noVideoTrack, writeFailed(String)
    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The file has no video track."
        case .writeFailed(let m): "Proxy encoding failed: \(m)"
        }
    }
}

/// Creates, replaces and removes the single preview proxy of a video asset.
/// Proxies are for preview only; export always reads the original file.
enum ProxyManager {
    static func fileName(for assetID: UUID) -> String { "\(assetID.uuidString).mov" }

    /// Encode a downscaled, low-bitrate proxy with a short GOP so frame stepping stays responsive.
    static func encode(source: URL, to dest: URL, scale: ProxyScale, codec: VideoCodecChoice,
                       progress: ((Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProxyError.noVideoTrack }
        let (natural, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration)
        let w = max(16, (Int(natural.width) / scale.rawValue) & ~1)
        let h = max(16, (Int(natural.height) / scale.rawValue) & ~1)

        try? FileManager.default.removeItem(at: dest)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: dest, fileType: .mov)
        let bitsPerPixel = codec == .hevc ? 0.05 : 0.08
        let bitrate = Double(w * h) * Double(max(rate, 24)) * bitsPerPixel
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: 6,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        guard reader.startReading() else { throw ProxyError.writeFailed(reader.error?.localizedDescription ?? "read") }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let total = max(duration.seconds, 0.001)
        let queue = DispatchQueue(label: "proxy.encode")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                    progress?(CMSampleBufferGetPresentationTimeStamp(buffer).seconds / total)
                    input.append(buffer)
                }
            }
        }
        await writer.finishWriting()
        if writer.status != .completed { throw ProxyError.writeFailed(writer.error?.localizedDescription ?? "unknown") }
    }
}

extension EditorModel {
    var proxyCodec: VideoCodecChoice { project.type == .musicVideo ? .hevc : .h264 }

    func proxyURL(for asset: Asset) -> URL? {
        guard let p = asset.proxy else { return nil }
        return folder("proxies")?.appendingPathComponent(p.fileName)
    }

    /// Create (or replace) the asset's proxy at the given scale.
    @MainActor
    func createProxy(assetID: UUID, scale: ProxyScale, progress: ((Double) -> Void)? = nil) async throws {
        guard let asset = project.asset(assetID), asset.kind == .video, let dir = folder("proxies") else { return }
        let name = ProxyManager.fileName(for: assetID)
        let temp = dir.appendingPathComponent("\(assetID.uuidString)-new.mov")
        try await ProxyManager.encode(source: asset.url, to: temp, scale: scale, codec: proxyCodec, progress: progress)
        let final = dir.appendingPathComponent(name)
        _ = try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: temp, to: final)
        edit("Create Proxy") { p in
            if let i = p.assets.firstIndex(where: { $0.id == assetID }) { p.assets[i].proxy = ProxyInfo(scale: scale, fileName: name) }
        }
    }

    @MainActor
    func deleteProxy(assetID: UUID) {
        guard let asset = project.asset(assetID), let url = proxyURL(for: asset) else { return }
        try? FileManager.default.removeItem(at: url)
        edit("Delete Proxy") { p in
            if let i = p.assets.firstIndex(where: { $0.id == assetID }) { p.assets[i].proxy = nil }
        }
    }

    /// Media URL to decode. Export passes `useProxies: false` and always gets the original.
    func mediaURL(for asset: Asset, useProxies: Bool) -> URL {
        if useProxies, let url = proxyURL(for: asset), FileManager.default.fileExists(atPath: url.path) { return url }
        return asset.url
    }
}
