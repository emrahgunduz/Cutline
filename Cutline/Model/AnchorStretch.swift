import Foundation

/// Re-times unconfirmed words around confirmed ones (KTD8, R25).
///
/// Confirmed words are anchors and never move. Every unconfirmed word is mapped by the
/// anchors around it: between two anchors, linearly from their old start times to their
/// new ones (so the words keep their relative timing and fit between them). After the last
/// anchor or before the first, only words marked `follows` (never aligned, e.g. a freshly
/// placed TXT being tapped through) shift by that anchor's move; aligned words stay put,
/// so one late tap can't drag the rest of the song along.
enum AnchorStretch {
    struct Span: Equatable {
        var start: Double
        var end: Double
    }

    /// - Parameters:
    ///   - before: word times before the edit, in song order.
    ///   - after: the same words after the edit (anchors may have moved).
    ///   - anchored: which words are confirmed.
    ///   - follows: which unconfirmed words follow a one-sided anchor move (nil = all).
    ///   - minLength: shortest a word may become.
    static func stretch(before: [Span], after: [Span], anchored: [Bool], follows: [Bool]? = nil, minLength: Double) -> [Span] {
        precondition(before.count == after.count && after.count == anchored.count)
        let follows = follows ?? Array(repeating: true, count: anchored.count)
        var out = after
        let anchors = anchored.indices.filter { anchored[$0] }
        guard !anchors.isEmpty else { return out }
        for i in out.indices where !anchored[i] {
            let left = anchors.last { $0 < i }, right = anchors.first { $0 > i }
            let map: (Double) -> Double
            switch (left, right) {
            case let (a?, b?):
                let oldA = before[a].start, oldB = before[b].start
                let newA = after[a].start, newB = after[b].start
                if oldB - oldA > 1e-6 {
                    let scale = (newB - newA) / (oldB - oldA)
                    map = { newA + ($0 - oldA) * scale }
                } else {
                    // Anchors used to coincide: spread the run evenly between them.
                    let run = (a + 1)..<b
                    let slot = (newB - newA) / Double(run.count + 1)
                    let k = Double(i - a)
                    out[i] = Span(start: newA + slot * k, end: newA + slot * (k + 1))
                    continue
                }
            case let (a?, nil):
                guard follows[i] else { continue }
                let d = after[a].start - before[a].start
                map = { $0 + d }
            case let (nil, b?):
                guard follows[i] else { continue }
                let d = after[b].start - before[b].start
                map = { $0 + d }
            case (nil, nil):
                continue
            }
            out[i] = Span(start: map(before[i].start), end: map(before[i].end))
        }
        return resolveOverlaps(out, anchored: anchored, minLength: minLength)
    }

    /// Keep words in order without overlaps, trimming unconfirmed words rather than anchors.
    static func resolveOverlaps(_ spans: [Span], anchored: [Bool], minLength: Double) -> [Span] {
        var s = spans
        for i in s.indices {
            if !anchored[i] {
                if i > 0 { s[i].start = max(s[i].start, s[i - 1].start + minLength) }
                s[i].end = max(s[i].end, s[i].start + minLength)
            }
            if i > 0, s[i - 1].end > s[i].start {
                if !anchored[i - 1] { s[i - 1].end = max(s[i - 1].start + min(minLength, s[i].start - s[i - 1].start), s[i].start) }
                else if !anchored[i] { s[i].start = s[i - 1].end; s[i].end = max(s[i].end, s[i].start + minLength) }
            }
        }
        return s
    }
}

extension Project {
    /// Lines of every lyric track in sung order: by start time, then by track (top first).
    func lyricLineOrder() -> [LyricLine] {
        var all: [(track: Int, line: LyricLine)] = []
        for (t, track) in lyricTracks.enumerated() {
            for line in track.lines { all.append((t, line)) }
        }
        all.sort { a, b in a.line.start != b.line.start ? a.line.start < b.line.start : a.track < b.track }
        return all.map { $0.line }
    }

    /// Every lyric word in sung order (lines in `lyricLineOrder`, then words in each line),
    /// with where it sits. The order follows the text, not the possibly edited word times.
    func lyricOrder() -> [(track: Int, line: Int, word: Int, value: LyricWord)] {
        var out: [(track: Int, line: Int, word: Int, value: LyricWord)] = []
        for line in lyricLineOrder() {
            guard let loc = lineLocation(line.id) else { continue }
            for (i, w) in line.words.enumerated() { out.append((loc.track, loc.index, i, w)) }
        }
        return out
    }

    /// Words of one lyric track in sung order.
    func trackWords(_ track: Int) -> [(line: Int, word: Int, value: LyricWord)] {
        lyricOrder().filter { $0.track == track }.map { ($0.line, $0.word, $0.value) }
    }

    /// After an edit that confirmed or moved words, re-time the unconfirmed words around the
    /// confirmed ones (R25), across all lyric tracks. `before` is the project before the edit.
    mutating func applyAnchorStretch(from before: Project) {
        let words = lyricOrder()
        guard words.count > 1 else { return }
        let old = Dictionary(uniqueKeysWithValues: before.lyricTracks.flatMap(\.lines).flatMap(\.words).map { ($0.id, $0) })
        // Only starts are re-timed (each word is a one-frame span here); ends stay as they are.
        let f = frameDuration
        let after = words.map { AnchorStretch.Span(start: $0.value.start, end: $0.value.start + f) }
        let prior = words.map { w in old[w.value.id].map { AnchorStretch.Span(start: $0.start, end: $0.start + f) } ?? AnchorStretch.Span(start: w.value.start, end: w.value.start + f) }
        let anchored = words.map(\.value.confirmed)
        let follows = words.map { $0.value.alignedStart == nil }
        write(AnchorStretch.stretch(before: prior, after: after, anchored: anchored, follows: follows, minLength: frameDuration), to: words, anchored: anchored)
    }

    /// Trim unconfirmed words so no two words overlap in sung order (confirmed ones stay).
    mutating func resolveLyricOverlaps() {
        let words = lyricOrder()
        let spans = words.map { AnchorStretch.Span(start: $0.value.start, end: $0.value.start + frameDuration) }
        let anchored = words.map(\.value.confirmed)
        write(AnchorStretch.resolveOverlaps(spans, anchored: anchored, minLength: frameDuration), to: words, anchored: anchored)
    }

    /// Write new word starts (ends stay, but never before their start).
    private mutating func write(_ result: [AnchorStretch.Span], to words: [(track: Int, line: Int, word: Int, value: LyricWord)], anchored: [Bool]) {
        let lead = lyricStyle.leadIn
        var touched = Set<[Int]>()
        for (k, w) in words.enumerated() where !anchored[k] {
            var word = lyricTracks[w.track].lines[w.line].words[w.word]
            let s = quantize(max(0, result[k].start))
            guard s != word.start else { continue }
            // A word pushed past its own end moves whole, keeping its length.
            if s > word.end - frameDuration { word.end = s + max(word.end - word.start, frameDuration) }
            word.start = s
            // Keep the lead-in from undoing the change later.
            if word.alignedStart != nil { word.alignedStart = s + lead }
            lyricTracks[w.track].lines[w.line].words[w.word] = word
            touched.insert([w.track, w.line])
        }
        for tl in touched {
            var line = lyricTracks[tl[0]].lines[tl[1]]
            for i in line.words.indices where line.words[i].end < line.words[i].start + frameDuration {
                line.words[i].end = line.words[i].start + frameDuration
            }
            line.containWords()
            lyricTracks[tl[0]].lines[tl[1]] = line
        }
    }
}

extension LyricLine {
    /// Make the line hug its words: from the first word's start to the last word's end.
    mutating func fitToWords() {
        guard let s = words.map(\.start).min(), let e = words.map(\.end).max() else { return }
        start = s; end = e
    }

    /// Grow the line so it contains every word (never shrinks it).
    mutating func containWords() {
        guard let s = words.map(\.start).min(), let e = words.map(\.end).max() else { return }
        start = min(start, s); end = max(end, e)
    }

    /// New words end with their line by default (they can be changed one by one after).
    mutating func endWordsAtLineEnd() {
        for i in words.indices { words[i].end = end }
    }
}

extension Project {
    /// After any change, every line still contains its words.
    mutating func keepLinesAroundWords() {
        for t in lyricTracks.indices {
            for l in lyricTracks[t].lines.indices { lyricTracks[t].lines[l].containWords() }
        }
    }
}
