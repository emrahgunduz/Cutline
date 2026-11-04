import CoreImage
import Foundation

/// Renders the lyric layer for a frame. Built per render snapshot.
final class LyricRenderer {
    let project: Project
    init(project: Project) { self.project = project }

    func image(at t: Double) -> CIImage? { nil }
}
