import Foundation

/// Pure timeline edits on the project value. `EditorModel.edit` wraps each in an undo step.
extension Project {
    /// Supported frame rates. NTSC rates are exact (24000/1001 rather than 23.976) so the
    /// editor's frame grid and the compositor's frame times are the same numbers.
    static let standardRates: [Double] = [24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 50, 60000.0 / 1001, 60]

    static func standardRate(near rate: Double) -> Double {
        standardRates.min { abs($0 - rate) < abs($1 - rate) } ?? 30
    }

    /// Move every timeline time onto the current frame grid (after a frame-rate migration).
    mutating func snapAllToFrameGrid() {
        for t in videoTracks.indices {
            for c in videoTracks[t].clips.indices {
                let start = quantize(videoTracks[t].clips[c].start), end = quantize(videoTracks[t].clips[c].end)
                videoTracks[t].clips[c].start = start
                videoTracks[t].clips[c].duration = max(frameDuration, end - start)
            }
        }
        for t in lyricTracks.indices {
            for l in lyricTracks[t].lines.indices {
                lyricTracks[t].lines[l].start = quantize(lyricTracks[t].lines[l].start)
                lyricTracks[t].lines[l].end = quantize(lyricTracks[t].lines[l].end)
                for w in lyricTracks[t].lines[l].words.indices {
                    lyricTracks[t].lines[l].words[w].start = quantize(lyricTracks[t].lines[l].words[w].start)
                    lyricTracks[t].lines[l].words[w].end = quantize(lyricTracks[t].lines[l].words[w].end)
                }
            }
        }
        if var a = audio { a.start = quantize(a.start); audio = a }
        cinemascope.startMarker = quantize(cinemascope.startMarker)
        cinemascope.endMarker = quantize(cinemascope.endMarker)
    }

    /// Older projects stored NTSC rates as rounded decimals (29.97). Map them to the exact
    /// rate and re-snap times. Returns true when anything changed.
    @discardableResult
    mutating func migrateFrameRate() -> Bool {
        let exact = Self.standardRate(near: fps)
        guard abs(exact - fps) > 1e-9, abs(exact - fps) < 0.05 else { return false }
        fps = exact
        snapAllToFrameGrid()
        return true
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

    /// Move the song in time (length unchanged). Everything is laid out against the song, so
    /// lyrics, video and image clips and the cinemascope markers move with it, unless `alone`
    /// (⌥-drag). Nothing is pushed before 0: the move stops where the earliest item hits it.
    mutating func moveAudio(start: Double, alone: Bool = false) {
        guard var a = audio else { return }
        var newStart = quantize(max(0, start))
        if !alone, newStart < a.start {
            // How far left everything can go before the earliest item reaches 0.
            let earliest = ([a.start] + videoTracks.flatMap(\.clips).map(\.start) + lyricTracks.flatMap(\.lines).map(\.start)).min() ?? a.start
            newStart = max(newStart, a.start - earliest)
        }
        let delta = newStart - a.start
        guard delta != 0 else { return }
        a.start = newStart
        audio = a
        if alone {
            // Only markers tied to the song's beats follow the song.
            if cinemascope.startAnchor != nil { cinemascope.startMarker = quantize(max(0, cinemascope.startMarker + delta)) }
            if cinemascope.endAnchor != nil { cinemascope.endMarker = quantize(max(0, cinemascope.endMarker + delta)) }
            return
        }
        cinemascope.startMarker = quantize(max(0, cinemascope.startMarker + delta))
        cinemascope.endMarker = quantize(max(0, cinemascope.endMarker + delta))
        for t in videoTracks.indices {
            for c in videoTracks[t].clips.indices { videoTracks[t].clips[c].start = quantize(videoTracks[t].clips[c].start + delta) }
        }
        for t in lyricTracks.indices {
            for l in lyricTracks[t].lines.indices {
                lyricTracks[t].lines[l].start += delta
                lyricTracks[t].lines[l].end += delta
                for w in lyricTracks[t].lines[l].words.indices {
                    lyricTracks[t].lines[l].words[w].start += delta
                    lyricTracks[t].lines[l].words[w].end += delta
                    lyricTracks[t].lines[l].words[w].alignedStart? += delta
                    lyricTracks[t].lines[l].words[w].alignedEnd? += delta
                }
            }
        }
    }

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
        for i in line.words.indices {
            line.words[i].start += delta; line.words[i].end += delta
            line.words[i].alignedStart? += delta; line.words[i].alignedEnd? += delta
        }
        lyricTracks[track].lines.append(line)
        lyricTracks[track].lines.sort { $0.start < $1.start }
    }

    /// Change a line's edges. The words travel with the edge being dragged: moving the start
    /// keeps every word's distance from the start (the end stays), moving the end keeps every
    /// word's distance from the end (the start stays). Words always end with the line. The
    /// words never cross the fixed edge.
    mutating func retimeLine(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let loc = lineLocation(id) else { return }
        var line = lyricTracks[loc.track].lines[loc.index]
        let f = frameDuration
        let firstStart = line.words.map(\.start).min() ?? line.start
        let lastStart = line.words.map(\.start).max() ?? line.start
        if let start {
            // The last word must still start a frame before the (fixed) end.
            let s = min(quantize(max(0, start)), line.start + (line.end - f - lastStart))
            shiftWords(&line, by: s - line.start)
            line.start = s
        }
        if let end {
            let firstNow = line.words.map(\.start).min() ?? firstStart
            // The first word can't move before the (fixed) start.
            let e = max(quantize(end), line.end + (line.start - firstNow), line.start + f)
            shiftWords(&line, by: e - line.end)
            line.end = e
        }
        for i in line.words.indices { line.words[i].end = line.end }
        lyricTracks[loc.track].lines[loc.index] = line
    }

    /// Move every word start (and its aligned time, so the lead-in stays right) by `delta`.
    private func shiftWords(_ line: inout LyricLine, by delta: Double) {
        guard delta != 0 else { return }
        for i in line.words.indices {
            line.words[i].start = quantize(line.words[i].start + delta)
            line.words[i].alignedStart? += delta
            line.words[i].alignedEnd? += delta
        }
    }

    /// Change a word's start and/or end. Words always end with their line, so a new end moves
    /// the line's end (for every word in it); a start past the line's end extends the line.
    mutating func retimeWord(_ id: UUID, start: Double? = nil, end: Double? = nil, confirm: Bool = true) {
        guard let loc = wordLocation(id) else { return }
        var line = lyricTracks[loc.track].lines[loc.line]
        var w = line.words[loc.word]
        if let start { w.start = quantize(max(0, start)) }
        if confirm { w.confirmed = true }
        w.alignedStart = nil; w.alignedEnd = nil   // set by hand now
        line.words[loc.word] = w
        let lastStart = line.words.map(\.start).max() ?? w.start
        if let end { line.end = quantize(end) }
        line.end = max(line.end, lastStart + frameDuration)
        line.start = min(line.start, w.start)
        for i in line.words.indices { line.words[i].end = line.end }
        lyricTracks[loc.track].lines[loc.line] = line
    }

    /// Move a word's start (it still ends with its line).
    mutating func moveWord(_ id: UUID, start: Double) {
        retimeWord(id, start: quantize(max(0, start)))
    }

    /// Remove a word; a line left without words is removed too.
    mutating func deleteWord(_ id: UUID) {
        guard let loc = wordLocation(id) else { return }
        lyricTracks[loc.track].lines[loc.line].words.remove(at: loc.word)
        if lyricTracks[loc.track].lines[loc.line].words.isEmpty { lyricTracks[loc.track].lines.remove(at: loc.line) }
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

extension Project {
    /// A standalone copy of `start..<end`, shifted to begin at 0, without audio. Used for
    /// size probes so they export a whole (small) project instead of seeking into this one.
    func excerpt(from start: Double, to end: Double) -> Project {
        var p = self
        p.audio = nil
        let len = end - start
        for t in p.videoTracks.indices {
            p.videoTracks[t].clips = p.videoTracks[t].clips.compactMap { c in
                guard c.end > start, c.start < end else { return nil }
                var n = c
                let cutHead = max(0, start - c.start)
                n.start = max(0, c.start - start)
                n.duration = min(c.end, end) - max(c.start, start)
                if asset(c.assetID)?.kind == .video { n.sourceIn += cutHead }
                return n.duration > 0 ? n : nil
            }
        }
        for t in p.lyricTracks.indices {
            p.lyricTracks[t].lines = p.lyricTracks[t].lines.compactMap { l in
                guard l.end > start, l.start < end else { return nil }
                var n = l
                n.start -= start; n.end -= start
                n.words = l.words.map { var w = $0; w.start -= start; w.end -= start; return w }
                return n
            }
        }
        p.cinemascope.startMarker -= start
        p.cinemascope.endMarker -= start
        _ = len
        return p
    }
}
