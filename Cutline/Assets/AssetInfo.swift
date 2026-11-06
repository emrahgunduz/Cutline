import Foundation

/// The details shown under an asset's name, as far as they make sense for its kind:
/// a video's size, length and frame rate; an image's size; a dummy's size (the project's: it's
/// drawn at it) and length; a song's length. Lyrics files have none.
enum AssetInfo {
    static func text(for a: Asset, canvas: CanvasSize) -> String? {
        var parts: [String] = []
        switch a.kind {
        case .lyrics:
            return nil
        case .audio:
            if let d = a.duration { parts.append(length(d)) }
        case .image:
            if let card = a.dummy {
                parts += [size(canvas), length(card.length)]
            } else if let s = a.pixelSize {
                parts.append(size(s))
            }
        case .video:
            if let s = a.pixelSize { parts.append(size(s)) }
            if let d = a.duration { parts.append(length(d)) }
            if let r = a.frameRate, r > 0 { parts.append("\(Project.rateLabel(r)) fps") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Whether the asset's length is in its details (the tile's own length badge then steps aside).
    static func includesLength(_ a: Asset) -> Bool {
        a.kind == .audio || a.kind == .video || a.isDummy
    }

    static func size(_ s: CanvasSize) -> String { "\(s.width)×\(s.height)" }

    /// m:ss, or h:mm:ss from an hour.
    static func length(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
