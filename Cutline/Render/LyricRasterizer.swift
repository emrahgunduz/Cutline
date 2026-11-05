import CoreImage
import Foundation

/// Renders the lyric layer for a frame: visible lines from every lyric track, stacked in
/// track order, each word faded independently, with an optional blurred drop shadow.
final class LyricRenderer {
    let project: Project
    /// Line rasters survive snapshot rebuilds; keyed by text, style and canvas.
    private static let cache = NSCache<NSString, RasterBox>()
    private final class RasterBox { let raster: LineRaster; init(_ r: LineRaster) { raster = r } }

    init(project: Project) {
        self.project = project
        platformSafeArea = SafeArea.rect(for: project)
    }

    /// Lyrics are placed independently of the cinemascope bars: the animation never moves them.
    /// Portrait projects keep automatically placed lines clear of every platform's UI.
    private let platformSafeArea: CGRect?
    func safeArea(_ t: Double) -> CGRect? { platformSafeArea }

    /// Where each drawn line sits on the canvas at time t (y up), plus its raster and scale.
    struct PlacedLine { let line: LyricLine; let rect: CGRect; let raster: LineRaster; let fit: CGFloat }

    func placedLines(at t: Double) -> [PlacedLine] {
        let style = project.lyricStyle
        let canvas = project.canvas
        let lines = drawnLines(at: t)
        guard !lines.isEmpty else { return [] }
        let fontSize = LyricLayout.fontSize(style, canvas: canvas)
        let safe = safeArea(t)
        let maxWidth = (safe?.width ?? CGFloat(canvas.width)) * 0.92
        let centerX = safe?.midX ?? CGFloat(canvas.width) / 2
        // Long lines wrap onto more rows at the same font size; they take more room in the stack.
        let rasters = lines.map { raster(for: $0, style: style, fontSize: fontSize, maxWidth: $0.hasPosition ? CGFloat(canvas.width) * 0.92 : maxWidth) }
        let pad = ceil(fontSize * 0.15)
        var heights: [CGFloat] = []
        for (line, r) in zip(lines, rasters) where !line.hasPosition {
            let rows = r?.rows ?? 1
            let rowStep = r.map { ($0.size.height - pad) / CGFloat(rows) } ?? 0
            heights.append(LyricLayout.stackHeight(rows: rows, rowStep: rowStep, style: style, canvas: canvas))
        }
        let origins = LyricLayout.stackOrigins(heights: heights, style: style, canvas: canvas, safeArea: safe)
        var autoIndex = 0
        var out: [PlacedLine] = []
        for (line, r) in zip(lines, rasters) {
            guard let raster = r else { if !line.hasPosition { autoIndex += 1 }; continue }
            // Only a single word wider than the frame is scaled down.
            let limit = line.hasPosition ? CGFloat(canvas.width) * 0.92 : maxWidth
            let fit = min(1, limit / raster.size.width)
            let size = CGSize(width: raster.size.width * fit, height: raster.size.height * fit)
            let origin: CGPoint
            if let cx = line.centerX, let cy = line.centerY {
                origin = CGPoint(x: cx - size.width / 2, y: cy - size.height / 2)
            } else {
                // The raster's bottom sits at the bottom of its slot (wrapped lines get taller slots).
                origin = CGPoint(x: centerX - size.width / 2, y: origins[autoIndex])
                autoIndex += 1
            }
            out.append(PlacedLine(line: line, rect: CGRect(origin: origin, size: size), raster: raster, fit: fit))
        }
        return out
    }

    /// Canvas size of a line's text block (for alignment).
    func size(of line: LyricLine) -> CGSize? {
        let style = project.lyricStyle
        let maxWidth = CGFloat(project.canvas.width) * 0.92
        guard let r = raster(for: line, style: style, fontSize: LyricLayout.fontSize(style, canvas: project.canvas), maxWidth: maxWidth) else { return nil }
        let fit = min(1, maxWidth / r.size.width)
        return CGSize(width: r.size.width * fit, height: r.size.height * fit)
    }

    func image(at t: Double) -> CIImage? {
        let style = project.lyricStyle
        let placed = placedLines(at: t)
        guard !placed.isEmpty else { return nil }
        var text = CIImage.empty()
        for p in placed {
            let base = CIImage(cgImage: p.raster.image)
            let anim = animation
            let place = CGAffineTransform(scaleX: p.fit, y: p.fit).concatenating(CGAffineTransform(translationX: p.rect.minX, y: p.rect.minY))
            for (w, word) in p.line.words.enumerated() where w < p.raster.wordRects.count {
                // Whole word, or each letter on its own staggered fade.
                let boxes = anim.letterByLetter && w < p.raster.letterRects.count ? p.raster.letterRects[w] : [p.raster.wordRects[w]]
                for (i, box) in boxes.enumerated() {
                    let a = LyricLayout.alpha(of: word, letter: i, of: boxes.count, at: t, animation: anim)
                    guard a > 0 else { continue }
                    let piece = FilterChain.withOpacity(base.cropped(to: box), a).transformed(by: place)
                    text = piece.composited(over: text)
                }
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
        let a = animation
        return project.lyricTracks.flatMap { track in
            track.lines.filter { LyricLayout.isDrawn($0, at: t, animation: a) }
        }
    }

    var animation: LyricAnimation { LyricAnimation(style: project.lyricStyle, fps: project.fps) }

    private func raster(for line: LyricLine, style: LyricStyle, fontSize: CGFloat, maxWidth: CGFloat) -> LineRaster? {
        let key = "\(line.words.map(\.text).joined(separator: "\u{1}"))|\(style.fontName)|\(fontSize)|\(Int(maxWidth))|\(style.color.r),\(style.color.g),\(style.color.b),\(style.color.a)" as NSString
        if let box = Self.cache.object(forKey: key) { return box.raster }
        guard let r = LineRasterizer.rasterize(words: line.words.map(\.text), style: style, fontSize: fontSize, maxWidth: maxWidth) else { return nil }
        Self.cache.setObject(RasterBox(r), forKey: key)
        return r
    }
}
