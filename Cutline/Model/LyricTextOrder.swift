import Foundation

/// The order lyric lines are sung in, from the lyrics file, independent of where the lines sit
/// on the timeline. Moving a line to another track or before another line never changes it,
/// so alignment always puts every line and word where it is sung.
extension Project {
    /// Lines in sung order. Lines of one lyrics file follow the file. Several files (one per
    /// import) interleave by time, each still in its own order; lines from no file go by time.
    func lyricTextOrder() -> [LyricLine] {
        var groups: [UUID?: [LyricLine]] = [:]
        for line in lyricTracks.flatMap(\.lines) { groups[line.textOrder?.group, default: []].append(line) }
        var queues: [[LyricLine]] = groups.map { key, lines in
            key == nil ? lines.sorted { $0.start < $1.start } : lines.sorted { $0.textOrder!.index < $1.textOrder!.index }
        }
        // Merge: repeatedly take the earliest-starting head (each queue keeps its own order).
        queues.sort { ($0.first?.start ?? 0) < ($1.first?.start ?? 0) }
        var out: [LyricLine] = []
        while let i = queues.indices.filter({ !queues[$0].isEmpty }).min(by: { queues[$0][0].start < queues[$1][0].start }) {
            out.append(queues[i].removeFirst())
        }
        return out
    }

    /// Give lines from before text order was kept (older projects) their place in the lyrics
    /// file, by matching each file line to a timeline line with the same words. A repeated line
    /// (a chorus) takes the earliest unmatched copy. Lines that match nothing keep no order.
    /// Returns true when anything was assigned.
    @discardableResult
    mutating func recoverTextOrder(from text: String, group: UUID) -> Bool {
        guard !lyricTracks.flatMap(\.lines).contains(where: { $0.textOrder != nil }) else { return false }
        let parsed = LyricImport.parse(text)
        var unused = lyricLineOrder().map(\.id)
        var changed = false
        for (i, p) in parsed.enumerated() {
            guard let k = unused.firstIndex(where: { id in line(id)?.words.map(\.text) == p.words }),
                  let loc = lineLocation(unused[k]) else { continue }
            lyricTracks[loc.track].lines[loc.index].textOrder = TextOrder(group: group, index: i)
            unused.remove(at: k)
            changed = true
        }
        return changed
    }

    func line(_ id: UUID) -> LyricLine? {
        guard let loc = lineLocation(id) else { return nil }
        return lyricTracks[loc.track].lines[loc.index]
    }
}
