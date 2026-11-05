import CryptoKit
import Foundation

/// Content keys for the render cache (KTD11, R32). A key covers everything that changes the
/// pixels of a time range: the clips and media visible there, their placement and filters,
/// the lyric words and lines drawn there with the style, the letterbox state, the canvas and
/// frame rate, and (for export segments) the encoder settings. An edit changes the keys only
/// of the ranges whose output it changes.
enum RenderKey {
    /// Bump when the renderer's output changes, so every cached frame and segment is stale.
    static let rendererVersion = 1

    private struct Signature: Encodable {
        var version = RenderKey.rendererVersion
        var canvas: CanvasSize
        var fps: Double
        var range: [Double]
        var clips: [ClipSig] = []
        var lines: [LineSig] = []
        var words: [WordSig] = []
        var style: LyricStyle
        var letterbox: String
        var encoder: EncoderSig?
        var proxies: [String]?
    }
    private struct ClipSig: Encodable {
        var track: Int; var asset: UUID; var path: String; var media: String
        var start: Double; var duration: Double; var sourceIn: Double
        var transform: ClipTransform; var filters: FilterSettings
    }
    private struct LineSig: Encodable { var id: UUID; var track: Int; var text: String; var x: Double?; var y: Double?; var drawn: [Double] }
    private struct WordSig: Encodable { var line: UUID; var text: String; var start: Double; var end: Double }
    struct EncoderSig: Encodable, Equatable { var codec: String; var mode: String; var quality: Double?; var bitrate: Double? }

    static func encoder(_ s: ExportSettings) -> EncoderSig {
        EncoderSig(codec: s.codec.rawValue, mode: s.rateMode == .quality ? "quality" : "bitrate",
                   quality: s.rateMode == .quality ? s.quality : nil, bitrate: s.rateMode == .quality ? nil : s.bitrateMbps)
    }

    /// Key for the frames in `start..<end` (project seconds).
    /// - Parameters:
    ///   - encoder: export segments include their encoder settings; preview frames don't.
    ///   - proxies: preview frames rendered from proxies include the proxy files used.
    static func key(project p: Project, start: Double, end: Double, encoder: EncoderSig? = nil, proxies: Bool = false) -> String {
        var sig = Signature(canvas: p.canvas, fps: p.fps, range: [start, end], style: p.lyricStyle,
                            letterbox: letterbox(p, start, end), encoder: encoder)
        for (t, track) in p.videoTracks.enumerated() {
            for c in track.clips where c.start < end && c.end > start {
                let asset = p.asset(c.assetID)
                sig.clips.append(ClipSig(track: t, asset: c.assetID, path: asset?.path ?? "", media: mediaStamp(asset),
                                         start: c.start, duration: c.duration, sourceIn: c.sourceIn, transform: c.transform, filters: c.filters))
            }
        }
        if proxies {
            sig.proxies = sig.clips.compactMap { c in p.asset(c.asset)?.proxy.map { "\(c.asset):\($0.fileName)" } }
        }
        let animation = LyricAnimation(style: p.lyricStyle, fps: p.fps)
        for (t, track) in p.lyricTracks.enumerated() {
            for l in track.lines {
                let drawnEnd = max(l.end, l.words.map { LyricLayout.visibleEnd(of: $0, letters: $0.text.count, animation: animation) }.max() ?? l.end)
                guard l.start < end, drawnEnd > start else { continue }
                // Only the part of the line's life inside this range matters (which lines stack).
                sig.lines.append(LineSig(id: l.id, track: t, text: l.text, x: l.centerX, y: l.centerY,
                                         drawn: [max(l.start, start), min(drawnEnd, end)]))
                for w in l.words where w.start < end && LyricLayout.visibleEnd(of: w, letters: w.text.count, animation: animation) > start {
                    sig.words.append(WordSig(line: l.id, text: w.text, start: w.start, end: w.end))
                }
            }
        }
        return digest(sig)
    }

    /// Letterbox contribution: fully open, fully closed, or the transition when it is inside.
    private static func letterbox(_ p: Project, _ start: Double, _ end: Double) -> String {
        let c = p.cinemascope
        guard p.type == .musicVideo, c.enabled else { return "off" }
        if end <= c.startMarker { return "open" }
        if start >= c.endMarker { return "closed" }
        return "\(c.startMarker)-\(c.endMarker)"
    }

    /// File size and modification date, so replacing media on disk invalidates its ranges.
    /// Looked up at most once a second per file (keys are computed per frame and per drag).
    private static func mediaStamp(_ asset: Asset?) -> String {
        guard let asset else { return "" }
        let now = Date()
        stampLock.lock()
        if let c = stamps[asset.path], now.timeIntervalSince(c.at) < 1 { stampLock.unlock(); return c.stamp }
        stampLock.unlock()
        let v = try? URL(fileURLWithPath: asset.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = "\(v?.fileSize ?? 0)@\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        stampLock.lock(); stamps[asset.path] = (stamp, now); stampLock.unlock()
        return stamp
    }
    private static let stampLock = NSLock()
    nonisolated(unsafe) private static var stamps: [String: (stamp: String, at: Date)] = [:]

    private static func digest<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(value)) ?? Data()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
