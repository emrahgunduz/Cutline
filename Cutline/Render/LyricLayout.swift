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
        stackOrigins(heights: Array(repeating: lineHeight(style, canvas: canvas), count: count), style: style, canvas: canvas, safeArea: safeArea)
    }

    /// Height a line takes in the stack: one line height, plus a row for each extra wrapped row.
    static func stackHeight(rows: Int, rowStep: CGFloat, style: LyricStyle, canvas: CanvasSize) -> CGFloat {
        lineHeight(style, canvas: canvas) + CGFloat(max(0, rows - 1)) * rowStep
    }

    /// Origins for stacked lines of the given heights (top line first).
    static func stackOrigins(heights: [CGFloat], style: LyricStyle, canvas: CanvasSize, safeArea: CGRect? = nil) -> [CGFloat] {
        let block = heights.reduce(0, +)
        let centerFromTop = CGFloat(style.verticalPosition) * CGFloat(canvas.height)
        var top = CGFloat(canvas.height) - centerFromTop + block / 2      // CI: y grows upwards
        if let safe = safeArea {
            top = min(top, safe.maxY)
            top = max(top, safe.minY + block)
        }
        var out: [CGFloat] = []
        var y = top
        for h in heights { y -= h; out.append(y) }
        return out
    }
}

/// One rasterized lyric line with the rectangle of each word inside the raster.
struct LineRaster {
    let image: CGImage
    let size: CGSize
    let wordRects: [CGRect]
    /// Per word, the rectangle of each letter (grapheme), for letter-by-letter fades.
    var letterRects: [[CGRect]] = []
    /// Rows the line has (1 for a single line).
    var rows = 1
    /// Where the letters are (glyph outlines, raster coordinates, y up).
    var ink: CGRect = .null
}

enum LineRasterizer {
    static func font(_ style: LyricStyle, size: CGFloat) -> CTFont {
        let f = CTFontCreateWithName(style.fontName as CFString, size, nil)
        return f
    }

    /// Rasterize the line's words in the lyric color, at the font size (never scaled to fit).
    /// - `wrapWidth` nil: one row, as wide as the text.
    /// - `wrapWidth` set: the words wrap at that width (in canvas pixels at `scale` 1); the box
    ///   is that wide (wider only if one word is), and as tall as its rows.
    /// - `align`: where each row sits inside the box.
    static func rasterize(words: [String], style: LyricStyle, fontSize: CGFloat, scale: CGFloat = 1,
                          wrapWidth: CGFloat? = nil, align: LineLayout.Align = .left) -> LineRaster? {
        guard !words.joined().isEmpty else { return nil }
        let ctFont = font(style, size: fontSize * scale)
        func ctLine(_ text: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.color.cgColor,
            ]))
        }
        func width(_ line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }
        let pad = ceil(fontSize * scale * 0.15)
        let rows = wrap(words, width: wrapWidth.map { $0 * scale }) { width(ctLine($0.joined(separator: " "))) }
        let lines = rows.map { ctLine($0.joined(separator: " ")) }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(ctLine(words.joined(separator: " ")), &ascent, &descent, &leading)
        let widths = lines.map(width)
        let content = max(widths.max() ?? 0, wrapWidth.map { $0 * scale } ?? 0)
        let rowStep = ceil(ascent + descent + pad)
        let size = CGSize(width: max(1, ceil(content + pad * 2)), height: ceil(rowStep * CGFloat(rows.count) + pad))
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setAllowsFontSmoothing(false)
        var rects: [CGRect] = []
        var letters: [[CGRect]] = []
        var ink = CGRect.null
        for (r, rowWords) in rows.enumerated() {
            let line = lines[r]
            // Row 0 is on top (y grows upwards).
            let bottom = rowStep * CGFloat(rows.count - 1 - r)
            let left: CGFloat
            switch align {
            case .left: left = 0
            case .center: left = (content - widths[r]) / 2
            case .right: left = content - widths[r]
            }
            ctx.textPosition = CGPoint(x: pad + left, y: pad + descent + bottom)
            CTLineDraw(line, ctx)
            let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            if !glyphs.isEmpty { ink = ink.union(glyphs.offsetBy(dx: pad + left, dy: pad + descent + bottom)) }
            // Each row's band: from halfway into the padding below to halfway above (first and
            // last rows reach the raster's edges), so neighbouring rows never double up.
            let y0 = r == rows.count - 1 ? 0 : bottom + pad / 2
            let y1 = r == 0 ? size.height : bottom + pad / 2 + rowStep
            var index = 0
            for w in rowWords {
                let len = (w as NSString).length
                let x0 = CTLineGetOffsetForStringIndex(line, index, nil)
                let x1 = CTLineGetOffsetForStringIndex(line, index + len, nil)
                let ox = pad + left
                rects.append(CGRect(x: ox + x0 - pad / 2, y: y0, width: x1 - x0 + pad, height: y1 - y0))
                // Letter boxes meet halfway between glyph edges so neighbours don't double up.
                var edges: [CGFloat] = []
                var u = index
                for ch in w { edges.append(CTLineGetOffsetForStringIndex(line, u, nil)); u += ch.utf16.count }
                edges.append(x1)
                var boxes: [CGRect] = []
                for k in 0..<(edges.count - 1) {
                    let l = k == 0 ? ox + edges[k] - pad / 2 : ox + edges[k]
                    let rt = k == edges.count - 2 ? ox + edges[k + 1] + pad / 2 : ox + edges[k + 1]
                    boxes.append(CGRect(x: l, y: y0, width: rt - l, height: y1 - y0))
                }
                letters.append(boxes)
                index += len + 1
            }
        }
        guard let image = ctx.makeImage() else { return nil }
        var raster = LineRaster(image: image, size: size, wordRects: rects)
        raster.letterRects = letters
        raster.rows = rows.count
        raster.ink = ink.isNull ? CGRect(origin: .zero, size: size) : ink
        return raster
    }

    /// Split words into rows no wider than `width`, filling each row before starting the next
    /// (like a text box). nil = one row. A word wider than the width gets a row of its own.
    static func wrap(_ words: [String], width: CGFloat?, measure: ([String]) -> CGFloat) -> [[String]] {
        guard let width, words.count > 1 else { return [words] }
        var rows: [[String]] = [], row: [String] = []
        for w in words {
            if !row.isEmpty && measure(row + [w]) > width + 0.5 { rows.append(row); row = [w] } else { row.append(w) }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    /// True when the font has a glyph for every character of `text`.
    static func covers(_ text: String, style: LyricStyle) -> Bool {
        let f = font(style, size: 24)
        let utf16 = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        return CTFontGetGlyphsForCharacters(f, utf16, &glyphs, utf16.count)
    }
}
