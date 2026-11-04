import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ExportSheet {
    static func present(editor: EditorModel, window: NSWindow?) {
        guard let window else { return }
        let host = NSHostingController(rootView: ExportView(editor: editor, close: { window.endSheet(window.attachedSheet!) }))
        let sheet = NSWindow(contentViewController: host)
        sheet.title = "Export"
        window.beginSheet(sheet)
    }
}

struct ExportView: View {
    @ObservedObject var editor: EditorModel
    let close: () -> Void
    @State private var settings: ExportSettings
    @State private var progress: Double?
    @State private var message: String?
    @State private var exporter: Exporter?

    init(editor: EditorModel, close: @escaping () -> Void) {
        self.editor = editor
        self.close = close
        _settings = State(initialValue: ExportSettings.defaults(for: editor.project))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export \(editor.project.type.title)").font(.headline)
            Text("\(editor.project.canvas.width)×\(editor.project.canvas.height) · \(Timecode.string(editor.project.duration, fps: editor.project.fps)) · \(settings.codec == .hevc ? "H.265 (HEVC 10-bit)" : "H.264")")
                .foregroundStyle(.secondary)
            Picker("Rate control", selection: $settings.rateMode) {
                Text("Quality").tag(ExportSettings.RateMode.quality)
                Text("Bitrate").tag(ExportSettings.RateMode.bitrate)
            }
            .pickerStyle(.segmented)
            if settings.rateMode == .quality {
                HStack {
                    Text("Quality")
                    Slider(value: $settings.quality, in: 0.3...1)
                    Text("\(Int(settings.quality * 100))%").monospacedDigit().frame(width: 44)
                }
            } else {
                HStack {
                    Text("Video bitrate")
                    TextField("Mbit/s", value: $settings.bitrateMbps, format: .number).frame(width: 80)
                    Text("Mbit/s")
                    Spacer()
                    Text("≈ \(estimatedMB, specifier: "%.0f") MB").foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Audio")
                Picker("", selection: $settings.audioBitrateKbps) {
                    ForEach([128.0, 192, 256, 320], id: \.self) { Text("\(Int($0)) kbit/s AAC").tag($0) }
                }
                .frame(width: 180)
            }
            if let progress { ProgressView(value: progress) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                if exporter != nil {
                    Button("Cancel Export") { exporter?.cancel() }
                } else {
                    Button("Close", action: close).keyboardShortcut(.cancelAction)
                    Button("Export…", action: start).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var estimatedMB: Double {
        (settings.bitrateMbps * 1_000_000 + settings.audioBitrateKbps * 1000) * editor.project.duration / 8 / 1_000_000
    }

    private func start() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.nameFieldStringValue = (editor.document?.displayName ?? "Cutline") + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ex = Exporter()
        exporter = ex
        progress = 0
        message = nil
        let project = editor.project, settings = settings
        Task { @MainActor in
            do {
                try await ex.export(project: project, settings: settings, to: url) { p in
                    Task { @MainActor in progress = p }
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                message = "Exported \(url.lastPathComponent) (\(String(format: "%.1f", Double(size) / 1_000_000)) MB)."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                message = error.localizedDescription
            }
            exporter = nil
            progress = nil
        }
    }
}
