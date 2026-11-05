import AppKit
import SwiftUI

/// Four regions: assets (left), preview (center), inspector (right), timeline (bottom).
/// Divider positions are restored from and saved to the project's layout.
final class MainWindowController: NSWindowController, NSSplitViewDelegate {
    private let vertical = NSSplitView()
    private let horizontal = NSSplitView()
    private var restoring = true
    let projectDocument: ProjectDocument

    init(document: ProjectDocument) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 1000, height: 640)
        window.center()
        window.setFrameAutosaveName("CutlineMainWindow")
        projectDocument = document
        super.init(window: window)
        // `document` is set by NSDocument.addWindowController; setting it here first makes
        // that call skip the controller, and the window never opens.
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent() {
        let editor = projectDocument.editor
        horizontal.isVertical = true
        horizontal.dividerStyle = .thin
        vertical.isVertical = false
        vertical.dividerStyle = .thin
        horizontal.delegate = self
        vertical.delegate = self

        let assets = NSHostingView(rootView: AssetsPanelView().environmentObject(editor))
        assetsPanel = assets
        horizontal.addArrangedSubview(assets)
        horizontal.addArrangedSubview(PreviewContainer.make(editor: editor))
        horizontal.addArrangedSubview(NSHostingView(rootView: InspectorView().environmentObject(editor)))
        vertical.addArrangedSubview(horizontal)
        vertical.addArrangedSubview(TimelineContainer.make(editor: editor))

        for (i, p) in [NSLayoutConstraint.Priority(260), .init(250), .init(260)].enumerated() {
            horizontal.setHoldingPriority(p, forSubviewAt: i)
        }
        vertical.setHoldingPriority(.init(250), forSubviewAt: 0)
        vertical.setHoldingPriority(.init(260), forSubviewAt: 1)
        // Status bar under everything; the split view fills the rest.
        let root = NSView()
        let status = NSHostingView(rootView: StatusBarView().environmentObject(editor))
        for v in [vertical, status] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            vertical.topAnchor.constraint(equalTo: root.topAnchor),
            vertical.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            vertical.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            vertical.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 26),
        ])
        window?.contentView = root
        installTransportKeys()
        installClickToEndEditing()
        editor.warmCaches()
        toolbar = WindowToolbar(editor: editor, windowController: self)
        if let window { toolbar?.install(on: window) }
    }

    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var toolbar: WindowToolbar?
    private weak var assetsPanel: NSView?

    /// The last click was in the assets panel: Backspace then deletes the selected assets.
    private var lastClickInAssets = false

    private var assetsHaveFocus: Bool {
        if lastClickInAssets { return true }
        guard let panel = assetsPanel, let r = window?.firstResponder as? NSView else { return false }
        return r.isDescendant(of: panel)
    }

    /// A click outside the text field being edited ends the editing (and commits it), so
    /// inspector fields don't keep the keyboard after you click the timeline or the preview.
    private func installClickToEndEditing() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window, let content = window.contentView else { return event }
            let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
            if let panel = self.assetsPanel { self.lastClickInAssets = hit?.isDescendant(of: panel) ?? false }
            guard let editing = window.firstResponder as? NSText, let field = editing.delegate as? NSView else { return event }
            if let hit, hit === field || hit.isDescendant(of: field) || hit === editing { return event }
            window.makeFirstResponder(nil)
            return event
        }
    }

    /// Single-key shortcuts that work anywhere in the window except while typing in a field.
    /// The list shown in the inspector lives in `Shortcuts` and must match this.
    private func installTransportKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, !(self.window?.firstResponder is NSText) else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let editor = self.projectDocument.editor
            let timeline = (self.vertical.arrangedSubviews.last as? TimelineContainer)?.timeline
            // Tap mode owns Space (tap), Esc (stop) and 1/2/3 (speed).
            if editor.isTapping {
                switch (event.keyCode, event.charactersIgnoringModifiers ?? "") {
                case (49, _): editor.tap(snap: timeline?.snappingEnabled ?? true); return nil
                case (53, _): editor.endTapMode(); return nil
                case (_, "1"): editor.setTapRate(1); return nil
                case (_, "2"): editor.setTapRate(0.75); return nil
                case (_, "3"): editor.setTapRate(0.5); return nil
                default: break
                }
            }
            switch (event.keyCode, flags) {
            case (49, []): editor.togglePlay()
            case (53, []): editor.clearLoop()
            case (36, []), (76, []):
                guard case .lyricWord = editor.selection else { return event }
                editor.toggleConfirmSelectedWords()
            case (123, []): editor.stepFrame(-1)
            case (124, []): editor.stepFrame(1)
            case (123, [.shift]): editor.step(seconds: -1)
            case (124, [.shift]): editor.step(seconds: 1)
            case (126, []): editor.jumpToEditPoint(forward: false)
            case (125, []): editor.jumpToEditPoint(forward: true)
            case (115, []): editor.goToStart()
            case (119, []): editor.goToEnd()
            case (51, []), (117, []):
                if self.assetsHaveFocus { editor.confirmDeleteAssets(editor.selectedAssets, window: self.window) } else { editor.deleteSelection() }
            default:
                guard flags.isEmpty || flags == [.shift], let ch = event.charactersIgnoringModifiers?.lowercased() else { return event }
                if flags == [.shift] && ch != "n" { return event }
                switch ch {
                case "c": editor.splitAtPlayhead()
                case "n": editor.jumpToUnsureWord(forward: !event.modifierFlags.contains(.shift))
                case "t": editor.isTapping ? editor.endTapMode() : editor.startTapMode()
                case "s": timeline?.snappingEnabled.toggle()
                case "=", "+": timeline?.zoomAroundPlayhead(1.5)
                case "-": timeline?.zoomAroundPlayhead(1 / 1.5)
                default: return event
                }
            }
            return nil
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    override func windowDidLoad() { super.windowDidLoad() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        restoreLayout()
    }

    private func restoreLayout() {
        restoring = true
        vertical.layoutSubtreeIfNeeded()
        let l = projectDocument.layout
        let width = horizontal.bounds.width
        horizontal.setPosition(l.assetsWidth, ofDividerAt: 0)
        horizontal.setPosition(width - l.inspectorWidth, ofDividerAt: 1)
        vertical.setPosition(vertical.bounds.height - l.timelineHeight, ofDividerAt: 0)
        DispatchQueue.main.async { self.restoring = false }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === vertical { return 200 }
        return dividerIndex == 0 ? 160 : proposedMinimumPosition + 320
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === vertical { return splitView.bounds.height - 140 }
        return dividerIndex == 0 ? splitView.bounds.width - 600 : splitView.bounds.width - 200
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !restoring, horizontal.arrangedSubviews.count == 3, vertical.arrangedSubviews.count == 2 else { return }
        var l = projectDocument.layout
        l.assetsWidth = horizontal.arrangedSubviews[0].frame.width
        l.inspectorWidth = horizontal.arrangedSubviews[2].frame.width
        l.timelineHeight = vertical.arrangedSubviews[1].frame.height
        guard l != projectDocument.layout else { return }
        projectDocument.layout = l
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(saveLayout), object: nil)
        perform(#selector(saveLayout), with: nil, afterDelay: 0.5)
    }

    @objc private func saveLayout() { projectDocument.persistLayout() }

    // MARK: Menu actions

    @objc func importMedia(_ sender: Any?) {
        AssetImporter.presentOpenPanel(for: projectDocument.editor, window: window)
    }

    /// Aligns all lyric lines (every track) to the song.
    @objc func alignLyrics(_ sender: Any?) {
        projectDocument.editor.alignLyrics(window: window)
    }

    /// Empty the render cache and say how much was freed (R42).
    @objc func clearRenderCache(_ sender: Any?) {
        let freed = projectDocument.editor.clearRenderCache()
        let alert = NSAlert()
        alert.messageText = "Render cache cleared"
        alert.informativeText = "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)). Proxies, thumbnails, waveforms and music analysis were kept. The next export renders everything again."
        if let window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
        toolbar?.refreshCacheSize()
    }

    @objc func resetMediaCaches(_ sender: Any?) {
        ResetCachesSheet.present(editor: projectDocument.editor, window: window)
    }

    @objc func nextUnsureWord(_ sender: Any?) { projectDocument.editor.jumpToUnsureWord(forward: true) }
    @objc func previousUnsureWord(_ sender: Any?) { projectDocument.editor.jumpToUnsureWord(forward: false) }
    @objc func confirmWord(_ sender: Any?) { projectDocument.editor.toggleConfirmSelectedWords() }
    @objc func stopLooping(_ sender: Any?) { projectDocument.editor.clearLoop() }
    @objc func toggleTapMode(_ sender: Any?) {
        let e = projectDocument.editor
        e.isTapping ? e.endTapMode() : e.startTapMode()
    }
    @objc func tapWord(_ sender: Any?) {
        let snapping = (vertical.arrangedSubviews.last as? TimelineContainer)?.timeline.snappingEnabled ?? true
        projectDocument.editor.tap(snap: snapping)
    }
    @objc func setTapSpeed(_ sender: NSMenuItem) { projectDocument.editor.setTapRate(EditorModel.tapRates[sender.tag]) }

    @objc func analyzeSongAgain(_ sender: Any?) {
        let editor = projectDocument.editor
        editor.audioAnalysis.ensure(for: editor.project.audio.flatMap { editor.project.asset($0.assetID) }, force: true)
    }

    @objc func showExport(_ sender: Any?) {
        ExportSheet.present(editor: projectDocument.editor, window: window)
    }
}

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let p = projectDocument.editor.project
        switch item.action {
        case #selector(alignLyrics(_:)): return p.audio != nil && p.lyricTracks.contains { !$0.lines.isEmpty }
        case #selector(analyzeSongAgain(_:)): return p.audio != nil && projectDocument.editor.audioAnalysis.state != .unavailable
        case #selector(nextUnsureWord(_:)), #selector(previousUnsureWord(_:)):
            return p.lyricTracks.flatMap(\.lines).flatMap(\.words).contains(where: LyricAlignment.isLow)
        case #selector(confirmWord(_:)):
            if case .lyricWord = projectDocument.editor.selection { return true }
            return false
        case #selector(stopLooping(_:)): return projectDocument.editor.transport.loop != nil
        case #selector(toggleTapMode(_:)):
            item.state = projectDocument.editor.isTapping ? .on : .off
            return p.lyricTracks.contains { !$0.lines.isEmpty }
        case #selector(tapWord(_:)): return projectDocument.editor.isTapping
        case #selector(setTapSpeed(_:)):
            item.state = projectDocument.editor.transport.rate == EditorModel.tapRates[item.tag] ? .on : .off
            return projectDocument.editor.isTapping
        default: return responds(to: item.action)
        }
    }
}
