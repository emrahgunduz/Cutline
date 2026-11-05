import SwiftUI

/// The project's budget while editing (R38): length against the type's limit and, when the
/// saved export settings have a size target, the size (or the bitrate it leaves) against it.
struct BudgetBarView: View {
    @EnvironmentObject var editor: EditorModel

    private var p: Project { editor.project }

    var body: some View {
        HStack(spacing: 10) {
            lengthBudget
            if let size = sizeBudget { size }
        }
    }

    @ViewBuilder private var lengthBudget: some View {
        let limit = p.lengthLimit
        let over = p.isOverLimit
        HStack(spacing: 5) {
            Image(systemName: "timer")
            if let limit {
                meter(fraction: p.duration / limit, over: over)
            }
            Text(Self.clock(p.duration) + (limit.map { " / " + Self.clock($0) } ?? ""))
        }
        .foregroundStyle(over ? Color.red : Color.secondary)
        .help(over ? "Longer than this project type allows. Use Trim to Limit in the timeline bar." : limit == nil ? "Project length (no limit)" : "Project length against the limit")
    }

    /// Size against the saved target, or nil when there is no target.
    private var sizeBudget: AnyView? {
        guard let s = p.exportSettings, let target = s.sizeTargetMB, p.duration > 0 else { return nil }
        switch s.rateMode {
        case .size:
            let mbps = s.sizeTargetBitrateMbps(duration: p.duration) ?? 0
            let tooSmall = mbps * 1_000_000 < SizeSolver.minimumVideoBitrate
            return AnyView(Label(tooSmall ? "\(ExportSheet.formatMB(target)) target is too small" : String(format: "\(ExportSheet.formatMB(target)) → %.1f Mbit/s", mbps),
                                 systemImage: "internaldrive")
                .foregroundStyle(tooSmall ? Color.red : Color.secondary)
                .help("Export size target and the video bitrate it leaves for this length"))
        case .bitrate:
            let mb = s.estimatedBytes(duration: p.duration) / 1_000_000
            let over = mb > target
            return AnyView(HStack(spacing: 5) {
                Image(systemName: "internaldrive")
                meter(fraction: mb / target, over: over)
                Text(String(format: "≈ %.1f / ", mb) + ExportSheet.formatMB(target))
            }
            .foregroundStyle(over ? Color.red : Color.secondary)
            .help("Estimated export size at the saved bitrate against the size target"))
        case .quality:
            return nil
        }
    }

    private func meter(fraction: Double, over: Bool) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.25))
            Capsule().fill(over ? Color.red : Color.accentColor).frame(width: 46 * min(1, max(0, fraction)))
        }
        .frame(width: 46, height: 5)
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
