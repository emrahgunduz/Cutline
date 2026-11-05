import AppKit
import Foundation

/// Times lyric words by aligning their known text on the song's vocal stem (KTD7, R21-R22).
enum LyricAlignment {
    /// Words below this confidence (and not confirmed) are tinted and visited by the
    /// next-uncertain-word key (U11).
    static let lowConfidence = 0.6

    struct Word: Decodable, Equatable { var text: String; var start: Double; var end: Double; var confidence: Double; var source: String }
    struct Result: Decodable, Equatable { var lines: [[Word]] }

    static func isLow(_ w: LyricWord) -> Bool { !w.confirmed && w.confidence < lowConfidence }
}

extension Project {
    /// Put aligned times (audio-file seconds) onto the lines of `track`, in time order.
    mutating func applyAlignment(_ r: LyricAlignment.Result, track: Int, audioStart: Double, keepEdits: Bool) {
        guard lyricTracks.indices.contains(track) else { return }
        let ids = lyricTracks[track].lines.sorted { $0.start < $1.start }.map(\.id)
        applyAlignment(r, lineIDs: ids, audioStart: audioStart, keepEdits: keepEdits)
    }

    /// Put aligned times onto the given lines (result line k goes to `lineIDs[k]`).
    /// With `keepEdits`, words you confirmed or moved by hand keep their times (and their flags);
    /// every word alignment re-times loses both.
    mutating func applyAlignment(_ r: LyricAlignment.Result, lineIDs: [UUID], audioStart: Double, keepEdits: Bool) {
        let f = frameDuration
        let lead = lyricStyle.leadIn
        for (li, aligned) in r.lines.enumerated() where lineIDs.indices.contains(li) {
            guard let loc = lineLocation(lineIDs[li]) else { continue }
            var line = lyricTracks[loc.track].lines[loc.index]
            guard line.words.count == aligned.count else { continue }
            for (wi, a) in aligned.enumerated() {
                if keepEdits && line.words[wi].isUserTimed { continue }
                let s = quantize(max(0, audioStart + a.start - lead))
                line.words[wi].start = s
                line.words[wi].end = max(s + f, quantize(audioStart + a.end - lead))
                line.words[wi].confidence = a.confidence
                line.words[wi].confirmed = false   // re-timed by alignment, no longer the user's time
                line.words[wi].handEdited = nil
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
                let e = max(quantize(audioStart + lineEnd - lead + lyricStyle.leadOut), (line.words.map(\.start).max() ?? 0) + f)
                for wi in line.words.indices where !(keepEdits && line.words[wi].isUserTimed) {
                    line.words[wi].end = max(e, line.words[wi].start + f)
                    line.words[wi].alignedEnd = audioStart + lineEnd
                }
            }
            line.fitToWords()
            lyricTracks[loc.track].lines[loc.index] = line
        }
        for t in lyricTracks.indices { lyricTracks[t].lines.sort { $0.start < $1.start } }
        endLinesBeforeTheirNeighbours()
    }

    /// Lines on one track never overlap: a line (and its words) that runs into the next line
    /// on its track ends where that one starts, but never before its own last word starts.
    mutating func endLinesBeforeTheirNeighbours() {
        let f = frameDuration
        for t in lyricTracks.indices {
            lyricTracks[t].lines.sort { $0.start < $1.start }
            for i in lyricTracks[t].lines.indices.dropLast() {
                let next = lyricTracks[t].lines[i + 1].start
                var line = lyricTracks[t].lines[i]
                guard line.end > next else { continue }
                let e = max(next, (line.words.map(\.start).max() ?? line.start) + f)
                line.end = e
                for w in line.words.indices where line.words[w].end > e { line.words[w].end = max(e, line.words[w].start + f) }
                lyricTracks[t].lines[i] = line
            }
        }
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
                    line.words[i].end = max(s + f, quantize(b - lead + lyricStyle.leadOut))
                }
                let first = line.words.map(\.start).min()!, last = line.words.map(\.end).max()!
                line.start = tightStart ? first : min(line.start, first)
                line.end = tightEnd ? last : max(line.end, last)
                lyricTracks[t].lines[l] = line
            }
        }
        endLinesBeforeTheirNeighbours()
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
        let changes = Self.userTimingSummary(words)
        guard let changes, let window else { startAlignment(keepEdits: true, window: window); return }
        let alert = NSAlert()
        alert.messageText = "Keep your lyric changes?"
        alert.informativeText = changes + "\n\nKeep My Changes keeps those times and fits the other words between them. Re-time All clears them and times every word to the song again."
        alert.addButton(withTitle: "Keep My Changes")
        alert.addButton(withTitle: "Re-time All")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r != .alertThirdButtonReturn else { return }
            self?.startAlignment(keepEdits: r == .alertFirstButtonReturn, window: window)
        }
    }

    /// What re-aligning would replace, or nil when every word still has its aligned time:
    /// words confirmed (next unsure word, tap mode, Return) and words moved or re-timed by hand
    /// (word, line and group drags).
    nonisolated static func userTimingSummary(_ words: [LyricWord]) -> String? {
        let confirmed = words.filter(\.confirmed).count
        let edited = words.filter { $0.isHandEdited && !$0.confirmed }.count
        guard confirmed + edited > 0 else { return nil }
        func n(_ k: Int) -> String { k == 1 ? "1 word" : "\(k) words" }
        var parts: [String] = []
        if confirmed > 0 { parts.append("\(n(confirmed)) confirmed (next unsure word, tap mode or a word drag)") }
        if edited > 0 { parts.append("\(n(edited)) moved or re-timed by hand (line and group drags)") }
        return "Re-aligning re-times every lyric word. You have " + parts.joined(separator: " and ") + "."
    }

    @MainActor
    private func startAlignment(keepEdits: Bool, window: NSWindow?) {
        alignmentTask?.cancel()
        alignmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if self.audioAnalysis.state == .running { await self.audioAnalysis.wait() }
                guard let audio = self.project.audio, let a = self.audioAnalysis.analysis,
                      let vocals = self.audioAnalysis.vocalsURL(a.audioHash), FileManager.default.fileExists(atPath: vocals.path) else {
                    throw AlignmentError.noAnalysis
                }
                // The song the result belongs to: if it moves or changes during the job, the
                // result is stale (word times are relative to where the song sits).
                let songAtStart = (asset: audio.assetID, start: audio.start, hash: a.audioHash)
                let order = self.project.lyricLineOrder()
                let ids = order.map(\.id)
                let lines = order.map { $0.words.map(\.text) }
                var args: [String: Any] = ["vocals": vocals.path, "lines": lines]
                if let lang = LyricsLanguage.resolved(for: self.project) { args["language"] = lang }
                let result = try await self.jobs.run("Aligning lyrics", command: "align_lyrics", args: args) { data, _ in
                    try JSONDecoder().decode(LyricAlignment.Result.self, from: data)
                }
                // Apply only if the words didn't change while the job ran.
                let now = Dictionary(uniqueKeysWithValues: self.project.lyricTracks.flatMap(\.lines).map { ($0.id, $0.words.map(\.text)) })
                guard zip(ids, lines).allSatisfy({ now[$0.0] == $0.1 }) else { throw AlignmentError.lyricsChanged }
                guard let audioNow = self.project.audio, audioNow.assetID == songAtStart.asset, audioNow.start == songAtStart.start,
                      self.audioAnalysis.analysis?.audioHash == songAtStart.hash else { throw AlignmentError.songChanged }
                self.edit("Align Lyrics") { p in
                    p.applyAlignment(result, lineIDs: ids, audioStart: audio.start, keepEdits: keepEdits)
                    // Newly aligned words never overlap the confirmed words that were kept.
                    if keepEdits { p.resolveLyricOverlaps() }
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
    case noAnalysis, lyricsChanged, songChanged
    var errorDescription: String? {
        switch self {
        case .noAnalysis: "Add the song and let its analysis finish first: alignment listens to the separated vocals."
        case .lyricsChanged: "The lyrics changed while they were being aligned, so the result was not applied. Run Align Words to Song again."
        case .songChanged: "The song was moved or replaced while the lyrics were being aligned, so the result was not applied. Run Align Words to Song again."
        }
    }
}
