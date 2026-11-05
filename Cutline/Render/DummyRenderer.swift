import AppKit
import CoreImage
import CoreText

/// Draws a dummy card: the color fills the frame; the title sits at the top left, the scene
/// description under it (wrapped across the frame), and the length at the bottom right. All
/// measurements are for an HD frame (1080 px on the short side) and scale with the frame, so
/// the card looks the same at any resolution.
enum DummyRenderer {
    /// Padding from the frame's edges, in HD pixels.
    static let padding: CGFloat = 100
    /// Font sizes in HD pixels.
    static let titleSize: CGFloat = 110
    static let descriptionSize: CGFloat = 44
    static let timeSize: CGFloat = 56

    struct Layout: Equatable {
        /// HD pixels → frame pixels.
        var scale: CGFloat
        var padding: CGFloat
        var titleSize: CGFloat
        var descriptionSize: CGFloat
        var timeSize: CGFloat
        /// Baseline origins (y up).
        var titleOrigin: CGPoint
        var titleWidth: CGFloat
        /// Where the description wraps (y up); empty when there is none.
        var descriptionRect: CGRect
        var timeOrigin: CGPoint
        var timeWidth: CGFloat
    }

    /// Black text on light colors, white on dark ones.
    static func textColor(on c: RGBA) -> RGBA {
        let luminance = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        return luminance > 0.55 ? RGBA(r: 0.08, g: 0.08, b: 0.09, a: 1) : .white
    }

    /// The font family at a size; the system font when the family isn't installed.
    static func font(_ family: String, size: CGFloat, bold: Bool) -> CTFont {
        let weight = bold ? 9 : 5
        if let f = NSFontManager.shared.font(withFamily: family, traits: bold ? .boldFontMask : [], weight: weight, size: size) { return f as CTFont }
        return NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular) as CTFont
    }

    private static func line(_ text: String, _ font: CTFont, _ color: RGBA) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]))
    }

    private static func width(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

    /// The share of the frame's height each cinemascope bar covers when the project draws
    /// them (0 = none): the card's text stays inside the picture the bars leave.
    static func barFraction(for p: Project) -> CGFloat {
        guard p.type == .musicVideo, p.cinemascope.enabled, p.canvas.height > 0 else { return 0 }
        return CGFloat(Letterbox.fullBarHeight(p.canvas) / Double(p.canvas.height))
    }

    /// - Parameter barFraction: bar height / frame height; the paddings start at the bars.
    static func layout(_ card: DummyCard, size: CGSize, barFraction: CGFloat = 0) -> Layout {
        let scale = max(0.01, min(size.width, size.height) / 1080)
        let pad = padding * scale
        let bar = max(0, min(0.4, barFraction)) * size.height
        let textWidth = max(1, size.width - pad * 2)
        // Title: one line, shrunk only if it wouldn't fit between the paddings.
        var tSize = titleSize * scale
        let probe = width(line(card.title, font(card.fontName, size: tSize, bold: true), .white))
        if probe > textWidth { tSize *= textWidth / probe }
        let titleFont = font(card.fontName, size: tSize, bold: true)
        let titleWidth = width(line(card.title, titleFont, .white))
        // Top left: the title's ascent touches the top padding.
        let titleOrigin = CGPoint(x: pad, y: size.height - bar - pad - CTFontGetAscent(titleFont))
        // Time: bottom right, its descent on the bottom padding.
        let timeSize = Self.timeSize * scale
        let timeFont = font(card.fontName, size: timeSize, bold: true)
        let timeWidth = width(line(card.lengthText, timeFont, .white))
        let timeOrigin = CGPoint(x: size.width - pad - timeWidth, y: bar + pad + CTFontGetDescent(timeFont))
        // Description: under the title, across the frame, down to just above the time.
        let gap = tSize * 0.35
        let top = titleOrigin.y - CTFontGetDescent(titleFont) - gap
        let bottom = timeOrigin.y + CTFontGetAscent(timeFont) + gap
        let rect = card.sceneDescription.isEmpty || top <= bottom ? .zero : CGRect(x: pad, y: bottom, width: textWidth, height: top - bottom)
        return Layout(scale: scale, padding: pad, titleSize: tSize, descriptionSize: descriptionSize * scale, timeSize: timeSize,
                      titleOrigin: titleOrigin, titleWidth: titleWidth, descriptionRect: rect, timeOrigin: timeOrigin, timeWidth: timeWidth)
    }

    /// The description wrapped into its rect (left aligned, a little line spacing).
    static func descriptionFrame(_ card: DummyCard, _ l: Layout, color: RGBA) -> CTFrame? {
        guard !l.descriptionRect.isEmpty else { return nil }
        var spacing = l.descriptionSize * 0.25
        let settings = [CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: &spacing)]
        let paragraph = CTParagraphStyleCreate(settings, settings.count)
        let text = NSAttributedString(string: card.sceneDescription, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(card.fontName, size: l.descriptionSize, bold: false),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
        let setter = CTFramesetterCreateWithAttributedString(text)
        return CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: l.descriptionRect, transform: nil), nil)
    }

    /// How many lines of the description fit (the rest is cut at the time line).
    static func descriptionLineCount(_ card: DummyCard, size: CGSize, barFraction: CGFloat = 0) -> Int {
        let l = layout(card, size: size, barFraction: barFraction)
        guard let f = descriptionFrame(card, l, color: .white) else { return 0 }
        return CFArrayGetCount(CTFrameGetLines(f))
    }

    private static let cache = NSCache<NSString, CGImage>()

    /// The card at `size` pixels (cached).
    static func image(_ card: DummyCard, size: CGSize, barFraction: CGFloat = 0) -> CGImage? {
        let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
        let key = "\(card.hashValue)|\(w)x\(h)|\(barFraction)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var bg = card.color
        bg.a = 1
        ctx.setFillColor(bg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let l = layout(card, size: CGSize(width: w, height: h), barFraction: barFraction)
        let ink = textColor(on: bg)
        var soft = ink
        soft.a = 0.85
        ctx.textPosition = l.titleOrigin
        CTLineDraw(line(card.title, font(card.fontName, size: l.titleSize, bold: true), ink), ctx)
        if let frame = descriptionFrame(card, l, color: soft) { CTFrameDraw(frame, ctx) }
        ctx.textPosition = l.timeOrigin
        CTLineDraw(line(card.lengthText, font(card.fontName, size: l.timeSize, bold: true), soft), ctx)
        guard let image = ctx.makeImage() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
