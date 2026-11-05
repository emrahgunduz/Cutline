import AppKit
import SwiftUI

/// Settings > Models: where the models are, their state, and moving, re-downloading or removing them.
struct ModelsSettingsView: View {
    @Bindable var store: ModelStore
    @State private var confirmTrash = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Location") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(store.folder.abbreviatedPath)
                            .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(store.folder.path)
                        Text(store.source == .chosen ? "Chosen by you" : "Default location")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Status") { statusView }
                if store.isReady {
                    LabeledContent("Size on disk", value: ByteFormat.string(store.bytesOnDisk))
                }
            } footer: {
                Text("Song analysis and lyric alignment use these models. Projects can't be created or opened without them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.folder]) }
                        .disabled(!FileManager.default.fileExists(atPath: store.folder.path))
                    Spacer()
                    if store.moving { ProgressView().controlSize(.small); Text("Moving…").foregroundStyle(.secondary) }
                    if store.isDownloading, let d = store.download {
                        Text("Downloading… \(d.fraction.formatted(.percent.precision(.fractionLength(0))))").foregroundStyle(.secondary)
                        Button("Cancel") { store.cancelDownload() }
                    }
                }
                HStack(spacing: 10) {
                    Button("Move To…") { pick(title: "Move the models to", prompt: "Move") { url in Task { await store.move(into: url) } } }
                        .disabled(!store.isReady || store.moving || store.isDownloading)
                        .help("Move the downloaded models to another folder or disk")
                    Button("Use Existing Folder…") { pick(title: "Choose a folder that already has the models", prompt: "Use") { store.useExisting($0) } }
                        .disabled(store.moving || store.isDownloading)
                    Spacer()
                }
                HStack(spacing: 10) {
                    Button(store.isReady ? "Re-download" : "Download") {
                        if store.isReady { store.moveToTrash() }
                        store.dismissDownload()
                        store.startDownload()
                    }
                    .disabled(store.moving || store.isDownloading)
                    Button("Move to Trash…") { confirmTrash = true }
                        .disabled(!FileManager.default.fileExists(atPath: store.folder.path) || store.moving || store.isDownloading)
                    Spacer()
                    if store.source == .chosen {
                        Button("Use Library Folder") { store.useStandardFolder() }
                            .disabled(store.moving || store.isDownloading)
                    }
                }
            }
            if let error = store.lastError {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { if !store.isDownloading { store.refresh() } }
        .alert("Move the models to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { store.moveToTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cutline needs them to create or open projects, so you'll be asked to download them again "
                 + "(\(ByteFormat.string(store.manifest?.totalBytes ?? 0))). You can restore them from the Trash.")
        }
    }

    @ViewBuilder private var statusView: some View {
        switch store.state {
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .checking: ProgressView().controlSize(.small)
        case .missing: Label("Not downloaded", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
        case .partial(let st):
            Label("Incomplete: \(ByteFormat.string(st.downloadedBytes)) of \(ByteFormat.string(st.totalBytes))",
                  systemImage: "circle.lefthalf.filled").foregroundStyle(.orange)
        case .unavailable: Label("Folder not found", systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
        case .broken(let m): Text(m).foregroundStyle(.red)
        }
    }

    private func pick(title: String, prompt: String, then action: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = store.folder.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            store.lastError = nil
            action(url)
        }
    }
}
