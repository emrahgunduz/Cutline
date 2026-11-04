import CoreImage
import Foundation

/// Renders the lyric layer for a frame: visible lines from every lyric track, stacked in
/// track order, each word faded independently, with an optional blurred drop shadow.
final class LyricRenderer {
    let project: Project
    /// Line rasters survive snapshot rebuilds; keyed by text, style and canvas.
    private static let cache = NSCache<NSString, RasterBox>()
    private final class RasterBox { let raster: LineRaster; init(_ r: LineRaster) { raster = r } }

    init(project: Project) { self.project = project }

    /// Optional bounds the lyric block must stay inside (canvas coordinates, CI orientation).
    var safeArea: (Double) -> CGRect? = { _ in nil }

    func image(at t: Double) -> CIImage? {
        let style = project.lyricStyle
        let canvas = project.canvas
        let lines = drawnLines(at: t)
        guard !lines.isEmpty else { return nil }
        let fontSize = LyricLayout.fontSize(style, canvas: canvas)
        let origins = LyricLayout.stackOrigins(count: lines.count, style: style, canvas: canvas, safeArea: safeArea(t))
        let maxWidth = CGFloat(canvas.width) * 0.92

        var text = CIImage.empty()
        for (i, line) in lines.enumerated() {
            guard let raster = raster(for: line, style: style, fontSize: fontSize) else { continue }
            let fit = min(1, maxWidth / raster.size.width)
            let x = (CGFloat(canvas.width) - raster.size.width * fit) / 2
            let base = CIImage(cgImage: raster.image)
            for (w, word) in line.words.enumerated() where w < raster.wordRects.count {
                let a = LyricLayout.alpha(of: word, at: t, fps: project.fps)
                guard a > 0 else { continue }
                var piece = base.cropped(to: raster.wordRects[w])
                piece = FilterChain.withOpacity(piece, a)
                piece = piece.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
                    .transformed(by: CGAffineTransform(translationX: x, y: origins[i]))
                text = piece.composited(over: text)
            }
        }
        guard style.shadowEnabled else { return text }
        // Shadow offset: +dx moves right, +dy moves down.
        let sc = style.shadowColor
        let shadow = text
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(sc.a)),
                "inputBiasVector": CIVector(x: CGFloat(sc.r), y: CGFloat(sc.g), z: CGFloat(sc.b), w: 0),
            ])
            .applyingGaussianBlur(sigma: max(0, style.shadowBlur))
            .transformed(by: CGAffineTransform(translationX: style.shadowDX, y: -style.shadowDY))
        return text.composited(over: shadow)
    }

    /// Lines on screen at t, in track order (track 1 first, drawn on top of the stack).
    func drawnLines(at t: Double) -> [LyricLine] {
        project.lyricTracks.flatMap { track in
            track.lines.filter { LyricLayout.isDrawn($0, at: t, fps: project.fps) }
        }
    }

    private func raster(for line: LyricLine, style: LyricStyle, fontSize: CGFloat) -> LineRaster? {
        let key = "\(line.words.map(\.text).joined(separator: "\u{1}"))|\(style.fontName)|\(fontSize)|\(style.color.r),\(style.color.g),\(style.color.b),\(style.color.a)" as NSString
        if let box = Self.cache.object(forKey: key) { return box.raster }
        guard let r = LineRasterizer.rasterize(words: line.words.map(\.text), style: style, fontSize: fontSize) else { return nil }
        Self.cache.setObject(RasterBox(r), forKey: key)
        return r
    }
}
