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

    // Squircle background with a deep night gradient.
    let bg = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.11, blue: 0.20, alpha: 1), NSColor(red: 0.03, green: 0.03, blue: 0.07, alpha: 1)])!
        .draw(in: bg, angle: -90)

    // Cinemascope frame: wide screen with a warm sunset image inside.
    let screen = r(170, 470, 684, 291)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 18 * s, yRadius: 18 * s)
    NSGradient(colors: [NSColor(red: 0.98, green: 0.55, blue: 0.25, alpha: 1), NSColor(red: 0.85, green: 0.22, blue: 0.45, alpha: 1),
                        NSColor(red: 0.30, green: 0.18, blue: 0.55, alpha: 1)])!.draw(in: screenPath, angle: -90)
    // Sun.
    NSColor(red: 1, green: 0.88, blue: 0.55, alpha: 0.95).setFill()
    NSBezierPath(ovalIn: r(440, 560, 144, 144)).fill()
    // Horizon silhouette.
    NSColor(red: 0.08, green: 0.06, blue: 0.14, alpha: 1).setFill()
    let hills = NSBezierPath()
    hills.move(to: CGPoint(x: screen.minX, y: screen.minY))
    hills.line(to: CGPoint(x: screen.minX, y: 540 * s))
    hills.curve(to: CGPoint(x: 512 * s, y: 545 * s), controlPoint1: CGPoint(x: 300 * s, y: 600 * s), controlPoint2: CGPoint(x: 420 * s, y: 520 * s))
    hills.curve(to: CGPoint(x: screen.maxX, y: 575 * s), controlPoint1: CGPoint(x: 640 * s, y: 580 * s), controlPoint2: CGPoint(x: 760 * s, y: 520 * s))
    hills.line(to: CGPoint(x: screen.maxX, y: screen.minY))
    hills.close()
    NSGraphicsContext.saveGraphicsState(); screenPath.addClip(); hills.fill(); NSGraphicsContext.restoreGraphicsState()

    // Timeline: two clip rows and a waveform.
    let clipColors = [NSColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 1), NSColor(red: 0.62, green: 0.45, blue: 0.85, alpha: 1)]
    let rows: [[(CGFloat, CGFloat)]] = [[(170, 230), (412, 180), (604, 250)], [(170, 120), (302, 300), (614, 240)]]
    for (i, row) in rows.enumerated() {
        for (x, w) in row {
            clipColors[i].setFill()
            NSBezierPath(roundedRect: r(x, 380 - CGFloat(i) * 70, w - 12, 50), xRadius: 12 * s, yRadius: 12 * s).fill()
        }
    }
    NSColor(red: 0.35, green: 0.85, blue: 0.60, alpha: 1).setFill()
    var x: CGFloat = 176
    var k = 0
    while x < 850 {
        let h = (abs(sin(CGFloat(k) * 0.55)) * 0.7 + abs(sin(CGFloat(k) * 1.7)) * 0.3) * 70 + 8
        NSBezierPath(roundedRect: r(x, 200 - h / 2, 10, h), xRadius: 5 * s, yRadius: 5 * s).fill()
        x += 18; k += 1
    }
    // Playhead.
    NSColor(red: 1, green: 0.30, blue: 0.30, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(560, 150, 10, 640), xRadius: 5 * s, yRadius: 5 * s).fill()
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
