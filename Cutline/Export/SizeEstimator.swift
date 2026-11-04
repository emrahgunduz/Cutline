import Foundation

/// Estimates the exported file size in quality mode by encoding a short sample from the
/// middle of the project and scaling by duration. Bitrate mode needs no probe.
enum SizeEstimator {
    static let probeSeconds = 2.0

    static func estimateBytes(project: Project, settings: ExportSettings) async throws -> Double {
        if settings.rateMode == .bitrate { return settings.estimatedBytes(duration: project.duration) }
        let d = project.duration
        let len = min(probeSeconds, d)
        let start = max(0, d / 2 - len / 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-probe-\(UUID().uuidString).\(settings.container.rawValue)")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Exporter().export(project: project, settings: settings, to: url, range: start...(start + len)) { _ in }
        let bytes = Double((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        return bytes * d / max(len, 0.001)
    }
}
