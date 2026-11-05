import Foundation

/// Estimates the exported file size in quality mode by test-encoding short video samples
/// from the busiest parts of the timeline and scaling by duration; audio is added from its
/// bitrate. Bitrate mode needs no probe.
enum SizeEstimator {
    static let sampleSeconds = 2.0
    static let sampleCount = 3
    static let timeout: TimeInterval = 25

    enum EstimateError: Error { case timedOut }

    /// How "busy" a moment is: the number of clips on screen at once (more layers, more data).
    static func busyness(_ project: Project, at t: Double) -> Int {
        project.videoTracks.flatMap(\.clips).filter { t >= $0.start && t < $0.end }.count
    }

    /// Start times of the probe samples: the busiest windows, spread apart.
    static func sampleStarts(_ project: Project) -> [Double] {
        let d = project.duration
        let len = min(sampleSeconds, d)
        guard d > 0 else { return [] }
        let clips = project.videoTracks.flatMap(\.clips)
        guard !clips.isEmpty else { return [max(0, d / 2 - len / 2)] }
        // Candidate windows every half sample length, scored by layers on screen at their middle.
        var candidates: [(start: Double, score: Int)] = []
        var t = 0.0
        while t + len <= d + 1e-6 {
            candidates.append((t, busyness(project, at: t + len / 2)))
            t += len / 2
        }
        if candidates.isEmpty { candidates = [(0, busyness(project, at: len / 2))] }
        var picks: [Double] = []
        for c in candidates.sorted(by: { $0.score != $1.score ? $0.score > $1.score : $0.start < $1.start }) where c.score > 0 {
            // Keep samples at least a sample length apart so they cover different shots.
            if picks.allSatisfy({ abs($0 - c.start) >= len * 3 }) { picks.append(c.start) }
            if picks.count == sampleCount { break }
        }
        return picks.isEmpty ? [max(0, d / 2 - len / 2)] : picks.sorted()
    }

    static func estimateBytes(project: Project, settings: ExportSettings) async throws -> Double {
        if settings.rateMode != .quality { return settings.estimatedBytes(duration: project.duration) }
        return try await withThrowingTaskGroup(of: Double.self) { group in
            group.addTask { try await probe(project: project, settings: settings) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw EstimateError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func probe(project: Project, settings: ExportSettings) async throws -> Double {
        let len = min(sampleSeconds, project.duration)
        var videoBytes = 0.0, seconds = 0.0
        for start in sampleStarts(project) {
            try Task.checkCancellation()
            let part = project.excerpt(from: start, to: start + len)
            guard part.duration > 0 else { continue }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-probe-\(UUID().uuidString).\(settings.container.rawValue)")
            defer { try? FileManager.default.removeItem(at: url) }
            try await Exporter().export(project: part, settings: settings, to: url, includeAudio: false) { _ in }
            videoBytes += Double((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
            seconds += part.duration
        }
        let perSecond = videoBytes / max(seconds, 0.001)
        let audioBytes = project.audio == nil ? 0 : settings.audioBitrateKbps * 1000 / 8 * project.duration
        return perSecond * project.duration + audioBytes
    }
}
