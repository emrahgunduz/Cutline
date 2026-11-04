import AppKit
import Combine

/// The timeline: ruler, video tracks, the audio track and lyric tracks. Draws only what is
/// visible and does its own hit-testing, so thousands of lyric words stay cheap.
final class TimelineView: NSView {
    let editor: EditorModel
    private var cancellables: Set<AnyCancellable> = []
    var pixelsPerSecond: CGFloat = 40
    var scrollTime: Double = 0
    var scrollY: CGFloat = 0

    private enum Edge { case left, right, body }
    private enum Hit {
        case clip(UUID, Edge), line(UUID, Edge), word(UUID, Edge), audio
        case ruler, header(TimelineRow), empty(TimelineRow)
    }
    private struct Drag {
        var hit: Hit
        var startPoint: CGPoint
        var original: Project
        var didEdit = false
    }
    private var drag: Drag?

    init(editor: EditorModel) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.string])
        let redraw: () -> Void = { [weak self] in self?.needsDisplay = true }
        editor.objectWillChange.receive(on: RunLoop.main).sink { _ in redraw() }.store(in: &cancellables)
        editor.thumbnails.objectWillChange.receive(on: RunLoop.main).sink { _ in redraw() }.store(in: &cancellables)
        editor.waveforms.objectWillChange.receive(on: RunLoop.main).sink { _ in redraw() }.store(in: &cancellables)
        editor.$playhead.receive(on: RunLoop.main).sink { [weak self] t in self?.followPlayhead(t) }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var layout: TimelineLayout {
        TimelineLayout(pixelsPerSecond: pixelsPerSecond, scrollTime: scrollTime, scrollY: scrollY,
                       videoTrackCount: editor.project.videoTracks.count,
                       lyricTrackCount: editor.project.lyricTracks.count, viewWidth: bounds.width)
    }

    private var project: Project { editor.project }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let l = layout
        NSColor.textBackgroundColor.withAlphaComponent(0.04).setFill()
        bounds.fill()
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: TimelineLayout.rulerHeight, width: bounds.width, height: bounds.height))
        for (row, y, h) in l.rows.dropFirst() {
            let rect = CGRect(x: 0, y: y, width: bounds.width, height: h)
            guard rect.intersects(dirtyRect) else { continue }
            drawRowBackground(row, rect)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: TimelineLayout.headerWidth, y: y, width: bounds.width, height: h))
            switch row {
            case .video(let t): drawVideoTrack(t, rect, l)
            case .audio: drawAudio(rect, l)
            case .lyric(let t): drawLyricTrack(t, rect, l)
            case .ruler: break
            }
            ctx.restoreGState()
            drawHeader(row, rect)
        }
        drawProjectEnd(l)
        ctx.restoreGState()
        drawRuler(l)
        drawPlayhead(l)
    }

    private func drawRowBackground(_ row: TimelineRow, _ rect: CGRect) {
        let isAlt: Bool
        switch row {
        case .video(let t): isAlt = t % 2 == 0
        case .lyric(let t): isAlt = t % 2 == 1
        default: isAlt = false
        }
        (isAlt ? NSColor.black.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.05)).setFill()
        rect.fill()
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: rect.maxY - 1, width: rect.width, height: 1).fill()
    }

    private func drawHeader(_ row: TimelineRow, _ rect: CGRect) {
        let header = CGRect(x: 0, y: rect.minY, width: TimelineLayout.headerWidth, height: rect.height - 1)
        NSColor.controlBackgroundColor.setFill()
        header.fill()
        let title: String
        switch row {
        case .video(let t): title = "Video \(t + 1)"
        case .audio: title = "Audio"
        case .lyric(let t): title = "Lyrics \(t + 1)"
        case .ruler: title = ""
        }
        (title as NSString).draw(at: CGPoint(x: 8, y: rect.minY + 6),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                  .foregroundColor: NSColor.secondaryLabelColor])
    }

    private func clipColor(_ selected: Bool) -> NSColor {
        selected ? NSColor.controlAccentColor : NSColor(calibratedRed: 0.24, green: 0.36, blue: 0.55, alpha: 1)
    }

    private func drawVideoTrack(_ t: Int, _ rect: CGRect, _ l: TimelineLayout) {
        let visible = l.visibleTimeRange
        for clip in project.videoTracks[t].clips where clip.end >= visible.lowerBound && clip.start <= visible.upperBound {
            let r = CGRect(x: l.x(for: clip.start), y: rect.minY + 3, width: CGFloat(clip.duration) * l.pixelsPerSecond, height: rect.height - 7)
            let selected = editor.selection == .clip(clip.id)
            let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            clipColor(selected).withAlphaComponent(0.85).setFill()
            path.fill()
            if let img = editor.thumbnails.images[clip.assetID] {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                let aspect = img.size.width / max(1, img.size.height)
                let tileH = r.height - 14
                let tileW = max(20, tileH * aspect)
                var x = r.minX
                while x < r.maxX && x < bounds.width {
                    if x + tileW > 0 { img.draw(in: CGRect(x: x, y: r.minY + 14, width: tileW, height: tileH)) }
                    x += tileW
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            let name = project.asset(clip.assetID)?.name ?? "?"
            (name as NSString).draw(in: CGRect(x: r.minX + 4, y: r.minY + 1, width: max(0, r.width - 8), height: 13),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white])
            if selected {
                NSColor.white.setStroke()
                path.lineWidth = 2
                path.stroke()
            }
        }
    }

    private func drawAudio(_ rect: CGRect, _ l: TimelineLayout) {
        guard let audio = project.audio else {
            ("Drop the song here" as NSString).draw(at: CGPoint(x: TimelineLayout.headerWidth + 10, y: rect.midY - 7),
                                                    withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor])
            return
        }
        let r = CGRect(x: l.x(for: audio.start), y: rect.minY + 3, width: CGFloat(audio.duration) * l.pixelsPerSecond, height: rect.height - 7)
        let selected = editor.selection == .audio
        NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.30, alpha: selected ? 1 : 0.8).setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        guard let wf = editor.waveforms.waveforms[audio.assetID],
              let level = wf.level(secondsPerPixel: 1 / Double(l.pixelsPerSecond)) else { return }
        let secondsPerBucket = Double(level.samplesPerBucket) / wf.sampleRate
        let mid = r.midY, half = r.height / 2 - 2
        let x0 = max(r.minX, TimelineLayout.headerWidth), x1 = min(r.maxX, bounds.width)
        guard x1 > x0 else { return }
        let peak = NSBezierPath(), rmsPath = NSBezierPath()
        var x = x0
        while x < x1 {
            let t0 = l.time(for: x) - audio.start, t1 = l.time(for: x + 1) - audio.start
            let b0 = max(0, Int(t0 / secondsPerBucket)), b1 = min(level.maxs.count, max(b0 + 1, Int(t1 / secondsPerBucket)))
            if b0 < level.maxs.count {
                var mx: Float = 0, mn: Float = 0, rm: Float = 0
                for b in b0..<b1 { mx = max(mx, level.maxs[b]); mn = min(mn, level.mins[b]); rm = max(rm, level.rms[b]) }
                peak.move(to: CGPoint(x: x, y: mid - CGFloat(mx) * half)); peak.line(to: CGPoint(x: x, y: mid - CGFloat(mn) * half))
                rmsPath.move(to: CGPoint(x: x, y: mid - CGFloat(rm) * half)); rmsPath.line(to: CGPoint(x: x, y: mid + CGFloat(rm) * half))
            }
            x += 1
        }
        NSColor.white.withAlphaComponent(0.45).setStroke(); peak.lineWidth = 1; peak.stroke()
        NSColor.white.withAlphaComponent(0.85).setStroke(); rmsPath.lineWidth = 1; rmsPath.stroke()
    }

    private func drawLyricTrack(_ t: Int, _ rect: CGRect, _ l: TimelineLayout) {
        let visible = l.visibleTimeRange
        for line in project.lyricTracks[t].lines where line.end >= visible.lowerBound && line.start <= visible.upperBound {
            let lr = CGRect(x: l.x(for: line.start), y: rect.minY + 2, width: CGFloat(line.end - line.start) * l.pixelsPerSecond, height: rect.height - 5)
            let lineSelected = editor.selection == .lyricLine(line.id)
            NSColor(calibratedRed: 0.45, green: 0.30, blue: 0.55, alpha: lineSelected ? 0.9 : 0.45).setFill()
            NSBezierPath(roundedRect: lr, xRadius: 3, yRadius: 3).fill()
            for w in line.words {
                let wr = CGRect(x: l.x(for: w.start), y: lr.minY + 12, width: max(2, CGFloat(w.end - w.start) * l.pixelsPerSecond), height: lr.height - 14)
                let selected = editor.selection == .lyricWord(w.id)
                let lowConfidence = !w.confirmed && w.confidence < 0.6
                (selected ? NSColor.controlAccentColor : lowConfidence ? NSColor.systemOrange : NSColor(calibratedRed: 0.62, green: 0.45, blue: 0.75, alpha: 1)).setFill()
                NSBezierPath(roundedRect: wr, xRadius: 2, yRadius: 2).fill()
                if wr.width > 14 {
                    (w.text as NSString).draw(in: wr.insetBy(dx: 2, dy: 1), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white])
                }
            }
            if lr.width > 30 {
                (line.text as NSString).draw(in: CGRect(x: lr.minX + 4, y: lr.minY, width: lr.width - 8, height: 12),
                                             withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.white.withAlphaComponent(0.7)])
            }
        }
    }

    private func drawProjectEnd(_ l: TimelineLayout) {
        let x = l.x(for: project.duration)
        guard x > TimelineLayout.headerWidth, x < bounds.width else { return }
        NSColor.white.withAlphaComponent(0.04).setFill()
        CGRect(x: x, y: TimelineLayout.rulerHeight, width: bounds.width - x, height: bounds.height).fill()
    }

    private func drawRuler(_ l: TimelineLayout) {
        let r = CGRect(x: 0, y: 0, width: bounds.width, height: TimelineLayout.rulerHeight)
        NSColor.windowBackgroundColor.setFill(); r.fill()
        NSColor.separatorColor.setFill(); CGRect(x: 0, y: r.maxY - 1, width: r.width, height: 1).fill()
        let step = l.tickInterval(fps: project.fps)
        var t = (l.scrollTime / step).rounded(.down) * step
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        while l.x(for: t) < bounds.width {
            let x = l.x(for: t)
            if x >= TimelineLayout.headerWidth {
                NSColor.tertiaryLabelColor.setFill()
                CGRect(x: x, y: r.maxY - 8, width: 1, height: 7).fill()
                (Timecode.string(t, fps: project.fps) as NSString).draw(at: CGPoint(x: x + 3, y: 3), withAttributes: attrs)
            }
            t += step
        }
    }

    private func drawPlayhead(_ l: TimelineLayout) {
        let x = l.x(for: editor.playhead)
        guard x >= TimelineLayout.headerWidth, x <= bounds.width else { return }
        NSColor.systemRed.setFill()
        CGRect(x: x - 0.5, y: 0, width: 1.5, height: bounds.height).fill()
        let tri = NSBezierPath()
        tri.move(to: CGPoint(x: x - 6, y: 0)); tri.line(to: CGPoint(x: x + 6, y: 0)); tri.line(to: CGPoint(x: x, y: 9)); tri.close()
        tri.fill()
    }

    // MARK: Hit testing

    private func hit(at p: CGPoint) -> Hit {
        let l = layout
        guard let row = l.row(atY: p.y) else { return .empty(.ruler) }
        if row == .ruler { return .ruler }
        if p.x < TimelineLayout.headerWidth { return .header(row) }
        let t = l.time(for: p.x)
        let grab = Double(TimelineLayout.edgeGrab / l.pixelsPerSecond)
        func edge(_ start: Double, _ end: Double) -> Edge {
            if abs(t - start) <= grab { return .left }
            if abs(t - end) <= grab { return .right }
            return .body
        }
        switch row {
        case .video(let ti):
            if let c = project.videoTracks[ti].clips.last(where: { t >= $0.start - grab && t <= $0.end + grab }) {
                return .clip(c.id, edge(c.start, c.end))
            }
        case .audio:
            if let a = project.audio, t >= a.start, t <= a.end { return .audio }
        case .lyric(let ti):
            guard let frame = l.frame(of: row) else { break }
            let inWordBand = p.y > frame.minY + 13
            for line in project.lyricTracks[ti].lines where t >= line.start - grab && t <= line.end + grab {
                if inWordBand, let w = line.words.first(where: { t >= $0.start - grab && t <= $0.end + grab }) {
                    return .word(w.id, edge(w.start, w.end))
                }
                return .line(line.id, edge(line.start, line.end))
            }
        case .ruler: break
        }
        return .empty(row)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let h = hit(at: p)
        switch h {
        case .clip(let id, _): editor.selection = .clip(id)
        case .line(let id, _): editor.selection = .lyricLine(id)
        case .word(let id, _): editor.selection = .lyricWord(id)
        case .audio: editor.selection = .audio
        case .ruler: editor.setPlayhead(layout.time(for: p.x))
        case .empty: editor.selection = .none; editor.setPlayhead(layout.time(for: p.x))
        case .header(let row): showHeaderMenu(row, event: event); return
        }
        drag = Drag(hit: h, startPoint: p, original: editor.project)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        let l = layout
        let dt = Double((p.x - d.startPoint.x) / l.pixelsPerSecond)
        let pointerTime = l.time(for: p.x)
        if case .ruler = d.hit { editor.setPlayhead(pointerTime); return }
        if case .empty = d.hit { editor.setPlayhead(pointerTime); return }
        guard abs(p.x - d.startPoint.x) > 2 || d.didEdit else { return }
        var next = d.original
        switch d.hit {
        case .clip(let id, let edge):
            guard let c = d.original.videoTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return }
            switch edge {
            case .left: next.trimStart(id, to: c.start + dt)
            case .right: next.trimEnd(id, to: c.end + dt)
            case .body:
                var track = d.original.clipLocation(id)!.track
                if case .video(let t)? = l.row(atY: p.y) { track = t }
                next.moveClip(id, toTrack: track, start: c.start + dt)
            }
        case .line(let id, let edge):
            guard let line = d.original.lyricTracks.flatMap(\.lines).first(where: { $0.id == id }) else { return }
            switch edge {
            case .left: next.retimeLine(id, start: line.start + dt)
            case .right: next.retimeLine(id, end: line.end + dt)
            case .body:
                var track = d.original.lineLocation(id)!.track
                if case .lyric(let t)? = l.row(atY: p.y) { track = t }
                next.moveLine(id, toTrack: track, start: line.start + dt)
            }
        case .word(let id, let edge):
            guard let w = d.original.lyricTracks.flatMap(\.lines).flatMap(\.words).first(where: { $0.id == id }) else { return }
            switch edge {
            case .left: next.retimeWord(id, start: min(w.start + dt, w.end - next.frameDuration))
            case .right: next.retimeWord(id, end: max(w.end + dt, w.start + next.frameDuration))
            case .body: next.moveWord(id, start: w.start + dt)
            }
        default: return
        }
        // Live preview of the drag; committed as one undo step on mouse up.
        editor.replaceWithoutUndo(next)
        d.didEdit = true
        drag = d
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard let d = drag, d.didEdit else { return }
        let final = editor.project
        editor.replaceWithoutUndo(d.original)
        editor.edit(actionName(for: d.hit)) { $0 = final }
    }

    private func actionName(for hit: Hit) -> String {
        switch hit {
        case .clip(_, .body), .line(_, .body), .word(_, .body): "Move"
        default: "Trim"
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            zoom(by: 1 + event.scrollingDeltaY * 0.01, around: convert(event.locationInWindow, from: nil).x)
            return
        }
        let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : (event.modifierFlags.contains(.shift) ? event.scrollingDeltaY : 0)
        scrollTime = max(0, scrollTime - Double(dx / pixelsPerSecond))
        if dx == 0 {
            let maxY = max(0, layout.contentHeight - bounds.height)
            scrollY = min(max(0, scrollY - event.scrollingDeltaY), maxY)
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil).x)
    }

    func zoom(by factor: CGFloat, around x: CGFloat) {
        let anchor = layout.time(for: x)
        let range = TimelineLayout.zoomRange(duration: project.duration, fps: project.fps, width: bounds.width)
        pixelsPerSecond = min(max(pixelsPerSecond * factor, range.lowerBound), range.upperBound)
        scrollTime = max(0, anchor - Double((x - TimelineLayout.headerWidth) / pixelsPerSecond))
        needsDisplay = true
    }

    func zoomToFit() {
        pixelsPerSecond = TimelineLayout.zoomRange(duration: project.duration, fps: project.fps, width: bounds.width).lowerBound
        scrollTime = 0
        needsDisplay = true
    }

    private func followPlayhead(_ t: Double) {
        guard editor.isPlaying else { needsDisplay = true; return }
        let l = layout
        if l.x(for: t) > bounds.width - 40 { scrollTime = t - Double((bounds.width - TimelineLayout.headerWidth) * 0.1 / pixelsPerSecond) }
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch (event.keyCode, event.charactersIgnoringModifiers ?? "") {
        case (49, _): editor.togglePlay()
        case (123, _): editor.stepFrame(-1)
        case (124, _): editor.stepFrame(1)
        case (115, _): editor.goToStart()
        case (119, _): editor.goToEnd()
        case (51, _), (117, _): editor.deleteSelection()
        case (_, "b") where cmd: editor.splitAtPlayhead()
        case (_, "=") where cmd, (_, "+") where cmd: zoom(by: 1.5, around: layout.x(for: editor.playhead))
        case (_, "-") where cmd: zoom(by: 1 / 1.5, around: layout.x(for: editor.playhead))
        case (_, "0") where cmd: zoomToFit()
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers {
        case "b", "=", "+", "-", "0": keyDown(with: event); return true
        default: return false
        }
    }

    // MARK: Track headers

    private func showHeaderMenu(_ row: TimelineRow, event: NSEvent) {
        let menu = NSMenu()
        func item(_ title: String, _ action: @escaping () -> Void) {
            let i = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            let target = MenuAction(action)
            i.target = target
            i.representedObject = target
            menu.addItem(i)
        }
        item("Add Video Track") { [editor] in editor.edit("Add Video Track") { $0.addVideoTrack() } }
        if case .video(let t) = row, project.videoTracks.count > 1 {
            item("Remove Video \(t + 1)") { [editor] in editor.edit("Remove Video Track") { $0.removeVideoTrack(at: t) } }
        }
        menu.addItem(.separator())
        item("Add Lyrics Track") { [editor] in editor.edit("Add Lyrics Track") { $0.addLyricTrack() } }
        if case .lyric(let t) = row, project.lyricTracks.count > 1 {
            item("Remove Lyrics \(t + 1)") { [editor] in editor.edit("Remove Lyrics Track") { $0.removeLyricTrack(at: t) } }
        }
        if case .audio = row, project.audio != nil {
            menu.addItem(.separator())
            item("Remove Audio") { [editor] in editor.edit("Remove Audio") { $0.removeAudio() } }
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let row = layout.row(atY: p.y), row != .ruler { showHeaderMenu(row, event: event) }
    }

    // MARK: Drop assets from the panel

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let str = sender.draggingPasteboard.string(forType: .string), let id = UUID(uuidString: str),
              let asset = project.asset(id) else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        let l = layout
        let time = max(0, l.time(for: p.x))
        let row = l.row(atY: p.y)
        switch (asset.kind, row) {
        case (.video, .video(let t)?), (.image, .video(let t)?):
            var newID: UUID?
            editor.edit("Add Clip") { newID = $0.addClip(assetID: id, track: t, at: time) }
            if let newID { editor.selection = .clip(newID) }
        case (.video, _), (.image, _):
            var newID: UUID?
            editor.edit("Add Clip") { newID = $0.addClip(assetID: id, track: 0, at: time) }
            if let newID { editor.selection = .clip(newID) }
        case (.audio, _):
            editor.edit(project.audio == nil ? "Add Audio" : "Replace Audio") { $0.setAudio(assetID: id) }
            Task { await editor.waveforms.ensureWaveform(for: asset) }
        case (.lyrics, _):
            editor.lyricsDropped?(asset)
        }
        return true
    }
}

private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

enum Timecode {
    /// mm:ss:ff
    static func string(_ t: Double, fps: Double) -> String {
        let rate = max(1, Int(fps.rounded()))
        let frames = Int((t * fps).rounded())
        let s = frames / rate, f = frames % rate
        return String(format: "%02d:%02d:%02d", s / 60, s % 60, f)
    }
}
