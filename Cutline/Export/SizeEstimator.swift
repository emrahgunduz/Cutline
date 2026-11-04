import Foundation

/// Estimates the exported file size in quality mode by test-encoding short samples and
/// scaling by duration. Samples come from stretches that have clips, so black gaps don't
/// make the estimate too low. Bitrate mode needs no probe.
enum SizeEstimator {
    static let sampleSeconds = 0.75
    static let sampleCount = 3

    /// Start times of the probe samples.
    static func sampleStarts(_ project: Project) -> [Double] {
        let d = project.duration
        let len = min(sampleSeconds, d)
        let clips = project.videoTracks.flatMap(\.clips).filter { $0.duration >= len }.sorted { $0.start < $1.start }
        guard !clips.isEmpty else { return [max(0, d / 2 - len / 2)] }
        let picks = (0..<sampleCount).map { i -> Clip in clips[min(clips.count - 1, i * clips.count / sampleCount)] }
        var seen = Set<UUID>()
        return picks.filter { seen.insert($0.id).inserted }.map { min(d - len, $0.start + ($0.duration - len) / 2) }
    }

    static func estimateBytes(project: Project, settings: ExportSettings) async throws -> Double {
        if settings.rateMode == .bitrate { return settings.estimatedBytes(duration: project.duration) }
        let len = min(sampleSeconds, project.duration)
        var bytes = 0.0
        let starts = sampleStarts(project)
        for start in starts {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-probe-\(UUID().uuidString).\(settings.container.rawValue)")
            defer { try? FileManager.default.removeItem(at: url) }
            try await Exporter().export(project: project, settings: settings, to: url, range: start...(start + len)) { _ in }
            bytes += Double((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        }
        let perSecond = bytes / (Double(starts.count) * max(len, 0.001))
        return perSecond * project.duration
    }
}
