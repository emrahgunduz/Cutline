import Foundation

/// Groups of snap targets, in priority order: when several are within the radius, the
/// earlier group wins (a section edge beats a downbeat beats a beat beats an edge).
enum SnapGroup: String, CaseIterable, Codable {
    case sections, downbeats, beats, edges

    var title: String {
        switch self {
        case .sections: "Sections"
        case .downbeats: "Downbeats"
        case .beats: "Beats"
        case .edges: "Edges & Playhead"
        }
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

    /// Edges of clips, lyric lines and words, the audio, the playhead and project start.
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

    /// Every target in the enabled groups. Beat-based targets are mapped onto the timeline
    /// through the audio's start; they are left out while the audio itself is dragged.
    static func targets(in project: Project, playhead: Double, excluding ids: Set<UUID>, includeAudio: Bool = true,
                        beats: ResolvedBeats?, groups: Set<SnapGroup>) -> [SnapTarget] {
        var out: [SnapTarget] = []
        if groups.contains(.edges) {
            out += targets(in: project, playhead: playhead, excluding: ids, includeAudio: includeAudio).map { SnapTarget(time: $0, group: .edges) }
        }
        if includeAudio, let beats, let audio = project.audio {
            let s = audio.start
            if groups.contains(.sections) { out += beats.sections.dropFirst().map { SnapTarget(time: s + $0.start, group: .sections) } }
            if groups.contains(.downbeats) { out += beats.downbeats.map { SnapTarget(time: s + $0, group: .downbeats) } }
            if groups.contains(.beats) { out += beats.beats.map { SnapTarget(time: s + $0, group: .beats) } }
        }
        return out
    }

    /// The target nearest to `time` within the pixel radius, if any.
    static func snap(_ time: Double, targets: [Double], pixelsPerSecond: Double) -> Double? {
        snap(time, targets: targets.map { SnapTarget(time: $0, group: .edges) }, pixelsPerSecond: pixelsPerSecond)?.time
    }

    /// Within the radius, the highest-priority group wins; inside a group, the nearest.
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
