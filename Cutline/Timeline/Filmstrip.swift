import AVFoundation
import AppKit

/// Timeline thumbnails taken at the source time each tile shows, so a trimmed clip starts
/// with the frame it now starts on. Frames are cached on a time grid that coarsens with zoom.
final class Filmstrip {
    private var cache: [String: NSImage] = [:]
    private var pending: Set<String> = []
    private var generators: [URL: AVAssetImageGenerator] = [:]
    var onUpdate: (() -> Void)?

    /// Grid step (seconds) for a tile spanning `tileSeconds`: a power of two ≥ one frame.
    static func gridStep(tileSeconds: Double, fps: Double) -> Double {
        var step = 1 / 64.0
        while step < tileSeconds { step *= 2 }
        return max(step, 1 / fps)
    }

    static func snapped(_ t: Double, step: Double) -> Double { (t / step).rounded(.down) * step }

    func image(url: URL, sourceTime: Double, step: Double) -> NSImage? {
        let t = Self.snapped(sourceTime, step: step)
        let key = "\(url.path)|\(t)"
        if let img = cache[key] { return img }
        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        let gen = generator(url)
        let time = CMTime(seconds: t, preferredTimescale: 600)
        gen.generateCGImageAsynchronously(for: time) { [weak self] cg, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(key)
                if let cg { self.cache[key] = NSImage(cgImage: cg, size: .zero) }
                if self.cache.count > 4000 { self.cache.removeAll() }
                self.onUpdate?()
            }
        }
        return nil
    }

    private func generator(_ url: URL) -> AVAssetImageGenerator {
        if let g = generators[url] { return g }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 240, height: 240)
        g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        generators[url] = g
        return g
    }
}
