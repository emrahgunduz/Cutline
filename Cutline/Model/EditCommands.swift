import Foundation

/// Pure timeline edits on the project value. `EditorModel.edit` wraps each in an undo step.
extension Project {
    static let standardRates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    static func standardRate(near rate: Double) -> Double {
        standardRates.min { abs($0 - rate) < abs($1 - rate) } ?? 30
    }

    /// The first video clip added fixes the project frame rate.
    mutating func lockFrameRate(from asset: Asset) {
        guard !fpsLocked, asset.kind == .video, let r = asset.frameRate, r > 0 else { return }
        fps = Self.standardRate(near: r)
        fpsLocked = true
    }

    // MARK: Video clips

    func clipLocation(_ id: UUID) -> (track: Int, index: Int)? {
        for (t, track) in videoTracks.enumerated() {
            if let i = track.clips.firstIndex(where: { $0.id == id }) { return (t, i) }
        }
        return nil
    }

    /// Images get a default length; video uses its full source length.
    static let defaultImageDuration = 5.0

    @discardableResult
    mutating func addClip(assetID: UUID, track: Int, at time: Double) -> UUID? {
        guard let asset = asset(assetID), asset.kind == .video || asset.kind == .image,
              videoTracks.indices.contains(track) else { return nil }
        lockFrameRate(from: asset)
        let duration = asset.kind == .video ? (asset.duration ?? Self.defaultImageDuration) : Self.defaultImageDuration
        let clip = Clip(assetID: assetID, start: quantize(max(0, time)), duration: quantize(duration))
        videoTracks[track].clips.append(clip)
        videoTracks[track].clips.sort { $0.start < $1.start }
        return clip.id
    }

    mutating func moveClip(_ id: UUID, toTrack track: Int, start: Double) {
        guard let loc = clipLocation(id), videoTracks.indices.contains(track) else { return }
        var clip = videoTracks[loc.track].clips.remove(at: loc.index)
        clip.start = quantize(max(0, start))
        videoTracks[track].clips.append(clip)
        videoTracks[track].clips.sort { $0.start < $1.start }
    }

    /// Maximum duration a clip can have from its current source in-point.
    func maxDuration(of clip: Clip) -> Double {
        guard let a = asset(clip.assetID), a.kind == .video, let d = a.duration else { return .infinity }
        return d - clip.sourceIn
    }

    /// Move the clip's left edge to `newStart`, keeping its right edge. Clamped to the source.
    mutating func trimStart(_ id: UUID, to newStart: Double) {
        guard let loc = clipLocation(id) else { return }
        var c = videoTracks[loc.track].clips[loc.index]
        let isVideo = asset(c.assetID)?.kind == .video
        var start = quantize(max(0, newStart))
        if isVideo { start = max(start, c.start - c.sourceIn) }      // cannot go before source frame 0
        start = min(start, c.end - frameDuration)
        let delta = start - c.start
        c.start = start
        c.duration -= delta
        if isVideo { c.sourceIn += delta }
        videoTracks[loc.track].clips[loc.index] = c
    }

    /// Move the clip's right edge, clamped to the source length.
    mutating func trimEnd(_ id: UUID, to newEnd: Double) {
        guard let loc = clipLocation(id) else { return }
        var c = videoTracks[loc.track].clips[loc.index]
        let end = quantize(newEnd)
        c.duration = min(max(frameDuration, end - c.start), maxDuration(of: c))
        videoTracks[loc.track].clips[loc.index] = c
    }

    /// Split every clip under `time` (or only `clipID`) into two contiguous clips.
    mutating func split(at time: Double, clipID: UUID? = nil) {
        let t = quantize(time)
        for ti in videoTracks.indices {
            var out: [Clip] = []
            for c in videoTracks[ti].clips {
                guard (clipID == nil || clipID == c.id), t > c.start, t < c.end else { out.append(c); continue }
                var left = c, right = c
                left.duration = t - c.start
                right.id = UUID()
                right.start = t
                right.duration = c.end - t
                if asset(c.assetID)?.kind == .video { right.sourceIn = c.sourceIn + left.duration }
                out += [left, right]
            }
            videoTracks[ti].clips = out
        }
    }

    mutating func deleteClip(_ id: UUID) {
        guard let loc = clipLocation(id) else { return }
        videoTracks[loc.track].clips.remove(at: loc.index)
    }

    mutating func updateClip(_ id: UUID, _ change: (inout Clip) -> Void) {
        guard let loc = clipLocation(id) else { return }
        change(&videoTracks[loc.track].clips[loc.index])
    }

    mutating func addVideoTrack() { videoTracks.append(VideoTrack()) }

    /// Insert a video track just above (higher layer than) `index`.
    mutating func insertVideoTrack(above index: Int) { videoTracks.insert(VideoTrack(), at: min(index + 1, videoTracks.count)) }

    mutating func moveVideoTrack(from: Int, to: Int) {
        guard videoTracks.indices.contains(from), videoTracks.indices.contains(to), from != to else { return }
        videoTracks.insert(videoTracks.remove(at: from), at: to)
    }

    /// Removes the track and its clips. The last remaining track cannot be removed.
    mutating func removeVideoTrack(at index: Int) {
        guard videoTracks.count > 1, videoTracks.indices.contains(index) else { return }
        videoTracks.remove(at: index)
    }

    // MARK: Audio

    mutating func setAudio(assetID: UUID) {
        guard let a = asset(assetID), a.kind == .audio else { return }
        audio = AudioClip(assetID: assetID, start: 0, duration: a.duration ?? 0)
    }

    mutating func removeAudio() { audio = nil }

    // MARK: Lyrics

    func lineLocation(_ id: UUID) -> (track: Int, index: Int)? {
        for (t, track) in lyricTracks.enumerated() {
            if let i = track.lines.firstIndex(where: { $0.id == id }) { return (t, i) }
        }
        return nil
    }

    func wordLocation(_ id: UUID) -> (track: Int, line: Int, word: Int)? {
        for (t, track) in lyricTracks.enumerated() {
            for (l, line) in track.lines.enumerated() {
                if let w = line.words.firstIndex(where: { $0.id == id }) { return (t, l, w) }
            }
        }
        return nil
    }

    mutating func addLyricTrack() { lyricTracks.append(LyricTrack()) }

    mutating func insertLyricTrack(below index: Int) { lyricTracks.insert(LyricTrack(), at: min(index + 1, lyricTracks.count)) }

    mutating func moveLyricTrack(from: Int, to: Int) {
        guard lyricTracks.indices.contains(from), lyricTracks.indices.contains(to), from != to else { return }
        lyricTracks.insert(lyricTracks.remove(at: from), at: to)
    }

    /// Removes the track; its lines go too. The last remaining track cannot be removed.
    mutating func removeLyricTrack(at index: Int) {
        guard lyricTracks.count > 1, lyricTracks.indices.contains(index) else { return }
        lyricTracks.remove(at: index)
    }

    /// Move a line in time (its words move with it) and optionally to another track.
    mutating func moveLine(_ id: UUID, toTrack track: Int, start: Double) {
        guard let loc = lineLocation(id), lyricTracks.indices.contains(track) else { return }
        var line = lyricTracks[loc.track].lines.remove(at: loc.index)
        let delta = quantize(max(0, start)) - line.start
        line.start += delta
        line.end += delta
        for i in line.words.indices { line.words[i].start += delta; line.words[i].end += delta }
        lyricTracks[track].lines.append(line)
        lyricTracks[track].lines.sort { $0.start < $1.start }
    }

    /// Change a line's edges. The line always contains its words, so edges stop at them.
    mutating func retimeLine(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let loc = lineLocation(id) else { return }
        var line = lyricTracks[loc.track].lines[loc.index]
        let firstWord = line.words.map(\.start).min() ?? line.end
        let lastWord = line.words.map(\.end).max() ?? line.start
        if let start { line.start = min(quantize(max(0, start)), firstWord, line.end - frameDuration) }
        if let end { line.end = max(quantize(end), lastWord, line.start + frameDuration) }
        lyricTracks[loc.track].lines[loc.index] = line
    }

    /// Change a word's start and/or end. A word moved past its line's edge extends the line.
    mutating func retimeWord(_ id: UUID, start: Double? = nil, end: Double? = nil, confirm: Bool = true) {
        guard let loc = wordLocation(id) else { return }
        var line = lyricTracks[loc.track].lines[loc.line]
        var w = line.words[loc.word]
        if let start { w.start = quantize(max(0, start)) }
        if let end { w.end = quantize(end) }
        if w.end - w.start < frameDuration {
            if end != nil && start == nil { w.end = w.start + frameDuration } else { w.start = w.end - frameDuration }
        }
        if confirm { w.confirmed = true }
        line.words[loc.word] = w
        line.start = min(line.start, w.start)
        line.end = max(line.end, w.end)
        lyricTracks[loc.track].lines[loc.line] = line
    }

    /// Move a word without changing its length.
    mutating func moveWord(_ id: UUID, start: Double) {
        guard let loc = wordLocation(id) else { return }
        let w = lyricTracks[loc.track].lines[loc.line].words[loc.word]
        let s = quantize(max(0, start))
        retimeWord(id, start: s, end: s + (w.end - w.start))
    }

    mutating func deleteLine(_ id: UUID) {
        guard let loc = lineLocation(id) else { return }
        lyricTracks[loc.track].lines.remove(at: loc.index)
    }

    /// Lines of all tracks visible at time t, in track order.
    func visibleLines(at t: Double) -> [(track: Int, line: LyricLine)] {
        lyricTracks.enumerated().flatMap { (ti, track) in
            track.lines.filter { $0.start <= t && t < $0.end }.map { (ti, $0) }
        }
    }
}
