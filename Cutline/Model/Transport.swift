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
    func goToEnd() { isPlaying = false; setPlayhead(project.duration) }
    func togglePlay() { isPlaying.toggle() }

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
