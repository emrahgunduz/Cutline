import AppKit
import SwiftUI

/// New Project card shown until the analysis models are ready: download, choose a folder,
/// live progress, resume, and recovery when a chosen folder's disk is missing.
struct ModelsCard: View {
    @Bindable var store: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let d = store.download, d.isRunning {
                DownloadProgressView(download: d, cancel: store.cancelDownload)
            } else {
                content
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.background.secondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(LinearGradient(colors: [ModelPalette.accent.opacity(0.75), ModelPalette.accent2.opacity(0.55)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: 1.2))
                .shadow(color: ModelPalette.accent.opacity(0.14), radius: 18, y: 6)
        }
        .animation(.smooth(duration: 0.3), value: store.state)
        .animation(.smooth(duration: 0.3), value: store.download?.phase)
    }

    @ViewBuilder private var content: some View {
        switch store.state {
        case .unavailable:
            header(symbol: "externaldrive.badge.exclamationmark", tint: .orange,
                   title: "Models folder not found",
                   text: "Cutline can't reach \(store.folder.abbreviatedPath). If it's on an external disk, connect it and try again. "
                       + "The first time Cutline opens a folder on another disk, macOS asks for permission; allow it.")
            HStack(spacing: 10) {
                Button("Try Again") { store.refresh() }.buttonStyle(.borderedProminent)
                Button("Choose Folder…") { chooseFolder() }
                Button("Download to Library") {
                    store.useStandardFolder()
                    start()
                }
            }
            .controlSize(.large)
        case .partial(let st):
            header(symbol: "arrow.down.circle", tint: ModelPalette.accent,
                   title: "Finish downloading the models",
                   text: "\(ByteFormat.string(st.downloadedBytes)) of \(ByteFormat.string(st.totalBytes)) are already here. "
                       + "The download picks up where it stopped.")
            ProgressCapsule(fraction: st.fraction, animated: false).frame(height: 8)
            locationRow
            actions(primary: "Resume Download")
        case .broken(let message):
            header(symbol: "exclamationmark.triangle", tint: .red, title: "Models unavailable", text: message)
        default:
            header(symbol: "square.stack.3d.down.right", tint: ModelPalette.accent,
                   title: "Download the analysis models",
                   text: "Song analysis and lyric alignment need them: a one-time download of "
                       + "\(ByteFormat.string(store.manifest?.totalBytes ?? 0)). After that, everything runs on this Mac, offline.")
            ModelList(items: store.manifest?.items ?? [], done: [], current: nil)
            locationRow
            actions(primary: "Download")
        }
        if let error = store.lastError ?? failureMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var failureMessage: String? {
        if case .failed(let m) = store.download?.phase { return m }
        if store.download?.phase == .cancelled { return "Download paused. Resume any time; nothing is lost." }
        return nil
    }

    private func header(symbol: String, tint: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var locationRow: some View {
        HStack(spacing: 8) {
            Image(systemName: store.source == .standard ? "internaldrive" : "externaldrive")
                .foregroundStyle(.secondary)
            Text(store.folder.abbreviatedPath)
                .font(.callout.monospaced())
                .lineLimit(1).truncationMode(.middle)
                .help(store.folder.path)
            if store.source == .chosen {
                Button("Use Library") { store.useStandardFolder() }
                    .buttonStyle(.link).font(.callout)
            }
        }
    }

    private func actions(primary: String) -> some View {
        HStack(spacing: 10) {
            Button { start() } label: {
                Label(primary, systemImage: "arrow.down.circle.fill").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(ModelPalette.accent)
            Button("Choose Folder…") { chooseFolder() }
                .help("Keep the models somewhere else, for example on another disk, or use a folder that already has them")
            Spacer()
        }
        .controlSize(.large)
    }

    private func start() {
        store.dismissDownload()
        store.startDownload()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where to keep the models"
        panel.message = "The models (\(ByteFormat.string(store.manifest?.totalBytes ?? 0))) go into a “\(ModelStore.folderName)” folder here. "
            + "Pick a folder that already has them to use them without downloading."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = store.folder.deletingLastPathComponent()
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        store.lastError = nil
        store.dismissDownload()
        store.use(folder: store.modelsFolder(in: picked))
    }
}

enum ModelPalette {
    /// Cutline's orange to pink (the New Project cards).
    static let accent = Color.orange
    static let accent2 = Color.pink
}

/// Live download: big percentage, gradient bar, speed and time left, and the per-model checklist.
private struct DownloadProgressView: View {
    let download: ModelDownloader
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Downloading models").font(.title3.weight(.semibold))
                    Text(detail).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Text(download.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: download.fraction))
            }
            ProgressCapsule(fraction: download.fraction, animated: true).frame(height: 10)
            ModelList(items: download.items, done: download.doneItems, current: download.currentItem)
            HStack {
                Label(download.folder.abbreviatedPath, systemImage: "folder")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .help("Stop now. The next download continues from here.")
            }
        }
        .animation(.smooth(duration: 0.35), value: download.fraction)
    }

    private var detail: String {
        var parts = ["\(ByteFormat.string(download.bytes)) of \(ByteFormat.string(download.total))"]
        if download.speed > 1 {
            parts.append(ByteFormat.rate(download.speed))
            let left = ByteFormat.remaining(download.secondsLeft)
            if !left.isEmpty { parts.append(left) }
        } else {
            parts.append("connecting…")
        }
        return parts.joined(separator: "  ·  ")
    }
}

/// Rounded progress bar with the gradient and a soft moving sheen while active.
struct ProgressCapsule: View {
    let fraction: Double
    let animated: Bool
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [ModelPalette.accent, ModelPalette.accent2], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geo.size.height, geo.size.width * min(1, max(0, fraction))))
                    .overlay {
                        if animated {
                            LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 80)
                                .offset(x: phase * geo.size.width)
                                .blendMode(.plusLighter)
                        }
                    }
                    .clipShape(Capsule())
            }
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1.1 }
        }
    }
}

/// The models with their sizes; done ones get a check, the current one a spinner.
private struct ModelList: View {
    let items: [ModelManifest.Item]
    let done: Set<String>
    let current: String?

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], alignment: .leading, spacing: 7) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    icon(item).frame(width: 16)
                    Text(item.label).lineLimit(1)
                        .foregroundStyle(done.contains(item.id) || item.id == current ? .primary : .secondary)
                    Spacer(minLength: 4)
                    Text(ByteFormat.string(item.bytes)).foregroundStyle(.tertiary).monospacedDigit()
                }
                .font(.callout)
                .help(item.label)
            }
        }
    }

    @ViewBuilder private func icon(_ item: ModelManifest.Item) -> some View {
        if done.contains(item.id) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).transition(.scale.combined(with: .opacity))
        } else if item.id == current {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        }
    }
}
