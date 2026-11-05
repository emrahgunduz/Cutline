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
        guard let cacheDir = editor.segmentCacheURL else { return }
        let exporter = SegmentExporter(cacheDir: cacheDir)
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
            var sizeNote: String?
            do {
                if settings.rateMode == .size {
                    sizeNote = try await exportToSize(project: project, settings: settings, targetMB: settings.sizeTarget, to: url, exporter: exporter, model: model) { solved in
                        var s = editor.project.exportSettings ?? settings
                        s.solvedSize = solved
                        editor.rememberExportSettings(s)
                    }
                } else {
                    let stats = try await exporter.export(project: project, settings: settings, to: url) { p in
                        Task { @MainActor in model.progress = p }
                    }
                    if stats.reused > 0 { sizeNote = "Reused \(stats.reused) of \(stats.reused + stats.encoded) unchanged segments from the cache." }
                }
            } catch { failure = error }
            editor.segmentCacheChanged()
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
                + (sizeNote.map { "\n\n" + $0 } ?? "")
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Show in Finder")
            alert.beginSheetModal(for: window) { r in
                if r == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
}

extension ExportSheet {
    /// Size-targeted export (R37): each pass renders to its own file beside `url`; the best
    /// one is kept. Returns a note for the finish alert.
    @MainActor
    static func exportToSize(project: Project, settings: ExportSettings, targetMB: Double, to url: URL,
                             exporter: SegmentExporter, model: ExportProgressModel,
                             onSolved: (ExportSettings.SolvedSize) -> Void = { _ in }) async throws -> String {
        let target = targetMB * 1_000_000
        var made: [URL] = []
        defer { made.forEach { try? FileManager.default.removeItem(at: $0) } }
        var reused = 0, total = 0
        let outcome = try await SizeSolver.run(targetBytes: target, duration: project.duration, audioKbps: settings.audioBitrateKbps,
                                               start: settings.solvedBitrate(duration: project.duration)) { bitrate, pass in
            model.pass = pass
            model.progress = 0
            var s = settings
            s.bitrateMbps = bitrate / 1_000_000
            let passURL = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-pass\(pass + 1).\(url.pathExtension)")
            made.append(passURL)
            let stats = try await exporter.export(project: project, settings: s, to: passURL) { p in Task { @MainActor in model.progress = p } }
            if pass == 0 { reused = stats.reused; total = stats.reused + stats.encoded }

            let bytes = (try FileManager.default.attributesOfItem(atPath: passURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            return SizeSolver.Attempt(bitrate: bitrate, bytes: bytes, url: passURL)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: outcome.best.url)
        } else {
            try FileManager.default.moveItem(at: outcome.best.url, to: url)
        }
        if outcome.met {
            onSolved(ExportSettings.SolvedSize(targetMB: targetMB, duration: project.duration, audioKbps: settings.audioBitrateKbps, bitrate: outcome.best.bitrate))
        }
        let size = ByteCountFormatter.string(fromByteCount: outcome.best.bytes, countStyle: .file)
        let passes = outcome.attempts.count == 1 ? "1 pass" : "\(outcome.attempts.count) passes"
        let cache = reused > 0 ? " Reused \(reused) of \(total) unchanged segments from the cache." : ""
        return (outcome.met
            ? "Fits the \(formatMB(targetMB)) target (\(size), \(passes))."
            : "Couldn't get under \(formatMB(targetMB)) in \(passes). Kept the smallest file (\(size)); try a lower target or a shorter cut.") + cache
    }

    static func formatMB(_ mb: Double) -> String { mb.rounded() == mb ? "\(Int(mb)) MB" : String(format: "%.1f MB", mb) }
}

final class ExportProgressModel: ObservableObject {
    @Published var progress: Double = 0
    /// Size-targeted export: which pass is running (0 = first).
    @Published var pass = 0
    let started = Date()
}

struct ExportProgressView: View {
    @ObservedObject var model: ExportProgressModel
    let fileName: String
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up.circle.fill").font(.system(size: 32)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.pass == 0 ? "Exporting" : "Exporting · correcting size, pass \(model.pass + 1) of \(SizeSolver.maxRetries + 1)").font(.title3.bold())
                    Text(fileName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            ProgressView(value: model.progress)
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack {
                    Text("Elapsed \(Self.clock(Date().timeIntervalSince(model.started)))")
                    Spacer()
                    Text("\(Int(model.progress * 100))%").bold()
                    Spacer()
                    Text(remaining)
                }
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction).controlSize(.large) }
        }
        .padding(24)
        .frame(width: 460)
    }

    static func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    private var remaining: String {
        let elapsed = Date().timeIntervalSince(model.started)
        guard model.progress > 0.02 else { return "Remaining —" }
        return "Remaining \(Self.clock(elapsed / model.progress - elapsed))"
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

    private let labelWidth: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up.circle.fill").font(.system(size: 36)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export \(editor.project.type.title)").font(.title2.bold())
                    Text(verbatim: "\(editor.project.canvas.width)×\(editor.project.canvas.height) · \(Timecode.string(editor.project.duration, fps: editor.project.fps)) · \(settings.codec == .hevc ? "H.265 (HEVC, 10-bit)" : "H.264")")
                        .foregroundStyle(.secondary)
                }
            }

            card("Format", "doc") {
                row("Container") {
                    Picker("", selection: $settings.container) {
                        ForEach(ExportSettings.Container.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                row("Audio") {
                    Picker("", selection: $settings.audioBitrateKbps) {
                        ForEach([128.0, 192, 256, 320], id: \.self) { Text("AAC \(Int($0)) kbit/s").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            card("Video", "film") {
                row("Rate control") {
                    Picker("", selection: $settings.rateMode) {
                        Text("Constant quality").tag(ExportSettings.RateMode.quality)
                        Text("Target bitrate").tag(ExportSettings.RateMode.bitrate)
                        Text("Target size").tag(ExportSettings.RateMode.size)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if settings.rateMode == .size {
                    row("Maximum size") {
                        HStack {
                            TextField("", value: Binding(get: { settings.sizeTarget }, set: { settings.sizeTargetMB = max(0.1, $0) }),
                                      format: .number.precision(.fractionLength(0...1)))
                                .textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing)
                            Text("MB").foregroundStyle(.secondary)
                            if let v = settings.sizeTargetBitrateMbps(duration: editor.project.duration) {
                                Text(v * 1_000_000 < SizeSolver.minimumVideoBitrate ? "too small for this length" : String(format: "≈ %.1f Mbit/s video", v))
                                    .foregroundStyle(v * 1_000_000 < SizeSolver.minimumVideoBitrate ? Color.red : Color.secondary)
                            }
                        }
                    }
                } else if settings.rateMode == .quality {
                    row("Quality") {
                        ValueRow(label: "", value: settings.quality * 100, range: 30...100, step: 1, format: "%.0f%%", defaultValue: 100,
                                 onChange: { settings.quality = $0 / 100 }, onCommit: {})
                    }
                } else {
                    row("Video bitrate") {
                        HStack {
                            TextField("", value: $settings.bitrateMbps, format: .number.precision(.fractionLength(0...1)))
                                .textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing)
                            Text("Mbit/s").foregroundStyle(.secondary)
                        }
                    }
                }
                row("Estimated size") {
                    HStack(spacing: 8) {
                        if estimating { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) }
                        else if let estimate { Text(ByteCountFormatter.string(fromByteCount: Int64(estimate), countStyle: .file)).font(.body.bold()) }
                        else { Text("Couldn't estimate").foregroundStyle(.secondary) }
                    }
                }
            }

            Label {
                Text(settings.rateMode == .quality
                     ? "Constant quality keeps the picture at the chosen quality, so busy scenes use more data. The size is measured by test-encoding the busiest parts of your timeline."
                     : settings.rateMode == .bitrate
                     ? "Target bitrate keeps the data rate fixed, so the size is predictable: bitrate × length."
                     : "Target size picks the bitrate that fills the size you set, checks the finished file, and re-encodes automatically (up to twice) if it came out too big. Use it when a platform limits file size.")
            } icon: { Image(systemName: "info.circle") }
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { estimateTask?.cancel(); finish(nil) }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Export…") { estimateTask?.cancel(); finish(settings) }.keyboardShortcut(.defaultAction).controlSize(.large)
                    .disabled(editor.project.duration <= 0)
            }
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refreshEstimate)
        .onDisappear { estimateTask?.cancel() }
        .onChange(of: settings) { _, s in
            // Remembered as soon as they change, for the next export and the budget bar.
            editor.rememberExportSettings(s)
            refreshEstimate()
        }
    }

    private func card<C: View>(_ title: String, _ icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content() }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func row<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label).frame(width: labelWidth, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func refreshEstimate() {
        estimateTask?.cancel()
        guard editor.project.duration > 0 else { estimate = nil; return }
        if settings.rateMode != .quality {
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
            estimate = value          // nil shows "Couldn't estimate" instead of spinning forever
            estimating = false
        }
    }
}
