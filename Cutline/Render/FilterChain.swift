import CoreImage
import CoreImage.CIFilterBuiltins

/// Per-clip color filters and fades. A filter that is switched off is not in the chain.
enum FilterChain {
    static func apply(_ filters: FilterSettings, to image: CIImage) -> CIImage {
        var out = image
        let c = filters.color
        if c.enabled && !c.isIdentity {
            let controls = CIFilter.colorControls()
            controls.inputImage = out
            controls.saturation = Float(c.saturation)
            controls.brightness = Float(c.brightness)
            controls.contrast = Float(c.contrast)
            out = controls.outputImage ?? out
            if c.hue != 0 {
                let hue = CIFilter.hueAdjust()
                hue.inputImage = out
                hue.angle = Float(c.hue * .pi / 180)
                out = hue.outputImage ?? out
            }
        }
        return out
    }

    /// Opacity from the clip's fade in/out at local time `t` (seconds since clip start).
    static func fadeOpacity(_ fade: FadeFilter, localTime t: Double, duration: Double) -> Double {
        guard fade.enabled else { return 1 }
        var o = 1.0
        if fade.fadeIn > 0 { o = min(o, t / fade.fadeIn) }
        if fade.fadeOut > 0 { o = min(o, (duration - t) / fade.fadeOut) }
        return min(max(o, 0), 1)
    }

    static func withOpacity(_ image: CIImage, _ opacity: Double) -> CIImage {
        guard opacity < 1 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
        ])
    }
}
