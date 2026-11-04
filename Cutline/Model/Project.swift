import Foundation
import CoreGraphics

/// Current on-disk schema version of `project.json`.
let projectSchemaVersion = 1

struct Project: Codable, Equatable {
    var schemaVersion: Int = projectSchemaVersion
    var type: ProjectType
    var canvas: CanvasSize
    /// Frames per second. Fixed once the first video clip is added.
    var fps: Double = 30
    var fpsLocked: Bool = false

    var assets: [Asset] = []
    var audio: AudioClip?
    var videoTracks: [VideoTrack] = [VideoTrack()]
    var lyricTracks: [LyricTrack] = [LyricTrack()]
    var lyricStyle = LyricStyle()
    var cinemascope = Cinemascope()

    init(type: ProjectType, canvas: CanvasSize) {
        self.type = type
        self.canvas = canvas
    }

    /// Project length: whichever ends later, the audio or the last video clip.
    var duration: Double {
        let audioEnd = audio?.end ?? 0
        let videoEnd = videoTracks.flatMap(\.clips).map(\.end).max() ?? 0
        return max(audioEnd, videoEnd)
    }

    func asset(_ id: UUID) -> Asset? { assets.first { $0.id == id } }

    /// Snap a time to the nearest frame boundary.
    func quantize(_ t: Double) -> Double { (t * fps).rounded() / fps }
    var frameDuration: Double { 1 / fps }
}

struct CanvasSize: Codable, Equatable, Hashable {
    var width: Int
    var height: Int
    var cgSize: CGSize { CGSize(width: width, height: height) }
}

// MARK: - Assets

enum AssetKind: String, Codable { case video, image, audio, lyrics }

struct Asset: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: AssetKind
    var name: String
    /// Absolute path at import time; used when the bookmark cannot be resolved.
    var path: String
    var bookmark: Data?
    /// Natural pixel size (video / image).
    var pixelSize: CanvasSize?
    /// Media duration in seconds (video / audio).
    var duration: Double?
    var frameRate: Double?
    var proxy: ProxyInfo?

    var url: URL {
        if let bookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return u
            }
        }
        return URL(fileURLWithPath: path)
    }
}

enum ProxyScale: Int, Codable, CaseIterable, Identifiable {
    case half = 2, quarter = 4, eighth = 8
    var id: Int { rawValue }
    var label: String { "1/\(rawValue)" }
}

struct ProxyInfo: Codable, Equatable {
    var scale: ProxyScale
    /// File name inside the package's `proxies/` folder.
    var fileName: String
}

// MARK: - Timeline items

struct AudioClip: Codable, Equatable {
    var assetID: UUID
    var start: Double = 0
    var duration: Double
    var end: Double { start + duration }
}

struct VideoTrack: Codable, Equatable, Identifiable {
    var id = UUID()
    var clips: [Clip] = []
}

struct Clip: Codable, Equatable, Identifiable {
    var id = UUID()
    var assetID: UUID
    /// Timeline position in seconds.
    var start: Double
    var duration: Double
    /// Offset into the source media (seconds). Ignored for images.
    var sourceIn: Double = 0
    var transform = ClipTransform()
    var filters = FilterSettings()
    var end: Double { start + duration }
}

/// Static size and placement in canvas space. `scale` 1 = fit the canvas.
struct ClipTransform: Codable, Equatable {
    var scale: Double = 1
    /// Center offset from canvas center, in canvas pixels.
    var offsetX: Double = 0
    var offsetY: Double = 0
}

struct FilterSettings: Codable, Equatable {
    var color = ColorFilter()
    var fade = FadeFilter()
}

struct ColorFilter: Codable, Equatable {
    var enabled = false
    var hue: Double = 0          // degrees -180...180
    var saturation: Double = 1   // 0...2
    var brightness: Double = 0   // -1...1
    var contrast: Double = 1     // 0...2
    var isIdentity: Bool { !enabled || (hue == 0 && saturation == 1 && brightness == 0 && contrast == 1) }
}

struct FadeFilter: Codable, Equatable {
    var enabled = false
    var fadeIn: Double = 0.5
    var fadeOut: Double = 0.5
}

// MARK: - Lyrics

struct LyricTrack: Codable, Equatable, Identifiable {
    var id = UUID()
    var lines: [LyricLine] = []
}

struct LyricLine: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var words: [LyricWord]
    /// Stanza index from the TXT (blank lines separate stanzas).
    var stanza: Int = 0
    var text: String { words.map(\.text).joined(separator: " ") }
}

struct LyricWord: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var start: Double
    var end: Double
    var confidence: Double = 1
    var confirmed = false
}

struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double
    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

struct LyricStyle: Codable, Equatable {
    var fontName = "HelveticaNeue-Bold"   // PostScript name
    /// Font size as a fraction of canvas height, so it scales across resolutions.
    var sizeFraction: Double = 0.06
    var color = RGBA.white
    var shadowEnabled = true
    var shadowBlur: Double = 8
    var shadowDX: Double = 0
    var shadowDY: Double = 4   // +down
    var shadowColor = RGBA(r: 0, g: 0, b: 0, a: 0.8)
    /// Vertical center of the lyric block, as a fraction of canvas height from the top.
    var verticalPosition: Double = 0.82
}

struct Cinemascope: Codable, Equatable {
    var enabled = false
    var startMarker: Double = 0
    var endMarker: Double = 5
}
