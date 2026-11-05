import CoreImage
import CoreGraphics
import Foundation

/// Everything needed to render any frame of the project, independent of AVFoundation.
/// Preview and export share this; only the source-frame provider differs.
struct RenderSnapshot {
    var project: Project
    /// Images decoded once per snapshot, keyed by asset id.
    var images: [UUID: CIImage]
    var lyrics: LyricRenderer?
    /// Preview only: keep composited frames in `FrameCache`. Export leaves this off, so it
    /// always renders from the original media.
    var cachesFrames = false
    /// Preview from proxies: part of the frame key, so proxy frames never stand in for originals.
    var usesProxies = false
}

enum FrameRenderer {
    /// Compose the frame at time `t`. `sourceFrame` returns the decoded video frame for a clip.
    static func render(_ snap: RenderSnapshot, at time: Double, sourceFrame: (Clip) -> CIImage?) -> CIImage {
        let canvas = CGRect(origin: .zero, size: snap.project.canvas.cgSize)
        var out = CIImage(color: .black).cropped(to: canvas)
        // Work on the frame grid: compare frame numbers, not floating-point seconds.
        let p = snap.project
        let frame = p.frameIndex(time)
        let t = Double(frame) / p.fps
        for track in snap.project.videoTracks where !track.isHidden {
            for clip in track.clips where frame >= p.frameIndex(clip.start) && frame < p.frameIndex(clip.end) {
                guard let asset = snap.project.asset(clip.assetID) else { continue }
                let source: CIImage? = asset.kind == .image ? snap.images[asset.id] : sourceFrame(clip)
                guard let src = source else { continue }
                var img = place(src, transform: clip.transform, canvas: canvas)
                img = FilterChain.apply(clip.filters, to: img)
                img = FilterChain.withOpacity(img, FilterChain.fadeOpacity(clip.filters.fade, localTime: t - clip.start, duration: clip.duration))
                out = img.composited(over: out)
            }
        }
        // The bars cover the picture only: lyrics (and their shadow) are drawn over them.
        out = Letterbox.apply(to: out, project: snap.project, at: t)
        if let lyrics = snap.lyrics, let layer = lyrics.image(at: t) {
            out = layer.composited(over: out)
        }
        return out.cropped(to: canvas)
    }

    /// Fit the source inside the canvas, then apply the clip's scale and offset (canvas pixels,
    /// +y is up in the preview, matching what users expect when dragging).
    static func place(_ src: CIImage, transform: ClipTransform, canvas: CGRect) -> CIImage {
        let e = src.extent
        guard e.width > 0, e.height > 0 else { return src }
        let fit = min(canvas.width / e.width, canvas.height / e.height) * transform.scale
        let w = e.width * fit, h = e.height * fit
        let x = canvas.midX - w / 2 + transform.offsetX
        let y = canvas.midY - h / 2 + transform.offsetY
        return src
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: fit, y: fit))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    static func loadImages(_ project: Project) -> [UUID: CIImage] {
        var out: [UUID: CIImage] = [:]
        let used = Set(project.videoTracks.flatMap(\.clips).map(\.assetID))
        for a in project.assets where a.kind == .image && used.contains(a.id) {
            if let card = a.dummy {
                // Drawn by Cutline at the project's size (no file).
                if let cg = DummyRenderer.image(card, size: project.canvas.cgSize, barFraction: DummyRenderer.barFraction(for: project)) { out[a.id] = CIImage(cgImage: cg) }
            } else if let img = CIImage(contentsOf: a.url, options: [.applyOrientationProperty: true]) { out[a.id] = img }
        }
        return out
    }
}
