import Foundation

/// Start a project from another one (R40): a one-time copy of the song, lyric timing, clips and
/// track layout. Everything gets new IDs and the package caches are copied, so the two
/// projects share nothing afterwards.
enum ProjectImport {
    struct Result {
        var project: Project
        /// Source asset ID → imported asset ID.
        var assetIDs: [UUID: UUID]
    }

    /// The imported model for a project of `type` on `canvas`.
    /// - Clips are centred on the new canvas and cover it as much as they covered the old one.
    /// - Lyric lines go back to automatic placement (the old positions were for another frame).
    /// - Cinemascope is kept only for a music video.
    /// - With `fps`, the new project runs at that rate (chosen in New Project) and every time
    ///   moves onto its frame grid; without, it keeps the source's rate.
    static func make(from source: Project, type: ProjectType, canvas: CanvasSize, fps: Double? = nil) -> Result {
        var p = Project(type: type, canvas: canvas)
        p.fps = source.fps
        p.fpsLocked = source.fpsLocked

        var ids: [UUID: UUID] = [:]
        p.assets = source.assets.map { a in
            var c = a
            c.id = UUID()
            ids[a.id] = c.id
            if let proxy = a.proxy { c.proxy = ProxyInfo(scale: proxy.scale, fileName: ProxyManager.fileName(for: c.id)) }
            return c
        }
        if var audio = source.audio, let id = ids[audio.assetID] {
            audio.assetID = id
            p.audio = audio
        }
        p.videoTracks = source.videoTracks.map { t in
            VideoTrack(clips: t.clips.compactMap { c in
                guard let id = ids[c.assetID] else { return nil }
                var n = c
                n.id = UUID()
                n.assetID = id
                n.transform.offsetX = 0
                n.transform.offsetY = 0
                // Keep how much the clip covers the frame: a video that filled the old canvas
                // fills the new one (a 16:9 shot in a 9:16 ad), and one zoomed in stays zoomed.
                if let a = source.asset(c.assetID) {
                    n.transform.scale = c.transform.scale / Project.fillScale(for: a, canvas: source.canvas) * Project.fillScale(for: a, canvas: canvas)
                }
                return n
            })
        }
        if p.videoTracks.isEmpty { p.videoTracks = [VideoTrack()] }
        p.lyricTracks = source.lyricTracks.map { t in
            LyricTrack(lines: t.lines.map { l in
                var n = l
                n.id = UUID()
                n.centerX = nil
                n.centerY = nil
                n.words = l.words.map { w in var c = w; c.id = UUID(); return c }
                return n
            })
        }
        if p.lyricTracks.isEmpty { p.lyricTracks = [LyricTrack()] }
        p.lyricStyle = source.lyricStyle
        p.beatCorrections = source.beatCorrections
        p.lyricsLanguage = source.lyricsLanguage
        if type == .musicVideo && source.type == .musicVideo { p.cinemascope = source.cinemascope }
        if let fps, abs(fps - p.fps) > 1e-9 || !p.fpsLocked {
            p.fps = fps
            p.fpsLocked = true
            p.snapAllToFrameGrid()
        }
        return Result(project: p, assetIDs: ids)
    }

    /// Copy the source package's caches into the new project's folders so nothing is computed
    /// again: song analysis and vocal stem (named by the song's hash), and the waveforms,
    /// thumbnails and proxies (renamed to the new asset IDs). The render cache is not copied:
    /// it is keyed by content, and a different canvas renders different frames anyway.
    static func copyCaches(from sourcePackage: URL, source: Project, ids: [UUID: UUID], into folder: (String) -> URL?) {
        let fm = FileManager.default
        func copy(_ src: URL, to dst: URL) {
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { return }
            try? fm.copyItem(at: src, to: dst)
        }
        let srcAnalysis = sourcePackage.appendingPathComponent("analysis")
        if let dst = folder("analysis") {
            for name in (try? fm.contentsOfDirectory(atPath: srcAnalysis.path)) ?? [] {
                if name.hasPrefix("audio-") || name.hasPrefix("vocals-") {
                    copy(srcAnalysis.appendingPathComponent(name), to: dst.appendingPathComponent(name))
                }
            }
            for (old, new) in ids {
                copy(srcAnalysis.appendingPathComponent("waveform-\(old.uuidString).plist"),
                     to: dst.appendingPathComponent("waveform-\(new.uuidString).plist"))
            }
        }
        if let dst = folder("thumbnails") {
            for (old, new) in ids {
                copy(sourcePackage.appendingPathComponent("thumbnails/\(old.uuidString).png"), to: dst.appendingPathComponent("\(new.uuidString).png"))
            }
        }
        if let dst = folder("proxies") {
            for a in source.assets {
                guard let proxy = a.proxy, let new = ids[a.id] else { continue }
                copy(sourcePackage.appendingPathComponent("proxies/\(proxy.fileName)"), to: dst.appendingPathComponent(ProxyManager.fileName(for: new)))
            }
        }
    }

    /// Proxies whose file didn't come across (deleted or never finished) are dropped.
    static func dropMissingProxies(_ p: inout Project, in folder: URL?) {
        for i in p.assets.indices {
            guard let proxy = p.assets[i].proxy else { continue }
            let exists = folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(proxy.fileName).path) } ?? false
            if !exists { p.assets[i].proxy = nil }
        }
    }
}

extension ProjectImport {
    /// A new, untitled document of `type` on `canvas` holding the import of the project at `url`.
    @MainActor
    static func document(importing url: URL, type: ProjectType, canvas: CanvasSize, fps: Double? = nil) throws -> ProjectDocument {
        let (source, _) = try ProjectDocument.load(from: url)
        var result = make(from: source, type: type, canvas: canvas, fps: fps)
        let doc = ProjectDocument()
        copyCaches(from: url, source: source, ids: result.assetIDs) { doc.folder($0) }
        dropMissingProxies(&result.project, in: doc.folder("proxies"))
        doc.editor.replaceWithoutUndo(result.project)
        // Untitled and unsaved: closing it asks to save rather than dropping the import.
        doc.updateChangeCount(.changeDone)
        return doc
    }
}
