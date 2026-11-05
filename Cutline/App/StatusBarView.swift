import AppKit
import SwiftUI

/// Window-wide status bar: what is selected, project length against its limit, format,
/// proxy use and save state.
struct StatusBarView: View {
    @EnvironmentObject var editor: EditorModel

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 5)) { _ in
            HStack(spacing: 14) {
                Label { Text(selectionText).lineLimit(1).truncationMode(.middle) } icon: { Image(systemName: selectionIcon) }
                Spacer(minLength: 12)
                lengthView
                divider
                Text(verbatim: "\(editor.project.canvas.width)×\(editor.project.canvas.height) · \(Int(editor.project.fps.rounded())) fps")
                if proxyCount > 0 {
                    divider
                    Label("\(proxyCount) proxied", systemImage: "bolt.horizontal").help("Videos playing from preview proxies")
                }
                JobStatusView(jobs: editor.jobs, analysis: editor.audioAnalysis, cancel: { editor.cancelJobs() })
                divider
                Label(saveText, systemImage: editor.document?.isDocumentEdited == true ? "pencil.circle" : "checkmark.circle")
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: NSColor(calibratedWhite: 0.13, alpha: 1)))
        }
    }

    private var divider: some View { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 1, height: 12) }

    private var p: Project { editor.project }
    private func tc(_ t: Double) -> String { Timecode.string(t, fps: p.fps) }

    private var proxyCount: Int {
        let used = Set(p.videoTracks.flatMap(\.clips).map(\.assetID))
        return p.assets.filter { used.contains($0.id) && $0.proxy != nil }.count
    }

    @ViewBuilder private var lengthView: some View {
        let limit = Presets.preset(for: p.type).maxDuration
        let over = limit.map { p.duration > $0 } ?? false
        HStack(spacing: 4) {
            Image(systemName: "timer")
            Text(tc(p.duration) + (limit.map { " / max \(tc($0))" } ?? ""))
        }
        .foregroundStyle(over ? Color.red : Color.secondary)
        .help(over ? "Longer than this project type allows" : "Project length")
    }

    private var selectionIcon: String {
        if editor.selectedItems.count > 1 { return "square.on.square" }
        switch editor.selection {
        case .clip: return "film"
        case .lyricLine, .lyricWord: return "text.quote"
        case .audio: return "waveform"
        case .none: return "info.circle"
        }
    }

    private var selectionText: String {
        if editor.selectedItems.count > 1 { return "\(editor.selectedItems.count) items selected" }
        switch editor.selection {
        case .clip(let id):
            guard let c = editor.clip(id), let a = p.asset(c.assetID) else { return "" }
            var parts = [a.name, "\(tc(c.start)) – \(tc(c.end))", "length \(tc(c.duration))"]
            if let s = a.pixelSize { parts.append("\(s.width)×\(s.height)") }
            if let proxy = a.proxy { parts.append("proxy \(proxy.scale.label)") }
            return parts.joined(separator: " · ")
        case .lyricLine(let id):
            guard let l = editor.line(id) else { return "" }
            return "“\(l.text)” · \(tc(l.start)) – \(tc(l.end)) · \(l.words.count) words"
        case .lyricWord(let id):
            guard let w = editor.word(id) else { return "" }
            return "“\(w.text)” · \(tc(w.start)) – \(tc(w.end)) · \(String(format: "%.2fs", w.end - w.start))"
        case .audio:
            guard let au = p.audio, let a = p.asset(au.assetID) else { return "" }
            return "\(a.name) · starts \(tc(au.start)) · length \(tc(au.duration))"
        case .none:
            let clips = p.videoTracks.flatMap(\.clips).count, lines = p.lyricTracks.flatMap(\.lines).count
            return "\(p.type.title) · \(clips) clips · \(lines) lyric lines · \(p.assets.count) assets"
        }
    }

    private var saveText: String {
        guard let doc = editor.document else { return "" }
        guard doc.fileURL != nil else { return "Not saved yet" }
        if doc.isDocumentEdited { return "Edited" }
        guard let date = doc.fileModificationDate else { return "Saved" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "Saved \(f.localizedString(for: date, relativeTo: Date()))"
    }
}

/// The running analysis job with its progress and a cancel button.
private struct JobStatusView: View {
    @ObservedObject var jobs: JobRunner
    @ObservedObject var analysis: AudioAnalysisStore
    let cancel: () -> Void

    var body: some View {
        if let job = jobs.active.first {
            Rectangle().fill(.secondary.opacity(0.4)).frame(width: 1, height: 12)
            HStack(spacing: 6) {
                ProgressView(value: job.fraction).progressViewStyle(.linear).frame(width: 70).controlSize(.mini)
                Text("\(job.message ?? job.title) \(Int((job.fraction * 100).rounded()))%").lineLimit(1)
                Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("Cancel")
            }
        } else if case .failed(let message) = analysis.state {
            Rectangle().fill(.secondary.opacity(0.4)).frame(width: 1, height: 12)
            Label("Analysis failed", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).help(message)
        }
    }
}
