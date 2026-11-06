import AppKit
import Foundation

/// Turns a lyrics TXT into timeline lines and words.
enum LyricImport {
    struct ParsedLine: Equatable {
        var words: [String]
        var stanza: Int
    }

    /// One line per non-empty TXT line; blank lines separate stanzas. Text is kept as written.
    static func parse(_ text: String) -> [ParsedLine] {
        var out: [ParsedLine] = []
        var stanza = 0
        var lastWasBlank = false
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let words = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if words.isEmpty {
                if !out.isEmpty && !lastWasBlank { stanza += 1 }
                lastWasBlank = true
                continue
            }
            lastWasBlank = false
            out.append(ParsedLine(words: words, stanza: stanza))
        }
        return out
    }

    /// Rough timing until audio alignment runs: lines fill `start..<end` in proportion to their
    /// length, with a pause between stanzas. Every word is marked unaligned (confidence 0).
    static func roughlyTimed(_ parsed: [ParsedLine], start: Double, end: Double, fps: Double, group: UUID = UUID()) -> [LyricLine] {
        guard !parsed.isEmpty, end > start else { return [] }
        func weight(_ w: String) -> Double { 1 + Double(w.count) / 6 }
        let stanzaGap = 2.0, lineGap = 0.6
        var total = 0.0
        for (i, l) in parsed.enumerated() {
            total += l.words.map(weight).reduce(0, +)
            if i > 0 { total += parsed[i - 1].stanza != l.stanza ? stanzaGap : lineGap }
        }
        let unit = (end - start) / total
        let q: (Double) -> Double = { ($0 * fps).rounded() / fps }
        var t = start
        var lines: [LyricLine] = []
        for (i, l) in parsed.enumerated() {
            if i > 0 { t += (parsed[i - 1].stanza != l.stanza ? stanzaGap : lineGap) * unit }
            var words: [LyricWord] = []
            for w in l.words {
                let d = weight(w) * unit
                let ws = q(t), we = max(ws + 1 / fps, q(t + d * 0.9))
                words.append(LyricWord(text: w, start: ws, end: we, confidence: 0))
                t += d
            }
            var line = LyricLine(start: words.first!.start, end: words.last!.end, words: words, stanza: l.stanza)
            line.textOrder = TextOrder(group: group, index: i)   // its place in the file, kept forever
            line.endWordsAtLineEnd()   // new words end with their line by default
            lines.append(line)
        }
        return lines
    }
}

extension Project {
    /// The timeline holds one lyrics file: its lines go on `track` (the first lyrics track when
    /// that one doesn't exist; one is added when there are none) and every other lyrics track is
    /// emptied. Returns the track the lines went on.
    @discardableResult
    mutating func replaceAllLyrics(with lines: [LyricLine], onTrack track: Int) -> Int {
        if lyricTracks.isEmpty { addLyricTrack() }
        let target = lyricTracks.indices.contains(track) ? track : 0
        for i in lyricTracks.indices { lyricTracks[i].lines = i == target ? lines : [] }
        return target
    }

    /// Lyric lines on the timeline, and on how many tracks.
    var lyricLineCounts: (lines: Int, tracks: Int) {
        let used = lyricTracks.filter { !$0.lines.isEmpty }
        return (used.reduce(0) { $0 + $1.lines.count }, used.count)
    }
}

extension EditorModel {
    /// Place the lyrics file on a lyric track, from `time` to the end of the song (or ~3 s per
    /// line). It replaces the lyrics on every lyrics track; when there are some, it asks first.
    @MainActor
    func placeLyrics(_ asset: Asset, track: Int, at time: Double, window: NSWindow?) {
        guard let text = (try? String(contentsOf: asset.url, encoding: .utf8)) ?? (try? String(contentsOf: asset.url, encoding: .isoLatin1)) else {
            if let window { NSAlert(error: CocoaError(.fileReadCorruptFile)).beginSheetModal(for: window) { _ in } }
            return
        }
        let parsed = LyricImport.parse(text)
        guard !parsed.isEmpty else { return }
        let songEnd = project.audio?.end ?? 0
        let end = songEnd > time + 5 ? songEnd : time + Double(parsed.count) * 3
        let lines = LyricImport.roughlyTimed(parsed, start: time, end: end, fps: project.fps)
        let existing = project.lyricLineCounts
        let apply = { [self] in
            edit(existing.lines > 0 ? "Replace Lyrics" : "Place Lyrics") { p in p.replaceAllLyrics(with: lines, onTrack: track) }
            // With a song on the timeline, time the words to it right away (R21).
            if project.audio != nil, audioAnalysis.state != .unavailable { alignLyrics(window: window) }
        }
        guard existing.lines > 0, let window else { apply(); return }
        let target = project.lyricTracks.indices.contains(track) ? track : 0
        let alert = NSAlert()
        alert.messageText = existing.tracks > 1 ? "Replace the lyrics on all lyrics tracks?" : "Replace the lyrics?"
        let onTracks = existing.tracks > 1 ? " on \(existing.tracks) lyrics tracks" : ""
        alert.informativeText = "The timeline has \(existing.lines) lyric lines\(onTracks). It holds one lyrics file, so all of them "
            + "are replaced by the lines of “\(asset.name)” on Lyrics \(target + 1), and their timing and placement are lost. You can undo this."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { apply() } }
    }
}
