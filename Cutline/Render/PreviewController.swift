import AVFoundation
import Combine

/// Keeps an AVPlayer in sync with the project: rebuilds the composition when clips or
/// media change, swaps only the video composition when looks change, and mirrors the
/// playhead and play state in both directions.
final class PreviewController: ObservableObject {
    let player = AVPlayer()
    private let editor: EditorModel
    private var cancellables: Set<AnyCancellable> = []
    private var timeObserver: Any?
    private var structureKey: Int?
    private var built: BuiltComposition?
    private var rebuildTask: Task<Void, Never>?
    private var seeking = false
    private var pendingSeek: Double?
    private var settingPlayheadFromPlayer = false
    var useProxies = true
    /// Viewport zoom (canvas pixels → view points); nil fits the canvas to the view.
    @Published var zoom: CGFloat?
    @Published var pan: CGPoint = .zero
    /// Current fit scale in percent, for the zoom menu.
    @Published var fitPercent = 100

    func resetView() { zoom = nil; pan = .zero }
    func center() { pan = .zero }
    func setZoom(percent: Double) { zoom = CGFloat(percent / 100); pan = .zero }
    func stepZoom(_ factor: CGFloat) { zoom = min(max((zoom ?? CGFloat(fitPercent) / 100) * factor, 0.05), 8) }

    init(editor: EditorModel) {
        self.editor = editor
        player.actionAtItemEnd = .pause
        editor.$revision
            // Throttle (not debounce) so continuous edits like slider drags show while dragging.
            .throttle(for: .milliseconds(40), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)
        editor.$playhead.removeDuplicates().sink { [weak self] t in self?.playheadChanged(t) }.store(in: &cancellables)
        editor.$isPlaying.removeDuplicates().sink { [weak self] playing in self?.setPlaying(playing) }.store(in: &cancellables)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            guard let self, self.player.rate != 0 else { return }
            self.settingPlayheadFromPlayer = true
            self.editor.playhead = min(time.seconds, self.editor.project.duration)
            self.settingPlayheadFromPlayer = false
        }
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .sink { [weak self] note in
                guard (note.object as? AVPlayerItem) === self?.player.currentItem else { return }
                self?.editor.isPlaying = false
            }
            .store(in: &cancellables)
        scheduleRebuild()
    }

    deinit { if let timeObserver { player.removeTimeObserver(timeObserver) } }

    /// Hash of everything that changes which media sits where (not looks).
    static func structureKey(_ p: Project, useProxies: Bool) -> Int {
        var h = Hasher()
        h.combine(useProxies)
        h.combine(p.fps)
        h.combine(p.canvas)
        h.combine(p.duration)
        for c in p.videoTracks.flatMap(\.clips) { h.combine(c.id); h.combine(c.assetID); h.combine(c.start); h.combine(c.duration); h.combine(c.sourceIn) }
        for a in p.assets { h.combine(a.id); h.combine(a.path); h.combine(a.proxy?.fileName); h.combine(a.proxy?.scale) }
        h.combine(p.audio?.assetID); h.combine(p.audio?.start)
        return h.finalize()
    }

    private func scheduleRebuild() {
        let project = editor.project
        let key = Self.structureKey(project, useProxies: useProxies)
        let snapshot = RenderSnapshot(project: project, images: FrameRenderer.loadImages(project), lyrics: LyricRenderer(project: project))
        if key == structureKey, let built, let item = player.currentItem {
            // Looks-only change: new instruction snapshot, same media. A structural rebuild still
            // in flight is now stale (e.g. a clip dragged back to where it started); drop it.
            rebuildTask?.cancel()
            rebuildTask = nil
            let baseID = built.composition.tracks(withMediaType: .video).first?.trackID ?? kCMPersistentTrackID_Invalid
            item.videoComposition = CompositionBuilder.makeVideoComposition(
                project: project, snapshot: snapshot, baseTrackID: baseID,
                clipTracks: built.clipTracks.mapValues { ($0.trackID, $0.transform) }, duration: built.duration)
            if player.rate == 0 { seek(to: editor.playhead) }
            return
        }
        rebuildTask?.cancel()
        let useProxies = self.useProxies
        rebuildTask = Task { @MainActor [weak self] in
            // Debounce structural rebuilds (e.g. while dragging a clip): only the latest one runs.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else { return }
            do {
                let b = try await CompositionBuilder.build(project: project, mediaURL: { self.editor.mediaURL(for: $0, useProxies: useProxies) }, snapshot: snapshot)
                guard !Task.isCancelled else { return }
                let item = AVPlayerItem(asset: b.composition)
                item.videoComposition = b.videoComposition
                self.built = b
                self.structureKey = key
                let wasPlaying = self.player.rate != 0
                self.player.replaceCurrentItem(with: item)
                self.seek(to: self.editor.playhead)
                if wasPlaying { self.player.play() }
            } catch is CancellationError {
            } catch {
                NSLog("Cutline preview rebuild failed: \(error)")
            }
        }
    }

    private func playheadChanged(_ t: Double) {
        guard !settingPlayheadFromPlayer, player.rate == 0 else { return }
        seek(to: t)
    }

    /// Frame-exact seek; requests arriving mid-seek are coalesced to the latest one.
    private func seek(to t: Double) {
        if seeking { pendingSeek = t; return }
        seeking = true
        player.seek(to: CompositionBuilder.time(t), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.seeking = false
                if let next = self.pendingSeek { self.pendingSeek = nil; self.seek(to: next) }
            }
        }
    }

    private func setPlaying(_ playing: Bool) {
        if playing {
            if editor.playhead >= editor.project.duration - editor.project.frameDuration { editor.playhead = 0; seek(to: 0) }
            player.play()
        } else {
            player.pause()
            editor.setPlayhead(editor.playhead)
            seek(to: editor.playhead)
        }
    }
}
