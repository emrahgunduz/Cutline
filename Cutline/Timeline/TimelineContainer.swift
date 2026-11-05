import AppKit
import Combine

/// Timeline with its button bar and scrollbars.
final class TimelineContainer: NSView {
    let timeline: TimelineView
    // NSScroller takes its orientation from the initial frame: wide = horizontal.
    private let hScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 200, height: 15))
    private let vScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 200))
    private let bar = NSStackView()
    private var snapButton: NSButton!
    private var groupButtons: [SnapGroup: NSButton] = [:]
    private var cinemaButton: NSButton!
    private var cancellables: Set<AnyCancellable> = []
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
        let split = button("scissors", "Cut at playhead (C)") { [weak editor] in editor?.splitAtPlayhead() }
        let delete = button("trash", "Delete selection (⌫)") { [weak editor] in editor?.deleteSelection() }
        snapButton = button("dot.arrowtriangles.up.right.down.left.circle", "Snapping (S): the groups to the right attract while dragging. Hold ⌘ to bypass.") { [weak self] in
            self?.timeline.snappingEnabled.toggle()
        }
        snapButton.setButtonType(.pushOnPushOff)
        let groupSymbols: [SnapGroup: (String, String)] = [
            .sections: ("square.split.2x1", "Snap to section edges (strongest)"),
            .downbeats: ("metronome.fill", "Snap to downbeats (first beat of each bar)"),
            .beats: ("metronome", "Snap to beats"),
            .edges: ("arrow.left.and.right.righttriangle.left.righttriangle.right", "Snap to clip, lyric and audio edges and the playhead"),
        ]
        for g in SnapGroup.allCases {
            let (symbol, tip) = groupSymbols[g]!
            let b = button(symbol, tip) { [weak self] in
                guard let self else { return }
                var groups = self.timeline.snapGroups
                if groups.contains(g) { groups.remove(g) } else { groups.insert(g) }
                self.timeline.snapGroups = groups
            }
            b.setButtonType(.pushOnPushOff)
            b.controlSize = .small
            groupButtons[g] = b
        }
        cinemaButton = button("rectangle.ratio.16.to.9", "Cinemascope bars (music videos): drag the orange markers on the ruler to set where the bars start and finish closing to 2.35:1") { [weak editor] in
            guard let editor else { return }
            editor.edit(editor.project.cinemascope.enabled ? "Cinemascope Off" : "Cinemascope On") { p in
                p.cinemascope.enabled.toggle()
                // First use: start at the playhead and close over four seconds.
                if p.cinemascope.enabled && p.cinemascope.startMarker == 0 && p.cinemascope.endMarker == 5 {
                    p.cinemascope.startMarker = p.quantize(editor.playhead)
                    p.cinemascope.endMarker = p.quantize(editor.playhead + 4)
                    p.anchorMarkers(editor.resolvedBeats, hash: editor.audioAnalysis.analysis?.audioHash)
                }
            }
        }
        cinemaButton.setButtonType(.pushOnPushOff)
        let zoomOut = button("minus.magnifyingglass", "Zoom out (−)") { [weak self] in self?.timeline.zoomAroundPlayhead(1 / 1.5) }
        let zoomIn = button("plus.magnifyingglass", "Zoom in (=)") { [weak self] in self?.timeline.zoomAroundPlayhead(1.5) }
        let fit = button("arrow.left.and.right.square", "Zoom to fit (⌘0)") { [weak self] in self?.timeline.zoomToFit() }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let groupViews: [NSView] = SnapGroup.allCases.map { groupButtons[$0]! }
        let items: [NSView] = [addVideo, addLyrics, separator(), split, delete, separator(), snapButton] + groupViews
            + [separator(), cinemaButton, spacer, zoomOut, zoomIn, fit]
        for v in items { bar.addArrangedSubview(v) }
        cinemaButton.isHidden = editor.project.type != .musicVideo
        editor.$revision.receive(on: RunLoop.main).sink { [weak self, weak editor] _ in
            guard let self, let editor else { return }
            self.cinemaButton.state = editor.project.cinemascope.enabled ? .on : .off
        }.store(in: &cancellables)

        for v in [bar, timeline, hScroller, vScroller] as [NSView] { addSubview(v) }
        hScroller.scrollerStyle = .legacy
        vScroller.scrollerStyle = .legacy
        hScroller.target = self; hScroller.action = #selector(hScrolled)
        vScroller.target = self; vScroller.action = #selector(vScrolled)
        hScroller.isEnabled = true; vScroller.isEnabled = true
        timeline.onScroll = { [weak self] in self?.syncScrollers() }
        timeline.onSnappingChange = { [weak self] _ in self?.syncSnapButtons() }
        timeline.onSnapGroupsChange = { [weak self] _ in self?.syncSnapButtons() }
        DispatchQueue.main.async { [weak self] in self?.syncSnapButtons() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Group toggles keep their own state but grey out while snapping is off.
    private func syncSnapButtons() {
        let on = timeline.snappingEnabled, groups = timeline.snapGroups
        snapButton.state = on ? .on : .off
        for (g, b) in groupButtons {
            b.state = groups.contains(g) ? .on : .off
            b.isEnabled = on
        }
    }

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
        // Top to bottom: button bar, horizontal scroller, timeline (with the vertical scroller on its right).
        bar.frame = CGRect(x: 0, y: h - Self.barHeight, width: w, height: Self.barHeight)
        hScroller.frame = CGRect(x: TimelineLayout.headerWidth, y: h - Self.barHeight - s, width: w - s - TimelineLayout.headerWidth, height: s)
        timeline.frame = CGRect(x: 0, y: 0, width: w - s, height: h - Self.barHeight - s)
        vScroller.frame = CGRect(x: w - s, y: 0, width: s, height: h - Self.barHeight - s)
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
