import CoreImage
import Foundation

/// Image files decoded once and reused while the file is unchanged (same size and modification
/// date). The preview rebuilds its render snapshot after every edit (up to ~25 times a second
/// while you drag on the timeline); decoding every PNG in the project each time made dragging
/// and trimming slow. An image edited on disk is decoded again.
final class DecodedImageCache: @unchecked Sendable {
    static let shared = DecodedImageCache(recheckInterval: 1)

    private final class Entry {
        let size: Int64
        let modified: Date
        let image: CIImage
        init(size: Int64, modified: Date, image: CIImage) { self.size = size; self.modified = modified; self.image = image }
    }

    private let cache = NSCache<NSURL, Entry>()
    private let lock = NSLock()
    private var decodes = 0
    /// When each file's size and date were last read, and what they were.
    private var checked: [URL: (at: Date, size: Int64, modified: Date)] = [:]
    private let recheckInterval: TimeInterval

    /// Up to `costLimit` bytes of decoded pixels (4 bytes a pixel); the least used go first, and
    /// all of it can go under memory pressure (they're decoded again when needed).
    /// `recheckInterval`: how long a file's size and date are trusted before reading them
    /// again. The app's cache trusts them for a second: the preview asks for every image in
    /// the project after each edit, and reading them all (a file system call each) took about
    /// 3 ms on an external drive; a file changed on disk is still picked up within a second.
    init(costLimit: Int = 1_500_000_000, recheckInterval: TimeInterval = 0) {
        cache.totalCostLimit = costLimit
        self.recheckInterval = recheckInterval
    }

    /// How many files were decoded (tests).
    var decodeCount: Int { lock.lock(); defer { lock.unlock() }; return decodes }

    func image(at url: URL) -> CIImage? {
        guard let (size, modified) = stamp(url) else { return nil }
        let key = url.standardizedFileURL as NSURL
        if let e = cache.object(forKey: key), e.size == size, e.modified == modified { return e.image }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        lock.lock(); decodes += 1; lock.unlock()
        let cost = Int(image.extent.width * image.extent.height * 4)
        cache.setObject(Entry(size: size, modified: modified, image: image), forKey: key, cost: max(1, cost))
        return image
    }

    /// The file's size and modification date: read from disk, or remembered for up to
    /// `recheckInterval`.
    private func stamp(_ url: URL) -> (Int64, Date)? {
        let now = Date()
        if recheckInterval > 0 {
            lock.lock()
            let c = checked[url]
            lock.unlock()
            if let c, now.timeIntervalSince(c.at) < recheckInterval { return (c.size, c.modified) }
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let modified = attrs[.modificationDate] as? Date else {
            lock.lock(); checked[url] = nil; lock.unlock()
            return nil
        }
        if recheckInterval > 0 { lock.lock(); checked[url] = (now, size, modified); lock.unlock() }
        return (size, modified)
    }

    func removeAll() {
        cache.removeAllObjects()
        lock.lock(); checked.removeAll(); lock.unlock()
    }
}
