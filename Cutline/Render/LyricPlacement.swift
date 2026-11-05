import CoreGraphics
import Foundation

/// Alignment of lyric lines on the canvas (y up), with padding from the frame edges.
enum LyricPlacement {
    enum Horizontal { case left, center, right }
    enum Vertical { case top, center, bottom }

    /// A line's box as drawn (canvas pixels) and where its letters actually are inside it
    /// (`ink`, box coordinates, y up). Padding is measured to the letters, not the box, so a
    /// line looks the same distance from every edge.
    struct Box: Equatable {
        var size: CGSize
        var ink: CGRect
        init(size: CGSize, ink: CGRect? = nil) { self.size = size; self.ink = ink ?? CGRect(origin: .zero, size: size) }
    }

    /// Centre x for a line so its letters sit `padding` from the left or right edge (or centred).
    static func x(for h: Horizontal, box: Box, canvasWidth w: CGFloat, padding: CGFloat) -> CGFloat {
        let half = box.size.width / 2
        switch h {
        case .left: return padding + half - box.ink.minX
        case .center: return w / 2 + half - box.ink.midX
        case .right: return w - padding - (box.ink.maxX - half)
        }
    }

    /// Centre y for lines stacked top to bottom with `gap` between their boxes, the block
    /// aligned as one inside `frame` (the full frame's height): its top letters `padding` under
    /// the top edge, its bottom letters `padding` over the bottom edge, or the letters
    /// centred. A single line is the same rule.
    static func stackedY(_ v: Vertical, boxes: [Box], frame: ClosedRange<CGFloat>, padding: CGFloat, gap: CGFloat) -> [CGFloat] {
        guard let first = boxes.first, let last = boxes.last else { return [] }
        // Stack from y = 0 downwards, then shift the whole block into place.
        var top: CGFloat = 0
        var centers: [CGFloat] = []
        for b in boxes {
            centers.append(top - b.size.height / 2)
            top -= b.size.height + gap
        }
        let inkTop = centers[0] + first.ink.maxY - first.size.height / 2
        let inkBottom = centers[centers.count - 1] + last.ink.minY - last.size.height / 2
        let shift: CGFloat
        switch v {
        case .top: shift = frame.upperBound - padding - inkTop
        case .bottom: shift = frame.lowerBound + padding - inkBottom
        case .center: shift = (frame.lowerBound + frame.upperBound) / 2 - (inkTop + inkBottom) / 2
        }
        return centers.map { $0 + shift }
    }
}

extension EditorModel {
    /// Lines the placement tools act on: the multi-selection, else the line of a selected word.
    var placementLineIDs: [UUID] {
        var ids = selectedLineIDs
        if ids.isEmpty, case .lyricWord(let w) = selection, let loc = project.wordLocation(w) {
            ids = [project.lyricTracks[loc.track].lines[loc.line].id]
        }
        if ids.isEmpty, case .lyricLine(let l) = selection { ids = [l] }
        // Top to bottom = track order, then time.
        return ids.sorted {
            let a = project.lineLocation($0), b = project.lineLocation($1)
            return (a?.track ?? 0, line($0)?.start ?? 0) < (b?.track ?? 0, line($1)?.start ?? 0)
        }
    }

    /// Align the placement lines: horizontal padding from the left and right frame edges,
    /// vertical padding from the top and bottom frame edges (the full frame, never the
    /// cinemascope bars). Several lines align as one stacked block; each line's letters get
    /// the same left (or right) edge.
    func alignLines(horizontal: LyricPlacement.Horizontal?, vertical: LyricPlacement.Vertical?, paddingX: Double, paddingY: Double, gap: Double) {
        let ids = placementLineIDs
        guard !ids.isEmpty else { return }
        let renderer = LyricRenderer(project: project)
        let canvas = project.canvas.cgSize
        let boxes = ids.map { id in line(id).flatMap(renderer.box(of:)) ?? LyricPlacement.Box(size: .zero) }
        // Always the full frame: the cinemascope bars are never a reference (set the vertical
        // padding to place lines relative to them).
        let frame = 0...canvas.height
        let ys = vertical.map { LyricPlacement.stackedY($0, boxes: boxes, frame: frame, padding: CGFloat(paddingY), gap: CGFloat(gap)) }
        edit("Align Lyrics") { p in
            for (i, id) in ids.enumerated() {
                guard let loc = p.lineLocation(id) else { continue }
                var l = p.lyricTracks[loc.track].lines[loc.index]
                let auto = renderer.placedLines(at: l.start + 0.001).first { $0.line.id == id }?.rect
                if let h = horizontal { l.centerX = Double(LyricPlacement.x(for: h, box: boxes[i], canvasWidth: canvas.width, padding: CGFloat(paddingX))).rounded() }
                else if l.centerX == nil { l.centerX = Double(auto?.midX ?? canvas.width / 2) }
                if let ys { l.centerY = Double(ys[i]).rounded() }
                else if l.centerY == nil { l.centerY = Double(auto?.midY ?? canvas.height * 0.2) }
                p.lyricTracks[loc.track].lines[loc.index] = l
            }
        }
    }

    func resetLinePositions() {
        let ids = placementLineIDs
        edit("Auto Position") { p in
            for id in ids {
                guard let loc = p.lineLocation(id) else { continue }
                p.lyricTracks[loc.track].lines[loc.index].centerX = nil
                p.lyricTracks[loc.track].lines[loc.index].centerY = nil
            }
        }
    }
}
