import Foundation

enum ProjectType: String, Codable, CaseIterable, Identifiable {
    case musicVideo, social, ad
    var id: String { rawValue }

    var title: String {
        switch self {
        case .musicVideo: "Music video (16:9)"
        case .social: "Portrait social (9:16)"
        case .ad: "Portrait ad (9:16)"
        }
    }

    var isPortrait: Bool { self != .musicVideo }
}

enum VideoCodecChoice: String, Codable { case hevc, h264 }

/// One row of the editable preset table.
struct FormatPreset: Codable, Equatable {
    var type: ProjectType
    /// Allowed canvas sizes; the first is the default.
    var canvases: [CanvasSize]
    /// Maximum project length in seconds; nil means unlimited.
    var maxDuration: Double?
    var codec: VideoCodecChoice
    /// Default bitrate in Mbit/s for bitrate-driven presets.
    var defaultBitrateMbps: Double?
    /// Default size target in MB, when the preset uses one.
    var defaultSizeTargetMB: Double?
}
