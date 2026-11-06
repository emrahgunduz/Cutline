import AppKit
import Combine

/// The timeline: ruler, audio, lyric tracks and video tracks. Draws only what is visible and
/// does its own hit-testing, so thousands of lyric words stay cheap.
final class TimelineView: NSView {
    let editor: EditorModel
    private var cancellables: Set<AnyCancellable> = []
    private let filmstrip = Filmstrip()

    var pixelsPerSecond: CGFloat = 40 { didSet { scrollChanged() } }
    var scrollTime: Double = 0 { didSet { scrollChanged() } }
    var scrollY: CGFloat = 0 { didSet { scrollChanged() } }
    /// Called whenever zoom or scroll changes, so scrollers can follow.
    var onScroll: (() -> Void)?
    var onSnappingChange: ((Bool) -> Void)?
    var onSnapGroupsChange: ((Set<SnapGroup>) -> Void)?

    /// Snap-target groups that are on (R41), saved per project.
    var snapGroups: Set<SnapGroup> {
        get { editor.document?.layout.snapGroups.map(Set.init) ?? Set(SnapGroup.allCases) }
        set {
            editor.document?.layout.snapGroups = SnapGroup.allCases.filter(newValue.contains)
            editor.document?.persistLayout()
            onSnapGroupsChange?(newValue)
        }
    }

    var snappingEnabled: Bool {
        get { editor.document?.layout.snapping ?? true }
        set { editor.document?.layout.snapping = newValue; editor.document?.persistLayout(); onSnappingChange?(newValue); needsDisplay = true }
    }

    private enum Edge { case left, right, body }
    private enum Hit {
        case clip(UUID, Edge), line(UUID, Edge), word(UUID, Edge), audio
        case sectionBoundary(Int), downbeat(Int)
        case ruler, empty(TimelineRow), marker(isStart: Bool)
        case headerButton(TimelineRow, HeaderButton), headerResize(TimelineRow), headerBody(TimelineRow)
    }
    enum HeaderButton { case add, remove, visibility }

    private enum DragKind {
        case edit(Hit, original: Project)
        case scrub
        case pan(startScroll: Double, startY: CGFloat)
        case resize(TimelineRow, startHeight: CGFloat)
        case reorder(TimelineRow)
        case marquee
        case marker(isStart: Bool, original: Project)
        case group(original: Project, clips: [UUID], lines: [UUID])
        case beat(Hit, original: Project, analysis: AudioAnalysis)
    }
    private struct Drag { var kind: DragKind; var startPoint: CGPoint; var didEdit = false }
    private var drag: Drag?
    /// Time of the snap target the current drag is locked to (drawn as a guide line).
    private var snapGuide: Double?
    private var reorderTarget: TimelineRow?
    private var marqueeRect: CGRect?
    /// The red playhead line and flag, a layer so moving it repaints nothing underneath.
    private let playheadLayer = CAShapeLayer()
    /// Cache strip states, recomputed only when the project or the segment files change.
    private var stripMemo: (revision: Int, files: Set<String>, states: [(segment: SegmentExporter.Segment, state: CacheStrip.State)])?

    init(editor: EditorModel) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.string, .fileURL])
        let redraw: () -> Void = { [weak self] in self?.needsDisplay = true }
        filmstrip.onUpdate = redraw
        editor.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.needsDisplay = true; self?.onScroll?() }.store(in: &cancellables)
        editor.$revision.receive(on: RunLoop.main).sink { [weak self] _ in self?.clampToContent() }.store(in: &cancellables)
        editor.thumbnails.objectWillChange.receive(on: RunLoop.main).sink { _ in redraw() }.store(in: &cancellables)
        editor.waveforms.objectWillChange.receive(on: RunLoop.main).sink { _ in redraw() }.store(in: &cancellables)
        editor.audioAnalysis.objectWillChange.receive(on: RunLoop.main).sink { _ in redraw() }.store(in: &cancellables)
        editor.$segmentFiles.receive(on: RunLoop.main).sink { _ in redraw() }.store(in: &cancellables)
        editor.transport.$loop.removeDuplicates().receive(on: RunLoop.main).sink { _ in redraw() }.store(in: &cancellables)
        editor.transport.$tapWordID.removeDuplicates().receive(on: RunLoop.main).sink { _ in redraw() }.store(in: &cancellables)
        editor.transport.$playhead.receive(on: RunLoop.main).sink { [weak self] t in self?.followPlayhead(t) }.store(in: &cancellables)
        playheadLayer.fillColor = NSColor.systemRed.cgColor
        playheadLayer.zPosition = 10
        playheadLayer.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(playheadLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func scrollChanged() {
        needsDisplay = true
        onScroll?()
    }

    // MARK: Layout

    private var project: Project { editor.project }

    func rowKey(_ row: TimelineRow) -> String {
        switch row {
        case .ruler: "ruler"
        case .audio: "audio"
        case .lyric(let t): project.lyricTracks.indices.contains(t) ? project.lyricTracks[t].id.uuidString : "lyric"
        case .video(let t): project.videoTracks.indices.contains(t) ? project.videoTracks[t].id.uuidString : "video"
        }
    }

    func rowHeight(_ row: TimelineRow) -> CGFloat {
        if row == .ruler { return TimelineLayout.rulerHeight }
        let stored = editor.document?.layout.trackHeights?[rowKey(row)].map { CGFloat($0) }
        return min(max(stored ?? TimelineLayout.defaultHeight(row), TimelineLayout.minRowHeight), TimelineLayout.maxRowHeight)
    }

    func setRowHeight(_ row: TimelineRow, _ h: CGFloat) {
        guard let doc = editor.document else { return }
        var heights = doc.layout.trackHeights ?? [:]
        heights[rowKey(row)] = Double(min(max(h, TimelineLayout.minRowHeight), TimelineLayout.maxRowHeight))
        doc.layout.trackHeights = heights
        needsDisplay = true
        onScroll?()
    }

    var layout: TimelineLayout {
        var l = TimelineLayout(pixelsPerSecond: pixelsPerSecond, scrollTime: scrollTime, scrollY: scrollY,
                               videoTrackCount: project.videoTracks.count,
                               lyricTrackCount: project.lyricTracks.count, viewWidth: bounds.width)
        l.height = { [unowned self] in self.rowHeight($0) }
        return l
    }

    /// Scrollable extent in seconds (a little past the project end).
    var contentDuration: Double { max(project.duration, layout.visibleDuration) + layout.visibleDuration * 0.25 }
    var maxScrollY: CGFloat { max(0, layout.contentHeight - bounds.height) }

    /// After the project gets shorter (or tracks are removed), pull zoom and scroll back
    /// inside the new extent so no empty width is left behind.
    func clampToContent() {
        guard bounds.width > 0 else { return }
        let range = TimelineLayout.zoomRange(duration: project.duration, fps: project.fps, width: bounds.width)
        if pixelsPerSecond < range.lowerBound { pixelsPerSecond = range.lowerBound }
        let maxTime = max(0, contentDuration - layout.visibleDuration)
        if scrollTime > maxTime { scrollTime = maxTime }
        if scrollY > maxScrollY { scrollY = maxScrollY }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let l = layout
        NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
        bounds.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: CGRect(x: 0, y: TimelineLayout.rulerHeight, width: bounds.width, height: bounds.height)).addClip()
        for (row, y, h) in l.rows.dropFirst() {
            let rect = CGRect(x: 0, y: y, width: bounds.width, height: h)
            guard rect.intersects(dirtyRect) else { continue }
            drawRowBackground(row, rect)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: CGRect(x: TimelineLayout.headerWidth, y: y, width: bounds.width, height: h - 1)).addClip()
            switch row {
            case .video(let t): drawVideoTrack(t, rect, l)
            case .audio: drawAudio(rect, l)
            case .lyric(let t): drawLyricTrack(t, rect, l)
            case .ruler: break
            }
            // A muted song or hidden track is dimmed, so it's clear it won't be seen or heard.
            if visibilityState(row)?.off == true {
                NSColor.black.withAlphaComponent(0.5).setFill()
                rect.fill(using: .sourceOver)
            }
            NSGraphicsContext.restoreGraphicsState()
            drawHeader(row, rect)
        }
        drawProjectEnd(l)
        if let target = reorderTarget, let f = l.frame(of: target) {
            NSColor.controlAccentColor.setFill()
            CGRect(x: 0, y: f.minY - 1, width: bounds.width, height: 3).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        drawRuler(l)
        if let limit = project.lengthLimit {
            HardOutLine.draw(limit: limit, duration: project.duration, layout: l, bounds: bounds, rulerHeight: TimelineLayout.rulerHeight)
        }
        if let m = marqueeRect {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            m.fill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: m.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
        if let g = snapGuide {
            let x = l.x(for: g)
            NSColor.systemYellow.setFill()
            CGRect(x: x - 0.5, y: 0, width: 1.5, height: bounds.height).fill()
        }
        updatePlayheadLayer(l, at: editor.playhead)
    }

    private func drawRowBackground(_ row: TimelineRow, _ rect: CGRect) {
        let shade: CGFloat
        switch row {
        case .audio: shade = 0.14
        case .lyric(let t): shade = t % 2 == 0 ? 0.15 : 0.13
        case .video(let t): shade = t % 2 == 0 ? 0.13 : 0.15
        case .ruler: shade = 0.1
        }
        NSColor(calibratedWhite: shade, alpha: 1).setFill()
        rect.fill()
        NSColor(calibratedWhite: 0.05, alpha: 1).setFill()
        CGRect(x: 0, y: rect.maxY - 1, width: rect.width, height: 1).fill()
    }

    private func title(_ row: TimelineRow) -> String {
        switch row {
        case .video(let t): project.videoTracks.indices.contains(t) ? (project.videoTracks[t].name ?? "Video \(t + 1)") : "Video \(t + 1)"
        case .audio: "Audio"
        case .lyric(let t): "Lyrics \(t + 1)"
        case .ruler: ""
        }
    }

    private func headerButtonRects(_ rect: CGRect) -> (add: CGRect, remove: CGRect, visibility: CGRect) {
        let y = rect.minY + 3
        let remove = CGRect(x: TimelineLayout.headerWidth - 22, y: y, width: 16, height: 16)
        let add = CGRect(x: TimelineLayout.headerWidth - 42, y: y, width: 16, height: 16)
        let visibility = CGRect(x: TimelineLayout.headerWidth - 62, y: y, width: 16, height: 16)
        return (add, remove, visibility)
    }

    /// Mute (audio) or show/hide (video and lyric tracks): the button's symbol and whether the
    /// row is switched off. nil when the row has no such button.
    private func visibilityState(_ row: TimelineRow) -> (symbol: String, off: Bool)? {
        switch row {
        case .audio:
            guard let a = project.audio else { return nil }
            return (a.isMuted ? "speaker.slash.fill" : "speaker.wave.2", a.isMuted)
        case .video(let t):
            guard project.videoTracks.indices.contains(t) else { return nil }
            return (project.videoTracks[t].isHidden ? "eye.slash.fill" : "eye", project.videoTracks[t].isHidden)
        case .lyric(let t):
            guard project.lyricTracks.indices.contains(t) else { return nil }
            return (project.lyricTracks[t].isHidden ? "eye.slash.fill" : "eye", project.lyricTracks[t].isHidden)
        case .ruler: return nil
        }
    }

    private func canRemove(_ row: TimelineRow) -> Bool {
        switch row {
        case .video: project.videoTracks.count > 1
        case .lyric: project.lyricTracks.count > 1
        case .audio: project.audio != nil
        case .ruler: false
        }
    }

    private func drawHeader(_ row: TimelineRow, _ rect: CGRect) {
        let header = CGRect(x: 0, y: rect.minY, width: TimelineLayout.headerWidth, height: rect.height - 1)
        NSColor(calibratedWhite: 0.19, alpha: 1).setFill()
        header.fill()
        let color: NSColor = switch row {
        case .audio: NSColor(calibratedRed: 0.30, green: 0.75, blue: 0.50, alpha: 1)
        case .lyric: NSColor(calibratedRed: 0.70, green: 0.50, blue: 0.90, alpha: 1)
        default: NSColor(calibratedRed: 0.40, green: 0.60, blue: 0.95, alpha: 1)
        }
        color.setFill()
        CGRect(x: 0, y: header.minY, width: 3, height: header.height).fill()
        if case .audio = row {} else {
            symbol("line.3.horizontal", at: CGRect(x: 8, y: rect.minY + 4, width: 12, height: 12), tint: .tertiaryLabelColor)
        }
        (title(row) as NSString).draw(at: CGPoint(x: 24, y: rect.minY + 3),
                                      withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let b = headerButtonRects(rect)
        if row != .audio { symbol("plus.circle", at: b.add, tint: .secondaryLabelColor) }
        if canRemove(row) { symbol("minus.circle", at: b.remove, tint: .secondaryLabelColor) }
        if let v = visibilityState(row) { symbol(v.symbol, at: b.visibility, tint: v.off ? .systemOrange : .secondaryLabelColor) }
        if case .video(let t) = row, rect.height > 38 {
            let count = project.videoTracks[t].clips.count
            ("\(count) clip\(count == 1 ? "" : "s")" as NSString).draw(at: CGPoint(x: 24, y: rect.minY + 19),
                                                                       withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor])
        }
        // Resize grip along the bottom edge.
        NSColor(calibratedWhite: 0.28, alpha: 1).setFill()
        CGRect(x: TimelineLayout.headerWidth / 2 - 10, y: rect.maxY - 4, width: 20, height: 2).fill()
    }

    private func symbol(_ name: String, at rect: CGRect, tint: NSColor) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: rect.height - 3, weight: .regular)) else { return }
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            tint.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: Self.aspectFit(img.size, in: rect))
    }

    /// `size` scaled to fit inside `rect` keeping its proportions, centred (symbols such as the
    /// eye and speaker are wider than tall; drawing them into a square distorts them).
    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let s = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    private func clipColor(_ selected: Bool) -> NSColor {
        selected ? NSColor.controlAccentColor : NSColor(calibratedRed: 0.22, green: 0.33, blue: 0.52, alpha: 1)
    }

    private func drawVideoTrack(_ t: Int, _ rect: CGRect, _ l: TimelineLayout) {
        let visible = l.visibleTimeRange
        for clip in project.videoTracks[t].clips where clip.end >= visible.lowerBound && clip.start <= visible.upperBound {
            let r = CGRect(x: l.x(for: clip.start), y: rect.minY + 2, width: CGFloat(clip.duration) * l.pixelsPerSecond, height: rect.height - 5)
            let selected = editor.isSelected(.clip(clip.id))
            let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            clipColor(selected).setFill()
            path.fill()
            guard let asset = project.asset(clip.assetID) else { continue }
            let labelH: CGFloat = Self.titleBarHeight
            // Title bar: a darker strip so the name is readable over any thumbnail.
            NSColor.black.withAlphaComponent(0.25).setFill()
            CGRect(x: r.minX, y: r.minY, width: r.width, height: min(labelH, r.height)).fill()
            if r.height > labelH + 8 {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)).addClip()
                drawFilmstrip(clip: clip, asset: asset, in: CGRect(x: r.minX, y: r.minY + labelH, width: r.width, height: r.height - labelH), l)
                NSGraphicsContext.restoreGraphicsState()
            }
            var labelX = r.minX + 5
            if let proxy = asset.proxy, r.width > 60 {
                // Orange "PROXY 1/4" badge: preview is playing the low-res copy of this clip.
                let text = "PROXY \(proxy.scale.label)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.black]
                let size = text.size(withAttributes: attrs)
                let badge = CGRect(x: labelX, y: r.minY + 4, width: size.width + 8, height: 12)
                NSColor.systemOrange.setFill()
                NSBezierPath(roundedRect: badge, xRadius: 5.5, yRadius: 5.5).fill()
                text.draw(at: CGPoint(x: badge.minX + 4, y: badge.minY), withAttributes: attrs)
                labelX = badge.maxX + 5
            }
            (asset.name as NSString).draw(in: CGRect(x: labelX, y: r.minY + 3, width: max(0, r.maxX - labelX - 5), height: 15),
                                          withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white])
            if asset.proxy != nil {
                NSColor.systemOrange.setFill()
                CGRect(x: r.minX, y: r.maxY - 3, width: r.width, height: 3).fill()
            }
            drawClipLength(Self.clipLength(clip.duration, fps: project.fps), in: r)
            NSColor.white.withAlphaComponent(selected ? 1 : 0.25).setStroke()
            path.lineWidth = selected ? 2 : 1
            path.stroke()
            // Edge handles hint that the ends can be dragged.
            if r.width > 24 {
                NSColor.white.withAlphaComponent(selected ? 0.9 : 0.35).setFill()
                NSBezierPath(roundedRect: CGRect(x: r.minX + 2, y: r.midY - 8, width: 3, height: 16), xRadius: 1.5, yRadius: 1.5).fill()
                NSBezierPath(roundedRect: CGRect(x: r.maxX - 5, y: r.midY - 8, width: 3, height: 16), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }

    /// The clip's length on the timeline (not its source file's), as MM:SS:FF in a small dark
    /// pill at the bottom right. A clip running past the right edge keeps it in view; it's left
    /// out when the clip is too small to fit it.
    private func drawClipLength(_ label: String, in r: CGRect) {
        let text = label as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                                                    .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let pill = CGSize(width: ceil(size.width) + 8, height: 14)
        guard r.width >= pill.width + 16, r.height >= Self.titleBarHeight + pill.height + 4 else { return }
        let right = min(r.maxX, bounds.maxX) - 4
        guard right - pill.width >= r.minX + 8 else { return }
        let box = CGRect(x: right - pill.width, y: r.maxY - pill.height - 3, width: pill.width, height: pill.height)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: box.minX + 4, y: box.midY - size.height / 2), withAttributes: attrs)
    }

    /// MM:SS:FF at the project's frame rate (frames run 00 to fps − 1), like the preview's timecode.
    static func clipLength(_ seconds: Double, fps: Double) -> String { Timecode.string(seconds, fps: fps) }

    /// Tiles across the clip, each showing the source frame at its own time.
    private func drawFilmstrip(clip: Clip, asset: Asset, in r: CGRect, _ l: TimelineLayout) {
        if asset.kind == .image {
            guard let img = editor.thumbnails.images[asset.id] else { return }
            let w = max(16, r.height * img.size.width / max(1, img.size.height))
            var x = r.minX
            while x < r.maxX { if x + w > TimelineLayout.headerWidth && x < bounds.width { img.draw(in: CGRect(x: x, y: r.minY, width: w, height: r.height)) }; x += w }
            return
        }
        let aspect = asset.pixelSize.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 16 / 9
        let tileW = max(24, r.height * aspect)
        let tileSeconds = Double(tileW / l.pixelsPerSecond)
        let step = Filmstrip.gridStep(tileSeconds: tileSeconds, fps: project.fps)
        let url = editor.mediaURL(for: asset, useProxies: true)
        var x = r.minX
        while x < r.maxX {
            if x + tileW > TimelineLayout.headerWidth && x < bounds.width {
                let localT = Double((x - r.minX) / l.pixelsPerSecond)
                let src = clip.sourceIn + localT
                if let img = filmstrip.image(url: url, sourceTime: src, step: step) ?? (localT == 0 ? editor.thumbnails.images[asset.id] : nil) {
                    img.draw(in: CGRect(x: x, y: r.minY, width: tileW, height: r.height))
                }
            }
            x += tileW
        }
    }

    private func drawAudio(_ rect: CGRect, _ l: TimelineLayout) {
        guard let audio = project.audio else {
            ("Drop the song here" as NSString).draw(at: CGPoint(x: TimelineLayout.headerWidth + 10, y: rect.minY + 4),
                                                    withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor])
            return
        }
        let r = CGRect(x: l.x(for: audio.start), y: rect.minY + 2, width: CGFloat(audio.duration) * l.pixelsPerSecond, height: rect.height - 5)
        let selected = editor.isSelected(.audio)
        NSColor(calibratedRed: 0.15, green: 0.38, blue: 0.27, alpha: 1).setFill()
        let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        path.fill()
        if selected { NSColor.controlAccentColor.setStroke(); path.lineWidth = 2; path.stroke() }
        let x0 = max(r.minX, TimelineLayout.headerWidth), x1 = min(r.maxX, bounds.width)
        guard x1 > x0 else { return }
        let store = editor.audioAnalysis
        let showAnalysis = r.height >= 40
        let wave = showAnalysis ? SectionLane.waveform(in: r) : r
        if showAnalysis {
            if let beats = editor.resolvedBeats {
                SectionLane.drawSections(beats.sections, audioStart: audio.start, duration: audio.duration, in: r, visible: x0...x1, x: l.x(for:))
                SectionLane.drawTicks(beats: beats.beats, downbeats: beats.downbeats, audioStart: audio.start, in: r,
                                      visible: x0...x1, pixelsPerSecond: l.pixelsPerSecond, x: l.x(for:))
            } else {
                let note: String? = switch store.state {
                case .running: "Analyzing song… (progress in the status bar)"
                case .failed(let m): "Analysis failed: \(m)"
                case .unavailable: "Song analysis is not in this build"
                case .idle: nil
                }
                if let note {
                    (note as NSString).draw(at: CGPoint(x: x0 + 6, y: r.minY), withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.75)])
                }
            }
        }
        guard wave.height > 16, let wf = editor.waveforms.waveforms[audio.assetID],
              let level = wf.level(secondsPerPixel: 1 / Double(l.pixelsPerSecond)) else { return }
        let secondsPerBucket = Double(level.samplesPerBucket) / wf.sampleRate
        let peak = NSBezierPath(), rmsPath = NSBezierPath()
        // The waveform is scaled so its highest peak just fits the row; the loudness curve and
        // its levels have their own scale, so the curve's loudest moment fills the row.
        let waveGain = wf.peakFitGain
        let lineGain = store.loudnessEnvelope?.displayGain() ?? wf.displayGain
        var x = x0
        while x < x1 {
            let t0 = l.time(for: x) - audio.start, t1 = l.time(for: x + 1) - audio.start
            let b0 = max(0, Int(t0 / secondsPerBucket)), b1 = min(level.maxs.count, max(b0 + 1, Int(t1 / secondsPerBucket)))
            if b0 < level.maxs.count {
                var mx: Float = 0, mn: Float = 0, rm: Float = 0
                for b in b0..<b1 { mx = max(mx, level.maxs[b]); mn = min(mn, level.mins[b]); rm = max(rm, level.rms[b]) }
                // Same scale as the loudness curve and its levels (SectionLane.amplitudeY).
                let hiY = SectionLane.amplitudeY(mx, gain: waveGain, in: wave).top, loY = SectionLane.amplitudeY(-mn, gain: waveGain, in: wave).bottom
                peak.move(to: CGPoint(x: x, y: hiY)); peak.line(to: CGPoint(x: x, y: loY))
                let r = SectionLane.amplitudeY(rm, gain: waveGain, in: wave)
                rmsPath.move(to: CGPoint(x: x, y: r.top)); rmsPath.line(to: CGPoint(x: x, y: r.bottom))
            }
            x += 1
        }
        NSColor.white.withAlphaComponent(0.40).setStroke(); peak.lineWidth = 1; peak.stroke()
        NSColor(calibratedRed: 0.55, green: 1, blue: 0.75, alpha: 0.9).setStroke(); rmsPath.lineWidth = 1; rmsPath.stroke()
        if showAnalysis {
            // Loud/quiet stretches over the waveform, then the curve and its levels on top.
            SectionLane.drawLoudness(store.loudness, audioStart: audio.start, in: wave, visible: x0...x1, x: l.x(for:))
            SectionLane.drawLoudnessCurve(store.loudnessEnvelope, gain: lineGain, audioStart: audio.start, in: wave, visible: x0...x1, time: l.time(for:))
        }
    }

    /// Lyric row layout: the line's name bar on top, then one row per word (word 1 on the
    /// first row, word 2 on the second, …), each row capped in height so lines with few and
    /// many words look alike. Words never touch, so each word's edges are easy to grab.
    struct LyricRowParts { var line: CGRect; var words: [CGRect] }

    static let maxWordRowHeight: CGFloat = 18
    static let minWordRowHeight: CGFloat = 5

    static func lyricParts(_ rect: CGRect, wordCount: Int) -> LyricRowParts {
        let lineH: CGFloat = min(Self.titleBarHeight, max(12, rect.height - 4))
        let line = CGRect(x: rect.minX, y: rect.minY + 2, width: rect.width, height: lineH)
        let n = max(1, wordCount)
        let gap: CGFloat = 2
        let remaining = rect.maxY - 3 - line.maxY - gap
        let rowH = min(maxWordRowHeight, (remaining - gap * CGFloat(n - 1)) / CGFloat(n))
        guard rowH >= minWordRowHeight else { return LyricRowParts(line: line, words: []) }
        var rows: [CGRect] = []
        var y = line.maxY + gap
        for _ in 0..<n {
            rows.append(CGRect(x: rect.minX, y: y, width: rect.width, height: rowH))
            y += rowH + gap
        }
        return LyricRowParts(line: line, words: rows)
    }

    /// Height of the name bar on top of clips and lyric lines (easy to grab).
    static let titleBarHeight: CGFloat = 20

    static let lineColor = NSColor(calibratedRed: 0.34, green: 0.22, blue: 0.46, alpha: 1)
    static let wordColor = NSColor(calibratedRed: 0.66, green: 0.52, blue: 0.86, alpha: 1)

    private func drawLyricTrack(_ t: Int, _ rect: CGRect, _ l: TimelineLayout) {
        let visible = l.visibleTimeRange
        for line in project.lyricTracks[t].lines where line.end >= visible.lowerBound && line.start <= visible.upperBound {
            let parts = Self.lyricParts(rect, wordCount: line.words.count)
            let x0 = l.x(for: line.start), w = CGFloat(line.end - line.start) * l.pixelsPerSecond
            let lineSelected = editor.isSelected(.lyricLine(line.id))
            // The line spans its whole box (bar plus word rows) so its extent stays readable.
            let span = CGRect(x: x0, y: parts.line.minY, width: w, height: (parts.words.last?.maxY ?? parts.line.maxY) - parts.line.minY)
            Self.lineColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: span, xRadius: 3, yRadius: 3).fill()
            let bar = CGRect(x: x0, y: parts.line.minY, width: w, height: parts.line.height)
            let bp = NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3)
            Self.lineColor.setFill()
            bp.fill()
            if lineSelected {
                NSColor.controlAccentColor.setStroke()
                let outline = NSBezierPath(roundedRect: span, xRadius: 3, yRadius: 3)
                outline.lineWidth = 2
                outline.stroke()
            }
            if bar.width > 30 {
                (line.text as NSString).draw(in: CGRect(x: bar.minX + 5, y: bar.minY + 3, width: bar.width - 10, height: 15),
                                             withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.9)])
            }
            guard parts.words.count == line.words.count else { continue }
            for (i, wd) in line.words.enumerated() {
                let row = parts.words[i]
                let wr = CGRect(x: l.x(for: wd.start), y: row.minY, width: max(2, CGFloat(wd.end - wd.start) * l.pixelsPerSecond), height: row.height)
                let selected = editor.isSelected(.lyricWord(wd.id))
                (selected ? NSColor.controlAccentColor : Self.wordColor).setFill()
                NSBezierPath(roundedRect: wr, xRadius: 2, yRadius: 2).fill()
                if wd.id == editor.transport.tapWordID {
                    // The word the next tap will time.
                    NSColor.systemGreen.setStroke()
                    let ring = NSBezierPath(roundedRect: wr.insetBy(dx: -1.5, dy: -1.5), xRadius: 3, yRadius: 3)
                    ring.lineWidth = 2
                    ring.stroke()
                }
                if LyricAlignment.isLow(wd) {
                    // Unsure timing (R22): an orange outline and a bar along the bottom.
                    NSColor.systemOrange.setStroke()
                    let outline = NSBezierPath(roundedRect: wr.insetBy(dx: 0.75, dy: 0.75), xRadius: 2, yRadius: 2)
                    outline.lineWidth = 1.5
                    outline.stroke()
                    NSColor.systemOrange.setFill()
                    CGRect(x: wr.minX + 1, y: wr.maxY - 3, width: max(0, wr.width - 2), height: 2).fill()
                }
                if wr.width > 14 && wr.height >= 10 {
                    (wd.text as NSString).draw(in: wr.insetBy(dx: 3, dy: 0),
                                               withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.black.withAlphaComponent(0.8)])
                }
            }
        }
    }

    private func drawProjectEnd(_ l: TimelineLayout) {
        let x = l.x(for: project.duration)
        guard x > TimelineLayout.headerWidth, x < bounds.width else { return }
        NSColor.black.withAlphaComponent(0.35).setFill()
        CGRect(x: x, y: TimelineLayout.rulerHeight, width: bounds.width - x, height: bounds.height).fill()
    }

    private func drawRuler(_ l: TimelineLayout) {
        let r = CGRect(x: 0, y: 0, width: bounds.width, height: TimelineLayout.rulerHeight)
        NSColor(calibratedWhite: 0.17, alpha: 1).setFill(); r.fill()
        NSColor(calibratedWhite: 0.05, alpha: 1).setFill(); CGRect(x: 0, y: r.maxY - 1, width: r.width, height: 1).fill()
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
        if let loop = editor.transport.loop {
            // Looping region (next unsure word): a yellow band on the ruler.
            let x0 = max(TimelineLayout.headerWidth, l.x(for: loop.lowerBound)), x1 = min(bounds.width, l.x(for: loop.upperBound))
            if x1 > x0 {
                NSColor.systemYellow.withAlphaComponent(0.35).setFill()
                CGRect(x: x0, y: 0, width: x1 - x0, height: r.height - 1).fill()
            }
        }
        drawCinemascopeMarkers(l, ruler: r)
        drawCacheStrip(l, ruler: r)
        NSColor(calibratedWhite: 0.19, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: TimelineLayout.headerWidth, height: r.height - 1).fill()
        (Timecode.string(editor.playhead, fps: project.fps) as NSString).draw(at: CGPoint(x: 10, y: 6),
            withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.systemRed])
    }

    private func drawCacheStrip(_ l: TimelineLayout, ruler r: CGRect) {
        if stripMemo?.revision != editor.revision || stripMemo?.files != editor.segmentFiles {
            let states = CacheStrip.states(project: project, settings: .defaults(for: project), files: editor.segmentFiles)
            stripMemo = (editor.revision, editor.segmentFiles, states)
        }
        CacheStrip.draw(stripMemo?.states ?? [], layout: l, width: bounds.width, y: r.maxY - CacheStrip.height - 1)
    }

    static let cinemaColor = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.22, alpha: 1)

    /// Cinemascope transition: a band on the ruler between the markers, a solid strip after
    /// the end marker (full 2.35:1), and a draggable flag on each marker.
    private func drawCinemascopeMarkers(_ l: TimelineLayout, ruler r: CGRect) {
        let c = project.cinemascope
        guard project.type == .musicVideo, c.enabled else { return }
        let xs = l.x(for: c.startMarker), xe = l.x(for: c.endMarker)
        let band = CGRect(x: xs, y: r.maxY - 6, width: max(0, xe - xs), height: 5)
        NSGradient(starting: Self.cinemaColor.withAlphaComponent(0.15), ending: Self.cinemaColor.withAlphaComponent(0.8))?.draw(in: band, angle: 0)
        Self.cinemaColor.withAlphaComponent(0.8).setFill()
        CGRect(x: xe, y: r.maxY - 6, width: max(0, bounds.width - xe), height: 5).fill()
        for (x, label) in [(xs, "▸ 2.35"), (xe, "2.35 ◂")] {
            Self.cinemaColor.setFill()
            CGRect(x: x - 1, y: 0, width: 2, height: r.height).fill()
            let flag = NSBezierPath()
            flag.move(to: CGPoint(x: x - 6, y: 0)); flag.line(to: CGPoint(x: x + 6, y: 0)); flag.line(to: CGPoint(x: x, y: 8)); flag.close()
            flag.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: Self.cinemaColor]
            let str = label as NSString
            let w = str.size(withAttributes: attrs).width
            str.draw(at: CGPoint(x: x == xs ? x + 4 : x - w - 4, y: 12), withAttributes: attrs)
        }
    }

    /// Place the playhead layer at `t` (hidden when it is scrolled out of view).
    private func updatePlayheadLayer(_ l: TimelineLayout, at t: Double) {
        let x = l.x(for: t)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadLayer.isHidden = !(x >= TimelineLayout.headerWidth && x <= bounds.width)
        let size = CGSize(width: 12, height: bounds.height)
        if playheadLayer.bounds.size != size {
            playheadLayer.bounds = CGRect(origin: .zero, size: size)
            let path = CGMutablePath()
            path.addRect(CGRect(x: 5.5, y: 0, width: 1.5, height: size.height))
            path.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 12, y: 0), CGPoint(x: 6, y: 9)])
            path.closeSubpath()
            playheadLayer.path = path
        }
        playheadLayer.position = CGPoint(x: x, y: size.height / 2)
        CATransaction.commit()
    }

    /// The ruler's header box that shows the playhead timecode.
    private var playheadTimecodeRect: CGRect { CGRect(x: 0, y: 0, width: TimelineLayout.headerWidth, height: TimelineLayout.rulerHeight) }

    // MARK: Hit testing

    private func hit(at p: CGPoint) -> Hit {
        let l = layout
        guard let row = l.row(atY: p.y) else { return .empty(.ruler) }
        if row == .ruler {
            let c = project.cinemascope
            if project.type == .musicVideo && c.enabled {
                if abs(l.x(for: c.startMarker) - p.x) <= 7 { return .marker(isStart: true) }
                if abs(l.x(for: c.endMarker) - p.x) <= 7 { return .marker(isStart: false) }
            }
            return .ruler
        }
        if p.x < TimelineLayout.headerWidth {
            guard let f = l.frame(of: row) else { return .headerBody(row) }
            let b = headerButtonRects(f)
            if row != .audio && b.add.insetBy(dx: -3, dy: -3).contains(p) { return .headerButton(row, .add) }
            if canRemove(row) && b.remove.insetBy(dx: -3, dy: -3).contains(p) { return .headerButton(row, .remove) }
            if visibilityState(row) != nil && b.visibility.insetBy(dx: -2, dy: -3).contains(p) { return .headerButton(row, .visibility) }
            if p.y > f.maxY - 6 { return .headerResize(row) }
            return .headerBody(row)
        }
        if let f = l.frame(of: row), p.y > f.maxY - 4 { return .headerResize(row) }
        let t = l.time(for: p.x)
        let grab = Double(TimelineLayout.edgeGrab / l.pixelsPerSecond)
        func edge(_ start: Double, _ end: Double) -> Edge {
            let span = end - start
            let g = min(grab, span / 3)
            if t - start <= g { return .left }
            if end - t <= g { return .right }
            return .body
        }
        switch row {
        case .video(let ti):
            if let c = project.videoTracks[ti].clips.last(where: { t >= $0.start && t <= $0.end }) {
                return .clip(c.id, edge(c.start, c.end))
            }
        case .audio:
            if let a = project.audio, t >= a.start, t <= a.end {
                if let beats = editor.resolvedBeats, let f = l.frame(of: row) {
                    let clipRect = CGRect(x: l.x(for: a.start), y: f.minY + 2, width: CGFloat(a.duration) * l.pixelsPerSecond, height: f.height - 5)
                    if clipRect.height >= 40 {
                        switch SectionLane.hit(p, clip: clipRect, sections: beats.sections, downbeats: beats.downbeats,
                                               audioStart: a.start, pixelsPerSecond: l.pixelsPerSecond, x: l.x(for:)) {
                        case .boundary(let i)?: return .sectionBoundary(i)
                        case .downbeat(let i)?: return .downbeat(i)
                        default: break
                        }
                    }
                }
                return .audio
            }
        case .lyric(let ti):
            guard let frame = l.frame(of: row) else { break }
            for line in project.lyricTracks[ti].lines where t >= line.start - grab && t <= line.end + grab {
                let parts = Self.lyricParts(frame, wordCount: line.words.count)
                for (i, w) in line.words.enumerated() where parts.words.count == line.words.count {
                    let r = parts.words[i]
                    if p.y >= r.minY && p.y <= r.maxY && t >= w.start - grab && t <= w.end + grab {
                        return .word(w.id, edge(w.start, w.end))
                    }
                }
                if t >= line.start && t <= line.end { return .line(line.id, edge(line.start, line.end)) }
            }
        case .ruler: break
        }
        return .empty(row)
    }

    /// True when `p` is over the section lane at the top of the song.
    private func isInSectionLane(_ p: CGPoint) -> Bool {
        let l = layout
        guard let a = project.audio, let f = l.frame(of: .audio) else { return false }
        let clip = CGRect(x: l.x(for: a.start), y: f.minY + 2, width: CGFloat(a.duration) * l.pixelsPerSecond, height: f.height - 5)
        return clip.height >= 40 && SectionLane.lane(in: clip).insetBy(dx: 0, dy: -1).contains(p)
    }

    // MARK: Cursors

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    private func updateCursor(at p: CGPoint) {
        switch hit(at: p) {
        case .clip(_, .left), .clip(_, .right), .line(_, .left), .line(_, .right), .word(_, .left), .word(_, .right):
            NSCursor.resizeLeftRight.set()
        case .clip(_, .body), .line(_, .body), .word(_, .body), .audio:
            NSCursor.openHand.set()
        case .headerResize: NSCursor.resizeUpDown.set()
        case .marker, .sectionBoundary, .downbeat: NSCursor.resizeLeftRight.set()
        case .headerButton: NSCursor.pointingHand.set()
        case .headerBody(let r) where r != .audio: NSCursor.openHand.set()
        default: NSCursor.arrow.set()
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let h = hit(at: p)
        let item: Selection? = {
            switch h {
            case .clip(let id, _): .clip(id)
            case .line(let id, _): .lyricLine(id)
            case .word(let id, _): .lyricWord(id)
            case .audio: .audio
            default: nil
            }
        }()
        if event.modifierFlags.contains(.command), let item { editor.toggleSelected(item); return }
        if event.modifierFlags.contains(.shift), item == nil, p.x > TimelineLayout.headerWidth, p.y > TimelineLayout.rulerHeight {
            drag = Drag(kind: .marquee, startPoint: p); return
        }
        // Dragging the body of an item that is part of a multi-selection moves the whole group.
        if let item, editor.selectedItems.count > 1, editor.isSelected(item) {
            switch h {
            case .clip(_, .body), .line(_, .body):
                drag = Drag(kind: .group(original: editor.project, clips: editor.selectedClipIDs, lines: editor.selectedLineIDs), startPoint: p)
                NSCursor.closedHand.set()
                return
            default: break
            }
        }
        switch h {
        case .clip(let id, let e): editor.selection = .clip(id); if e == .body { NSCursor.closedHand.set() }
        case .line(let id, _): editor.selection = .lyricLine(id)
        case .word(let id, _): editor.selection = .lyricWord(id)
        case .audio:
            editor.selection = .audio
            if event.clickCount == 2, let a = editor.audioAnalysis.analysis, isInSectionLane(p) {
                let t = layout.time(for: p.x) - (project.audio?.start ?? 0)
                editor.edit("Add Section Boundary") { $0.addSectionBoundary(at: t, analysis: a) }
                return
            }
        case .sectionBoundary, .downbeat:
            guard let a = editor.audioAnalysis.analysis else { return }
            drag = Drag(kind: .beat(h, original: editor.project, analysis: a), startPoint: p); return
        case .marker(let isStart):
            drag = Drag(kind: .marker(isStart: isStart, original: editor.project), startPoint: p); return
        case .ruler:
            editor.isPlaying = false
            editor.setPlayhead(layout.time(for: p.x))
            drag = Drag(kind: .scrub, startPoint: p); return
        case .empty:
            editor.selection = .none
            editor.isPlaying = false
            editor.setPlayhead(layout.time(for: p.x))
            drag = Drag(kind: .scrub, startPoint: p); return
        case .headerButton(let row, let b): headerAction(row, b); return
        case .headerResize(let row): drag = Drag(kind: .resize(row, startHeight: rowHeight(row)), startPoint: p); return
        case .headerBody(let row):
            if event.clickCount == 2 { setRowHeight(row, rowHeight(row) > TimelineLayout.minRowHeight + 1 ? TimelineLayout.minRowHeight : TimelineLayout.defaultHeight(row)); return }
            if row != .audio { drag = Drag(kind: .reorder(row), startPoint: p) }
            return
        }
        drag = Drag(kind: .edit(h, original: editor.project), startPoint: p)
    }

    private var draggingAudio: Bool {
        if case .edit(.audio, _)? = drag?.kind { return true }
        return false
    }

    /// Snap `time` to nearby targets unless snapping is off or ⌘ is held.
    private func snapped(_ time: Double, excluding ids: Set<UUID>, event: NSEvent?) -> Double {
        let source = drag.map { if case .edit(_, let o) = $0.kind { return o } else { return project } } ?? project
        let result = Snapping.resolve(time, enabled: snappingEnabled, bypass: event?.modifierFlags.contains(.command) ?? false,
                                      targets: Snapping.targets(in: source, playhead: editor.playhead, excluding: ids,
                                                                includeAudio: !draggingAudio, beats: editor.resolvedBeats, groups: snapGroups),
                                      pixelsPerSecond: Double(pixelsPerSecond))
        snapGuide = result.target?.time
        return result.time
    }

    /// New start for an item being moved: snap its start, or failing that its end.
    private func snappedMove(start: Double, duration: Double, excluding ids: Set<UUID>, event: NSEvent?) -> Double {
        let s1 = snapped(start, excluding: ids, event: event)
        if s1 != start { return s1 }
        return snapped(start + duration, excluding: ids, event: event) - duration
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        let l = layout
        autoscroll(at: p)
        switch d.kind {
        case .scrub:
            editor.setPlayhead(l.time(for: p.x)); return
        case .pan: return
        case .resize(let row, let h0):
            setRowHeight(row, h0 + (p.y - d.startPoint.y)); return
        case .reorder(let row):
            reorderTarget = reorderDestination(for: row, at: p.y)
            needsDisplay = true
            return
        case .marker(let isStart, let original):
            var next = original
            let t = max(0, snapped(l.time(for: p.x), excluding: [], event: event))
            if isStart { next.cinemascope.startMarker = next.quantize(min(t, original.cinemascope.endMarker)) }
            else { next.cinemascope.endMarker = next.quantize(max(t, original.cinemascope.startMarker)) }
            editor.replaceWithoutUndo(next)
            d.didEdit = true
            drag = d
            return
        case .beat(let hit, let original, let analysis):
            guard abs(p.x - d.startPoint.x) > 1 || d.didEdit else { return }
            let t = l.time(for: p.x) - (original.audio?.start ?? 0)
            var next = original
            switch hit {
            case .sectionBoundary(let i): next.moveSectionBoundary(i, to: t, analysis: analysis)
            case .downbeat(let i): next.moveDownbeat(i, to: t, analysis: analysis)
            default: return
            }
            editor.replaceWithoutUndo(next)
            d.didEdit = true
            drag = d
            return
        case .marquee:
            let r = CGRect(x: min(p.x, d.startPoint.x), y: min(p.y, d.startPoint.y), width: abs(p.x - d.startPoint.x), height: abs(p.y - d.startPoint.y))
            marqueeRect = r
            editor.setSelection(items(in: r))
            needsDisplay = true
            return
        case .group(let original, let clips, let lines):
            guard abs(p.x - d.startPoint.x) > 2 || d.didEdit else { return }
            var dt = Double((p.x - d.startPoint.x) / l.pixelsPerSecond)
            // The first item snaps; the others keep their distance from it.
            let members: [(start: Double, duration: Double)] =
                original.videoTracks.flatMap(\.clips).filter { clips.contains($0.id) }.map { ($0.start, $0.duration) }
                + original.lyricTracks.flatMap(\.lines).filter { lines.contains($0.id) }.map { ($0.start, $0.end - $0.start) }
            if let first = members.min(by: { $0.start < $1.start }) {
                let ids = Set(clips + lines + original.lyricTracks.flatMap(\.lines).filter { lines.contains($0.id) }.flatMap { $0.words.map(\.id) })
                dt = snappedMove(start: first.start + dt, duration: first.duration, excluding: ids, event: event) - first.start
                // Never push any member before 0.
                dt = max(dt, -first.start)
            }
            dt = original.clampLineShift(dt, lines: Set(lines))
            var next = original
            for id in clips { if let loc = original.clipLocation(id), let c = original.videoTracks[loc.track].clips.first(where: { $0.id == id }) { next.moveClip(id, toTrack: loc.track, start: c.start + dt) } }
            for id in lines { if let loc = original.lineLocation(id), let ln = original.lyricTracks[loc.track].lines.first(where: { $0.id == id }) { next.moveLine(id, toTrack: loc.track, start: ln.start + dt) } }
            editor.replaceWithoutUndo(next)
            d.didEdit = true
            drag = d
            return
        case .edit(let hit, let original):
            guard abs(p.x - d.startPoint.x) > 2 || d.didEdit else { return }
            let dt = Double((p.x - d.startPoint.x) / l.pixelsPerSecond)
            var next = original
            switch hit {
            case .clip(let id, let edge):
                guard let c = original.videoTracks.flatMap(\.clips).first(where: { $0.id == id }) else { return }
                switch edge {
                case .left: next.trimStart(id, to: snapped(c.start + dt, excluding: [id], event: event))
                case .right: next.trimEnd(id, to: snapped(c.end + dt, excluding: [id], event: event))
                case .body:
                    var track = original.clipLocation(id)!.track
                    if case .video(let t)? = l.row(atY: p.y) { track = t }
                    next.moveClip(id, toTrack: track, start: snappedMove(start: c.start + dt, duration: c.duration, excluding: [id], event: event))
                }
            case .line(let id, let edge):
                guard let line = original.lyricTracks.flatMap(\.lines).first(where: { $0.id == id }) else { return }
                let ids = Set([id] + line.words.map(\.id))
                // Lines on one track never overlap: edges stop at the neighbours, and a moved
                // line stays against a neighbour until the pointer is past its middle.
                let limits = original.lineEdgeLimits(id)
                switch edge {
                case .left: next.retimeLine(id, start: max(limits.minStart, snapped(line.start + dt, excluding: ids, event: event)))
                case .right: next.retimeLine(id, end: min(limits.maxEnd, snapped(line.end + dt, excluding: ids, event: event)))
                case .body:
                    let home = original.lineLocation(id)!.track
                    var track = home
                    if case .lyric(let t)? = l.row(atY: p.y) { track = t }
                    let want = snapped(line.start + dt, excluding: ids, event: event)
                    let duration = line.end - line.start
                    if let s = original.freeLineStart(want, duration: duration, track: track, ignoring: [id]) {
                        next.moveLine(id, toTrack: track, start: s)
                    } else if track != home, let s = original.freeLineStart(want, duration: duration, track: home, ignoring: [id]) {
                        next.moveLine(id, toTrack: home, start: s)
                    }
                }
            case .word(let id, let edge):
                guard let w = original.lyricTracks.flatMap(\.lines).flatMap(\.words).first(where: { $0.id == id }),
                      let loc = original.wordLocation(id) else { return }
                // A word dragged past its line's edge grows the line, up to the neighbouring lines.
                let limits = original.lineEdgeLimits(original.lyricTracks[loc.track].lines[loc.line].id)
                switch edge {
                case .left: next.retimeWord(id, start: max(limits.minStart, min(snapped(w.start + dt, excluding: [id], event: event), w.end - next.frameDuration)))
                case .right: next.retimeWord(id, end: min(limits.maxEnd, max(snapped(w.end + dt, excluding: [id], event: event), w.start + next.frameDuration)))
                case .body:
                    let len = w.end - w.start
                    let s = min(max(limits.minStart, snapped(w.start + dt, excluding: [id], event: event)), limits.maxEnd - len)
                    next.moveWord(id, start: s)
                }
            case .audio:
                guard let a = original.audio else { return }
                let alone = event.modifierFlags.contains(.option)
                // When everything moves with the song, only the playhead and project start are fixed targets.
                let moving: Set<UUID> = alone ? [] : Set(original.videoTracks.flatMap(\.clips).map(\.id) + original.lyricTracks.flatMap(\.lines).flatMap { [$0.id] + $0.words.map(\.id) })
                next.moveAudio(start: snappedMove(start: a.start + dt, duration: a.duration, excluding: moving, event: event), alone: alone)
            default: return
            }
            // Live preview of the drag; committed as one undo step on mouse up.
            editor.replaceWithoutUndo(next)
            d.didEdit = true
            drag = d
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; snapGuide = nil; reorderTarget = nil; marqueeRect = nil; needsDisplay = true; updateCursor(at: convert(event.locationInWindow, from: nil)) }
        guard let d = drag else { return }
        switch d.kind {
        case .resize: editor.document?.persistLayout()
        case .reorder(let row):
            if let target = reorderTarget { performReorder(row, to: target) }
        case .marker(_, let original) where d.didEdit:
            var final = editor.project
            final.anchorMarkers(editor.resolvedBeats, hash: editor.audioAnalysis.analysis?.audioHash)
            editor.replaceWithoutUndo(original)
            editor.edit("Move Cinemascope Marker") { $0 = final }
        case .beat(let hit, let original, _) where d.didEdit:
            let final = editor.project
            editor.replaceWithoutUndo(original)
            editor.edit(actionName(for: hit)) { $0 = final }
        case .group(let original, _, _) where d.didEdit:
            var final = editor.project
            final.markHandEditedWords(comparedTo: original)
            editor.replaceWithoutUndo(original)
            editor.edit("Move Items") { $0 = final }
        case .edit(let hit, let original) where d.didEdit:
            // Only the dragged item changes: an edited word is confirmed, but the words around
            // it keep their times (tap mode is what re-times the words between taps).
            var final = editor.project
            // Moved or re-timed lyrics are your timing now: re-aligning asks before replacing it.
            switch hit {
            case .line, .word: final.markHandEditedWords(comparedTo: original)
            default: break
            }
            editor.replaceWithoutUndo(original)
            editor.edit(actionName(for: hit)) { $0 = final }
        default: break
        }
    }

    private func actionName(for hit: Hit) -> String {
        switch hit {
        case .clip(_, .body), .line(_, .body), .word(_, .body): "Move"
        case .audio: "Move Audio"
        case .sectionBoundary: "Move Section Boundary"
        case .downbeat: "Move Downbeat"
        default: "Trim"
        }
    }

    /// Clips and lyric lines whose boxes intersect a view rectangle.
    private func items(in r: CGRect) -> Set<Selection> {
        let l = layout
        var out: Set<Selection> = []
        for (row, y, h) in l.rows.dropFirst() {
            let band = CGRect(x: TimelineLayout.headerWidth, y: y, width: bounds.width, height: h)
            guard band.intersects(r) else { continue }
            switch row {
            case .video(let t):
                for c in project.videoTracks[t].clips {
                    let cr = CGRect(x: l.x(for: c.start), y: y, width: CGFloat(c.duration) * l.pixelsPerSecond, height: h)
                    if cr.intersects(r) { out.insert(.clip(c.id)) }
                }
            case .lyric(let t):
                for ln in project.lyricTracks[t].lines {
                    let lr = CGRect(x: l.x(for: ln.start), y: y, width: CGFloat(ln.end - ln.start) * l.pixelsPerSecond, height: h)
                    if lr.intersects(r) { out.insert(.lyricLine(ln.id)) }
                }
            default: break
            }
        }
        return out
    }

    // MARK: Track reordering

    /// The row a dragged header would land in front of (same kind only).
    private func reorderDestination(for row: TimelineRow, at y: CGFloat) -> TimelineRow? {
        guard let over = layout.row(atY: y), over != row else { return nil }
        switch (row, over) {
        case (.video, .video), (.lyric, .lyric): return over
        default: return nil
        }
    }

    private func performReorder(_ row: TimelineRow, to target: TimelineRow) {
        switch (row, target) {
        case (.video(let from), .video(let to)): editor.edit("Move Track") { $0.moveVideoTrack(from: from, to: to) }
        case (.lyric(let from), .lyric(let to)): editor.edit("Move Track") { $0.moveLyricTrack(from: from, to: to) }
        default: break
        }
    }

    // MARK: Track header actions

    func headerAction(_ row: TimelineRow, _ b: HeaderButton) {
        switch (row, b) {
        case (.video(let t), .add): editor.edit("Add Video Track") { $0.insertVideoTrack(above: t) }
        case (.lyric(let t), .add): editor.edit("Add Lyrics Track") { $0.insertLyricTrack(below: t) }
        case (.video(let t), .remove): confirmRemoveTrack(row) { self.editor.edit("Remove Video Track") { $0.removeVideoTrack(at: t) } }
        case (.lyric(let t), .remove): confirmRemoveTrack(row) { self.editor.edit("Remove Lyrics Track") { $0.removeLyricTrack(at: t) } }
        case (.audio, .remove): editor.edit("Remove Audio") { $0.removeAudio() }
        case (.audio, .visibility):
            editor.edit(project.audio?.isMuted == true ? "Unmute Song" : "Mute Song") { $0.toggleAudioMuted() }
        case (.video(let t), .visibility):
            editor.edit(project.videoTracks[t].isHidden ? "Show Video Track" : "Hide Video Track") { $0.toggleVideoTrackHidden(t) }
        case (.lyric(let t), .visibility):
            editor.edit(project.lyricTracks[t].isHidden ? "Show Lyrics Track" : "Hide Lyrics Track") { $0.toggleLyricTrackHidden(t) }
        default: break
        }
    }

    private func confirmRemoveTrack(_ row: TimelineRow, _ remove: @escaping () -> Void) {
        let count: Int
        switch row {
        case .video(let t): count = project.videoTracks[t].clips.count
        case .lyric(let t): count = project.lyricTracks[t].lines.count
        default: count = 0
        }
        guard count > 0, let window else { remove(); return }
        let alert = NSAlert()
        alert.messageText = "Remove \(title(row))?"
        alert.informativeText = "It contains \(count) item\(count == 1 ? "" : "s"). You can undo this."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { remove() } }
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let row = layout.row(atY: p.y), row != .ruler else { return }
        let menu = NSMenu()
        func item(_ title: String, _ action: @escaping () -> Void) {
            let i = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            let target = MenuAction(action)
            i.target = target
            i.representedObject = target
            menu.addItem(i)
        }
        if case .clip(let id, _) = hit(at: p), let clip = editor.clip(id), let asset = project.asset(clip.assetID) {
            editor.selection = .clip(id)
            let t = layout.time(for: p.x)
            item("Split Here") { self.editor.edit("Split") { $0.split(at: t, clipID: id) } }
            item("Delete Clip") { self.editor.edit("Delete Clip") { $0.deleteClip(id) } }
            if asset.kind == .video {
                menu.addItem(.separator())
                for scale in ProxyScale.allCases {
                    item("\(asset.proxy == nil ? "Create" : "Replace with") \(scale.label) Proxy") { [editor] in
                        Task { @MainActor in
                            do { try await editor.createProxy(assetID: asset.id, scale: scale) }
                            catch { NSAlert(error: error).runModal() }
                        }
                    }
                }
                if asset.proxy != nil { item("Remove Proxy") { [editor] in editor.deleteProxy(assetID: asset.id) } }
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        switch row {
        case .video(let t):
            item("Add Video Track Above") { self.headerAction(row, .add) }
            if project.videoTracks.count > 1 { item("Remove \(title(row))") { self.headerAction(row, .remove) } }
            if t < project.videoTracks.count - 1 { item("Move Up") { self.editor.edit("Move Track") { $0.moveVideoTrack(from: t, to: t + 1) } } }
            if t > 0 { item("Move Down") { self.editor.edit("Move Track") { $0.moveVideoTrack(from: t, to: t - 1) } } }
        case .lyric(let t):
            if !project.lyricTracks[t].lines.isEmpty, project.audio != nil {
                item("Align Words to Song") { self.editor.alignLyrics(window: self.window) }
                menu.addItem(.separator())
            }
            item("Add Lyrics Track Below") { self.headerAction(row, .add) }
            if project.lyricTracks.count > 1 { item("Remove \(title(row))") { self.headerAction(row, .remove) } }
            if t > 0 { item("Move Up") { self.editor.edit("Move Track") { $0.moveLyricTrack(from: t, to: t - 1) } } }
            if t < project.lyricTracks.count - 1 { item("Move Down") { self.editor.edit("Move Track") { $0.moveLyricTrack(from: t, to: t + 1) } } }
        case .audio:
            if let audio = project.audio {
                let store = editor.audioAnalysis
                if let a = store.analysis {
                    let t = layout.time(for: p.x) - audio.start
                    if case .sectionBoundary(let i) = hit(at: p) {
                        item("Remove Section Boundary") { self.editor.edit("Remove Section Boundary") { $0.removeSectionBoundary(i, analysis: a) } }
                    } else if isInSectionLane(p) {
                        item("Add Section Boundary Here") { self.editor.edit("Add Section Boundary") { $0.addSectionBoundary(at: t, analysis: a) } }
                    }
                    if project.beatCorrections?.audioHash == a.audioHash {
                        item("Reset Beat and Section Fixes") { self.editor.edit("Reset Beat Fixes") { $0.beatCorrections = nil } }
                    }
                }
                if store.state == .running {
                    item("Cancel Song Analysis") { store.cancel() }
                } else if store.state != .unavailable {
                    item("Analyze Song Again") { store.ensure(for: self.project.asset(audio.assetID), force: true) }
                }
                menu.addItem(.separator())
                item("Remove Audio") { self.headerAction(row, .remove) }
            }
        case .ruler: break
        }
        menu.addItem(.separator())
        item("Collapse Track") { self.setRowHeight(row, TimelineLayout.minRowHeight); self.editor.document?.persistLayout() }
        item("Default Height") { self.setRowHeight(row, TimelineLayout.defaultHeight(row)); self.editor.document?.persistLayout() }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Scrolling and zoom

    override func otherMouseDown(with event: NSEvent) {
        drag = Drag(kind: .pan(startScroll: scrollTime, startY: scrollY), startPoint: convert(event.locationInWindow, from: nil))
        NSCursor.closedHand.set()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard let d = drag, case .pan(let s0, let y0) = d.kind else { return }
        let p = convert(event.locationInWindow, from: nil)
        scrollTime = min(max(0, s0 - Double((p.x - d.startPoint.x) / pixelsPerSecond)), contentDuration)
        scrollY = min(max(0, y0 - (p.y - d.startPoint.y)), maxScrollY)
    }

    override func otherMouseUp(with event: NSEvent) { drag = nil; NSCursor.arrow.set() }

    /// What a scroll does. A mouse wheel zooms at the pointer (⇧ scrolls in time, and over
    /// the track names it scrolls the tracks); trackpad scrolling pans; ⌥ or ⌘ always zooms.
    enum WheelAction: Equatable { case zoom(CGFloat), pan(dx: CGFloat, dy: CGFloat) }

    static func wheelAction(dx: CGFloat, dy: CGFloat, precise: Bool, flags: NSEvent.ModifierFlags, overHeader: Bool) -> WheelAction {
        if flags.contains(.option) || flags.contains(.command) {
            // A wheel notch is about 1; trackpad deltas are pixels.
            return .zoom(precise ? 1 + dy * 0.01 : pow(1.15, max(-5, min(5, dy))))
        }
        if precise { return .pan(dx: dx, dy: dy) }
        if flags.contains(.shift) { return .pan(dx: (dx == 0 ? dy : dx) * 8, dy: 0) }
        if overHeader { return .pan(dx: 0, dy: dy * 8) }
        if dy == 0 { return .pan(dx: dx * 8, dy: 0) }      // a tilt wheel scrolls in time
        return .zoom(pow(1.15, max(-5, min(5, dy))))
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas, event.modifierFlags.contains(.shift), dx == 0 { dx = dy; dy = 0 }
        switch Self.wheelAction(dx: dx, dy: dy, precise: event.hasPreciseScrollingDeltas, flags: event.modifierFlags,
                                overHeader: p.x < TimelineLayout.headerWidth) {
        case .zoom(let factor):
            zoom(by: factor, around: max(p.x, TimelineLayout.headerWidth))
        case .pan(let px, let py):
            scrollTime = min(max(0, scrollTime - Double(px / pixelsPerSecond)), contentDuration)
            scrollY = min(max(0, scrollY - py), maxScrollY)
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil).x)
    }

    func zoom(by factor: CGFloat, around x: CGFloat) {
        let anchor = layout.time(for: x)
        let range = TimelineLayout.zoomRange(duration: project.duration, fps: project.fps, width: bounds.width)
        pixelsPerSecond = min(max(pixelsPerSecond * factor, range.lowerBound), range.upperBound)
        scrollTime = max(0, anchor - Double((x - TimelineLayout.headerWidth) / pixelsPerSecond))
    }

    func zoomAroundPlayhead(_ factor: CGFloat) {
        let x = layout.x(for: editor.playhead)
        zoom(by: factor, around: (TimelineLayout.headerWidth...bounds.width).contains(x) ? x : bounds.midX)
    }

    func zoomToFit() {
        pixelsPerSecond = TimelineLayout.zoomRange(duration: project.duration, fps: project.fps, width: bounds.width).lowerBound
        scrollTime = 0
    }

    /// Scroll while dragging near the left/right edges.
    private func autoscroll(at p: CGPoint) {
        let margin: CGFloat = 30
        if p.x > bounds.width - margin { scrollTime += Double(8 / pixelsPerSecond) }
        else if p.x < TimelineLayout.headerWidth + margin && p.x > TimelineLayout.headerWidth { scrollTime = max(0, scrollTime - Double(8 / pixelsPerSecond)) }
    }

    /// Keep the playhead visible: continuous scrolling while playing, recentering after jumps.
    /// Without a scroll only the playhead layer moves and the timecode box repaints.
    private func followPlayhead(_ t: Double) {
        let scrubbing: Bool = { if case .scrub? = drag?.kind { return true }; return false }()
        let next = scrubbing ? scrollTime : layout.scrollTimeFollowing(t, playing: editor.isPlaying)
        if next != scrollTime { scrollTime = next; return }
        updatePlayheadLayer(layout, at: t)
        setNeedsDisplay(playheadTimecodeRect)
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
        case (_, "=") where cmd, (_, "+") where cmd: zoomAroundPlayhead(1.5)
        case (_, "-") where cmd: zoomAroundPlayhead(1 / 1.5)
        case (_, "0") where cmd: zoomToFit()
        case (_, "s") where !cmd: snappingEnabled.toggle()
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

    // MARK: Drop assets from the panel, or files from the Finder

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Where it was dropped, read now: the view can scroll or zoom while files import.
        let p = convert(sender.draggingLocation, from: nil)
        let l = layout
        let time = max(0, l.time(for: p.x)), row = l.row(atY: p.y)
        let ids = (sender.draggingPasteboard.string(forType: .string) ?? "")
            .split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        if !ids.isEmpty {
            placeDropped(ids.compactMap { project.asset($0) }, at: time, on: row)
            return true
        }
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        // Files from the Finder go into the assets first (a file the project has is reused).
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (assets, errors) = await self.editor.importAssets(urls, reuseExisting: true)
            self.placeDropped(assets, at: time, on: row)
            if let error = errors.first, let window = self.window { NSAlert(error: error).beginSheetModal(for: window) { _ in } }
        }
        return true
    }

    /// Videos and images go where they're dropped (on the video track under the pointer, else
    /// the bottom one), one after another. A song replaces the song (the timeline has one). A
    /// lyrics file replaces all the lyrics, after asking.
    private func placeDropped(_ assets: [Asset], at dropTime: Double, on row: TimelineRow?) {
        var time = dropTime
        let visuals = assets.filter { $0.kind == .video || $0.kind == .image }
        if !visuals.isEmpty {
            var track = 0
            if case .video(let t)? = row { track = t }
            var lastID: UUID?
            editor.edit(visuals.count > 1 ? "Add Clips" : "Add Clip") { p in
                for a in visuals {
                    lastID = p.addClip(assetID: a.id, track: track, at: time)
                    if let id = lastID, let c = p.videoTracks[track].clips.first(where: { $0.id == id }) { time = c.end }
                }
            }
            if let lastID { editor.selection = .clip(lastID) }
        }
        if let audio = assets.first(where: { $0.kind == .audio }) {
            editor.edit(project.audio == nil ? "Add Audio" : "Replace Audio") { $0.setAudio(assetID: audio.id) }
            Task { await editor.waveforms.ensureWaveform(for: audio) }
        }
        if let lyrics = assets.first(where: { $0.kind == .lyrics }) {
            var track = 0
            if case .lyric(let t)? = row { track = t }
            editor.placeLyrics(lyrics, track: track, at: dropTime, window: window)
        }
    }
}

private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
