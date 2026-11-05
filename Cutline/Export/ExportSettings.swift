import AVFoundation

/// Export choices, saved with the project so the next export and the budget bar reuse them.
struct ExportSettings: Equatable, Codable {
    enum RateMode: String, CaseIterable, Identifiable, Codable { case quality, bitrate, size; var id: String { rawValue } }

    var codec: VideoCodecChoice
    var rateMode: RateMode
    /// 0...1, used in quality mode.
    var quality: Double
    /// Mbit/s, used in bitrate mode.
    var bitrateMbps: Double
    var audioBitrateKbps: Double = 320
    var container: Container = .mp4
    /// MB (10^6 bytes), used in size mode: the file must come out at or under this.
    var sizeTargetMB: Double?

    enum Container: String, CaseIterable, Identifiable, Codable {
        case mp4, mov
        var id: String { rawValue }
        var title: String { self == .mp4 ? "MP4 (.mp4)" : "QuickTime (.mov)" }
        var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
    }

    /// Size estimate for bitrate mode (exact up to container overhead); the target in size mode.
    func estimatedBytes(duration: Double) -> Double {
        if rateMode == .size, let mb = sizeTargetMB { return mb * 1_000_000 }
        return (bitrateMbps * 1_000_000 + audioBitrateKbps * 1000) * duration / 8
    }

    /// The video bitrate (Mbit/s) a size target leaves for this length.
    func sizeTargetBitrateMbps(duration: Double) -> Double? {
        guard let mb = sizeTargetMB else { return nil }
        return SizeSolver.videoBitrate(targetBytes: mb * 1_000_000, duration: duration, audioKbps: audioBitrateKbps) / 1_000_000
    }

    /// The project's saved choices, else the type's defaults: music videos highest-quality
    /// HEVC; social bitrate-driven H.264; ads H.264 aimed at the preset's size target.
    static func defaults(for project: Project) -> ExportSettings {
        if var saved = project.exportSettings {
            saved.codec = Presets.preset(for: project.type).codec
            return saved
        }
        let preset = Presets.preset(for: project.type)
        switch project.type {
        case .musicVideo:
            return ExportSettings(codec: preset.codec, rateMode: .quality, quality: 1, bitrateMbps: project.canvas.height >= 2160 ? 80 : 30)
        case .social, .ad:
            var s = ExportSettings(codec: preset.codec, rateMode: .bitrate, quality: 0.8, bitrateMbps: preset.defaultBitrateMbps ?? 12,
                                   sizeTargetMB: preset.defaultSizeTargetMB)
            if preset.defaultSizeTargetMB != nil { s.rateMode = .size }
            return s
        }
    }

    var tenBit: Bool { codec == .hevc }

    func videoOutputSettings(canvas: CanvasSize, fps: Double) -> [String: Any] {
        var props: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: Int((fps * 2).rounded()),
        ]
        switch rateMode {
        case .quality: props[AVVideoQualityKey] = quality
        case .bitrate, .size: props[AVVideoAverageBitRateKey] = bitrateMbps * 1_000_000
        }
        switch codec {
        case .hevc: props[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        case .h264: props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        return [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: canvas.width,
            AVVideoHeightKey: canvas.height,
            AVVideoCompressionPropertiesKey: props,
        ]
    }

    var audioOutputSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
         AVEncoderBitRateKey: audioBitrateKbps * 1000]
    }
}
