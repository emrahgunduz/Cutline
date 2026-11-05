import Foundation

/// Fast lyric correction (R23-R25): jump to the next unsure word and loop around it,
/// confirm words, and tap words in time while the song plays.
extension EditorModel {
    /// Seconds of song played before and after an unsure word while it loops.
    static let loopPadding = 1.75
    /// A tap snaps to a vocal onset this close.
    static let tapSnapWindow = 0.04
    static let tapRates: [Float] = [1, 0.75, 0.5]
    /// Tap mode starts playing this long before the first word...
    static let tapLeadTime = 5.0
    /// ...and keeps playing this long after the last word is tapped.
    static let tapTailTime = 5.0

    /// All lyric words in time order with their track.
    private var allWords: [(track: Int, word: LyricWord)] {
        project.lyricOrder().map { ($0.track, $0.value) }.sorted { $0.word.start < $1.word.start }
    }

    /// Select the next (or previous) low-confidence, unconfirmed word after the selected
    /// word or the playhead, wrapping around, and loop playback around it.
    @MainActor
    func jumpToUnsureWord(forward: Bool = true) {
        let unsure = allWords.filter { LyricAlignment.isLow($0.word) }
        guard !unsure.isEmpty else { return }
        let from: Double = {
            if case .lyricWord(let id) = selection, let w = word(id) { return w.start }
            return playhead
        }()
        let eps = 1e-6
        let target = forward
            ? unsure.first { $0.word.start > from + eps } ?? unsure.first!
            : unsure.last { $0.word.start < from - eps } ?? unsure.last!
        selection = .lyricWord(target.word.id)
        loopAround(target.word)
    }

    @MainActor
    func loopAround(_ w: LyricWord) {
        let lo = max(0, w.start - Self.loopPadding)
        let end = w.end + Self.loopPadding
        let hi = project.duration > w.end ? min(project.duration, end) : end
        transport.loop = lo...hi
        setPlayhead(lo)
        isPlaying = true
    }

    @MainActor
    func clearLoop() { transport.loop = nil }


    /// Confirm the selected words (or un-confirm them if all already are).
    @MainActor
    func toggleConfirmSelectedWords() {
        let ids = selectedItems.compactMap { if case .lyricWord(let id) = $0 { return id } else { return nil } }
        guard !ids.isEmpty else { return }
        let allConfirmed = ids.allSatisfy { word($0)?.confirmed == true }
        edit(allConfirmed ? "Unconfirm Word" : "Confirm Word") { p in
            for id in ids {
                guard let loc = p.wordLocation(id) else { continue }
                p.lyricTracks[loc.track].lines[loc.line].words[loc.word].confirmed = !allConfirmed
            }
        }
    }

    // MARK: Tap mode

    var isTapping: Bool { transport.tapWordID != nil }

    /// Start tapping from the selected word, else the first word after the playhead.
    @MainActor
    func startTapMode() {
        let words = allWords
        let start: LyricWord? = {
            if case .lyricWord(let id) = selection, let w = word(id) { return w }
            return words.first { $0.word.end > playhead }?.word ?? words.first?.word
        }()
        guard let first = start else { return }
        clearLoop()
        transport.stopAt = nil
        transport.tapWordID = first.id
        selection = .lyricWord(first.id)
        // Start well before the word so you hear the run-up and the first tap lands on time.
        setPlayhead(max(0, first.start - Self.tapLeadTime))
        isPlaying = true
    }

    @MainActor
    func endTapMode() {
        transport.tapWordID = nil
        transport.stopAt = nil
        transport.rate = 1
        isPlaying = false
    }

    /// After the last word: leave tap mode but let the song play on for the tail, then pause.
    @MainActor
    private func finishTapMode(after lastEnd: Double) {
        transport.tapWordID = nil
        transport.stopAt = lastEnd + Self.tapTailTime
    }

    /// Called by playback when it reaches `stopAt`.
    @MainActor
    func reachedStopPoint() {
        transport.stopAt = nil
        transport.rate = 1
        isPlaying = false
    }

    @MainActor
    func setTapRate(_ rate: Float) { transport.rate = rate }

    /// Set the current word's start to the song time now (snapped to a vocal onset within
    /// 40 ms, then shown early by the lead-in), confirm it, re-time the words around it,
    /// and move on to the next word sung.
    @MainActor
    func tap(snap: Bool = true) {
        guard let id = transport.tapWordID, project.wordLocation(id) != nil else { endTapMode(); return }
        var t = transport.currentTime()
        if snap, let onsets = resolvedBeats?.onsets, let audio = project.audio {
            let near = onsets.map { $0 + audio.start }.min { abs($0 - t) < abs($1 - t) }
            if let near, abs(near - t) <= Self.tapSnapWindow { t = near }
        }
        let shown = max(0, t - project.lyricStyle.leadIn)
        let before = project
        edit("Tap Word") { p in
            // Only the start is set: every word ends with its line.
            p.retimeWord(id, start: p.quantize(shown))
            p.applyAnchorStretch(from: before)
        }
        // Next word in sung order, whichever track it is on.
        let order = project.lyricOrder().map(\.value.id)
        if let i = order.firstIndex(of: id), i + 1 < order.count {
            transport.tapWordID = order[i + 1]
            selection = .lyricWord(order[i + 1])
        } else {
            finishTapMode(after: word(id)?.end ?? t)
        }
    }
}
