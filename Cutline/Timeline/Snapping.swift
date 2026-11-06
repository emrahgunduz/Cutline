import Foundation

/// Groups of snap targets, from the most to the least important: when targets of several
/// groups are within reach, the more important group wins (inside a group, the nearest).
/// The song's points are in one group each: a section start is a section, a downbeat (that
/// isn't a section start) a downbeat, and Beats are only the beats in between. So each toggle
/// turns exactly its own points on and off.
enum SnapGroup: String, CaseIterable, Codable {
    /// Edges of the other clips and of the song, the playhead and the project start.
    case clips
    /// Edges of lyric lines and words.
    case lyrics
    case beats, downbeats, sections

    var title: String {
        switch self {
        case .clips: "Clips & Audio"
        case .lyrics: "Lyrics & Words"
        case .beats: "Beats"
        case .downbeats: "Downbeats"
        case .sections: "Sections"
        }
    }

    /// Saved names to groups. Projects saved before the split had one "edges" group for
    /// clips, lyrics, the song and the playhead; it becomes both of its parts. Unknown names
    /// are skipped.
    static func decode(_ names: [String]) -> [SnapGroup] {
        let groups = names.flatMap { $0 == "edges" ? [SnapGroup.clips, .lyrics] : SnapGroup(rawValue: $0).map { [$0] } ?? [] }
        return allCases.filter(groups.contains)
    }
}

struct SnapTarget: Equatable {
    var time: Double
    var group: SnapGroup
}

/// Snap targets for timeline drags (R15, R41).
enum Snapping {
    /// Radius in pixels, so it covers less time as you zoom in.
    static let radiusPixels = 8.0

    /// Every target in the enabled groups. Beat-based targets are mapped onto the timeline
    /// through the audio's start; they and the song's edges are left out while the song itself
    /// is dragged (`includeAudio` false).
    static func targets(in project: Project, playhead: Double, excluding ids: Set<UUID>, includeAudio: Bool = true,
                        beats: ResolvedBeats?, groups: Set<SnapGroup>) -> [SnapTarget] {
        var out: [SnapTarget] = []
        if groups.contains(.clips) {
            var t: [Double] = [0, playhead]
            for c in project.videoTracks.flatMap(\.clips) where !ids.contains(c.id) { t += [c.start, c.end] }
            if includeAudio, let a = project.audio { t += [a.start, a.end] }
            out += t.map { SnapTarget(time: $0, group: .clips) }
        }
        if groups.contains(.lyrics) {
            var t: [Double] = []
            for l in project.lyricTracks.flatMap(\.lines) where !ids.contains(l.id) {
                t += [l.start, l.end]
                for w in l.words where !ids.contains(w.id) { t += [w.start, w.end] }
            }
            out += t.map { SnapTarget(time: $0, group: .lyrics) }
        }
        if includeAudio, let beats, let audio = project.audio {
            let s = audio.start
            let sections = beats.sections.dropFirst().map(\.start)
            let downbeats = beats.downbeats.filter { !contains(sections, $0) }
            if groups.contains(.beats) {
                out += beats.beats.filter { !contains(downbeats, $0) && !contains(sections, $0) }.map { SnapTarget(time: s + $0, group: .beats) }
            }
            if groups.contains(.downbeats) { out += downbeats.map { SnapTarget(time: s + $0, group: .downbeats) } }
            if groups.contains(.sections) { out += sections.map { SnapTarget(time: s + $0, group: .sections) } }
        }
        return out
    }

    /// Whether `times` has one within 2 ms of `t` (a downbeat sits on a beat, a section start
    /// on a downbeat; the analysis gives them separately).
    private static func contains(_ times: [Double], _ t: Double) -> Bool {
        times.contains { abs($0 - t) < 0.002 }
    }

    /// Where a dragged time lands: on the best target in reach, unless snapping is off or
    /// bypassed (⌘ held). Nil target means it stays where it is.
    static func resolve(_ time: Double, enabled: Bool, bypass: Bool, targets: @autoclosure () -> [SnapTarget],
                        pixelsPerSecond: Double) -> (time: Double, target: SnapTarget?) {
        guard enabled, !bypass, let hit = snap(time, targets: targets(), pixelsPerSecond: pixelsPerSecond) else { return (time, nil) }
        return (hit.time, hit)
    }

    /// Within the radius, the most important group wins; inside a group, the nearest.
    static func snap(_ time: Double, targets: [SnapTarget], pixelsPerSecond: Double) -> SnapTarget? {
        let radius = radiusPixels / pixelsPerSecond
        let near = targets.filter { abs($0.time - time) <= radius }
        let order = SnapGroup.allCases
        return near.min {
            let a = order.firstIndex(of: $0.group)!, b = order.firstIndex(of: $1.group)!
            return a != b ? a < b : abs($0.time - time) < abs($1.time - time)
        }
    }
}

// MARK: - Beat anchors

/// Ties a timeline marker to a beat, downbeat or section start of the song, plus an
/// offset, so the marker follows when that beat is corrected or the audio moves (KTD6).
/// Times are audio-file seconds.
struct BeatAnchor: Codable, Equatable {
    enum Kind: String, Codable { case beat, downbeat, section }
    var kind: Kind
    var index: Int
    var offset: Double
    /// The song the index refers to; anchors for another song are ignored.
    var audioHash: String
}

extension ResolvedBeats {
    func time(of kind: BeatAnchor.Kind, _ index: Int) -> Double? {
        switch kind {
        case .beat: beats.indices.contains(index) ? beats[index] : nil
        case .downbeat: downbeats.indices.contains(index) ? downbeats[index] : nil
        case .section: sections.indices.contains(index) ? sections[index].start : nil
        }
    }

    /// Anchor for audio time `t`: a section start or downbeat it sits on, else the nearest beat.
    func anchor(at t: Double, hash: String) -> BeatAnchor? {
        let eps = 0.002
        if let i = sections.firstIndex(where: { abs($0.start - t) < eps }), i > 0 { return BeatAnchor(kind: .section, index: i, offset: 0, audioHash: hash) }
        if let i = downbeats.firstIndex(where: { abs($0 - t) < eps }) { return BeatAnchor(kind: .downbeat, index: i, offset: 0, audioHash: hash) }
        guard let i = beats.indices.min(by: { abs(beats[$0] - t) < abs(beats[$1] - t) }) else { return nil }
        return BeatAnchor(kind: .beat, index: i, offset: t - beats[i], audioHash: hash)
    }
}

extension Project {
    /// Anchor both cinemascope markers to the song at their current times.
    mutating func anchorMarkers(_ beats: ResolvedBeats?, hash: String?) {
        guard let beats, let hash, let audio else {
            cinemascope.startAnchor = nil; cinemascope.endAnchor = nil; return
        }
        cinemascope.startAnchor = beats.anchor(at: cinemascope.startMarker - audio.start, hash: hash)
        cinemascope.endAnchor = beats.anchor(at: cinemascope.endMarker - audio.start, hash: hash)
    }

    /// Move anchored markers to where their beats are now.
    mutating func followAnchors(_ beats: ResolvedBeats, hash: String) {
        guard let audio else { return }
        func resolve(_ a: BeatAnchor?) -> Double? {
            guard let a, a.audioHash == hash, let t = beats.time(of: a.kind, a.index) else { return nil }
            return quantize(max(0, audio.start + t + a.offset))
        }
        if let s = resolve(cinemascope.startAnchor) { cinemascope.startMarker = s }
        if let e = resolve(cinemascope.endAnchor) { cinemascope.endMarker = max(e, cinemascope.startMarker) }
    }
}
