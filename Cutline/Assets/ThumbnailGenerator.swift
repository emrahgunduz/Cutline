import AVFoundation
import AppKit

/// Asset-panel thumbnails, cached in the package's `thumbnails/` folder.
final class ThumbnailGenerator: ObservableObject {
    @Published private(set) var images: [UUID: NSImage] = [:]
    private let folder: () -> URL?
    static let maxSize = CGSize(width: 320, height: 320)

    init(folder: @escaping () -> URL?) { self.folder = folder }

    func url(for id: UUID) -> URL? { folder()?.appendingPathComponent("\(id.uuidString).png") }

    @MainActor
    func ensureThumbnail(for asset: Asset) async {
        if images[asset.id] != nil { return }
        if let url = url(for: asset.id), let img = NSImage(contentsOf: url) { images[asset.id] = img; return }
        guard let cg = try? await Self.render(asset) else { return }
        if let url = url(for: asset.id) { try? Self.writePNG(cg, to: url) }
        images[asset.id] = NSImage(cgImage: cg, size: .zero)
    }

    /// First-frame (video) or downscaled (image) thumbnail. PNG keeps alpha.
    static func render(_ asset: Asset) async throws -> CGImage? {
        switch asset.kind {
        case .video:
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = maxSize
            let t = CMTime(seconds: min(1, (asset.duration ?? 0) / 2), preferredTimescale: 600)
            return try await gen.image(at: t).image
        case .image:
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
