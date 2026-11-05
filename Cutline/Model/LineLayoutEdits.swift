import CoreGraphics
import Foundation

extension LineLayout {
    /// The left edge of a line's box from its anchor x (see `LyricLine.centerX`).
    static func boxMinX(anchor: CGFloat, width: CGFloat, align: Align) -> CGFloat {
        switch align {
        case .left: anchor
        case .center: anchor - width / 2
        case .right: anchor - width
        }
    }

    /// The anchor x for a box whose middle is at `midX`.
    static func anchor(boxMidX midX: CGFloat, width: CGFloat, align: Align) -> CGFloat {
        switch align {
        case .left: midX - width / 2
        case .center: midX
        case .right: midX + width / 2
        }
    }
}

extension Project {
    /// Projects saved before line layouts (schema 1) stored a positioned line's box middle in
    /// `centerX`; those lines become centre-aligned so they stay exactly where they were.
    mutating func migrateLineLayouts() {
        guard schemaVersion < 2 else { return }
        for t in lyricTracks.indices {
            for l in lyricTracks[t].lines.indices where lyricTracks[t].lines[l].hasPosition && lyricTracks[t].lines[l].layoutValue == nil {
                lyricTracks[t].lines[l].layout = LineLayout(align: .center)
            }
        }
        schemaVersion = projectSchemaVersion
    }
}

extension EditorModel {
    /// Change the layout of the placement lines (one undo step). Switching mode or width keeps a
    /// positioned line's anchor, so the text grows away from it; changing the alignment keeps
    /// the line's box where it is and moves the anchor to the box's new reference edge.
    func setLineLayout(_ name: String, live: Bool = false, _ change: (inout LineLayout) -> Void) {
        let ids = placementLineIDs
        guard !ids.isEmpty else { return }
        let renderer = LyricRenderer(project: project)
        let update: (inout Project) -> Void = { p in
            for id in ids {
                guard let loc = p.lineLocation(id) else { continue }
                var line = p.lyricTracks[loc.track].lines[loc.index]
                let before = line.layout
                var after = before
                change(&after)
                after.width = max(0, after.width)
                guard after != before else { continue }
                if after.align != before.align, let x = line.centerX, let w = renderer.box(of: line)?.size.width {
                    let mid = LineLayout.boxMinX(anchor: CGFloat(x), width: w, align: before.align) + w / 2
                    line.centerX = Double(LineLayout.anchor(boxMidX: mid, width: w, align: after.align)).rounded()
                }
                line.layout = after
                p.lyricTracks[loc.track].lines[loc.index] = line
            }
        }
        if live { liveEdit(update) } else { edit(name, update) }
    }
}

extension EditorModel {
    /// Switch the placement lines between single line and wrapped. A line wrapped for the first
    /// time starts at its current text width (at most 90% of the frame), so it doesn't jump.
    func setLineMode(_ mode: LineLayout.Mode) {
        let ids = placementLineIDs
        let renderer = LyricRenderer(project: project)
        let pad = ceil(LyricLayout.fontSize(project.lyricStyle, canvas: project.canvas) * 0.15)
        let limit = Double(project.canvas.width) * 0.9
        edit(mode == .wrapped ? "Wrap Lyric Lines" : "Single-Line Lyrics") { p in
            for id in ids {
                guard let loc = p.lineLocation(id) else { continue }
                var line = p.lyricTracks[loc.track].lines[loc.index]
                guard line.layout.mode != mode else { continue }
                var layout = line.layout
                if mode == .wrapped, line.layoutValue == nil || layout.width == LineLayout().width,
                   let w = renderer.box(of: line)?.size.width {
                    layout.width = min(Double(w - pad * 2), limit).rounded()
                }
                layout.mode = mode
                line.layout = layout
                p.lyricTracks[loc.track].lines[loc.index] = line
            }
        }
    }
}

extension Project {
    /// After a timeline drag: words whose start or end changed are marked hand-edited, so
    /// re-aligning asks before replacing them.
    mutating func markHandEditedWords(comparedTo before: Project) {
        let old = Dictionary(before.lyricTracks.flatMap(\.lines).flatMap(\.words).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for t in lyricTracks.indices {
            for l in lyricTracks[t].lines.indices {
                for w in lyricTracks[t].lines[l].words.indices {
                    let word = lyricTracks[t].lines[l].words[w]
                    guard let o = old[word.id], o.start != word.start || o.end != word.end else { continue }
                    lyricTracks[t].lines[l].words[w].handEdited = true
                }
            }
        }
    }
}
