import AppKit
import Foundation

/// Times lyric words by aligning their known text on the song's vocal stem (KTD7, R21-R22).
enum LyricAlignment {
    /// Words below this confidence (and not confirmed) are tinted and visited by the
    /// next-uncertain-word key (U11).
    static let lowConfidence = 0.6

    struct Word: Decodable, Equatable { var text: String; var start: Double; var end: Double; var confidence: Double; var source: String }
    struct Result: Decodable, Equatable { var lines: [[Word]] }

    /// Whisper's language hint: Turkish letters mean Turkish; otherwise let it detect.
    static func language(for words: [String]) -> String? {
        let tr = Set("çğıöşüÇĞİÖŞÜ")
        return words.contains { $0.contains(where: tr.contains) } ? "tr" : nil
    }

    static func isLow(_ w: LyricWord) -> Bool { !w.confirmed && w.confidence < lowConfidence }
}

extension Project {
    /// Put aligned times (audio-file seconds) onto the lines of `track`, in time order.
    mutating func applyAlignment(_ r: LyricAlignment.Result, track: Int, audioStart: Double, keepConfirmed: Bool) {
        guard lyricTracks.indices.contains(track) else { return }
        let ids = lyricTracks[track].lines.sorted { $0.start < $1.start }.map(\.id)
        applyAlignment(r, lineIDs: ids, audioStart: audioStart, keepConfirmed: keepConfirmed)
    }

    /// Put aligned times onto the given lines (result line k goes to `lineIDs[k]`).
    /// With `keepConfirmed`, words the user confirmed keep their times.
    mutating func applyAlignment(_ r: LyricAlignment.Result, lineIDs: [UUID], audioStart: Double, keepConfirmed: Bool) {
        let f = frameDuration
        let lead = lyricStyle.leadIn
        for (li, aligned) in r.lines.enumerated() where lineIDs.indices.contains(li) {
            guard let loc = lineLocation(lineIDs[li]) else { continue }
            var line = lyricTracks[loc.track].lines[loc.index]
            guard line.words.count == aligned.count else { continue }
            for (wi, a) in aligned.enumerated() {
                if keepConfirmed && line.words[wi].confirmed { continue }
                let s = quantize(max(0, audioStart + a.start - lead))
                line.words[wi].start = s
                line.words[wi].end = max(s + f, quantize(audioStart + a.end - lead))
                line.words[wi].confidence = a.confidence
                line.words[wi].confirmed = false   // re-timed by alignment, no longer the user's time
                line.words[wi].alignedStart = audioStart + a.start
                line.words[wi].alignedEnd = audioStart + a.end
            }
            // Starts stay in order after quantizing (ends may overlap: words end with the line).
            for wi in line.words.indices.dropFirst() where line.words[wi].start <= line.words[wi - 1].start {
                line.words[wi].start = line.words[wi - 1].start + f
                line.words[wi].end = max(line.words[wi].end, line.words[wi].start + f)
            }
            // New timing: every word ends with the line (the last word's end); each word's end
            // can be changed afterwards.
            if let lineEnd = aligned.map(\.end).max() {
                let e = max(quantize(audioStart + lineEnd - lead), (line.words.map(\.start).max() ?? 0) + f)
                for wi in line.words.indices where !(keepConfirmed && line.words[wi].confirmed) {
                    line.words[wi].end = max(e, line.words[wi].start + f)
                    line.words[wi].alignedEnd = audioStart + lineEnd
                }
            }
            line.fitToWords()
            lyricTracks[loc.track].lines[loc.index] = line
        }
        for t in lyricTracks.indices { lyricTracks[t].lines.sort { $0.start < $1.start } }
    }

    /// Re-place aligned, unconfirmed words for the current lead-in. Lines that hugged their
    /// words keep hugging them; lines the user widened keep their edges if they still fit.
    mutating func applyLeadIn() {
        let f = frameDuration, lead = lyricStyle.leadIn
        for t in lyricTracks.indices {
            for l in lyricTracks[t].lines.indices {
                var line = lyricTracks[t].lines[l]
                guard !line.words.isEmpty else { continue }
                let tightStart = line.start == line.words.first!.start, tightEnd = line.end == line.words.last!.end
                for i in line.words.indices where !line.words[i].confirmed {
                    guard let a = line.words[i].alignedStart, let b = line.words[i].alignedEnd else { continue }
                    let s = quantize(max(0, a - lead))
                    line.words[i].start = s
                    line.words[i].end = max(s + f, quantize(b - lead))
                }
                let first = line.words.map(\.start).min()!, last = line.words.map(\.end).max()!
                line.start = tightStart ? first : min(line.start, first)
                line.end = tightEnd ? last : max(line.end, last)
                lyricTracks[t].lines[l] = line
            }
        }
    }
}

extension EditorModel {
    /// Time every lyric word to the song: the lines of all lyric tracks, in time order, are
    /// one sung sequence. Waits for song analysis if it is still running, and asks before
    /// re-timing words the user confirmed.
    @MainActor
    func alignLyrics(window: NSWindow?) {
        let words = project.lyricTracks.flatMap(\.lines).flatMap(\.words)
        guard !words.isEmpty else { return }
        let confirmed = words.filter(\.confirmed).count
        guard confirmed > 0, let window else { startAlignment(keepConfirmed: true, window: window); return }
        let alert = NSAlert()
        alert.messageText = "Keep the \(confirmed) confirmed word\(confirmed == 1 ? "" : "s")?"
        alert.informativeText = "Alignment re-times every word. Confirmed words can keep the times you set; the words around them are fitted between them."
        alert.addButton(withTitle: "Keep Confirmed")
        alert.addButton(withTitle: "Re-time All")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r != .alertThirdButtonReturn else { return }
            self?.startAlignment(keepConfirmed: r == .alertFirstButtonReturn, window: window)
        }
    }

    @MainActor
    private func startAlignment(keepConfirmed: Bool, window: NSWindow?) {
        alignmentTask?.cancel()
        alignmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if self.audioAnalysis.state == .running { await self.audioAnalysis.wait() }
                guard let audio = self.project.audio, let a = self.audioAnalysis.analysis,
                      let vocals = self.audioAnalysis.vocalsURL(a.audioHash), FileManager.default.fileExists(atPath: vocals.path) else {
                    throw AlignmentError.noAnalysis
                }
                let order = self.project.lyricLineOrder()
                let ids = order.map(\.id)
                let lines = order.map { $0.words.map(\.text) }
                var args: [String: Any] = ["vocals": vocals.path, "lines": lines]
                if let lang = LyricAlignment.language(for: lines.flatMap { $0 }) { args["language"] = lang }
                let result = try await self.jobs.run("Aligning lyrics", command: "align_lyrics", args: args) { data, _ in
                    try JSONDecoder().decode(LyricAlignment.Result.self, from: data)
                }
                // Apply only if the words didn't change while the job ran.
                let now = Dictionary(uniqueKeysWithValues: self.project.lyricTracks.flatMap(\.lines).map { ($0.id, $0.words.map(\.text)) })
                guard zip(ids, lines).allSatisfy({ now[$0.0] == $0.1 }) else { throw AlignmentError.lyricsChanged }
                self.edit("Align Lyrics") { p in
                    p.applyAlignment(result, lineIDs: ids, audioStart: audio.start, keepConfirmed: keepConfirmed)
                    // Newly aligned words never overlap the confirmed words that were kept.
                    if keepConfirmed { p.resolveLyricOverlaps() }
                }
            } catch is CancellationError {
            } catch {
                if let window { NSAlert(error: error).beginSheetModal(for: window) { _ in } }
            }
        }
    }

    /// Stop running analysis and alignment jobs (status bar cancel button).
    @MainActor
    func cancelJobs() {
        audioAnalysis.cancel()
        alignmentTask?.cancel()
        alignmentTask = nil
    }
}

enum AlignmentError: LocalizedError {
    case noAnalysis, lyricsChanged
    var errorDescription: String? {
        switch self {
        case .noAnalysis: "Add the song and let its analysis finish first: alignment listens to the separated vocals."
        case .lyricsChanged: "The lyrics changed while they were being aligned, so the result was not applied. Run Align Words to Song again."
        }
    }
}
