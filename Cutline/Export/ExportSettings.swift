import AVFoundation

struct ExportSettings: Equatable {
    enum RateMode: String, CaseIterable, Identifiable { case quality, bitrate; var id: String { rawValue } }

    var codec: VideoCodecChoice
    var rateMode: RateMode
    /// 0...1, used in quality mode.
    var quality: Double
    /// Mbit/s, used in bitrate mode.
    var bitrateMbps: Double
    var audioBitrateKbps: Double = 320
    var container: Container = .mp4

    enum Container: String, CaseIterable, Identifiable {
        case mp4, mov
        var id: String { rawValue }
        var title: String { self == .mp4 ? "MP4 (.mp4)" : "QuickTime (.mov)" }
        var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
    }

    /// Size estimate for bitrate mode (exact up to container overhead).
    func estimatedBytes(duration: Double) -> Double {
        (bitrateMbps * 1_000_000 + audioBitrateKbps * 1000) * duration / 8
    }

    /// Music videos default to highest-quality HEVC; social and ads to bitrate-driven H.264.
    static func defaults(for project: Project) -> ExportSettings {
        let preset = Presets.preset(for: project.type)
        switch project.type {
        case .musicVideo:
            return ExportSettings(codec: preset.codec, rateMode: .quality, quality: 1, bitrateMbps: project.canvas.height >= 2160 ? 80 : 30)
        case .social, .ad:
            return ExportSettings(codec: preset.codec, rateMode: .bitrate, quality: 0.8, bitrateMbps: preset.defaultBitrateMbps ?? 12)
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
        case .bitrate: props[AVVideoAverageBitRateKey] = bitrateMbps * 1_000_000
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
