import CoreGraphics
import Foundation

/// Approximate screen zones a platform's app draws over a portrait video (R27). Values are
/// in a 1080×1920 reference frame, top-left origin, and scale to the project canvas.
/// Edit `platform_overlays.json` to adjust them.
struct PlatformOverlay: Codable, Equatable, Identifiable {
    struct Zone: Codable, Equatable { var name: String; var x: Double; var y: Double; var width: Double; var height: Double }
    var id: String
    var name: String
    var reference: CanvasSize
    var zones: [Zone]

    static let all: [PlatformOverlay] = {
        guard let url = Bundle.main.url(forResource: "platform_overlays", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([PlatformOverlay].self, from: data) else { return [] }
        return list
    }()

    /// Zones on `canvas` in Core Image coordinates (y up).
    func rects(on canvas: CanvasSize) -> [CGRect] {
        let sx = Double(canvas.width) / Double(reference.width), sy = Double(canvas.height) / Double(reference.height)
        return zones.map { z in
            CGRect(x: z.x * sx, y: Double(canvas.height) - (z.y + z.height) * sy, width: z.width * sx, height: z.height * sy)
        }
    }
}

enum SafeArea {
    /// The rectangle of `canvas` (y up) clear of every zone that touches a frame edge: each
    /// edge moves in past the deepest zone on it. Nil when no zones are given.
    static func rect(canvas: CanvasSize, avoiding zones: [CGRect]) -> CGRect? {
        guard !zones.isEmpty else { return nil }
        let w = CGFloat(canvas.width), h = CGFloat(canvas.height)
        let eps: CGFloat = 0.5
        var left: CGFloat = 0, right: CGFloat = 0, bottom: CGFloat = 0, top: CGFloat = 0
        for z in zones {
            // A full-width band is a top or bottom zone; otherwise a zone on a side edge
            // (like the right-hand button column) narrows the frame from that side.
            let fullWidth = z.minX <= eps && z.maxX >= w - eps
            if fullWidth {
                if z.maxY >= h - eps { top = max(top, h - z.minY) }
                if z.minY <= eps { bottom = max(bottom, z.maxY) }
            } else {
                if z.maxX >= w - eps { right = max(right, w - z.minX) }
                if z.minX <= eps { left = max(left, z.maxX) }
            }
        }
        let r = CGRect(x: left, y: bottom, width: w - left - right, height: h - bottom - top)
        return r.width > 0 && r.height > 0 ? r : nil
    }

    /// Safe area for a project: portrait projects avoid the overlays they have switched on.
    /// Portrait projects keep automatically placed lyrics clear of every platform's UI, whether
    /// or not its zones are shown: the Platform UI menu only draws them in the preview, so
    /// switching it doesn't move anything (and the export is safe on every platform).
    static func rect(for project: Project) -> CGRect? {
        guard project.type.isPortrait else { return nil }
        let zones = PlatformOverlay.all.flatMap { $0.rects(on: project.canvas) }
        return rect(canvas: project.canvas, avoiding: zones)
    }
}
