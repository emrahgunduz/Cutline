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
    /// Put aligned times (audio-file seconds) onto the lines of `track`, in order.
    /// With `keepConfirmed`, words the user confirmed keep their times.
    mutating func applyAlignment(_ r: LyricAlignment.Result, track: Int, audioStart: Double, keepConfirmed: Bool) {
        guard lyricTracks.indices.contains(track) else { return }
        let f = frameDuration
        var lines = lyricTracks[track].lines.sorted { $0.start < $1.start }
        for (li, aligned) in r.lines.enumerated() where lines.indices.contains(li) && lines[li].words.count == aligned.count {
            for (wi, a) in aligned.enumerated() {
                if keepConfirmed && lines[li].words[wi].confirmed { continue }
                let s = quantize(max(0, audioStart + a.start))
                lines[li].words[wi].start = s
                lines[li].words[wi].end = max(s + f, quantize(audioStart + a.end))
                lines[li].words[wi].confidence = a.confidence
            }
            // Words never overlap after quantizing.
            for wi in lines[li].words.indices.dropFirst() where lines[li].words[wi].start < lines[li].words[wi - 1].end {
                lines[li].words[wi - 1].end = max(lines[li].words[wi - 1].start + f, lines[li].words[wi].start)
                if lines[li].words[wi].start < lines[li].words[wi - 1].end { lines[li].words[wi].start = lines[li].words[wi - 1].end }
                lines[li].words[wi].end = max(lines[li].words[wi].end, lines[li].words[wi].start + f)
            }
            lines[li].start = lines[li].words.first!.start
            lines[li].end = lines[li].words.last!.end
        }
        lyricTracks[track].lines = lines
    }
}

extension EditorModel {
    /// Time the words on `track` to the song. Waits for song analysis if it is still running.
    /// Asks before overwriting words the user confirmed.
    @MainActor
    func alignLyrics(track: Int, window: NSWindow?) {
        guard project.lyricTracks.indices.contains(track), !project.lyricTracks[track].lines.isEmpty else { return }
        let confirmed = project.lyricTracks[track].lines.flatMap(\.words).filter(\.confirmed).count
        guard confirmed > 0, let window else { startAlignment(track: track, keepConfirmed: true, window: window); return }
        let alert = NSAlert()
        alert.messageText = "Keep the \(confirmed) confirmed word\(confirmed == 1 ? "" : "s") on Lyrics \(track + 1)?"
        alert.informativeText = "Alignment re-times every word. Confirmed words can keep the times you set."
        alert.addButton(withTitle: "Keep Confirmed")
        alert.addButton(withTitle: "Re-time All")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r != .alertThirdButtonReturn else { return }
            self?.startAlignment(track: track, keepConfirmed: r == .alertFirstButtonReturn, window: window)
        }
    }

    @MainActor
    private func startAlignment(track: Int, keepConfirmed: Bool, window: NSWindow?) {
        alignmentTask?.cancel()
        alignmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if self.audioAnalysis.state == .running { await self.audioAnalysis.wait() }
                guard let audio = self.project.audio, let a = self.audioAnalysis.analysis,
                      let vocals = self.audioAnalysis.vocalsURL(a.audioHash), FileManager.default.fileExists(atPath: vocals.path) else {
                    throw AlignmentError.noAnalysis
                }
                let trackID = self.project.lyricTracks[track].id
                let lines = self.project.lyricTracks[track].lines.sorted { $0.start < $1.start }.map { $0.words.map(\.text) }
                var args: [String: Any] = ["vocals": vocals.path, "lines": lines]
                if let lang = LyricAlignment.language(for: lines.flatMap { $0 }) { args["language"] = lang }
                let result = try await self.jobs.run("Aligning lyrics", command: "align_lyrics", args: args) { data, _ in
                    try JSONDecoder().decode(LyricAlignment.Result.self, from: data)
                }
                // The track may have moved while the job ran; apply only if its text is unchanged.
                guard let t = self.project.lyricTracks.firstIndex(where: { $0.id == trackID }),
                      self.project.lyricTracks[t].lines.sorted(by: { $0.start < $1.start }).map({ $0.words.map(\.text) }) == lines else {
                    throw AlignmentError.lyricsChanged
                }
                self.edit("Align Lyrics") { $0.applyAlignment(result, track: t, audioStart: audio.start, keepConfirmed: keepConfirmed) }
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
