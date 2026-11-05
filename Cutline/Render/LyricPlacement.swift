import CoreGraphics
import Foundation

/// Alignment of lyric lines on the canvas (y up), with padding from the frame edges.
enum LyricPlacement {
    enum Horizontal { case left, center, right }
    enum Vertical { case top, center, bottom }

    static func x(for h: Horizontal, width: CGFloat, canvas: CGSize, padding: CGFloat) -> CGFloat {
        switch h {
        case .left: padding + width / 2
        case .center: canvas.width / 2
        case .right: canvas.width - padding - width / 2
        }
    }

    /// Vertical centers for lines stacked top to bottom with `gap` between them; the whole
    /// block is aligned as one. A single line is the same rule with one entry.
    static func stackedY(_ v: Vertical, heights: [CGFloat], canvas: CGSize, padding: CGFloat, gap: CGFloat) -> [CGFloat] {
        guard !heights.isEmpty else { return [] }
        let block = heights.reduce(0, +) + gap * CGFloat(heights.count - 1)
        var top: CGFloat
        switch v {
        case .top: top = canvas.height - padding
        case .center: top = canvas.height / 2 + block / 2
        case .bottom: top = padding + block
        }
        var out: [CGFloat] = []
        for h in heights {
            out.append(top - h / 2)
            top -= h + gap
        }
        return out
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

    func alignLines(horizontal: LyricPlacement.Horizontal?, vertical: LyricPlacement.Vertical?, padding: Double, gap: Double) {
        let ids = placementLineIDs
        guard !ids.isEmpty else { return }
        let renderer = LyricRenderer(project: project)
        let canvas = project.canvas.cgSize
        let sizes = ids.map { id in line(id).flatMap(renderer.size(of:)) ?? .zero }
        let ys = vertical.map { LyricPlacement.stackedY($0, heights: sizes.map(\.height), canvas: canvas, padding: padding, gap: gap) }
        edit("Align Lyrics") { p in
            for (i, id) in ids.enumerated() {
                guard let loc = p.lineLocation(id) else { continue }
                var l = p.lyricTracks[loc.track].lines[loc.index]
                let auto = renderer.placedLines(at: l.start + 0.001).first { $0.line.id == id }?.rect
                if let h = horizontal { l.centerX = Double(LyricPlacement.x(for: h, width: sizes[i].width, canvas: canvas, padding: padding)) }
                else if l.centerX == nil { l.centerX = Double(auto?.midX ?? canvas.width / 2) }
                if let ys { l.centerY = Double(ys[i]) }
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
