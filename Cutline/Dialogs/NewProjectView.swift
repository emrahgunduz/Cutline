import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "New Project" window: pick what you're making as a card, then a resolution.
enum NewProjectChoice { case create(Project), open, openRecent(URL), importFrom(URL, ProjectType, CanvasSize) }

enum NewProjectPrompt {
    /// The window while it's up (it runs modally, so there is at most one).
    private(set) static var window: NSWindow?
    static var isShowing: Bool { window != nil }

    /// nil when cancelled.
    static func run() -> NewProjectChoice? {
        var result: NewProjectChoice?
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        // Swift owns it; AppKit releasing it on close as well crashes the app.
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        let host = NSHostingController(rootView: NewProjectView { choice in
            result = choice
            NSApp.stopModal()
        })
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        window.center()
        let closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            NSApp.stopModal()
        }
        Self.window = window
        NSApp.runModal(for: window)
        Self.window = nil
        NotificationCenter.default.removeObserver(closeObserver)
        window.orderOut(nil)
        return result
    }
}

struct NewProjectView: View {
    let finish: (NewProjectChoice?) -> Void
    @State private var type: ProjectType = .musicVideo
    @State private var canvasIndex = 0
    @State private var recents: [URL] = RecentProjects.list()
    /// Projects can't be made or opened until the analysis models are downloaded.
    private var models: ModelStore { .shared }
    private var ready: Bool { models.isReady }

    private var preset: FormatPreset { Presets.preset(for: type) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Project").font(.title2.bold())
                    Text("Choose what you're making. You can't change this later.").foregroundStyle(.secondary)
                }
            }
            if !ready {
                ModelsCard(store: models)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.97))))
            }
            HStack(spacing: 12) {
                ForEach(ProjectType.allCases) { t in
                    TypeCard(type: t, preset: Presets.preset(for: t), selected: t == type)
                        .onTapGesture { type = t; canvasIndex = 0 }
                        .onTapGesture(count: 2) { type = t; if ready { create() } }
                }
            }
            HStack {
                Text("Resolution").foregroundStyle(.secondary).fixedSize()
                Picker("", selection: $canvasIndex) {
                    ForEach(preset.canvases.indices, id: \.self) { i in
                        let c = preset.canvases[i]
                        Text(verbatim: (c.height >= 2160 || c.width >= 2160 ? "4K · " : "HD · ") + "\(c.width)×\(c.height)").tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(preset.canvases.count < 2)
                Spacer()
            }
            HStack {
                Button("Open…") { finish(.open) }.controlSize(.large).help("Open an existing project")
                    .disabled(!ready)
                Button("Import from Project…", action: importFromProject).controlSize(.large)
                    .help("Create this project with the song, lyric timing, clips and tracks of another project (a one-time copy)")
                    .disabled(!ready)
                Spacer()
                if !ready {
                    Text(models.isDownloading ? "Downloading the models…" : "Download the models to start")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Create Project", action: create).keyboardShortcut(.defaultAction).controlSize(.large)
                    .disabled(!ready)
            }
            Divider()
            recentSection
        }
        .padding(24)
        .frame(width: 640)
        .animation(.smooth(duration: 0.35), value: ready)
        // A project opened while the models were missing lands in the list (see CutlineDocumentController).
        .onReceive(NotificationCenter.default.publisher(for: RecentProjects.changed)) { _ in recents = RecentProjects.list() }
    }

    @ViewBuilder private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Projects").font(.headline)
                Spacer()
                Button("Clear") {
                    RecentProjects.clear()
                    recents = []
                }
                .controlSize(.small)
                .disabled(recents.isEmpty)
                .help("Forget the recent projects list (the projects themselves are not touched)")
            }
            if recents.isEmpty {
                Text("Projects you open or save appear here.").font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(recents, id: \.self) { url in
                            RecentRow(url: url, enabled: ready) { finish(.openRecent(url)) }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private var canvas: CanvasSize { preset.canvases[min(canvasIndex, preset.canvases.count - 1)] }

    private func create() {
        guard ready else { return }
        finish(.create(Project(type: type, canvas: canvas)))
    }

    private func importFromProject() {
        let panel = NSOpenPanel()
        panel.message = "Choose the project to copy the song, lyrics and clips from"
        panel.prompt = "Import"
        // The exported document type: a type made from the extension doesn't match packages.
        panel.allowedContentTypes = [UTType("com.emrahgunduz.cutline.project") ?? .package]
        panel.treatsFilePackagesAsDirectories = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        finish(.importFrom(url, type, canvas))
    }
}

private struct TypeCard: View {
    let type: ProjectType
    let preset: FormatPreset
    let selected: Bool

    private var icon: String {
        switch type {
        case .musicVideo: "film"
        case .social: "iphone"
        case .ad: "megaphone"
        }
    }

    private var subtitle: String {
        switch type {
        case .musicVideo: "16:9 · cinemascope bars"
        case .social: "9:16 · TikTok, Reels, Shorts"
        case .ad: "9:16 · paid placements"
        }
    }

    private var limit: String {
        preset.maxDuration.map { $0 >= 60 ? "Up to \(Int($0 / 60)) min" : "Up to \(Int($0)) s" } ?? "No length limit"
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing).opacity(selected ? 1 : 0.55))
                    .frame(width: type.isPortrait ? 36 : 80, height: type.isPortrait ? 64 : 45)
                Image(systemName: icon).foregroundStyle(.white).font(.title3)
            }
            .frame(height: 70)
            VStack(spacing: 3) {
                Text(type.title.replacingOccurrences(of: " (16:9)", with: "").replacingOccurrences(of: " (9:16)", with: ""))
                    .font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                Text(limit)
                Text(preset.codec == .hevc ? "Exports H.265 (HEVC)" : "Exports H.264")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }
}

/// Cutline's own list of recently opened or saved projects (newest first, up to 10).
/// Kept in user defaults because the system recent-documents list doesn't record this
/// locally signed build.
enum RecentProjects {
    static let limit = 10
    static let key = "recentProjects"
    static var defaults: UserDefaults = .standard

    /// Projects that still exist on disk.
    static func list() -> [URL] {
        (defaults.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func note(_ url: URL) {
        guard url.pathExtension == "cutline", !url.path.hasPrefix(FileManager.default.temporaryDirectory.path) else { return }
        var paths = (defaults.stringArray(forKey: key) ?? []).filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        defaults.set(Array(paths.prefix(limit)), forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func clear() {
        defaults.removeObject(forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static let changed = Notification.Name("CutlineRecentProjectsChanged")
}

private struct RecentRow: View {
    let url: URL
    var enabled = true
    let open: () -> Void
    @State private var hovering = false

    private var folder: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
    private var modified: String? {
        guard let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        return d.formatted(.relative(presentation: .named))
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 13, weight: .medium))
                    Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let modified { Text(modified).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.accentColor.opacity(0.15) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .onHover { hovering = $0 && enabled }
        .help(enabled ? url.path : "\(url.path)\nOpens once the models are downloaded")
    }
}
