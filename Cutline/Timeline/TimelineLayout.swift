import CoreGraphics
import Foundation

enum TimelineRow: Equatable, Hashable {
    case ruler
    case audio
    case lyric(Int)
    case video(Int)

    var kindName: String {
        switch self {
        case .ruler: ""
        case .audio: "Audio"
        case .lyric: "Lyrics"
        case .video: "Video"
        }
    }
}

/// Maps time and tracks to view coordinates.
/// Rows top to bottom: ruler, audio, lyric tracks (1…n), video tracks (top layer first).
struct TimelineLayout {
    static let headerWidth: CGFloat = 132
    static let rulerHeight: CGFloat = 26
    static let minRowHeight: CGFloat = 22      // title only
    static let maxRowHeight: CGFloat = 220
    static let defaultHeights: [String: CGFloat] = ["audio": 76, "lyric": 66, "video": 60]
    static let edgeGrab: CGFloat = 7

    var pixelsPerSecond: CGFloat
    /// Time at the left edge of the track area.
    var scrollTime: Double
    var scrollY: CGFloat = 0
    var videoTrackCount: Int
    var lyricTrackCount: Int
    var viewWidth: CGFloat
    /// Row height for a row, already clamped.
    var height: (TimelineRow) -> CGFloat = { TimelineLayout.defaultHeight($0) }

    static func defaultHeight(_ row: TimelineRow) -> CGFloat {
        switch row {
        case .ruler: rulerHeight
        case .audio: defaultHeights["audio"]!
        case .lyric: defaultHeights["lyric"]!
        case .video: defaultHeights["video"]!
        }
    }

    var orderedRows: [TimelineRow] {
        [.audio] + (0..<lyricTrackCount).map { .lyric($0) } + (0..<videoTrackCount).reversed().map { .video($0) }
    }

    /// Rows in display order with their y origin and height (ruler is pinned, not scrolled).
    var rows: [(row: TimelineRow, y: CGFloat, height: CGFloat)] {
        var out: [(TimelineRow, CGFloat, CGFloat)] = [(.ruler, 0, Self.rulerHeight)]
        var y = Self.rulerHeight - scrollY
        for r in orderedRows {
            let h = height(r)
            out.append((r, y, h))
            y += h
        }
        return out
    }

    var contentHeight: CGFloat { Self.rulerHeight + orderedRows.map(height).reduce(0, +) }

    func frame(of row: TimelineRow) -> CGRect? {
        rows.first { $0.row == row }.map { CGRect(x: 0, y: $0.y, width: viewWidth, height: $0.height) }
    }

    func row(atY y: CGFloat) -> TimelineRow? {
        if y < Self.rulerHeight { return .ruler }
        return rows.dropFirst().first { y >= $0.y && y < $0.y + $0.height }?.row
    }

    func x(for time: Double) -> CGFloat { Self.headerWidth + CGFloat(time - scrollTime) * pixelsPerSecond }
    func time(for x: CGFloat) -> Double { scrollTime + Double((x - Self.headerWidth) / pixelsPerSecond) }

    var visibleDuration: Double { Double(max(1, viewWidth - Self.headerWidth) / pixelsPerSecond) }
    var visibleTimeRange: ClosedRange<Double> { scrollTime...(scrollTime + visibleDuration) }

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

    /// New scroll time that keeps the playhead visible. During playback the view scrolls
    /// continuously once the playhead passes 70% of the width (no page jumps).
    func scrollTimeFollowing(_ t: Double, playing: Bool) -> Double {
        let d = visibleDuration
        if playing {
            let anchor = scrollTime + d * 0.7
            if t > anchor { return t - d * 0.7 }
            if t < scrollTime { return max(0, t - d * 0.1) }
            return scrollTime
        }
        if t < scrollTime || t > scrollTime + d { return max(0, t - d * 0.5) }
        return scrollTime
    }
}
