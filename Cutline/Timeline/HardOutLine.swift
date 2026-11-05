import AppKit

extension Project {
    /// Maximum length for this project type (nil = unlimited), from the presets (R35).
    var lengthLimit: Double? { Presets.preset(for: type).maxDuration }
    var isOverLimit: Bool { lengthLimit.map { duration > $0 + 1e-6 } ?? false }

    /// Where Trim to Limit ends the project (AE3): the last downbeat or lyric-line end at or
    /// before the limit; the limit itself when there is neither.
    func trimPoint(limit: Double, beats: ResolvedBeats?) -> Double {
        var candidates: [Double] = []
        if let beats, let audio { candidates += beats.downbeats.map { audio.start + $0 } }
        candidates += lyricTracks.flatMap(\.lines).map(\.end)
        let best = candidates.filter { $0 > frameDuration && $0 <= limit + 1e-6 }.max() ?? limit
        return min(quantize(best), limit)
    }

    /// End the project at `end`: later items are removed, items crossing it are shortened.
    mutating func trim(to end: Double) {
        let f = frameDuration
        for t in videoTracks.indices {
            videoTracks[t].clips = videoTracks[t].clips.compactMap { c in
                guard c.start < end - f / 2 else { return nil }
                var c = c
                c.duration = min(c.duration, end - c.start)
                return c
            }
        }
        for t in lyricTracks.indices {
            lyricTracks[t].lines = lyricTracks[t].lines.compactMap { l in
                guard l.start < end - f / 2 else { return nil }
                var l = l
                l.words = l.words.filter { $0.start < end - f / 2 }
                guard !l.words.isEmpty else { return nil }
                for i in l.words.indices { l.words[i].end = min(l.words[i].end, end) }
                l.end = min(l.end, end)
                return l
            }
        }
        if var a = audio {
            if a.start >= end - f / 2 { audio = nil } else { a.duration = min(a.duration, end - a.start); audio = a }
        }
        cinemascope.startMarker = min(cinemascope.startMarker, end)
        cinemascope.endMarker = min(cinemascope.endMarker, end)
    }
}

extension EditorModel {
    /// Trim the project to its type's length limit, ending on a downbeat or lyric-line end.
    @MainActor
    func trimToLimit() {
        guard let limit = project.lengthLimit, project.isOverLimit else { return }
        let end = project.trimPoint(limit: limit, beats: resolvedBeats)
        edit("Trim to Limit") { $0.trim(to: end) }
        if playhead > end { setPlayhead(end) }
    }
}

/// Draws the hard-out line at the length limit and shades everything past it as over (R35).
enum HardOutLine {
    static let color = NSColor.systemRed

    static func draw(limit: Double, duration: Double, layout l: TimelineLayout, bounds: CGRect, rulerHeight: CGFloat) {
        let x = l.x(for: limit)
        guard x < bounds.width else { return }
        let lineX = max(TimelineLayout.headerWidth, x)
        if duration > limit {
            let endX = min(bounds.width, l.x(for: duration))
            if endX > lineX {
                color.withAlphaComponent(0.14).setFill()
                CGRect(x: lineX, y: rulerHeight, width: endX - lineX, height: bounds.height - rulerHeight).fill()
                // Diagonal hatching so "over" reads even on busy rows.
                let hatch = NSBezierPath()
                var hx = lineX - bounds.height
                while hx < endX {
                    hatch.move(to: CGPoint(x: hx, y: bounds.height)); hatch.line(to: CGPoint(x: hx + bounds.height, y: rulerHeight))
                    hx += 14
                }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: CGRect(x: lineX, y: rulerHeight, width: endX - lineX, height: bounds.height - rulerHeight)).addClip()
                color.withAlphaComponent(0.18).setStroke()
                hatch.lineWidth = 1
                hatch.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        guard x >= TimelineLayout.headerWidth else { return }
        color.setFill()
        CGRect(x: x - 1, y: 0, width: 2, height: bounds.height).fill()
        let label = String(format: "LIMIT %d:%02d", Int(limit) / 60, Int(limit) % 60) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        let tag = CGRect(x: x + 2, y: 2, width: size.width + 8, height: rulerHeight - 6)
        color.setFill()
        NSBezierPath(roundedRect: tag, xRadius: 3, yRadius: 3).fill()
        label.draw(at: CGPoint(x: tag.minX + 4, y: tag.midY - size.height / 2), withAttributes: attrs)
    }
}
