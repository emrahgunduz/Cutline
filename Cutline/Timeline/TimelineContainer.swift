import AppKit

/// Timeline with its button bar and scrollbars.
final class TimelineContainer: NSView {
    let timeline: TimelineView
    private let hScroller = NSScroller()
    private let vScroller = NSScroller()
    private let bar = NSStackView()
    private var snapButton: NSButton!
    static let barHeight: CGFloat = 30

    static func make(editor: EditorModel) -> NSView { TimelineContainer(editor: editor) }

    init(editor: EditorModel) {
        timeline = TimelineView(editor: editor)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor

        bar.orientation = .horizontal
        bar.spacing = 4
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        let addVideo = button("rectangle.stack.badge.plus", "Add video track") { [weak editor] in
            editor?.edit("Add Video Track") { $0.addVideoTrack() }
        }
        let addLyrics = button("text.badge.plus", "Add lyrics track") { [weak editor] in
            editor?.edit("Add Lyrics Track") { $0.addLyricTrack() }
        }
        let split = button("scissors", "Split at playhead (⌘B)") { [weak editor] in editor?.splitAtPlayhead() }
        let delete = button("trash", "Delete selection (⌫)") { [weak editor] in editor?.deleteSelection() }
        snapButton = button("dot.arrowtriangles.up.right.down.left.circle", "Snapping (N): edges, playhead and lyrics attract while dragging. Hold ⌘ to bypass.") { [weak self] in
            self?.timeline.snappingEnabled.toggle()
        }
        snapButton.setButtonType(.pushOnPushOff)
        let zoomOut = button("minus.magnifyingglass", "Zoom out (⌘−)") { [weak self] in self?.timeline.zoomAroundPlayhead(1 / 1.5) }
        let zoomIn = button("plus.magnifyingglass", "Zoom in (⌘=)") { [weak self] in self?.timeline.zoomAroundPlayhead(1.5) }
        let fit = button("arrow.left.and.right.square", "Zoom to fit (⌘0)") { [weak self] in self?.timeline.zoomToFit() }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        for v in [addVideo, addLyrics, separator(), split, delete, separator(), snapButton!, spacer, zoomOut, zoomIn, fit] { bar.addArrangedSubview(v) }

        for v in [bar, timeline, hScroller, vScroller] as [NSView] { addSubview(v) }
        hScroller.scrollerStyle = .legacy
        vScroller.scrollerStyle = .legacy
        hScroller.target = self; hScroller.action = #selector(hScrolled)
        vScroller.target = self; vScroller.action = #selector(vScrolled)
        hScroller.isEnabled = true; vScroller.isEnabled = true
        timeline.onScroll = { [weak self] in self?.syncScrollers() }
        timeline.onSnappingChange = { [weak self] on in self?.snapButton.state = on ? .on : .off }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapButton.state = self.timeline.snappingEnabled ? .on : .off
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func separator() -> NSView {
        let b = NSBox(); b.boxType = .separator
        b.widthAnchor.constraint(equalToConstant: 1).isActive = true
        b.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return b
    }

    private func button(_ symbol: String, _ tip: String, action: @escaping () -> Void) -> NSButton {
        let b = ActionButton(action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.bezelStyle = .accessoryBarAction
        b.isBordered = true
        b.toolTip = tip
        b.imagePosition = .imageOnly
        return b
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let s = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        bar.frame = CGRect(x: 0, y: h - Self.barHeight, width: w, height: Self.barHeight)
        timeline.frame = CGRect(x: 0, y: s, width: w - s, height: h - Self.barHeight - s)
        hScroller.frame = CGRect(x: TimelineLayout.headerWidth, y: 0, width: w - s - TimelineLayout.headerWidth, height: s)
        vScroller.frame = CGRect(x: w - s, y: s, width: s, height: h - Self.barHeight - s)
        syncScrollers()
    }

    private func syncScrollers() {
        let l = timeline.layout
        let total = timeline.contentDuration
        hScroller.knobProportion = CGFloat(min(1, l.visibleDuration / max(total, 0.001)))
        let maxScroll = max(0.0001, total - l.visibleDuration)
        hScroller.doubleValue = min(1, timeline.scrollTime / maxScroll)
        let contentH = l.contentHeight, viewH = timeline.bounds.height
        vScroller.knobProportion = contentH > 0 ? min(1, viewH / contentH) : 1
        vScroller.doubleValue = timeline.maxScrollY > 0 ? Double(timeline.scrollY / timeline.maxScrollY) : 0
        vScroller.isEnabled = contentH > viewH
    }

    @objc private func hScrolled() {
        let l = timeline.layout
        let maxScroll = max(0, timeline.contentDuration - l.visibleDuration)
        switch hScroller.hitPart {
        case .decrementPage: timeline.scrollTime = max(0, timeline.scrollTime - l.visibleDuration * 0.9)
        case .incrementPage: timeline.scrollTime = min(maxScroll, timeline.scrollTime + l.visibleDuration * 0.9)
        default: timeline.scrollTime = hScroller.doubleValue * maxScroll
        }
    }

    @objc private func vScrolled() {
        timeline.scrollY = CGFloat(vScroller.doubleValue) * timeline.maxScrollY
    }
}

/// NSButton that runs a closure.
final class ActionButton: NSButton {
    private let handler: () -> Void
    init(action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(run)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    @objc private func run() { handler() }
}
