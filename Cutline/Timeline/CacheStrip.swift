import AppKit

/// Render cache state for the editor: the encoded export segments on disk and the preview
/// frames in memory (R32-R34, R42).
extension EditorModel {
    /// `cache/segments/` inside the project package.
    var segmentCacheURL: URL? { folder("cache").map { $0.appendingPathComponent("segments", isDirectory: true) } }

    /// Re-read which segments exist (after an export or a clear).
    @MainActor
    func segmentCacheChanged() {
        guard let dir = segmentCacheURL else { segmentFiles = []; return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        segmentFiles = Set(names.filter { $0.hasSuffix(".mov") && !$0.hasPrefix(".") })
    }

    /// Bytes used by the render cache: segments and audio on disk plus frames in memory.
    var renderCacheBytes: Int64 {
        Int64(FrameCache.shared.approximateBytes) + (segmentCacheURL.map(MediaFolders.size(of:)) ?? 0)
    }

    /// Empty the render cache (R42): preview frames and export segments. Proxies, thumbnails,
    /// waveforms and analysis are kept. Returns the bytes freed.
    @MainActor
    @discardableResult
    func clearRenderCache() -> Int64 {
        let freed = renderCacheBytes
        FrameCache.shared.removeAll()
        if let dir = segmentCacheURL { try? FileManager.default.removeItem(at: dir) }
        segmentCacheChanged()
        return freed
    }
}

/// Sizes of folders inside the package.
enum MediaFolders {
    static func size(of url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }
}

/// The strip under the ruler: each export segment is cached (green), stale (orange: an older
/// version was encoded and an edit or setting change outdated it) or uncached (none) (R33).
enum CacheStrip {
    enum State: Equatable { case cached, stale, uncached }
    static let height: CGFloat = 3

    static func states(project: Project, settings: ExportSettings, files: Set<String>) -> [(segment: SegmentExporter.Segment, state: State)] {
        guard project.duration > 0 else { return [] }
        let slots = Set(files.compactMap { $0.split(separator: "-").first.flatMap { Int($0) } })
        return SegmentExporter.segments(project: project, settings: settings).map { s in
            (s, files.contains(s.fileName) ? .cached : (slots.contains(s.index) ? .stale : .uncached))
        }
    }

    static func draw(_ states: [(segment: SegmentExporter.Segment, state: State)], layout l: TimelineLayout, width: CGFloat, y: CGFloat) {
        for (seg, state) in states where state != .uncached {
            let x0 = max(TimelineLayout.headerWidth, l.x(for: seg.start)), x1 = min(width, l.x(for: seg.end))
            guard x1 > x0 else { continue }
            (state == .cached ? NSColor.systemGreen : NSColor.systemOrange).withAlphaComponent(0.85).setFill()
            CGRect(x: x0, y: y, width: max(1, x1 - x0 - 0.5), height: height).fill()
        }
    }
}
