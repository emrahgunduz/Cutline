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
    static func roughlyTimed(_ parsed: [ParsedLine], start: Double, end: Double, fps: Double) -> [LyricLine] {
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
            lines.append(LyricLine(start: words.first!.start, end: words.last!.end, words: words, stanza: l.stanza))
        }
        return lines
    }
}

extension EditorModel {
    /// Place the lyrics file on a lyric track, from `time` to the end of the song (or ~3 s per line).
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
        let apply = { [self] in
            edit("Place Lyrics") { p in
                guard p.lyricTracks.indices.contains(track) else { return }
                p.lyricTracks[track].lines = lines
            }
        }
        if project.lyricTracks.indices.contains(track), !project.lyricTracks[track].lines.isEmpty, let window {
            let alert = NSAlert()
            alert.messageText = "Replace the lyrics on Lyrics \(track + 1)?"
            alert.informativeText = "The track already has \(project.lyricTracks[track].lines.count) lines. You can undo this."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { apply() } }
        } else {
            apply()
        }
    }
}
