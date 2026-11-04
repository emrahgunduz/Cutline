import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Export runs in two steps: a settings sheet, then (after the save panel) a progress
/// sheet that closes by itself when the file is done.
enum ExportSheet {
    static func present(editor: EditorModel, window: NSWindow?) {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: ExportSettingsView(editor: editor, finish: { settings in
            window.endSheet(sheet)
            guard let settings else { return }
            DispatchQueue.main.async { chooseDestination(editor: editor, settings: settings, window: window) }
        }))
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }

    static func defaultName(_ editor: EditorModel) -> String {
        var name = editor.document?.displayName ?? "Cutline"
        if name.lowercased().hasSuffix(".cutline") { name = String(name.dropLast(8)) }
        return name
    }

    private static func chooseDestination(editor: EditorModel, settings: ExportSettings, window: NSWindow) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [settings.container == .mp4 ? .mpeg4Movie : .quickTimeMovie]
        panel.nameFieldStringValue = defaultName(editor) + "." + settings.container.rawValue
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async { run(editor: editor, settings: settings, to: url, window: window) }
        }
    }

    private static func run(editor: EditorModel, settings: ExportSettings, to url: URL, window: NSWindow) {
        let exporter = Exporter()
        let model = ExportProgressModel()
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: ExportProgressView(model: model, fileName: url.lastPathComponent,
                                                                    cancel: { exporter.cancel() }))
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
        let project = editor.project
        Task { @MainActor in
            var failure: Error?
            do {
                try await exporter.export(project: project, settings: settings, to: url) { p in
                    Task { @MainActor in model.progress = p }
                }
            } catch { failure = error }
            window.endSheet(sheet)
            if let failure {
                if case ExportError.cancelled = failure { return }
                NSAlert(error: failure).beginSheetModal(for: window) { _ in }
                return
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let alert = NSAlert()
            alert.messageText = "Export finished"
            alert.informativeText = "\(url.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Show in Finder")
            alert.beginSheetModal(for: window) { r in
                if r == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
}

final class ExportProgressModel: ObservableObject {
    @Published var progress: Double = 0
    let started = Date()
}

struct ExportProgressView: View {
    @ObservedObject var model: ExportProgressModel
    let fileName: String
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Exporting \(fileName)", systemImage: "square.and.arrow.up").font(.headline)
            ProgressView(value: model.progress)
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(remaining).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack { Spacer(); Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var remaining: String {
        let elapsed = Date().timeIntervalSince(model.started)
        let pct = Int(model.progress * 100)
        guard model.progress > 0.02 else { return "\(pct)% · estimating time…" }
        let left = elapsed / model.progress - elapsed
        return "\(pct)% · about \(Int(left.rounded()))s left"
    }
}

struct ExportSettingsView: View {
    @ObservedObject var editor: EditorModel
    let finish: (ExportSettings?) -> Void
    @State private var settings: ExportSettings
    @State private var estimate: Double?
    @State private var estimating = false
    @State private var estimateTask: Task<Void, Never>?

    init(editor: EditorModel, finish: @escaping (ExportSettings?) -> Void) {
        self.editor = editor
        self.finish = finish
        _settings = State(initialValue: ExportSettings.defaults(for: editor.project))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Export \(editor.project.type.title)", systemImage: "square.and.arrow.up").font(.title3.bold())
            Text("\(editor.project.canvas.width)×\(editor.project.canvas.height) · \(Timecode.string(editor.project.duration, fps: editor.project.fps)) · \(settings.codec == .hevc ? "H.265 (HEVC, 10-bit)" : "H.264")")
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Format").gridColumnAlignment(.trailing)
                    Picker("", selection: $settings.container) {
                        ForEach(ExportSettings.Container.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 200)
                }
                GridRow {
                    Text("Rate control")
                    Picker("", selection: $settings.rateMode) {
                        Text("Constant quality").tag(ExportSettings.RateMode.quality)
                        Text("Target bitrate").tag(ExportSettings.RateMode.bitrate)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
                if settings.rateMode == .quality {
                    GridRow {
                        Text("Quality")
                        HStack {
                            Slider(value: $settings.quality, in: 0.3...1).frame(width: 220)
                            Text("\(Int(settings.quality * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                } else {
                    GridRow {
                        Text("Video bitrate")
                        HStack {
                            TextField("", value: $settings.bitrateMbps, format: .number.precision(.fractionLength(0...1)))
                                .textFieldStyle(.roundedBorder).frame(width: 70)
                            Text("Mbit/s")
                        }
                    }
                }
                GridRow {
                    Text("Audio")
                    Picker("", selection: $settings.audioBitrateKbps) {
                        ForEach([128.0, 192, 256, 320], id: \.self) { Text("AAC \(Int($0)) kbit/s").tag($0) }
                    }
                    .labelsHidden().frame(width: 200)
                }
                GridRow {
                    Text("Estimated size")
                    HStack {
                        if estimating { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) }
                        else if let estimate { Text(ByteCountFormatter.string(fromByteCount: Int64(estimate), countStyle: .file)).bold() }
                        else { Text("—").foregroundStyle(.secondary) }
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            Text(settings.rateMode == .quality
                 ? "Constant quality keeps the picture at a chosen quality; busy scenes use more data, so the size is estimated from short test encodes of your clips."
                 : "Target bitrate keeps the data rate fixed, so the file size is predictable (bitrate × length). Use it when a platform limits file size.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button("Export…") { finish(settings) }.keyboardShortcut(.defaultAction)
                    .disabled(editor.project.duration <= 0)
            }
        }
        .padding(20)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refreshEstimate)
        .onChange(of: settings) { _, _ in refreshEstimate() }
    }

    private func refreshEstimate() {
        estimateTask?.cancel()
        guard editor.project.duration > 0 else { estimate = nil; return }
        if settings.rateMode == .bitrate {
            estimating = false
            estimate = settings.estimatedBytes(duration: editor.project.duration)
            return
        }
        estimating = true
        let project = editor.project, s = settings
        estimateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let value = try? await SizeEstimator.estimateBytes(project: project, settings: s)
            guard !Task.isCancelled else { return }
            estimate = value
            estimating = false
        }
    }
}
