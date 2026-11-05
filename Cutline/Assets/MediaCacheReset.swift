import Foundation

/// Rebuilding the slow caches (R43): thumbnails and waveforms, music analysis, and proxies.
/// The render cache (Clear Cache) is separate; neither touches the other's files, and
/// nothing here changes the project itself (lyric timing and edits live in project.json).
enum MediaCacheKind: String, CaseIterable, Identifiable {
    case thumbnails, analysis, proxies
    var id: String { rawValue }

    var title: String {
        switch self {
        case .thumbnails: "Thumbnails and waveforms"
        case .analysis: "Music analysis (vocal stem, beats, sections)"
        case .proxies: "Proxies"
        }
    }

    var detail: String {
        switch self {
        case .thumbnails: "Asset and timeline pictures and the audio waveform."
        case .analysis: "Runs the song analysis again. Your beat and section fixes are kept."
        case .proxies: "Re-encodes every proxy at its current size."
        }
    }
}

extension EditorModel {
    /// The files a kind owns inside the package.
    func mediaCacheFiles(_ kind: MediaCacheKind) -> [URL] {
        let fm = FileManager.default
        func list(_ folder: String, _ keep: (String) -> Bool) -> [URL] {
            guard let dir = self.folder(folder) else { return [] }
            return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter(keep).map { dir.appendingPathComponent($0) }
        }
        switch kind {
        case .thumbnails: return list("thumbnails") { _ in true } + list("analysis") { $0.hasPrefix("waveform-") }
        case .analysis: return list("analysis") { $0.hasPrefix("audio-") || $0.hasPrefix("vocals-") }
        case .proxies: return list("proxies") { _ in true }
        }
    }

    func mediaCacheBytes(_ kind: MediaCacheKind) -> Int64 {
        mediaCacheFiles(kind).reduce(0) { total, url in
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            return total + Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
    }

    /// Delete the chosen kinds and rebuild them through the normal builders.
    @MainActor
    func resetMediaCaches(_ kinds: Set<MediaCacheKind>) async {
        guard !kinds.isEmpty, mediaResetMessage == nil else { return }
        defer { mediaResetMessage = nil }
        let fm = FileManager.default
        if kinds.contains(.thumbnails) {
            mediaResetMessage = "Rebuilding thumbnails and waveforms…"
            mediaCacheFiles(.thumbnails).forEach { try? fm.removeItem(at: $0) }
            thumbnails.removeAll()
            waveforms.removeAll()
            for a in project.assets {
                switch a.kind {
                case .video, .image: await thumbnails.ensureThumbnail(for: a)
                case .audio: await waveforms.ensureWaveform(for: a)
                case .lyrics: break
                }
            }
        }
        if kinds.contains(.analysis) {
            mediaResetMessage = "Rebuilding music analysis…"
            mediaCacheFiles(.analysis).forEach { try? fm.removeItem(at: $0) }
            if let audio = project.audio, let asset = project.asset(audio.assetID) {
                audioAnalysis.ensure(for: asset, force: true)
                await audioAnalysis.wait()
            }
        }
        if kinds.contains(.proxies) {
            // Files no asset uses go; every proxy in use is re-encoded at its scale (the new
            // file replaces the old one, so preview keeps working meanwhile).
            let used = Set(project.assets.compactMap { $0.proxy?.fileName })
            mediaCacheFiles(.proxies).filter { !used.contains($0.lastPathComponent) }.forEach { try? fm.removeItem(at: $0) }
            let proxied = project.assets.filter { $0.proxy != nil }
            for (i, a) in proxied.enumerated() {
                guard let scale = a.proxy?.scale else { continue }
                mediaResetMessage = "Rebuilding proxies \(i + 1) of \(proxied.count)…"
                try? await createProxy(assetID: a.id, scale: scale)
            }
        }
    }
}
