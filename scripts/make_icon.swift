// Draws the Cutline app icon and writes the macOS AppIcon set.
// Usage: swift scripts/make_icon.swift <AppIcon.appiconset dir>
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Minimal mark: a dark squircle, one wide 2.35:1 frame, and a white cut line through it.
    let bg = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.16, blue: 0.19, alpha: 1), NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)])!
        .draw(in: bg, angle: -90)
    let frame = r(190, 395, 644, 274)          // 644 / 274 ≈ 2.35:1
    let framePath = NSBezierPath(roundedRect: frame, xRadius: 34 * s, yRadius: 34 * s)
    NSGradient(colors: [NSColor(red: 1.00, green: 0.62, blue: 0.24, alpha: 1), NSColor(red: 0.93, green: 0.24, blue: 0.47, alpha: 1)])!
        .draw(in: framePath, angle: 0)
    // Cut line with a small playhead cap.
    NSColor.white.setFill()
    NSBezierPath(roundedRect: r(566, 330, 16, 404), xRadius: 8 * s, yRadius: 8 * s).fill()
    let cap = NSBezierPath()
    cap.move(to: CGPoint(x: 544 * s, y: 760 * s))
    cap.line(to: CGPoint(x: 604 * s, y: 760 * s))
    cap.line(to: CGPoint(x: 574 * s, y: 722 * s))
    cap.close()
    cap.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! draw(size: CGFloat(px)).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let json: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("Contents.json"))
