import CoreImage
import Foundation

/// Animated cinemascope bars (music videos only): none before the start marker, easing out
/// between the markers, fully closed from the end marker on. Closed, each bar is the project's
/// bar height, by default the one that leaves a 2.35:1 picture.
enum Letterbox {
    static let ratio = 2.35

    /// The bar height (each of top and bottom) that leaves a 2.35:1 picture on the canvas.
    static func defaultBarHeight(_ canvas: CanvasSize) -> Double {
        max(0, (Double(canvas.height) - Double(canvas.width) / ratio) / 2)
    }

    /// The tallest a bar can be: together they leave at least one row of picture.
    static func maxBarHeight(_ canvas: CanvasSize) -> Double { max(0, (Double(canvas.height) - 1) / 2) }

    /// Each bar's height once closed: the project's own, or the 2.35:1 default.
    static func fullBarHeight(_ project: Project) -> Double {
        let h = project.cinemascope.barHeight ?? defaultBarHeight(project.canvas)
        return min(max(0, h), maxBarHeight(project.canvas))
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
        return fullBarHeight(project) * progress(project.cinemascope, at: t)
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
