import AVFoundation
import CoreImage
import Metal

final class CutlineInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let snapshot: RenderSnapshot
    let clipTracks: [UUID: (trackID: CMPersistentTrackID, transform: CGAffineTransform)]

    init(timeRange: CMTimeRange, snapshot: RenderSnapshot, baseTrackID: CMPersistentTrackID,
         clipTracks: [UUID: (trackID: CMPersistentTrackID, transform: CGAffineTransform)]) {
        self.timeRange = timeRange
        self.snapshot = snapshot
        self.clipTracks = clipTracks
        let ids = Set(clipTracks.values.map(\.trackID)).union([baseTrackID])
        requiredSourceTrackIDs = ids.sorted().map { NSNumber(value: $0) }
    }
}

/// Renders every frame through `FrameRenderer` with a Metal-backed Core Image context.
final class CutlineCompositor: NSObject, AVVideoCompositing {
    static let context: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext()
    }()

    let sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    var supportsWideColorSourceFrames: Bool { false }

    private let queue = DispatchQueue(label: "cutline.compositor", qos: .userInteractive)

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            guard let instruction = request.videoCompositionInstruction as? CutlineInstruction,
                  let out = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Cutline", code: 1))
                return
            }
            let t = request.compositionTime.seconds
            let snap = instruction.snapshot
            var key: String?
            if snap.cachesFrames {
                let p = snap.project
                let f = Double(p.frameIndex(t)) / p.fps
                let k = RenderKey.key(project: p, start: f, end: f + p.frameDuration, proxies: snap.usesProxies)
                if let cached = FrameCache.shared.frame(k) {
                    request.finish(withComposedVideoFrame: cached)
                    return
                }
                key = k
            }
            let image = FrameRenderer.render(instruction.snapshot, at: t) { clip in
                guard let info = instruction.clipTracks[clip.id],
                      let pb = request.sourceFrame(byTrackID: info.trackID) else { return nil }
                return CIImage(cvPixelBuffer: pb).transformed(by: Self.orientation(info.transform, pb))
            }
            Self.context.render(image, to: out, bounds: CGRect(origin: .zero, size: instruction.snapshot.project.canvas.cgSize),
                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            if let key { FrameCache.shared.store(out, for: key) }
            request.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    /// Source preferred transform expressed in Core Image's bottom-left coordinate space.
    static func orientation(_ t: CGAffineTransform, _ pb: CVPixelBuffer) -> CGAffineTransform {
        guard !t.isIdentity else { return .identity }
        let h = CGFloat(CVPixelBufferGetHeight(pb))
        let flip = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -h)
        return flip.concatenating(t).concatenating(CGAffineTransform(scaleX: 1, y: -1))
    }
}
