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
        switch selection {
        case .clip(let id): edit("Delete Clip") { $0.deleteClip(id) }
        case .lyricLine(let id): edit("Delete Line") { $0.deleteLine(id) }
        case .audio: edit("Remove Audio") { $0.removeAudio() }
        default: break
        }
    }
}
