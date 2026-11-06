import CoreImage
import Foundation

/// Image files decoded once and reused while the file is unchanged (same size and modification
/// date). The preview rebuilds its render snapshot after every edit (up to ~25 times a second
/// while you drag on the timeline); decoding every PNG in the project each time made dragging
/// and trimming slow. An image edited on disk is decoded again.
final class DecodedImageCache: @unchecked Sendable {
    static let shared = DecodedImageCache()

    private final class Entry {
        let size: Int64
        let modified: Date
        let image: CIImage
        init(size: Int64, modified: Date, image: CIImage) { self.size = size; self.modified = modified; self.image = image }
    }

    private let cache = NSCache<NSURL, Entry>()
    private let lock = NSLock()
    private var decodes = 0

    /// Up to `costLimit` bytes of decoded pixels (4 bytes a pixel); the least used go first, and
    /// all of it can go under memory pressure (they're decoded again when needed).
    init(costLimit: Int = 1_500_000_000) {
        cache.totalCostLimit = costLimit
    }

    /// How many files were decoded (tests).
    var decodeCount: Int { lock.lock(); defer { lock.unlock() }; return decodes }

    func image(at url: URL) -> CIImage? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        let key = url.standardizedFileURL as NSURL
        if let e = cache.object(forKey: key), e.size == size, e.modified == modified { return e.image }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        lock.lock(); decodes += 1; lock.unlock()
        let cost = Int(image.extent.width * image.extent.height * 4)
        cache.setObject(Entry(size: size, modified: modified, image: image), forKey: key, cost: max(1, cost))
        return image
    }

    func removeAll() { cache.removeAllObjects() }
}
