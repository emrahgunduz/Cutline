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

    /// Lyrics are placed independently of the cinemascope bars: the animation never moves them.
    func safeArea(_ t: Double) -> CGRect? { nil }

    /// Where each drawn line sits on the canvas at time t (y up), plus its raster and scale.
    struct PlacedLine { let line: LyricLine; let rect: CGRect; let raster: LineRaster; let fit: CGFloat }

    func placedLines(at t: Double) -> [PlacedLine] {
        let style = project.lyricStyle
        let canvas = project.canvas
        let lines = drawnLines(at: t)
        guard !lines.isEmpty else { return [] }
        let fontSize = LyricLayout.fontSize(style, canvas: canvas)
        let auto = lines.filter { !$0.hasPosition }
        let origins = LyricLayout.stackOrigins(count: auto.count, style: style, canvas: canvas, safeArea: safeArea(t))
        let maxWidth = CGFloat(canvas.width) * 0.92
        var autoIndex = 0
        var out: [PlacedLine] = []
        for line in lines {
            guard let raster = raster(for: line, style: style, fontSize: fontSize) else { continue }
            let fit = min(1, maxWidth / raster.size.width)
            let size = CGSize(width: raster.size.width * fit, height: raster.size.height * fit)
            let origin: CGPoint
            if let cx = line.centerX, let cy = line.centerY {
                origin = CGPoint(x: cx - size.width / 2, y: cy - size.height / 2)
            } else {
                origin = CGPoint(x: (CGFloat(canvas.width) - size.width) / 2, y: origins[autoIndex])
                autoIndex += 1
            }
            out.append(PlacedLine(line: line, rect: CGRect(origin: origin, size: size), raster: raster, fit: fit))
        }
        return out
    }

    /// Canvas size of a line's text block (for alignment).
    func size(of line: LyricLine) -> CGSize? {
        let style = project.lyricStyle
        guard let r = raster(for: line, style: style, fontSize: LyricLayout.fontSize(style, canvas: project.canvas)) else { return nil }
        let fit = min(1, CGFloat(project.canvas.width) * 0.92 / r.size.width)
        return CGSize(width: r.size.width * fit, height: r.size.height * fit)
    }

    func image(at t: Double) -> CIImage? {
        let style = project.lyricStyle
        let placed = placedLines(at: t)
        guard !placed.isEmpty else { return nil }
        var text = CIImage.empty()
        for p in placed {
            let base = CIImage(cgImage: p.raster.image)
            for (w, word) in p.line.words.enumerated() where w < p.raster.wordRects.count {
                let a = LyricLayout.alpha(of: word, at: t, fps: project.fps)
                guard a > 0 else { continue }
                var piece = base.cropped(to: p.raster.wordRects[w])
                piece = FilterChain.withOpacity(piece, a)
                piece = piece.transformed(by: CGAffineTransform(scaleX: p.fit, y: p.fit))
                    .transformed(by: CGAffineTransform(translationX: p.rect.minX, y: p.rect.minY))
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
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(sc.a * style.shadowStrength)),
                "inputBiasVector": CIVector(x: CGFloat(sc.r), y: CGFloat(sc.g), z: CGFloat(sc.b), w: 0),
            ])
            .applyingGaussianBlur(sigma: max(0, style.shadowBlur))
            // Strength above 1 also boosts the blurred falloff, so the shadow reads denser.
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(1, style.shadowStrength))),
            ])
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
