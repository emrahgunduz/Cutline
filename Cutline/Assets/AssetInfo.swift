import Foundation

/// The details shown under an asset's name, as far as they make sense for its kind, in two
/// boxes: the size (a video's or image's own; a dummy's is the project's, it's drawn at it),
/// and the length as MM:SS (FF) with the frame rate (a video's own; a dummy's and a song's
/// frames count at the project's rate, and a song has no rate of its own). Lyrics files have
/// none.
enum AssetInfo {
    struct Details: Equatable {
        var size: String?
        var length: String?
        var rate: String?
    }

    static func details(for a: Asset, canvas: CanvasSize, fps: Double) -> Details {
        var d = Details()
        switch a.kind {
        case .lyrics:
            break
        case .audio:
            if let s = a.duration { d.length = Project.lengthLabel(s, fps: fps) }
        case .image:
            if let card = a.dummy {
                d.size = size(canvas)
                d.length = Project.lengthLabel(card.length, fps: fps)
                d.rate = rate(fps)
            } else if let s = a.pixelSize {
                d.size = size(s)
            }
        case .video:
            let own = a.frameRate.flatMap { $0 > 0 ? $0 : nil }
            if let s = a.pixelSize { d.size = size(s) }
            if let s = a.duration { d.length = Project.lengthLabel(s, fps: own ?? fps) }
            d.rate = own.map(rate)
        }
        return d
    }

    static func size(_ s: CanvasSize) -> String { "\(s.width)×\(s.height)" }
    static func rate(_ r: Double) -> String { "\(Project.rateLabel(r)) fps" }
}
