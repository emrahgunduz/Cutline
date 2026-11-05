import CoreVideo
import Foundation

/// Preview frames in memory, keyed by `RenderKey` (KTD11, R32). Scrubbing back over a range,
/// or looping an unsure word, shows the already-composited frames. Bounded by bytes; the
/// least recently used frames are evicted first.
final class FrameCache {
    static let shared = FrameCache()
    static let byteLimit = 512 * 1024 * 1024

    private final class Box { let buffer: CVPixelBuffer; init(_ b: CVPixelBuffer) { buffer = b } }
    private let cache = NSCache<NSString, Box>()
    private let lock = NSLock()
    private var keys = Set<String>()
    private var bytes: [String: Int] = [:]
    private(set) var hits = 0

    init() { cache.totalCostLimit = Self.byteLimit }

    func frame(_ key: String) -> CVPixelBuffer? {
        let b = cache.object(forKey: key as NSString)?.buffer
        if b != nil { lock.lock(); hits += 1; lock.unlock() }
        return b
    }

    func store(_ buffer: CVPixelBuffer, for key: String) {
        let cost = CVPixelBufferGetDataSize(buffer)
        cache.setObject(Box(buffer), forKey: key as NSString, cost: cost)
        lock.lock(); keys.insert(key); bytes[key] = cost; lock.unlock()
    }

    /// Approximate bytes held (frames NSCache already evicted may still be counted).
    var approximateBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return keys.filter { cache.object(forKey: $0 as NSString) != nil }.reduce(0) { $0 + (bytes[$1] ?? 0) }
    }

    func removeAll() {
        cache.removeAllObjects()
        lock.lock(); keys.removeAll(); bytes.removeAll(); hits = 0; lock.unlock()
    }
}
