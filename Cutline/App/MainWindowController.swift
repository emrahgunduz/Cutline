import AppKit
import SwiftUI

/// Four regions: assets (left), preview (center), inspector (right), timeline (bottom).
/// Divider positions are restored from and saved to the project's layout.
final class MainWindowController: NSWindowController, NSSplitViewDelegate {
    private let vertical = NSSplitView()
    private let horizontal = NSSplitView()
    private var restoring = true
    private let projectDocument: ProjectDocument

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

        horizontal.addArrangedSubview(NSHostingView(rootView: AssetsPanelView().environmentObject(editor)))
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
        editor.warmCaches()
        toolbar = WindowToolbar(editor: editor, windowController: self)
        if let window { toolbar?.install(on: window) }
    }

    private var keyMonitor: Any?
    private var toolbar: WindowToolbar?

    /// Single-key shortcuts that work anywhere in the window except while typing in a field.
    /// The list shown in the inspector lives in `Shortcuts` and must match this.
    private func installTransportKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, !(self.window?.firstResponder is NSText) else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let editor = self.projectDocument.editor
            let timeline = (self.vertical.arrangedSubviews.last as? TimelineContainer)?.timeline
            switch (event.keyCode, flags) {
            case (49, []): editor.togglePlay()
            case (123, []): editor.stepFrame(-1)
            case (124, []): editor.stepFrame(1)
            case (123, [.shift]): editor.step(seconds: -1)
            case (124, [.shift]): editor.step(seconds: 1)
            case (126, []): editor.jumpToEditPoint(forward: false)
            case (125, []): editor.jumpToEditPoint(forward: true)
            case (115, []): editor.goToStart()
            case (119, []): editor.goToEnd()
            case (51, []), (117, []): editor.deleteSelection()
            default:
                guard flags.isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased() else { return event }
                switch ch {
                case "c": editor.splitAtPlayhead()
                case "s": timeline?.snappingEnabled.toggle()
                case "=", "+": timeline?.zoomAroundPlayhead(1.5)
                case "-": timeline?.zoomAroundPlayhead(1 / 1.5)
                default: return event
                }
            }
            return nil
        }
    }

    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

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

    /// Aligns the lyrics track of the selected line or word, else the first track with lines.
    @objc func alignLyrics(_ sender: Any?) {
        let editor = projectDocument.editor
        let p = editor.project
        let selected: Int? = switch editor.selection {
        case .lyricLine(let id): p.lineLocation(id)?.track
        case .lyricWord(let id): p.wordLocation(id)?.track
        default: nil
        }
        guard let track = selected ?? p.lyricTracks.firstIndex(where: { !$0.lines.isEmpty }) else { return }
        editor.alignLyrics(track: track, window: window)
    }

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
        default: return responds(to: item.action)
        }
    }
}
