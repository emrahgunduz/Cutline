import Foundation

enum Timecode {
    /// mm:ss:ff
    static func string(_ t: Double, fps: Double) -> String {
        let rate = max(1, Int(fps.rounded()))
        let frames = Int((max(0, t) * fps).rounded())
        let s = frames / rate, f = frames % rate
        return String(format: "%02d:%02d:%02d", s / 60, s % 60, f)
    }
}
