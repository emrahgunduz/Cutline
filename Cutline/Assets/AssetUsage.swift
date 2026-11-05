import AppKit

extension Project {
    /// Number of timeline items that use the asset.
    func usageCount(of id: UUID) -> Int {
        guard let a = asset(id) else { return 0 }
        switch a.kind {
        case .video, .image: return videoTracks.flatMap(\.clips).filter { $0.assetID == id }.count
        case .audio: return audio?.assetID == id ? 1 : 0
        case .lyrics: return lyricTracks.flatMap(\.lines).isEmpty ? 0 : 1
        }
    }

    /// Remove assets and everything built on them: their clips, the song placement with its
    /// beat fixes and the cinemascope beat anchors, and (for the lyrics TXT) every lyric line
    /// and the extra lyric tracks (one empty track stays).
    mutating func removeAssets(_ ids: Set<UUID>) {
        for t in videoTracks.indices { videoTracks[t].clips.removeAll { ids.contains($0.assetID) } }
        if let a = audio, ids.contains(a.assetID) {
            audio = nil
            beatCorrections = nil
            cinemascope.startAnchor = nil
            cinemascope.endAnchor = nil
        }
        if assets.contains(where: { ids.contains($0.id) && $0.kind == .lyrics }) {
            lyricTracks = [LyricTrack(id: lyricTracks.first?.id ?? UUID())]
            lyricsLanguage = nil
        }
        assets.removeAll { ids.contains($0.id) }
    }
}

extension EditorModel {
    /// Delete assets (one undo step for the model). Files derived from them go too: proxies,
    /// thumbnails, waveforms, and a song's analysis and vocal stem.
    @MainActor
    func deleteAssets(_ ids: Set<UUID>) {
        let removed = ids.compactMap { project.asset($0) }
        let proxies = removed.compactMap(proxyURL(for:))
        let songHashes = removed.filter { $0.kind == .audio }.compactMap(analysisHash(of:))
        let clearsSong = removed.contains { $0.id == project.audio?.assetID }
        edit(ids.count == 1 ? "Delete Asset" : "Delete Assets") { $0.removeAssets(ids) }
        let fm = FileManager.default
        proxies.forEach { try? fm.removeItem(at: $0) }
        for a in removed {
            if let t = thumbnails.url(for: a.id) { try? fm.removeItem(at: t) }
            if let dir = folder("analysis") { try? fm.removeItem(at: dir.appendingPathComponent("waveform-\(a.id.uuidString).plist")) }
        }
        if let dir = folder("analysis") {
            for h in songHashes {
                try? fm.removeItem(at: dir.appendingPathComponent("audio-\(h).json"))
                try? fm.removeItem(at: dir.appendingPathComponent("vocals-\(h).flac"))
            }
        }
        if clearsSong { audioAnalysis.ensure(for: nil) }
        selectedAssets.subtract(ids)
    }

    /// The hash the song's analysis files are named by (the loaded analysis when it is this
    /// song, else read from the file).
    @MainActor private func analysisHash(of asset: Asset) -> String? {
        if asset.id == project.audio?.assetID, let h = audioAnalysis.analysis?.audioHash { return h }
        return try? AudioAnalysisStore.hash(of: asset.url)
    }

    /// Ask before deleting assets, saying what goes with them, then delete.
    @MainActor
    func confirmDeleteAssets(_ ids: Set<UUID>, window: NSWindow?) {
        let assets = ids.compactMap { project.asset($0) }
        guard !assets.isEmpty else { return }
        let uses = assets.map { project.usageCount(of: $0.id) }.reduce(0, +)
        var notes: [String] = []
        if uses == 0 {
            notes.append(assets.count == 1 ? "It isn't used in the timeline." : "None of them are used in the timeline.")
        } else {
            let clips = assets.filter { $0.kind == .video || $0.kind == .image }.map { project.usageCount(of: $0.id) }.reduce(0, +)
            if clips > 0 { notes.append("\(clips) clip\(clips == 1 ? "" : "s") using \(assets.count == 1 ? "it" : "them") will be removed.") }
        }
        if assets.contains(where: { $0.kind == .audio }) {
            notes.append("The song's analysis (beats, sections, vocal stem), waveform and beat fixes are deleted too.")
        }
        if assets.contains(where: { $0.kind == .lyrics }) {
            notes.append("Every lyric line and its timing is removed, with the extra lyric tracks.")
        }
        notes.append(assets.contains(where: { $0.kind == .audio }) ? "You can undo this (the analysis then runs again)." : "You can undo this.")
        let alert = NSAlert()
        alert.messageText = assets.count == 1 ? "Delete “\(assets[0].name)”?" : "Delete \(assets.count) assets?"
        alert.informativeText = notes.joined(separator: " ")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] in if $0 == .alertFirstButtonReturn { self?.deleteAssets(ids) } }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }
}
