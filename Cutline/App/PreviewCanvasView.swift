import AVFoundation
import AppKit
import Combine

/// Geometry shared by the canvas view and its tests: where the project canvas sits in the
/// view (fit × zoom, centered, panned) and where a clip sits on the canvas.
struct PreviewGeometry {
    var viewSize: CGSize
    var canvas: CGSize
    /// nil = fit to view.
    var zoom: CGFloat?
    var pan: CGPoint

    var fitScale: CGFloat { min(viewSize.width / max(canvas.width, 1), viewSize.height / max(canvas.height, 1)) }
    var scale: CGFloat { zoom.map { $0 } ?? fitScale }

    /// Canvas rectangle in view coordinates (view is y-down).
    var canvasRect: CGRect {
        let w = canvas.width * scale, h = canvas.height * scale
        return CGRect(x: (viewSize.width - w) / 2 + pan.x, y: (viewSize.height - h) / 2 + pan.y, width: w, height: h)
    }

    /// Canvas point (y-up, pixels) → view point.
    func viewPoint(_ p: CGPoint) -> CGPoint {
        let r = canvasRect
        return CGPoint(x: r.minX + p.x * scale, y: r.minY + (canvas.height - p.y) * scale)
    }

    func canvasPoint(_ v: CGPoint) -> CGPoint {
        let r = canvasRect
        return CGPoint(x: (v.x - r.minX) / scale, y: canvas.height - (v.y - r.minY) / scale)
    }

    /// Clip rectangle on the canvas (y-up), same rule as the renderer's placement.
    static func clipRect(source: CGSize, transform: ClipTransform, canvas: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0 else { return .zero }
        let fit = min(canvas.width / source.width, canvas.height / source.height) * transform.scale
        let w = source.width * fit, h = source.height * fit
        return CGRect(x: canvas.width / 2 - w / 2 + transform.offsetX, y: canvas.height / 2 - h / 2 + transform.offsetY, width: w, height: h)
    }

    func viewRect(ofCanvasRect r: CGRect) -> CGRect {
        let a = viewPoint(CGPoint(x: r.minX, y: r.maxY)), b = viewPoint(CGPoint(x: r.maxX, y: r.minY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }
}

/// Preview surface: the player, viewport zoom/pan, and on-canvas move/scale of the selected clip.
final class PreviewCanvasView: NSView {
    private let playerLayer: AVPlayerLayer
    private let overlay = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    /// Platform UI zones (portrait projects, preview only): tinted rectangles with labels.
    private let platformLayer = CALayer()
    private let editor: EditorModel
    private let controller: PreviewController
    private var cancellables: Set<AnyCancellable> = []

    private enum DragMode { case move, scale(anchor: CGPoint), pan, moveLines([UUID: CGPoint]) }
    private var drag: (mode: DragMode, start: CGPoint, original: Project, clip: Clip?, startPan: CGPoint)?

    init(controller: PreviewController, editor: EditorModel) {
        self.controller = controller
        self.editor = editor
        playerLayer = AVPlayerLayer(player: controller.player)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resize
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
        overlay.fillColor = nil
        overlay.strokeColor = NSColor.controlAccentColor.cgColor
        overlay.lineWidth = 1.5
        handlesLayer.fillColor = NSColor.white.cgColor
        handlesLayer.strokeColor = NSColor.controlAccentColor.cgColor
        handlesLayer.lineWidth = 1.5
        layer?.addSublayer(platformLayer)
        layer?.addSublayer(overlay)
        layer?.addSublayer(handlesLayer)
        let relayout: () -> Void = { [weak self] in self?.needsLayout = true }
        controller.$zoom.sink { _ in DispatchQueue.main.async(execute: relayout) }.store(in: &cancellables)
        controller.$pan.sink { _ in DispatchQueue.main.async(execute: relayout) }.store(in: &cancellables)
        editor.objectWillChange.sink { _ in DispatchQueue.main.async(execute: relayout) }.store(in: &cancellables)
        // The selection overlay depends on what is on screen at the playhead; skip the
        // relayout during playback when nothing is selected.
        editor.transport.$playhead.removeDuplicates().sink { [weak self] _ in
            guard let self, self.editor.selection != .none else { return }
            DispatchQueue.main.async(execute: relayout)
        }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var geometry: PreviewGeometry {
        PreviewGeometry(viewSize: bounds.insetBy(dx: 12, dy: 12).size, canvas: editor.project.canvas.cgSize,
                        zoom: controller.zoom, pan: controller.pan)
    }

    private func viewRect(_ g: PreviewGeometry) -> CGRect { g.canvasRect.offsetBy(dx: 12, dy: 12) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let g = geometry
        playerLayer.frame = viewRect(g)
        layoutPlatformZones(g)
        let fit = Int((g.fitScale * 100).rounded())
        if controller.fitPercent != fit { DispatchQueue.main.async { self.controller.fitPercent = fit } }
        let lineRects = selectedLineViewRects(g)
        if !lineRects.isEmpty {
            let path = CGMutablePath()
            lineRects.forEach { path.addRect($0) }
            overlay.path = path
            handlesLayer.path = nil
        } else if let r = selectedClipViewRect(g) {
            overlay.path = CGPath(rect: r, transform: nil)
            let handles = CGMutablePath()
            for c in corners(r) { handles.addEllipse(in: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)) }
            handlesLayer.path = handles
        } else {
            overlay.path = nil
            handlesLayer.path = nil
        }
        CATransaction.commit()
    }

    /// Draws the zones of the platform overlays switched on, so lyrics and titles can be kept
    /// clear of the app's buttons and captions. Never part of the render or export.
    private func layoutPlatformZones(_ g: PreviewGeometry) {
        platformLayer.sublayers = nil
        let p = editor.project
        guard p.type.isPortrait, let ids = p.platformOverlays, !ids.isEmpty else { return }
        let colors: [NSColor] = [.systemPink, .systemTeal, .systemOrange]
        for (i, overlay) in PlatformOverlay.all.enumerated() where ids.contains(overlay.id) {
            let color = colors[i % colors.count]
            for (zone, rect) in zip(overlay.zones, overlay.rects(on: p.canvas)) {
                let r = g.viewRect(ofCanvasRect: rect).offsetBy(dx: 12, dy: 12)
                let box = CALayer()
                box.frame = r
                box.backgroundColor = color.withAlphaComponent(0.18).cgColor
                box.borderColor = color.withAlphaComponent(0.8).cgColor
                box.borderWidth = 1
                let label = CATextLayer()
                label.string = "\(overlay.name): \(zone.name)"
                label.fontSize = 10
                label.foregroundColor = NSColor.white.cgColor
                label.contentsScale = window?.backingScaleFactor ?? 2
                label.isWrapped = true
                label.frame = r.insetBy(dx: 4, dy: 3)
                box.addSublayer(label)
                label.frame = CGRect(x: 4, y: 3, width: max(0, r.width - 8), height: max(0, r.height - 6))
                platformLayer.addSublayer(box)
            }
        }
    }

    private func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    private func sourceSize(_ clip: Clip) -> CGSize? {
        editor.project.asset(clip.assetID)?.pixelSize.map { $0.cgSize }
    }

    private func clipViewRect(_ clip: Clip, _ g: PreviewGeometry) -> CGRect? {
        guard let s = sourceSize(clip) else { return nil }
        return g.viewRect(ofCanvasRect: PreviewGeometry.clipRect(source: s, transform: clip.transform, canvas: g.canvas)).offsetBy(dx: 12, dy: 12)
    }

    private func selectedClipViewRect(_ g: PreviewGeometry) -> CGRect? {
        guard let clip = editor.selectedClip, editor.playhead >= clip.start, editor.playhead < clip.end else { return nil }
        return clipViewRect(clip, g)
    }

    private func lyricRenderer() -> LyricRenderer { LyricRenderer(project: editor.project) }

    /// Lyric lines drawn at the playhead with their view rectangles.
    private func visibleLineRects(_ g: PreviewGeometry) -> [(LyricLine, CGRect)] {
        lyricRenderer().placedLines(at: editor.playhead).map { ($0.line, g.viewRect(ofCanvasRect: $0.rect).offsetBy(dx: 12, dy: 12)) }
    }

    private func selectedLineViewRects(_ g: PreviewGeometry) -> [CGRect] {
        visibleLineRects(g).filter { editor.isSelected(.lyricLine($0.0.id)) }.map(\.1)
    }

    /// Start a drag of lyric lines: the clicked one, plus any other selected visible lines.
    private func beginLineDrag(_ line: LyricLine, at p: CGPoint, event: NSEvent) {
        if event.modifierFlags.contains(.command) { editor.toggleSelected(.lyricLine(line.id)); return }
        if !editor.isSelected(.lyricLine(line.id)) { editor.selection = .lyricLine(line.id) }
        let placed = lyricRenderer().placedLines(at: editor.playhead)
        var starts: [UUID: CGPoint] = [:]
        for pl in placed where editor.isSelected(.lyricLine(pl.line.id)) { starts[pl.line.id] = CGPoint(x: pl.rect.midX, y: pl.rect.midY) }
        drag = (.moveLines(starts), p, editor.project, nil, controller.pan)
        NSCursor.closedHand.set()
    }

    /// Topmost clip under the point at the playhead.
    private func clip(at p: CGPoint) -> Clip? {
        let g = geometry
        for track in editor.project.videoTracks.reversed() {
            for c in track.clips where editor.playhead >= c.start && editor.playhead < c.end {
                if let r = clipViewRect(c, g), r.contains(p) { return c }
            }
        }
        return nil
    }

    // MARK: Mouse

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let original = editor.project
        if event.modifierFlags.contains(.option) || event.clickCount == 0 {
            drag = (.pan, p, original, nil, controller.pan); return
        }
        let g = geometry
        // Lyric lines sit above video, so they are hit first. Words are never picked alone.
        if let (line, _) = visibleLineRects(g).last(where: { $0.1.insetBy(dx: -4, dy: -4).contains(p) }) {
            beginLineDrag(line, at: p, event: event)
            return
        }
        if let r = selectedClipViewRect(g), let clip = editor.selectedClip {
            if let corner = corners(r).first(where: { hypot($0.x - p.x, $0.y - p.y) < 9 }) {
                _ = corner   // scaling is uniform around the clip center
                drag = (.scale(anchor: CGPoint(x: r.midX, y: r.midY)), p, original, clip, controller.pan)
                return
            }
            if r.contains(p) { drag = (.move, p, original, clip, controller.pan); NSCursor.closedHand.set(); return }
        }
        if let hit = clip(at: p) {
            editor.selection = .clip(hit.id)
            drag = (.move, p, editor.project, hit, controller.pan)
            NSCursor.closedHand.set()
        } else {
            editor.selection = .none
            drag = (.pan, p, original, nil, controller.pan)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        let g = geometry
        switch d.mode {
        case .pan:
            guard controller.zoom != nil else { return }   // nothing to pan when fitted
            controller.pan = CGPoint(x: d.startPan.x + p.x - d.start.x, y: d.startPan.y + p.y - d.start.y)
        case .move:
            guard let clip = d.clip else { return }
            var next = d.original
            let dx = Double((p.x - d.start.x) / g.scale), dy = Double(-(p.y - d.start.y) / g.scale)
            var ox = clip.transform.offsetX + dx, oy = clip.transform.offsetY + dy
            // Snap back to center when close (6 view px).
            if abs(ox) * Double(g.scale) < 6 && !event.modifierFlags.contains(.command) { ox = 0 }
            if abs(oy) * Double(g.scale) < 6 && !event.modifierFlags.contains(.command) { oy = 0 }
            next.updateClip(clip.id) { $0.transform.offsetX = ox.rounded(); $0.transform.offsetY = oy.rounded() }
            editor.replaceWithoutUndo(next)
        case .moveLines(let starts):
            var next = d.original
            let dx = Double((p.x - d.start.x) / g.scale), dy = Double(-(p.y - d.start.y) / g.scale)
            for (id, c) in starts {
                guard let loc = next.lineLocation(id) else { continue }
                next.lyricTracks[loc.track].lines[loc.index].centerX = (Double(c.x) + dx).rounded()
                next.lyricTracks[loc.track].lines[loc.index].centerY = (Double(c.y) + dy).rounded()
            }
            editor.replaceWithoutUndo(next)
        case .scale(let center):
            guard let clip = d.clip else { return }
            let d0 = hypot(d.start.x - center.x, d.start.y - center.y), d1 = hypot(p.x - center.x, p.y - center.y)
            guard d0 > 1 else { return }
            var next = d.original
            let s = min(max(clip.transform.scale * Double(d1 / d0), 0.05), 10)
            next.updateClip(clip.id) { $0.transform.scale = (s * 1000).rounded() / 1000 }
            editor.replaceWithoutUndo(next)
        }
        needsLayout = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; NSCursor.arrow.set() }
        guard let d = drag else { return }
        if case .moveLines = d.mode {
            let final = editor.project
            guard final != d.original else { return }
            editor.replaceWithoutUndo(d.original)
            editor.edit("Move Lyrics") { $0 = final }
            return
        }
        guard d.clip != nil else { return }
        let final = editor.project
        guard final != d.original else { return }
        editor.replaceWithoutUndo(d.original)
        if case .scale = d.mode { editor.edit("Scale Clip") { $0 = final } } else { editor.edit("Move Clip") { $0 = final } }
    }

    override func otherMouseDown(with event: NSEvent) { drag = (.pan, convert(event.locationInWindow, from: nil), editor.project, nil, controller.pan) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { drag = nil }

    /// Mouse wheel zooms at the pointer. A trackpad's two-finger scroll pans (pinch zooms);
    /// hold ⌥ on a trackpad to zoom with scrolling instead.
    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let isTrackpad = event.hasPreciseScrollingDeltas
        if !isTrackpad || event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            let dy = isTrackpad ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
            guard dy != 0 else { return }
            zoom(by: max(0.5, min(1.5, 1 + dy)), at: p)
            return
        }
        if controller.zoom == nil { controller.zoom = geometry.fitScale }
        controller.pan = CGPoint(x: controller.pan.x + event.scrollingDeltaX, y: controller.pan.y + event.scrollingDeltaY)
    }

    override func magnify(with event: NSEvent) { zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil)) }

    /// Zoom keeping the canvas point under `p` fixed.
    func zoom(by factor: CGFloat, at p: CGPoint) {
        let g = geometry
        let local = CGPoint(x: p.x - 12, y: p.y - 12)
        let canvasP = g.canvasPoint(local)
        let newScale = min(max(g.scale * factor, 0.05), 8)
        controller.zoom = newScale
        var g2 = g; g2.zoom = newScale; g2.pan = .zero
        let unpanned = g2.viewPoint(canvasP)
        controller.pan = CGPoint(x: local.x - unpanned.x, y: local.y - unpanned.y)
    }

    override func keyDown(with event: NSEvent) {
        guard let clip = editor.selectedClip else { super.keyDown(with: event); return }
        let step = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
        var dx = 0.0, dy = 0.0
        switch event.keyCode {
        case 123 where event.modifierFlags.contains(.option): dx = -step
        case 124 where event.modifierFlags.contains(.option): dx = step
        case 125 where event.modifierFlags.contains(.option): dy = -step
        case 126 where event.modifierFlags.contains(.option): dy = step
        default: super.keyDown(with: event); return
        }
        editor.edit("Nudge Clip") { $0.updateClip(clip.id) { $0.transform.offsetX += dx; $0.transform.offsetY += dy } }
    }
}
