import CoreGraphics
import CoreText
import Foundation

/// Timing and placement rules for lyric words, independent of rendering.
enum LyricLayout {
    /// Fast fade length in frames, shortened for words too brief to hold two full fades.
    static let fadeFrames = 3.0

    static func fadeDuration(wordDuration: Double, fps: Double) -> Double {
        let full = fadeFrames / fps
        return min(full, max(wordDuration, 0) / 2)
    }

    /// Word opacity at time t: fades in from `start`, holds, fades out after `end`.
    static func alpha(of word: LyricWord, at t: Double, fps: Double) -> Double {
        let fade = fadeDuration(wordDuration: word.end - word.start, fps: fps)
        guard fade > 0 else { return t >= word.start && t < word.end ? 1 : 0 }
        if t < word.start || t >= word.end + fade { return 0 }
        if t < word.start + fade { return (t - word.start) / fade }
        if t < word.end { return 1 }
        return 1 - (t - word.end) / fade
    }

    /// A line is drawn while any of its words is still visible.
    static func isDrawn(_ line: LyricLine, at t: Double, fps: Double) -> Bool {
        let tail = line.words.map { $0.end + fadeDuration(wordDuration: $0.end - $0.start, fps: fps) }.max() ?? line.end
        return t >= line.start && t < max(line.end, tail)
    }

    static func fontSize(_ style: LyricStyle, canvas: CanvasSize) -> CGFloat {
        CGFloat(style.sizeFraction) * CGFloat(canvas.height)
    }

    static func lineHeight(_ style: LyricStyle, canvas: CanvasSize) -> CGFloat { fontSize(style, canvas: canvas) * 1.3 }

    /// Baseline-box origins (bottom-left, Core Image coordinates) for `count` stacked lines.
    /// Index 0 is the top line; the block is centered on the style's vertical position.
    static func stackOrigins(count: Int, style: LyricStyle, canvas: CanvasSize, safeArea: CGRect? = nil) -> [CGFloat] {
        let lh = lineHeight(style, canvas: canvas)
        let block = lh * CGFloat(count)
        let centerFromTop = CGFloat(style.verticalPosition) * CGFloat(canvas.height)
        var top = CGFloat(canvas.height) - centerFromTop + block / 2      // CI: y grows upwards
        if let safe = safeArea {
            top = min(top, safe.maxY)
            top = max(top, safe.minY + block)
        }
        return (0..<count).map { top - lh * CGFloat($0 + 1) }
    }
}

/// One rasterized lyric line with the rectangle of each word inside the raster.
struct LineRaster {
    let image: CGImage
    let size: CGSize
    let wordRects: [CGRect]
}

enum LineRasterizer {
    static func font(_ style: LyricStyle, size: CGFloat) -> CTFont {
        let f = CTFontCreateWithName(style.fontName as CFString, size, nil)
        return f
    }

    /// Rasterize the line's words (joined by spaces) in the lyric color.
    static func rasterize(words: [String], style: LyricStyle, fontSize: CGFloat, scale: CGFloat = 1) -> LineRaster? {
        let text = words.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let ctFont = font(style, size: fontSize * scale)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.color.cgColor,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let pad = ceil(fontSize * scale * 0.15)
        let size = CGSize(width: ceil(width + pad * 2), height: ceil(ascent + descent + pad * 2))
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setAllowsFontSmoothing(false)
        ctx.textPosition = CGPoint(x: pad, y: pad + descent)
        CTLineDraw(line, ctx)
        guard let image = ctx.makeImage() else { return nil }

        var rects: [CGRect] = []
        var index = 0
        let ns = text as NSString
        for w in words {
            let len = (w as NSString).length
            let x0 = CTLineGetOffsetForStringIndex(line, index, nil)
            let x1 = CTLineGetOffsetForStringIndex(line, index + len, nil)
            rects.append(CGRect(x: pad + x0 - pad / 2, y: 0, width: x1 - x0 + pad, height: size.height))
            index += len + 1
            _ = ns
        }
        return LineRaster(image: image, size: size, wordRects: rects)
    }

    /// True when the font has a glyph for every character of `text`.
    static func covers(_ text: String, style: LyricStyle) -> Bool {
        let f = font(style, size: 24)
        let utf16 = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        return CTFontGetGlyphsForCharacters(f, utf16, &glyphs, utf16.count)
    }
}
