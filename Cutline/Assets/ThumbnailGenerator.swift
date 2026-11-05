import AVFoundation
import AppKit

/// Asset-panel thumbnails, cached in the package's `thumbnails/` folder.
final class ThumbnailGenerator: ObservableObject {
    @Published private(set) var images: [UUID: NSImage] = [:]
    private let folder: () -> URL?
    /// Dummies are drawn inside the cinemascope bars when the project has them on.
    var dummyBarFraction: () -> CGFloat = { 0 }
    static let maxSize = CGSize(width: 320, height: 320)

    init(folder: @escaping () -> URL?) { self.folder = folder }

    func url(for id: UUID) -> URL? { folder()?.appendingPathComponent("\(id.uuidString).png") }

    /// Forget the thumbnails in memory (Reset Media Caches rebuilds them).
    @MainActor
    func removeAll() { images = [:] }

    /// Redraw the dummies' thumbnails (after the cinemascope setting changed).
    @MainActor
    func refreshDummies(_ assets: [Asset]) {
        for a in assets where a.isDummy { images[a.id] = nil }
        for a in assets where a.isDummy { Task { await ensureThumbnail(for: a) } }
    }

    @MainActor
    func ensureThumbnail(for asset: Asset) async {
        if images[asset.id] != nil { return }
        // Dummies are drawn on the spot (cheap, and they follow the cinemascope setting).
        if asset.isDummy {
            if let cg = try? await Self.render(asset, barFraction: dummyBarFraction()) { images[asset.id] = NSImage(cgImage: cg, size: .zero) }
            return
        }
        if let url = url(for: asset.id), let img = NSImage(contentsOf: url) { images[asset.id] = img; return }
        guard let cg = try? await Self.render(asset) else { return }
        if let url = url(for: asset.id) { try? Self.writePNG(cg, to: url) }
        images[asset.id] = NSImage(cgImage: cg, size: .zero)
    }

    /// First-frame (video) or downscaled (image) thumbnail. PNG keeps alpha.
    static func render(_ asset: Asset, barFraction: CGFloat = 0) async throws -> CGImage? {
        switch asset.kind {
        case .video:
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = maxSize
            let t = CMTime(seconds: min(1, (asset.duration ?? 0) / 2), preferredTimescale: 600)
            return try await gen.image(at: t).image
        case .image:
            if let card = asset.dummy {
                let px = asset.pixelSize.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 1920, height: 1080)
                let scale = min(1, maxSize.width / max(px.width, px.height))
                return DummyRenderer.image(card, size: CGSize(width: px.width * scale, height: px.height * scale), barFraction: barFraction)
            }
            guard let src = CGImageSourceCreateWithURL(asset.url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceThumbnailMaxPixelSize: Int(maxSize.width),
                                         kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        default:
            return nil
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
