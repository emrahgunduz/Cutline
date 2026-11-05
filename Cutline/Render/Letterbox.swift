import CoreImage
import Foundation

/// Animated cinemascope bars (music videos only): none before the start marker, easing out
/// between the markers, a full 2.35:1 frame from the end marker on.
enum Letterbox {
    static let ratio = 2.35

    /// Full bar height (each of top and bottom) for the canvas.
    static func fullBarHeight(_ canvas: CanvasSize) -> Double {
        max(0, (Double(canvas.height) - Double(canvas.width) / ratio) / 2)
    }

    static func progress(_ c: Cinemascope, at t: Double) -> Double {
        guard c.enabled else { return 0 }
        let s = min(c.startMarker, c.endMarker), e = max(c.startMarker, c.endMarker)
        if t <= s { return 0 }
        if t >= e { return 1 }
        let x = (t - s) / max(e - s, 1e-6)
        return 1 - pow(1 - x, 3)            // cubic ease-out: moves quickly, settles gently
    }

    static func barHeight(project: Project, at t: Double) -> Double {
        guard project.type == .musicVideo else { return 0 }
        return fullBarHeight(project.canvas) * progress(project.cinemascope, at: t)
    }

    /// Visible picture area between the bars (Core Image coordinates, y up).
    static func visibleRect(project: Project, at t: Double) -> CGRect {
        let h = barHeight(project: project, at: t)
        return CGRect(x: 0, y: h, width: Double(project.canvas.width), height: Double(project.canvas.height) - 2 * h)
    }

    static func apply(to image: CIImage, project: Project, at t: Double) -> CIImage {
        let h = barHeight(project: project, at: t)
        guard h > 0.01 else { return image }
        let w = CGFloat(project.canvas.width), H = CGFloat(project.canvas.height)
        let black = CIImage(color: .black)
        let bottom = black.cropped(to: CGRect(x: 0, y: 0, width: w, height: CGFloat(h)))
        let top = black.cropped(to: CGRect(x: 0, y: H - CGFloat(h), width: w, height: CGFloat(h)))
        return top.composited(over: bottom.composited(over: image))
    }
}
