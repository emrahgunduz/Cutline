import Foundation
import CoreGraphics
import CoreMedia

/// Current on-disk schema version of `project.json`.
/// 2: lyric lines have a layout (single line or wrapped, text alignment); a line's x is its
/// alignment anchor.
let projectSchemaVersion = 2

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
    /// User fixes to the song's beats and sections (see AudioAnalysis).
    var beatCorrections: BeatCorrections?
    /// Language Whisper uses to double-check aligned lyrics (a Whisper code such as "tr");
    /// nil detects it from the lyric text.
    var lyricsLanguage: String?
    /// Portrait only: platform UI overlays shown in the preview (ids from platform_overlays.json);
    /// automatically placed lyrics stay clear of them.
    var platformOverlays: [String]?
    /// The last export choices (rate mode, bitrate, size target...), reused by the next export.
    var exportSettings: ExportSettings?

    init(type: ProjectType, canvas: CanvasSize) {
        self.type = type
        self.canvas = canvas
    }

    /// Set only on render excerpts (one export segment, a size probe): their exact length.
    var renderLength: Double?

    /// Project length: whichever ends later, the audio or the last video clip.
    var duration: Double {
        if let renderLength { return renderLength }
        let audioEnd = audio?.end ?? 0
        let videoEnd = videoTracks.flatMap(\.clips).map(\.end).max() ?? 0
        return max(audioEnd, videoEnd)
    }

    func asset(_ id: UUID) -> Asset? { assets.first { $0.id == id } }

    /// Snap a time to the nearest frame boundary.
    func quantize(_ t: Double) -> Double { (t * fps).rounded() / fps }
    var frameDuration: Double { 1 / fps }
    /// Index of the frame that contains time t (times on the grid map to their own frame).
    func frameIndex(_ t: Double) -> Int { Int((t * fps + 1e-6).rounded(.down)) }

    /// Exact frame duration for the compositor: 1001/30000 for 29.97, 1/24 for 24, and so on.
    var frameTime: CMTime {
        for (rate, ts) in [(24000.0 / 1001, Int32(24000)), (30000.0 / 1001, 30000), (60000.0 / 1001, 60000)] where abs(fps - rate) < 0.01 {
            return CMTime(value: 1001, timescale: ts)
        }
        return CMTime(value: 1, timescale: Int32(max(1, fps.rounded())))
    }
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
    /// Muted: the song is silent in the preview and the export (nil = audible).
    var muted: Bool?
    var isMuted: Bool { muted == true }
    var end: Double { start + duration }
}

struct VideoTrack: Codable, Equatable, Identifiable {
    var id = UUID()
    var clips: [Clip] = []
    /// Hidden tracks aren't drawn in the preview or the export (nil = shown).
    var hidden: Bool?
    var isHidden: Bool { hidden == true }
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
    /// Hidden tracks aren't drawn in the preview or the export (nil = shown). Their lines are
    /// still aligned with the others.
    var hidden: Bool?
    var isHidden: Bool { hidden == true }
}

struct LyricLine: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var words: [LyricWord]
    /// Stanza index from the TXT (blank lines separate stanzas).
    var stanza: Int = 0
    /// Explicit position on the canvas (pixels, y up); nil = automatic stack. `centerY` is the
    /// middle of the line's box. `centerX` is its anchor, set by the text alignment: the box's
    /// left edge for left-aligned text, its middle for centred text, its right edge for
    /// right-aligned text (so the text grows away from the anchor when it changes).
    var centerX: Double?
    var centerY: Double?
    /// Single line or wrapped at a width, and the text alignment. nil = the defaults.
    var layoutValue: LineLayout?
    /// Where the line is in its lyrics file. Alignment sings the lines in this order wherever
    /// they were moved on the timeline (any track, any time). nil = not from a file.
    var textOrder: TextOrder?
    var hasPosition: Bool { centerX != nil && centerY != nil }
    var text: String { words.map(\.text).joined(separator: " ") }
    var layout: LineLayout { get { layoutValue ?? LineLayout() } set { layoutValue = newValue == LineLayout() ? nil : newValue } }

    enum CodingKeys: String, CodingKey { case id, start, end, words, stanza, centerX, centerY, layoutValue = "layout", textOrder }
}

/// A line's place in the lyrics file it came from: the file (one import) and its index there.
struct TextOrder: Codable, Equatable, Hashable {
    var group: UUID
    var index: Int
}

/// How one lyric line is laid out (per line).
struct LineLayout: Codable, Equatable, Hashable {
    enum Mode: String, Codable, CaseIterable { case singleLine, wrapped }
    enum Align: String, Codable, CaseIterable { case left, center, right }

    /// Single line: as wide as the text (it may be wider than the frame), as tall as the font.
    /// Wrapped: the text wraps at `width` and the line is as tall as its rows.
    var mode: Mode = .singleLine
    /// Wrap width in canvas pixels (wrapped mode). A word longer than this keeps its own row.
    var width: Double = 800
    var align: Align = .left

    init(mode: Mode = .singleLine, width: Double = 800, align: Align = .left) {
        self.mode = mode
        self.width = max(0, width)
        self.align = align
    }

    /// The wrap width, or nil for a single line.
    var wrapWidth: Double? { mode == .wrapped ? width : nil }
}

struct LyricWord: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var start: Double
    var end: Double
    var confidence: Double = 1
    var confirmed = false
    /// Timeline times found by alignment, before the lead-in. Cleared when the word is
    /// edited by hand; then the lead-in no longer moves it.
    var alignedStart: Double?
    var alignedEnd: Double?
    /// Set when you moved or re-timed the word on the timeline (a word, line or group drag).
    /// Re-aligning asks before clearing it. nil = not edited.
    var handEdited: Bool?
    var isHandEdited: Bool { handEdited == true }
    /// Confirmed or hand-edited: your timing, which re-aligning asks before replacing.
    var isUserTimed: Bool { confirmed || isHandEdited }
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
    // Word animation. Optional storage so older projects load; nil means the default.
    /// Fade-in / fade-out time in seconds (default: 3 frames).
    var fadeInValue: Double?
    var fadeOutValue: Double?
    /// true = letters fade one after another; false = whole words fade.
    var letterByLetterValue: Bool?
    /// How much consecutive letter fades overlap (0 = one after another, 1 = all together).
    var letterOverlapValue: Double?
    /// Aligned words are shown this many seconds early (they read better slightly ahead of the voice).
    var leadInValue: Double?
    var leadIn: Double { get { leadInValue ?? 0.15 } set { leadInValue = newValue } }
    /// Aligned lines stay on screen this many seconds longer after their last word (on top of
    /// where the lead-in puts their end).
    var leadOutValue: Double?
    var leadOut: Double { get { leadOutValue ?? 0 } set { leadOutValue = newValue } }
    var letterByLetter: Bool { get { letterByLetterValue ?? false } set { letterByLetterValue = newValue } }
    var letterOverlap: Double { get { letterOverlapValue ?? 0.5 } set { letterOverlapValue = newValue } }

    /// Shadow density multiplier (1 = the color's own opacity). Optional so older projects load.
    var shadowStrengthValue: Double?
    var shadowStrength: Double {
        get { shadowStrengthValue ?? 1 }
        set { shadowStrengthValue = newValue }
    }
    /// Vertical center of the lyric block, as a fraction of canvas height from the top.
    var verticalPosition: Double = 0.82
}

struct Cinemascope: Codable, Equatable {
    var enabled = false
    var startMarker: Double = 0
    var endMarker: Double = 5
    /// Set when a marker is tied to the song's beats (it then follows beat corrections).
    var startAnchor: BeatAnchor?
    var endAnchor: BeatAnchor?
}
