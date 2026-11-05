import AppKit
import SwiftUI

/// Settings window: the editable format presets (R39, KTD13). Changes apply to projects
/// opened afterwards and to the length limit and export defaults of open ones.
final class PresetsSettingsWindow: NSObject {
    static let shared = PresetsSettingsWindow()
    private var window: NSWindow?

    @objc func show(_ sender: Any?) {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Cutline Settings"
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: PresetsSettingsView())
            host.sizingOptions = [.preferredContentSize]
            w.contentViewController = host
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PresetsSettingsView: View {
    @State private var presets = Presets.all()
    @State private var saved = Presets.all()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Format Presets").font(.title2.bold())
                Text("Length limits, codecs and export defaults for each kind of project.").foregroundStyle(.secondary)
            }
            ForEach($presets, id: \.type) { $preset in
                PresetCard(preset: $preset)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Restore Defaults") {
                    Presets.restoreDefaults()
                    presets = Presets.all()
                    saved = presets
                }
                .disabled(presets == Presets.bundled)
                Spacer()
                Button("Revert") { presets = saved }.disabled(presets == saved)
                Button("Save") {
                    do { try Presets.save(presets); saved = presets; error = nil } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(presets == saved)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private struct PresetCard: View {
    @Binding var preset: FormatPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(preset.type.title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Length limit")
                    HStack {
                        Toggle("", isOn: Binding(get: { preset.maxDuration != nil },
                                                 set: { preset.maxDuration = $0 ? (preset.maxDuration ?? 60) : nil }))
                            .labelsHidden()
                        if preset.maxDuration != nil {
                            TextField("", value: Binding(get: { preset.maxDuration ?? 0 }, set: { preset.maxDuration = max(1, $0) }), format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 70).multilineTextAlignment(.trailing)
                            Text("seconds").foregroundStyle(.secondary)
                        } else {
                            Text("No limit").foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    Text("Codec")
                    Picker("", selection: $preset.codec) {
                        Text("H.265 (HEVC)").tag(VideoCodecChoice.hevc)
                        Text("H.264").tag(VideoCodecChoice.h264)
                    }
                    .labelsHidden().fixedSize()
                }
                if preset.type != .musicVideo {
                    GridRow {
                        Text("Default bitrate")
                        HStack {
                            TextField("", value: Binding(get: { preset.defaultBitrateMbps ?? 12 }, set: { preset.defaultBitrateMbps = max(0.5, $0) }), format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 70).multilineTextAlignment(.trailing)
                            Text("Mbit/s").foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Default size target")
                        HStack {
                            Toggle("", isOn: Binding(get: { preset.defaultSizeTargetMB != nil },
                                                     set: { preset.defaultSizeTargetMB = $0 ? (preset.defaultSizeTargetMB ?? 50) : nil }))
                                .labelsHidden()
                            if preset.defaultSizeTargetMB != nil {
                                TextField("", value: Binding(get: { preset.defaultSizeTargetMB ?? 0 }, set: { preset.defaultSizeTargetMB = max(0.1, $0) }), format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 70).multilineTextAlignment(.trailing)
                                Text("MB").foregroundStyle(.secondary)
                            } else {
                                Text("None").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}
