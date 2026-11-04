import Foundation

/// Snap targets for timeline drags: the playhead, project start, and edges of clips,
/// lyric lines and words (beats and sections join once music analysis exists).
enum Snapping {
    static let radiusPixels = 8.0

    static func targets(in project: Project, playhead: Double, excluding ids: Set<UUID>, includeAudio: Bool = true) -> [Double] {
        var out: [Double] = [0, playhead]
        for c in project.videoTracks.flatMap(\.clips) where !ids.contains(c.id) { out += [c.start, c.end] }
        for l in project.lyricTracks.flatMap(\.lines) where !ids.contains(l.id) {
            out += [l.start, l.end]
            for w in l.words where !ids.contains(w.id) { out += [w.start, w.end] }
        }
        if includeAudio, let a = project.audio { out += [a.start, a.end] }
        return out
    }

    /// The target nearest to `time` within the pixel radius, if any.
    static func snap(_ time: Double, targets: [Double], pixelsPerSecond: Double) -> Double? {
        let radius = radiusPixels / pixelsPerSecond
        let best = targets.min { abs($0 - time) < abs($1 - time) }
        guard let best, abs(best - time) <= radius else { return nil }
        return best
    }
}
