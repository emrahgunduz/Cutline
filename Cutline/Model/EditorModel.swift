import AppKit
import Combine

enum Selection: Hashable {
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
    /// The primary (last clicked) selected item.
    @Published var selection: Selection = .none {
        didSet {
            if !updatingMulti { selectedItems = selection == .none ? [] : [selection] }
            syncAssetSelection()
        }
    }
    /// Everything selected on the timeline (includes `selection`).
    @Published private(set) var selectedItems: Set<Selection> = []
    private var updatingMulti = false

    func setSelection(_ items: Set<Selection>, primary: Selection? = nil) {
        updatingMulti = true
        selectedItems = items
        selection = primary.flatMap { items.contains($0) ? $0 : nil } ?? items.first ?? .none
        updatingMulti = false
    }

    /// ⌘-click: add or remove one item.
    func toggleSelected(_ s: Selection) {
        var items = selectedItems
        if items.contains(s) { items.remove(s) } else { items.insert(s) }
        setSelection(items, primary: items.contains(s) ? s : nil)
    }
    /// Assets selected in the assets panel.
    @Published var selectedAssets: Set<UUID> = [] {
        didSet {
            assetSelectionOrder.removeAll { !selectedAssets.contains($0) }
            for id in selectedAssets where !assetSelectionOrder.contains(id) { assetSelectionOrder.append(id) }
        }
    }
    /// The selected assets in the order they were clicked (used when dropping several at once).
    private(set) var assetSelectionOrder: [UUID] = []
    /// Playback state lives in its own object so the 60 Hz playhead ticks don't
    /// fire `objectWillChange` on the whole editor (and redraw every panel).
    let transport = TransportState()
    var playhead: Double {
        get { transport.playhead }
        set { transport.playhead = newValue }
    }
    var isPlaying: Bool {
        get { transport.isPlaying }
        set { transport.isPlaying = newValue }
    }
    /// Assets with a proxy encode in flight (main actor only).
    var proxyJobs: Set<UUID> = []
    /// Bumped on every project change so renderers can rebuild.
    @Published private(set) var revision = 0

    weak var document: ProjectDocument?
    private(set) lazy var thumbnails = ThumbnailGenerator { [weak self] in self?.folder("thumbnails") }
    private(set) lazy var waveforms = WaveformStore { [weak self] in self?.folder("analysis") }
    /// Analysis jobs on the bundled helper (progress shown in the status bar).
    private(set) lazy var jobs = JobRunner()
    private(set) lazy var audioAnalysis = AudioAnalysisStore(folder: { [weak self] in self?.folder("analysis") },
                                                            analyzer: AudioAnalysisStore.helperAnalyzer(jobs))
    /// Analyse the song automatically when it is added or replaced (off in unit tests).
    var autoAnalyze = !AppDelegate.isTestHost
    private var analysisWatch: AnyCancellable?

    init(document: ProjectDocument?) {
        self.document = document
        self.project = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
    }

    var undoManager: UndoManager? { document?.undoManager }

    /// Load cached thumbnails and waveforms (or build them) for every asset, e.g. after opening.
    @MainActor
    func warmCaches() {
        watchSong()
        for a in project.assets {
            switch a.kind {
            case .video, .image: Task { await thumbnails.ensureThumbnail(for: a) }
            case .audio: Task { await waveforms.ensureWaveform(for: a) }
            case .lyrics: break
            }
        }
    }

    /// Keep the song's analysis and loud/quiet regions in step with the audio row.
    @MainActor
    func watchSong() {
        guard analysisWatch == nil else { return }
        analysisWatch = $project.map { $0.audio?.assetID }.removeDuplicates()
            .combineLatest(waveforms.$waveforms)
            .receive(on: RunLoop.main)
            .sink { [weak self] id, wfs in
                guard let self else { return }
                let asset = id.flatMap { self.project.asset($0) }
                if self.autoAnalyze { self.audioAnalysis.ensure(for: asset) }
                self.audioAnalysis.updateLoudness(id.flatMap { wfs[$0] })
            }
    }

    /// Analysis with the user's corrections, for drawing and snapping.
    @MainActor var resolvedBeats: ResolvedBeats? {
        audioAnalysis.analysis.map { ResolvedBeats($0, project.beatCorrections) }
    }

    func replaceWithoutUndo(_ p: Project) {
        project = p
        revision += 1
    }

    // MARK: Live edits (slider drags): many updates, one undo step.

    private var liveOriginal: Project?

    func liveEdit(_ change: (inout Project) -> Void) {
        if liveOriginal == nil { liveOriginal = project }
        var next = project
        change(&next)
        guard next != project else { return }
        project = next
        revision += 1
    }

    func endLiveEdit(_ actionName: String) {
        guard let original = liveOriginal else { return }
        liveOriginal = nil
        let final = project
        project = original
        guard final != original else { return }
        apply(final, actionName: actionName)
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

    /// Selecting a timeline item selects the asset it uses.
    private func syncAssetSelection() {
        switch selection {
        case .clip(let id): if let c = clip(id) { selectedAssets = [c.assetID] }
        case .audio: if let a = project.audio { selectedAssets = [a.assetID] }
        case .lyricLine, .lyricWord:
            if let l = project.assets.first(where: { $0.kind == .lyrics }) { selectedAssets = [l.id] }
        case .none: break
        }
    }

    private func validateSelection() {
        selectedAssets = selectedAssets.filter { project.asset($0) != nil }
        let alive = selectedItems.filter {
            switch $0 {
            case .clip(let id): clip(id) != nil
            case .lyricLine(let id): line(id) != nil
            case .lyricWord(let id): word(id) != nil
            case .audio: project.audio != nil
            case .none: false
            }
        }
        if alive != selectedItems { setSelection(alive, primary: selection) }
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

    func isSelected(_ s: Selection) -> Bool { selectedItems.contains(s) }

    var selectedClipIDs: [UUID] { selectedItems.compactMap { if case .clip(let id) = $0 { return id } else { return nil } } }
    var selectedLineIDs: [UUID] { selectedItems.compactMap { if case .lyricLine(let id) = $0 { return id } else { return nil } } }

    var selectedClip: Clip? { if case .clip(let id) = selection { return clip(id) }; return nil }

    func folder(_ name: String) -> URL? { document?.folder(name) }
}

/// Playhead and play/pause, observed separately from the editor model.
final class TransportState: ObservableObject {
    @Published var playhead: Double = 0
    @Published var isPlaying = false
}
