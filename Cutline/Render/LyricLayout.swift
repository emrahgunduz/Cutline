import CoreGraphics
import CoreText
import Foundation

/// Timing and placement rules for lyric words, independent of rendering.
/// Resolved word animation for a project: fade times and letter-by-letter settings.
struct LyricAnimation {
    var fadeIn: Double
    var fadeOut: Double
    var letterByLetter: Bool
    var overlap: Double

    static func defaultFade(fps: Double) -> Double { LyricLayout.fadeFrames / fps }

    init(fadeIn: Double, fadeOut: Double, letterByLetter: Bool = false, overlap: Double = 0.5) {
        self.fadeIn = fadeIn; self.fadeOut = fadeOut; self.letterByLetter = letterByLetter; self.overlap = overlap
    }

    init(style: LyricStyle, fps: Double) {
        let d = Self.defaultFade(fps: fps)
        self.init(fadeIn: style.fadeInValue ?? d, fadeOut: style.fadeOutValue ?? d,
                  letterByLetter: style.letterByLetter, overlap: min(max(style.letterOverlap, 0), 1))
    }
}

enum LyricLayout {
    /// Default fast fade length in frames.
    static let fadeFrames = 3.0

    static func fadeDuration(wordDuration: Double, fps: Double) -> Double {
        min(fadeFrames / fps, max(wordDuration, 0) / 2)
    }

    /// A fade length shortened for words too brief to hold both fades.
    static func clamped(_ fade: Double, wordDuration: Double) -> Double { min(max(fade, 0), max(wordDuration, 0) / 2) }

    /// Rising/falling ramp: 0 before `start`, 1 after `start + length`.
    private static func ramp(_ t: Double, start: Double, length: Double) -> Double {
        guard length > 0 else { return t >= start ? 1 : 0 }
        return min(max((t - start) / length, 0), 1)
    }

    /// Letter-by-letter timing inside a word fade of length `total`: each of `n` letters
    /// fades for `length`, and the next starts after `step` = length × (1 − overlap), so the
    /// whole word still appears (or disappears) within `total`.
    static func letterTiming(total: Double, letters n: Int, overlap: Double) -> (length: Double, step: Double) {
        guard n > 1 else { return (total, 0) }
        let length = total / (1 + Double(n - 1) * (1 - overlap))
        return (length, length * (1 - overlap))
    }

    /// Opacity of letter `index` of `count` (whole-word mode is count 1).
    static func alpha(of word: LyricWord, letter index: Int = 0, of count: Int = 1, at t: Double, animation a: LyricAnimation) -> Double {
        let dur = word.end - word.start
        let fin = clamped(a.fadeIn, wordDuration: dur), fout = clamped(a.fadeOut, wordDuration: dur)
        let n = a.letterByLetter ? max(1, count) : 1
        let i = Double(a.letterByLetter ? min(index, n - 1) : 0)
        let tin = letterTiming(total: fin, letters: n, overlap: a.overlap)
        let tout = letterTiming(total: fout, letters: n, overlap: a.overlap)
        let inStart = word.start + i * tin.step
        let outStart = word.end + i * tout.step
        if t < inStart || t >= outStart + tout.length { return 0 }
        return min(ramp(t, start: inStart, length: tin.length), 1 - ramp(t, start: outStart, length: tout.length))
    }

    /// Word opacity with the default animation (kept for callers that only know the fps).
    static func alpha(of word: LyricWord, at t: Double, fps: Double) -> Double {
        let d = LyricAnimation.defaultFade(fps: fps)
        return alpha(of: word, at: t, animation: LyricAnimation(fadeIn: d, fadeOut: d))
    }

    /// When a word has fully disappeared.
    static func visibleEnd(of word: LyricWord, letters: Int, animation a: LyricAnimation) -> Double {
        // Fade-out (all letters included) always fits in the fade-out time.
        word.end + clamped(a.fadeOut, wordDuration: word.end - word.start)
    }

    /// A line is drawn while any of its words is still visible.
    static func isDrawn(_ line: LyricLine, at t: Double, animation a: LyricAnimation) -> Bool {
        let tail = line.words.map { visibleEnd(of: $0, letters: $0.text.count, animation: a) }.max() ?? line.end
        return t >= line.start && t < max(line.end, tail)
    }

    static func isDrawn(_ line: LyricLine, at t: Double, fps: Double) -> Bool {
        let d = LyricAnimation.defaultFade(fps: fps)
        return isDrawn(line, at: t, animation: LyricAnimation(fadeIn: d, fadeOut: d))
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
    /// Per word, the rectangle of each letter (grapheme), for letter-by-letter fades.
    var letterRects: [[CGRect]] = []
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
        var letters: [[CGRect]] = []
        var index = 0
        for w in words {
            let len = (w as NSString).length
            let x0 = CTLineGetOffsetForStringIndex(line, index, nil)
            let x1 = CTLineGetOffsetForStringIndex(line, index + len, nil)
            rects.append(CGRect(x: pad + x0 - pad / 2, y: 0, width: x1 - x0 + pad, height: size.height))
            // Letter boxes meet halfway between glyph edges so neighbours don't double up.
            var edges: [CGFloat] = []
            var u = index
            for ch in w { edges.append(CTLineGetOffsetForStringIndex(line, u, nil)); u += ch.utf16.count }
            edges.append(x1)
            var boxes: [CGRect] = []
            for k in 0..<(edges.count - 1) {
                let left = k == 0 ? pad + edges[k] - pad / 2 : pad + edges[k]
                let right = k == edges.count - 2 ? pad + edges[k + 1] + pad / 2 : pad + edges[k + 1]
                boxes.append(CGRect(x: left, y: 0, width: right - left, height: size.height))
            }
            letters.append(boxes)
            index += len + 1
        }
        var raster = LineRaster(image: image, size: size, wordRects: rects)
        raster.letterRects = letters
        return raster
    }

    /// True when the font has a glyph for every character of `text`.
    static func covers(_ text: String, style: LyricStyle) -> Bool {
        let f = font(style, size: 24)
        let utf16 = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        return CTFontGetGlyphsForCharacters(f, utf16, &glyphs, utf16.count)
    }
}
