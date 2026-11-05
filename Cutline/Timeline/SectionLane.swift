import AppKit

/// Song analysis drawn in the audio row: a section lane along the top, loud and quiet
/// shading behind the waveform, and beat ticks along the bottom (downbeats taller).
/// Analysis times are audio-file seconds; `audioStart` maps them onto the timeline.
enum SectionLane {
    static let laneHeight: CGFloat = 13
    static let tickHeight: CGFloat = 7
    static let boundaryGrab: CGFloat = 5
    static let downbeatGrab: CGFloat = 4

    static func lane(in clip: CGRect) -> CGRect { CGRect(x: clip.minX, y: clip.minY, width: clip.width, height: laneHeight) }
    static func ticks(in clip: CGRect) -> CGRect { CGRect(x: clip.minX, y: clip.maxY - tickHeight, width: clip.width, height: tickHeight) }
    /// The waveform area once the lane and ticks are drawn.
    static func waveform(in clip: CGRect) -> CGRect {
        CGRect(x: clip.minX, y: clip.minY + laneHeight, width: clip.width, height: max(0, clip.height - laneHeight - tickHeight))
    }

    static let palette: [NSColor] = [
        NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.95, green: 0.60, blue: 0.30, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.45, alpha: 1), NSColor(calibratedRed: 0.85, green: 0.45, blue: 0.75, alpha: 1),
        NSColor(calibratedRed: 0.95, green: 0.85, blue: 0.35, alpha: 1), NSColor(calibratedRed: 0.45, green: 0.85, blue: 0.85, alpha: 1),
    ]

    static func color(for label: String) -> NSColor {
        let i = Int(label.unicodeScalars.first?.value ?? 65) - 65
        return palette[((i % palette.count) + palette.count) % palette.count]
    }

    static let loudColor = NSColor.systemOrange
    static let quietColor = NSColor(calibratedRed: 0.35, green: 0.6, blue: 1, alpha: 1)

    /// Loudness over the waveform: tinted patches for loud (orange) and quiet (blue) stretches,
    /// the loudness curve they come from, and the two levels it is measured against (dashed).
    /// A patch is where the curve stays above the loud line or below the quiet line.
    static func drawLoudness(_ regions: [Loudness.Region], audioStart: Double, in wave: CGRect,
                             visible: ClosedRange<CGFloat>, x: (Double) -> CGFloat) {
        let font = NSFont.systemFont(ofSize: 8, weight: .bold)
        for r in regions {
            let x0 = max(wave.minX, x(audioStart + r.start)), x1 = min(wave.maxX, x(audioStart + r.end))
            guard x1 > x0 else { continue }
            let c = r.kind == .loud ? loudColor : quietColor
            c.withAlphaComponent(0.14).setFill()
            CGRect(x: x0, y: wave.minY, width: x1 - x0, height: wave.height).fill()
            let label = (r.kind == .loud ? "LOUD" : "QUIET") as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: c.withAlphaComponent(0.95)]
            let size = label.size(withAttributes: attrs)
            if x1 - x0 > size.width + 8 {
                label.draw(at: CGPoint(x: max(x0, visible.lowerBound) + 3, y: wave.maxY - size.height - 1), withAttributes: attrs)
            }
        }
    }

    /// Where the waveform draws an amplitude `v` (0...1) in `wave`: above and below its centre
    /// line. The waveform, the loudness curve and the loud/quiet levels all use this, so they
    /// share one scale.
    /// `gain` scales the song so its loudest moment fills the row (Waveform.displayGain).
    static let wavePadding: CGFloat = 4

    static func amplitudeY(_ v: Float, gain: Float = 1, in wave: CGRect) -> (top: CGFloat, bottom: CGFloat) {
        let half = max(0, wave.height / 2 - wavePadding)
        let a = CGFloat(min(1, max(0, v * gain))) * half
        return (wave.midY - a, wave.midY + a)
    }

    /// The loudness curve (smoothed RMS, mirrored like the waveform's RMS layer) and the loud
    /// and quiet levels (dashed, mirrored), drawn over the waveform on its own scale.
    static func drawLoudnessCurve(_ envelope: Loudness.Envelope?, gain: Float, audioStart: Double, in wave: CGRect,
                                  visible: ClosedRange<CGFloat>, time: (CGFloat) -> Double) {
        guard let e = envelope, e.peak > 0, wave.height > 12 else { return }
        let lo = max(visible.lowerBound, wave.minX), hi = min(visible.upperBound, wave.maxX)
        guard hi > lo else { return }
        for (level, color) in [(e.loudLevel, loudColor), (e.quietLevel, quietColor)] {
            let y = amplitudeY(level, gain: gain, in: wave)
            let line = NSBezierPath()
            for edge in [y.top, y.bottom] {
                line.move(to: CGPoint(x: lo, y: edge)); line.line(to: CGPoint(x: hi, y: edge))
            }
            line.setLineDash([4, 3], count: 2, phase: 0)
            line.lineWidth = 1
            color.withAlphaComponent(0.8).setStroke()
            line.stroke()
        }
        let upper = NSBezierPath(), lower = NSBezierPath()
        var px = lo
        var first = true
        while px <= hi {
            let y = amplitudeY(e.value(at: time(px) - audioStart), gain: gain, in: wave)
            if first { upper.move(to: CGPoint(x: px, y: y.top)); lower.move(to: CGPoint(x: px, y: y.bottom)); first = false }
            else { upper.line(to: CGPoint(x: px, y: y.top)); lower.line(to: CGPoint(x: px, y: y.bottom)) }
            px += 2
        }
        NSColor.systemYellow.withAlphaComponent(0.9).setStroke()
        for c in [upper, lower] { c.lineWidth = 1.5; c.lineJoinStyle = .round; c.stroke() }
    }

    static func drawSections(_ sections: [SongSection], audioStart: Double, duration: Double, in clip: CGRect,
                             visible: ClosedRange<CGFloat>, x: (Double) -> CGFloat) {
        let lane = lane(in: clip)
        let font = NSFont.systemFont(ofSize: 9, weight: .bold)
        for (i, s) in sections.enumerated() {
            let end = i + 1 < sections.count ? sections[i + 1].start : duration
            let x0 = x(audioStart + s.start), x1 = x(audioStart + end)
            guard x1 > visible.lowerBound, x0 < visible.upperBound else { continue }
            let r = CGRect(x: x0, y: lane.minY + 1, width: max(0, x1 - x0 - 1), height: lane.height - 2)
            let c = color(for: s.label)
            c.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
            if i > 0 {
                NSColor.white.withAlphaComponent(0.9).setFill()
                CGRect(x: x0 - 0.5, y: lane.minY, width: 1.5, height: clip.height).fill()
            }
            if r.width > 14 {
                let label = s.label as NSString
                let lx = max(r.minX + 3, min(visible.lowerBound + 3, r.maxX - 12))
                label.draw(at: CGPoint(x: lx, y: lane.minY), withAttributes: [.font: font, .foregroundColor: NSColor.white])
            }
        }
    }

    static func drawTicks(beats: [Double], downbeats: [Double], audioStart: Double, in clip: CGRect,
                          visible: ClosedRange<CGFloat>, pixelsPerSecond: CGFloat, x: (Double) -> CGFloat) {
        let strip = ticks(in: clip)
        let spacing = beats.count > 1 ? CGFloat((beats.last! - beats.first!) / Double(beats.count - 1)) * pixelsPerSecond : 0
        if spacing >= 4 {
            NSColor.white.withAlphaComponent(0.35).setFill()
            for b in beats {
                let bx = x(audioStart + b)
                if bx < visible.lowerBound { continue }
                if bx > visible.upperBound { break }
                CGRect(x: bx, y: strip.maxY - 3, width: 1, height: 3).fill()
            }
        }
        if spacing * 4 >= 4 {
            NSColor.white.withAlphaComponent(0.85).setFill()
            for d in downbeats {
                let dx = x(audioStart + d)
                if dx < visible.lowerBound { continue }
                if dx > visible.upperBound { break }
                CGRect(x: dx - 0.5, y: strip.minY, width: 1.5, height: strip.height).fill()
            }
        }
    }

    enum Hit: Equatable { case boundary(Int), lane, downbeat(Int) }

    static func hit(_ p: CGPoint, clip: CGRect, sections: [SongSection], downbeats: [Double], audioStart: Double,
                    pixelsPerSecond: CGFloat, x: (Double) -> CGFloat) -> Hit? {
        let lane = lane(in: clip)
        if p.y >= lane.minY && p.y < lane.maxY + 2 {
            for (i, s) in sections.enumerated() where i > 0 && abs(x(audioStart + s.start) - p.x) <= boundaryGrab { return .boundary(i) }
            return .lane
        }
        if ticks(in: clip).insetBy(dx: 0, dy: -2).contains(p), pixelsPerSecond * 2 >= 4 {
            if let i = downbeats.indices.min(by: { abs(x(audioStart + downbeats[$0]) - p.x) < abs(x(audioStart + downbeats[$1]) - p.x) }),
               abs(x(audioStart + downbeats[i]) - p.x) <= downbeatGrab { return .downbeat(i) }
        }
        return nil
    }
}
