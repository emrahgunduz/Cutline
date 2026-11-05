import Foundation

/// Playback state shared by the preview, timeline and keyboard shortcuts.
extension EditorModel {
    func setPlayhead(_ t: Double) {
        playhead = min(max(0, project.quantize(t)), max(0, project.duration))
    }

    func stepFrame(_ delta: Int) {
        isPlaying = false
        setPlayhead(playhead + Double(delta) * project.frameDuration)
    }

    func goToStart() { isPlaying = false; setPlayhead(0) }

    /// Clip, lyric line and audio edges, sorted — where ↑/↓ jump to.
    var editPoints: [Double] {
        var pts: Set<Double> = [0, project.duration]
        for c in project.videoTracks.flatMap(\.clips) { pts.insert(c.start); pts.insert(c.end) }
        for l in project.lyricTracks.flatMap(\.lines) { pts.insert(l.start); pts.insert(l.end) }
        if let a = project.audio { pts.insert(a.start); pts.insert(a.end) }
        if project.cinemascope.enabled { pts.insert(project.cinemascope.startMarker); pts.insert(project.cinemascope.endMarker) }
        return pts.map { project.quantize($0) }.sorted()
    }

    func jumpToEditPoint(forward: Bool) {
        isPlaying = false
        let eps = project.frameDuration / 2
        let target = forward ? editPoints.first { $0 > playhead + eps } : editPoints.last { $0 < playhead - eps }
        if let target { setPlayhead(target) }
    }

    func step(seconds: Double) {
        isPlaying = false
        setPlayhead(playhead + seconds)
    }
    func goToEnd() { isPlaying = false; setPlayhead(project.duration) }
    func togglePlay() { transport.stopAt = nil; isPlaying.toggle() }

    /// Split the selected clip at the playhead, or every clip under it when none is selected.
    func splitAtPlayhead() {
        let id = selectedClip?.id
        edit("Split") { $0.split(at: playhead, clipID: id) }
    }

    func deleteSelection() {
        let items = selectedItems.isEmpty ? [selection] : Array(selectedItems)
        guard items.contains(where: { $0 != .none }) else { return }
        edit(items.count > 1 ? "Delete Items" : "Delete") { p in
            for item in items {
                switch item {
                case .clip(let id): p.deleteClip(id)
                case .lyricLine(let id): p.deleteLine(id)
                case .lyricWord(let id): p.deleteWord(id)
                case .audio: p.removeAudio()
                case .none: break
                }
            }
        }
    }
}
