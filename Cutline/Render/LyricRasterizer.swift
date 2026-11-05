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

    /// Where each drawn line sits on the canvas at time t (y up), plus its raster. `fit` is
    /// always 1: lyrics are drawn at the font size and never scaled to fit the frame.
    struct PlacedLine { let line: LyricLine; let rect: CGRect; let raster: LineRaster; let fit: CGFloat }

    func placedLines(at t: Double) -> [PlacedLine] {
        let style = project.lyricStyle
        let canvas = project.canvas
        let lines = drawnLines(at: t)
        guard !lines.isEmpty else { return [] }
        let fontSize = LyricLayout.fontSize(style, canvas: canvas)
        let safe = safeArea(t)
        let centerX = safe?.midX ?? CGFloat(canvas.width) / 2
        let rasters = lines.map { raster(for: $0, style: style, fontSize: fontSize) }
        // Wrapped lines take one stack slot per row.
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
            let size = raster.size
            let origin: CGPoint
            if let ax = line.centerX, let cy = line.centerY {
                // The anchor is the box's left edge, middle or right edge, by the text alignment.
                origin = CGPoint(x: LineLayout.boxMinX(anchor: CGFloat(ax), width: size.width, align: line.layout.align), y: CGFloat(cy) - size.height / 2)
            } else {
                // Automatic stack: boxes centred, each raster's bottom at the bottom of its slot.
                origin = CGPoint(x: centerX - size.width / 2, y: origins[autoIndex])
                autoIndex += 1
            }
            out.append(PlacedLine(line: line, rect: CGRect(origin: origin, size: size), raster: raster, fit: 1))
        }
        return out
    }

    /// A line's drawn box and where its letters are in it (for alignment).
    func box(of line: LyricLine) -> LyricPlacement.Box? {
        let style = project.lyricStyle
        guard let r = raster(for: line, style: style, fontSize: LyricLayout.fontSize(style, canvas: project.canvas)) else { return nil }
        return LyricPlacement.Box(size: r.size, ink: r.ink)
    }

    /// Canvas size of a line's text block.
    func size(of line: LyricLine) -> CGSize? { box(of: line)?.size }

    /// Where a line's anchor x is for a box drawn at `rect` (see `LyricLine.centerX`).
    static func anchor(of line: LyricLine, rect: CGRect) -> CGFloat {
        LineLayout.anchor(boxMidX: rect.midX, width: rect.width, align: line.layout.align)
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
        return project.lyricTracks.filter { !$0.isHidden }.flatMap { track in
            track.lines.filter { LyricLayout.isDrawn($0, at: t, animation: a) }
        }
    }

    var animation: LyricAnimation { LyricAnimation(style: project.lyricStyle, fps: project.fps) }

    private func raster(for line: LyricLine, style: LyricStyle, fontSize: CGFloat) -> LineRaster? {
        let l = line.layout
        let wrap = l.wrapWidth.map { CGFloat($0) }
        let key = "\(line.words.map(\.text).joined(separator: "\u{1}"))|\(style.fontName)|\(fontSize)|\(wrap.map { "\($0)" } ?? "single")|\(l.align.rawValue)|\(style.color.r),\(style.color.g),\(style.color.b),\(style.color.a)" as NSString
        if let box = Self.cache.object(forKey: key) { return box.raster }
        guard let r = LineRasterizer.rasterize(words: line.words.map(\.text), style: style, fontSize: fontSize, wrapWidth: wrap, align: l.align) else { return nil }
        Self.cache.setObject(RasterBox(r), forKey: key)
        return r
    }
}
