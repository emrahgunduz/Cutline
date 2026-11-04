import AppKit
import Combine

enum Selection: Equatable {
    case none
    case clip(UUID)
    case lyricLine(UUID)
    case lyricWord(UUID)
    case audio
}

/// Observable editing state for one open project. Every project mutation goes through
/// `edit(_:_:)`, which registers an undo step that restores the previous project value.
final class EditorModel: ObservableObject {
    @Published private(set) var project: Project
    @Published var selection: Selection = .none
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    /// Bumped on every project change so renderers can rebuild.
    @Published private(set) var revision = 0

    weak var document: ProjectDocument?
    /// Called when a lyrics TXT is dropped on the timeline.
    var lyricsDropped: ((Asset) -> Void)?
    private(set) lazy var thumbnails = ThumbnailGenerator { [weak self] in self?.folder("thumbnails") }
    private(set) lazy var waveforms = WaveformStore { [weak self] in self?.folder("analysis") }

    init(document: ProjectDocument?) {
        self.document = document
        self.project = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
    }

    var undoManager: UndoManager? { document?.undoManager }

    /// Load cached thumbnails and waveforms (or build them) for every asset, e.g. after opening.
    @MainActor
    func warmCaches() {
        for a in project.assets {
            switch a.kind {
            case .video, .image: Task { await thumbnails.ensureThumbnail(for: a) }
            case .audio: Task { await waveforms.ensureWaveform(for: a) }
            case .lyrics: break
            }
        }
    }

    func replaceWithoutUndo(_ p: Project) {
        project = p
        revision += 1
    }

    /// Apply a change as one undoable step.
    func edit(_ actionName: String, _ change: (inout Project) -> Void) {
        var next = project
        change(&next)
        guard next != project else { return }
        apply(next, actionName: actionName)
    }

    private func apply(_ next: Project, actionName: String) {
        let previous = project
        project = next
        revision += 1
        if let um = undoManager {
            um.registerUndo(withTarget: self) { target in
                target.apply(previous, actionName: actionName)
            }
            um.setActionName(actionName)
        }
        document?.updateChangeCount(.changeDone)
        validateSelection()
    }

    private func validateSelection() {
        switch selection {
        case .clip(let id) where clip(id) == nil: selection = .none
        case .lyricLine(let id) where line(id) == nil: selection = .none
        case .lyricWord(let id) where word(id) == nil: selection = .none
        case .audio where project.audio == nil: selection = .none
        default: break
        }
    }

    // MARK: Lookup

    func clip(_ id: UUID) -> Clip? { project.videoTracks.lazy.flatMap(\.clips).first { $0.id == id } }
    func line(_ id: UUID) -> LyricLine? { project.lyricTracks.lazy.flatMap(\.lines).first { $0.id == id } }
    func word(_ id: UUID) -> LyricWord? { project.lyricTracks.lazy.flatMap(\.lines).flatMap(\.words).first { $0.id == id } }

    var selectedClip: Clip? { if case .clip(let id) = selection { return clip(id) }; return nil }

    func folder(_ name: String) -> URL? { document?.folder(name) }
}
