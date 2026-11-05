import Foundation

/// Lines on the same lyric track never overlap: lines meant to be on screen together go on
/// different tracks. Drags and edge changes are held to the free time on the track.
extension Project {
    /// Free time on a lyric track (lines in `ignoring` don't count), as [start, end) ranges;
    /// the last one is open-ended.
    func lineGaps(track: Int, ignoring: Set<UUID> = []) -> [ClosedRange<Double>] {
        guard lyricTracks.indices.contains(track) else { return [] }
        var gaps: [ClosedRange<Double>] = []
        var cursor = 0.0
        for l in lyricTracks[track].lines.filter({ !ignoring.contains($0.id) }).sorted(by: { $0.start < $1.start }) {
            if l.start > cursor { gaps.append(cursor...l.start) }
            cursor = max(cursor, l.end)
        }
        gaps.append(cursor...Double.greatestFiniteMagnitude)
        return gaps
    }

    /// Where a line `duration` long lands when dragged to `desired` on `track`: in the free
    /// gap nearest to where the pointer wants it. Against a neighbour it stays stuck at the
    /// neighbour's edge; once the pointer is closer to the far side, it jumps past it.
    /// nil when no gap on the track is long enough.
    func freeLineStart(_ desired: Double, duration: Double, track: Int, ignoring: Set<UUID>) -> Double? {
        var best: (start: Double, distance: Double)?
        for g in lineGaps(track: track, ignoring: ignoring) where g.upperBound - g.lowerBound >= duration - 1e-9 {
            let s = min(max(desired, g.lowerBound), g.upperBound - duration)
            let d = abs(s - desired)
            if best == nil || d < best!.distance { best = (s, d) }
        }
        return best?.start
    }

    /// How far a line's edges may go before they reach its neighbours on the track.
    func lineEdgeLimits(_ id: UUID) -> (minStart: Double, maxEnd: Double) {
        guard let loc = lineLocation(id) else { return (0, .greatestFiniteMagnitude) }
        let me = lyricTracks[loc.track].lines[loc.index]
        let others = lyricTracks[loc.track].lines.filter { $0.id != id }
        let before = others.map(\.end).filter { $0 <= me.start + 1e-9 }.max() ?? 0
        let after = others.filter { $0.start >= me.end - 1e-9 }.map(\.start).min() ?? .greatestFiniteMagnitude
        return (before, after)
    }

    /// Clamp a time shift for a group of lines so none of them runs into a line that isn't
    /// moving with it on its track.
    func clampLineShift(_ dt: Double, lines ids: Set<UUID>) -> Double {
        var lo = -Double.greatestFiniteMagnitude, hi = Double.greatestFiniteMagnitude
        for (t, track) in lyricTracks.enumerated() {
            for l in track.lines where ids.contains(l.id) {
                let others = lyricTracks[t].lines.filter { !ids.contains($0.id) }
                if let prev = others.filter({ $0.end <= l.start + 1e-9 }).map(\.end).max() { lo = max(lo, prev - l.start) }
                if let next = others.filter({ $0.start >= l.end - 1e-9 }).map(\.start).min() { hi = min(hi, next - l.end) }
            }
        }
        guard lo <= hi else { return 0 }
        return min(max(dt, lo), hi)
    }
}
