// Draws the .cutline document icon and writes an .iconset folder for iconutil.
// Usage: swift scripts/make_doc_icon.swift <output.iconset>
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Page with a folded top-right corner.
    let fold: CGFloat = 190
    let page = NSBezierPath()
    page.move(to: CGPoint(x: 180 * s, y: 60 * s))
    page.line(to: CGPoint(x: 844 * s, y: 60 * s))
    page.line(to: CGPoint(x: 844 * s, y: (964 - fold) * s))
    page.line(to: CGPoint(x: (844 - fold) * s, y: 964 * s))
    page.line(to: CGPoint(x: 180 * s, y: 964 * s))
    page.close()
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 18 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSGradient(colors: [NSColor(red: 0.20, green: 0.20, blue: 0.23, alpha: 1), NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)])!
        .draw(in: page, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let corner = NSBezierPath()
    corner.move(to: CGPoint(x: (844 - fold) * s, y: 964 * s))
    corner.line(to: CGPoint(x: (844 - fold) * s, y: (964 - fold) * s))
    corner.line(to: CGPoint(x: 844 * s, y: (964 - fold) * s))
    corner.close()
    NSColor(red: 0.34, green: 0.34, blue: 0.38, alpha: 1).setFill()
    corner.fill()

    // The app mark: 2.35:1 frame with a cut line.
    let frame = r(262, 470, 500, 213)
    NSGradient(colors: [NSColor(red: 1.00, green: 0.62, blue: 0.24, alpha: 1), NSColor(red: 0.93, green: 0.24, blue: 0.47, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: frame, xRadius: 28 * s, yRadius: 28 * s), angle: 0)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: r(546, 420, 14, 313), xRadius: 7 * s, yRadius: 7 * s).fill()

    // Label.
    if size >= 64 {
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 92 * s, weight: .heavy),
                                                    .foregroundColor: NSColor.white.withAlphaComponent(0.9), .paragraphStyle: para, .kern: 6 * s]
        ("CUTLINE" as NSString).draw(in: r(180, 200, 664, 120), withAttributes: attrs)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! draw(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
