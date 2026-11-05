import Foundation

/// Size-targeted export (KTD12, R37): pick the video bitrate that lands the file just under a
/// size target, encode, measure, and correct an overshoot by re-encoding at most twice.
enum SizeSolver {
    /// Share of the computed bitrate actually requested, leaving room for container overhead.
    static let headroom = 0.95
    /// Extra margin on a corrected pass, so it lands under rather than at the target.
    static let correctionMargin = 0.97
    static let maxRetries = 2
    /// Below this the picture falls apart; a target that needs less is reported as too small.
    static let minimumVideoBitrate = 250_000.0

    enum Failure: LocalizedError, Equatable {
        case targetTooSmall(minimumMB: Double)
        var errorDescription: String? {
            switch self {
            case .targetTooSmall(let mb):
                String(format: "The size target is too small for this length. It needs at least %.1f MB.", mb)
            }
        }
    }

    /// Video bitrate (bit/s) that fills `targetBytes` over `duration` next to the audio.
    static func videoBitrate(targetBytes: Double, duration: Double, audioKbps: Double) -> Double {
        guard duration > 0 else { return 0 }
        return (targetBytes * 8 - audioKbps * 1000 * duration) / duration * headroom
    }

    /// Smallest target (bytes) that still allows `minimumVideoBitrate`.
    static func minimumTargetBytes(duration: Double, audioKbps: Double) -> Double {
        (minimumVideoBitrate / headroom + audioKbps * 1000) * duration / 8
    }

    /// Bitrate for the next pass after a file came out at `actualBytes`.
    static func corrected(bitrate: Double, targetBytes: Double, actualBytes: Double) -> Double {
        guard actualBytes > 0 else { return bitrate }
        return bitrate * targetBytes / actualBytes * correctionMargin
    }

    struct Attempt: Equatable {
        var bitrate: Double
        var bytes: Int64
        var url: URL
    }

    struct Outcome: Equatable {
        var attempts: [Attempt]
        /// The file to keep: the largest one under the target, else the smallest one.
        var best: Attempt
        var met: Bool
    }

    /// Run passes until a file fits (`encode` writes one pass and reports its size).
    static func run(targetBytes: Double, duration: Double, audioKbps: Double,
                    encode: (_ bitrate: Double, _ pass: Int) async throws -> Attempt) async throws -> Outcome {
        var bitrate = videoBitrate(targetBytes: targetBytes, duration: duration, audioKbps: audioKbps)
        guard bitrate >= minimumVideoBitrate else {
            throw Failure.targetTooSmall(minimumMB: minimumTargetBytes(duration: duration, audioKbps: audioKbps) / 1_000_000)
        }
        var attempts: [Attempt] = []
        for pass in 0...maxRetries {
            let a = try await encode(bitrate, pass)
            attempts.append(a)
            if Double(a.bytes) <= targetBytes { break }
            bitrate = max(minimumVideoBitrate, corrected(bitrate: bitrate, targetBytes: targetBytes, actualBytes: Double(a.bytes)))
        }
        let fitting = attempts.filter { Double($0.bytes) <= targetBytes }
        let best = fitting.max { $0.bytes < $1.bytes } ?? attempts.min { $0.bytes < $1.bytes }!
        return Outcome(attempts: attempts, best: best, met: !fitting.isEmpty)
    }
}
