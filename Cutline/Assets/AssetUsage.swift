import Foundation

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

    /// Remove assets and every clip or audio placement that uses them. Lyric lines stay:
    /// they are the user's timing work, not a reference to the file.
    mutating func removeAssets(_ ids: Set<UUID>) {
        for t in videoTracks.indices { videoTracks[t].clips.removeAll { ids.contains($0.assetID) } }
        if let a = audio, ids.contains(a.assetID) { audio = nil }
        assets.removeAll { ids.contains($0.id) }
    }
}

extension EditorModel {
    @MainActor
    func deleteAssets(_ ids: Set<UUID>) {
        let proxies = ids.compactMap { project.asset($0) }.compactMap(proxyURL(for:))
        edit(ids.count == 1 ? "Delete Asset" : "Delete Assets") { $0.removeAssets(ids) }
        // Proxy files are cheap to rebuild; thumbnails and waveforms stay so undo restores instantly.
        proxies.forEach { try? FileManager.default.removeItem(at: $0) }
        selectedAssets.subtract(ids)
    }
}
