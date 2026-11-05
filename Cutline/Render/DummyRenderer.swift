import AppKit
import CoreImage
import CoreText

/// Draws a dummy card: the color fills the frame, the title is centred in the middle, and its
/// length sits under it in a smaller size, aligned to the title's left edge. Sizes follow the
/// frame, so the card looks the same at any resolution.
enum DummyRenderer {
    /// Title size as a fraction of the frame height, shrunk if the title would be wider than
    /// `maxWidth` of the frame.
    static let titleFraction: CGFloat = 0.085
    static let maxWidth: CGFloat = 0.8
    /// The length line, relative to the title size.
    static let subtitleScale: CGFloat = 0.42

    struct Layout: Equatable {
        var titleSize: CGFloat
        var subtitleSize: CGFloat
        /// Baseline origins (y up).
        var titleOrigin: CGPoint
        var subtitleOrigin: CGPoint
        var titleWidth: CGFloat
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

    static func layout(_ card: DummyCard, size: CGSize) -> Layout {
        var titleSize = max(1, size.height * titleFraction)
        let probe = line(card.title, font(card.fontName, size: titleSize, bold: true), .white)
        let w = width(probe)
        if w > size.width * maxWidth { titleSize *= size.width * maxWidth / w }
        let titleFont = font(card.fontName, size: titleSize, bold: true)
        let title = line(card.title, titleFont, .white)
        let titleWidth = width(title)
        let subtitleSize = titleSize * subtitleScale
        // The title's letters are centred in the frame (cap height around the middle).
        let capHeight = CTFontGetCapHeight(titleFont)
        let titleOrigin = CGPoint(x: (size.width - titleWidth) / 2, y: (size.height - capHeight) / 2)
        let gap = titleSize * 0.35
        let subtitleFont = font(card.fontName, size: subtitleSize, bold: false)
        let subtitleOrigin = CGPoint(x: titleOrigin.x, y: titleOrigin.y - CTFontGetDescent(titleFont) - gap - CTFontGetAscent(subtitleFont) * 0.75)
        return Layout(titleSize: titleSize, subtitleSize: subtitleSize, titleOrigin: titleOrigin, subtitleOrigin: subtitleOrigin, titleWidth: titleWidth)
    }

    private static let cache = NSCache<NSString, CGImage>()

    /// The card at `size` pixels (cached).
    static func image(_ card: DummyCard, size: CGSize) -> CGImage? {
        let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
        let key = "\(card.hashValue)|\(w)x\(h)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var bg = card.color
        bg.a = 1
        ctx.setFillColor(bg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let l = layout(card, size: CGSize(width: w, height: h))
        let ink = textColor(on: bg)
        var dim = ink
        dim.a = 0.72
        ctx.textPosition = l.titleOrigin
        CTLineDraw(line(card.title, font(card.fontName, size: l.titleSize, bold: true), ink), ctx)
        ctx.textPosition = l.subtitleOrigin
        CTLineDraw(line(card.lengthText, font(card.fontName, size: l.subtitleSize, bold: false), dim), ctx)
        guard let image = ctx.makeImage() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
