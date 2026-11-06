import AVFoundation
import AppKit
import UniformTypeIdentifiers

enum AssetImportError: LocalizedError {
    case unsupported(String)
    var errorDescription: String? {
        switch self { case .unsupported(let name): "\(name) is not a video, image, audio or TXT file." }
    }
}

/// Reads metadata for media files and turns them into project assets.
enum AssetLibrary {
    static func kind(of url: URL) -> AssetKind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .plainText) { return .lyrics }
        return nil
    }

    static func makeAsset(from url: URL) async throws -> Asset {
        guard let kind = kind(of: url) else { throw AssetImportError.unsupported(url.lastPathComponent) }
        var asset = Asset(kind: kind, name: url.lastPathComponent, path: url.path,
                          bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        switch kind {
        case .video:
            let av = AVURLAsset(url: url)
            asset.duration = try await av.load(.duration).seconds
            if let track = try await av.loadTracks(withMediaType: .video).first {
                let (size, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                let r = CGRect(origin: .zero, size: size).applying(transform)
                asset.pixelSize = CanvasSize(width: Int(abs(r.width).rounded()), height: Int(abs(r.height).rounded()))
                asset.frameRate = Double(rate)
            }
        case .audio:
            asset.duration = try await AVURLAsset(url: url).load(.duration).seconds
        case .image:
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                asset.pixelSize = CanvasSize(width: w, height: h)
            }
        case .lyrics:
            break
        }
        return asset
    }
}

extension EditorModel {
    /// Import files as assets. A second TXT replaces the existing lyrics file.
    @MainActor
    func importFiles(_ urls: [URL]) async -> [Error] { await importAssets(urls).errors }

    /// Imports files into the assets. With `reuseExisting`, a file the project already has is not
    /// added again; its asset is returned instead. Returns the assets in the order of `urls` (to
    /// place them on the timeline) and the files that couldn't be imported. A lyrics file replaces
    /// the lyrics asset (a project keeps one).
    func importAssets(_ urls: [URL], reuseExisting: Bool = false) async -> (assets: [Asset], errors: [Error]) {
        var errors: [Error] = []
        var result: [Asset] = []
        var imported: [Asset] = []
        for url in urls {
            if reuseExisting, let existing = project.assets.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                result.append(existing)
                continue
            }
            do {
                let a = try await AssetLibrary.makeAsset(from: url)
                imported.append(a)
                result.append(a)
            } catch { errors.append(error) }
        }
        guard !imported.isEmpty else { return (result, errors) }
        edit("Import Media") { p in
            for a in imported {
                if a.kind == .lyrics { p.assets.removeAll { $0.kind == .lyrics } }
                p.assets.append(a)
            }
        }
        for a in imported where a.kind == .video || a.kind == .image {
            Task { await thumbnails.ensureThumbnail(for: a) }
        }
        for a in imported where a.kind == .audio {
            Task { await waveforms.ensureWaveform(for: a) }
        }
        return (result, errors)
    }
}
