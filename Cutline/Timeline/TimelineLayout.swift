import CoreGraphics
import Foundation

enum TimelineRow: Equatable {
    case ruler
    case video(Int)
    case audio
    case lyric(Int)
}

/// Maps time and tracks to view coordinates. Video tracks are listed top layer first.
struct TimelineLayout {
    static let headerWidth: CGFloat = 96
    static let rulerHeight: CGFloat = 26
    static let videoHeight: CGFloat = 56
    static let audioHeight: CGFloat = 76
    static let lyricHeight: CGFloat = 44
    static let edgeGrab: CGFloat = 6

    var pixelsPerSecond: CGFloat
    /// Time at the left edge of the track area.
    var scrollTime: Double
    var scrollY: CGFloat = 0
    var videoTrackCount: Int
    var lyricTrackCount: Int
    var viewWidth: CGFloat

    /// Rows in display order with their y origin and height (ruler is pinned, not scrolled).
    var rows: [(row: TimelineRow, y: CGFloat, height: CGFloat)] {
        var out: [(TimelineRow, CGFloat, CGFloat)] = [(.ruler, 0, Self.rulerHeight)]
        var y = Self.rulerHeight - scrollY
        for t in (0..<videoTrackCount).reversed() { out.append((.video(t), y, Self.videoHeight)); y += Self.videoHeight }
        out.append((.audio, y, Self.audioHeight)); y += Self.audioHeight
        for t in 0..<lyricTrackCount { out.append((.lyric(t), y, Self.lyricHeight)); y += Self.lyricHeight }
        return out
    }

    var contentHeight: CGFloat {
        Self.rulerHeight + CGFloat(videoTrackCount) * Self.videoHeight + Self.audioHeight + CGFloat(lyricTrackCount) * Self.lyricHeight
    }

    func frame(of row: TimelineRow) -> CGRect? {
        rows.first { $0.row == row }.map { CGRect(x: 0, y: $0.y, width: viewWidth, height: $0.height) }
    }

    func row(atY y: CGFloat) -> TimelineRow? {
        if y < Self.rulerHeight { return .ruler }
        return rows.dropFirst().first { y >= $0.y && y < $0.y + $0.height }?.row
    }

    func x(for time: Double) -> CGFloat { Self.headerWidth + CGFloat(time - scrollTime) * pixelsPerSecond }
    func time(for x: CGFloat) -> Double { scrollTime + Double((x - Self.headerWidth) / pixelsPerSecond) }

    var visibleTimeRange: ClosedRange<Double> { scrollTime...time(for: viewWidth) }

    /// Zoom limits: a single frame spans ~20 px at most zoom; the whole project fits at least zoom.
    static func zoomRange(duration: Double, fps: Double, width: CGFloat) -> ClosedRange<CGFloat> {
        let maxPPS = CGFloat(fps) * 20
        let fit = max(1, width - headerWidth - 20) / CGFloat(max(duration, 1))
        return min(fit, maxPPS)...maxPPS
    }

    /// Ruler tick spacing in seconds that keeps labels ~80 px apart.
    func tickInterval(fps: Double) -> Double {
        let frame = 1 / fps
        let candidates = [frame, 2 * frame, 5 * frame, 10 * frame, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        return candidates.first { CGFloat($0) * pixelsPerSecond >= 80 } ?? 600
    }
}
