import AppKit
import SwiftUI

/// The "New Project" window: pick what you're making as a card, then a resolution.
enum NewProjectPrompt {
    static func run() -> Project? {
        var result: Project?
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        let host = NSHostingController(rootView: NewProjectView { project in
            result = project
            NSApp.stopModal()
        })
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        window.center()
        let closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            NSApp.stopModal()
        }
        NSApp.runModal(for: window)
        NotificationCenter.default.removeObserver(closeObserver)
        window.orderOut(nil)
        return result
    }
}

struct NewProjectView: View {
    let finish: (Project?) -> Void
    @State private var type: ProjectType = .musicVideo
    @State private var canvasIndex = 0

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
            HStack(spacing: 12) {
                ForEach(ProjectType.allCases) { t in
                    TypeCard(type: t, preset: Presets.preset(for: t), selected: t == type)
                        .onTapGesture { type = t; canvasIndex = 0 }
                        .onTapGesture(count: 2) { type = t; create() }
                }
            }
            HStack {
                Text("Resolution").foregroundStyle(.secondary)
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
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Create Project", action: create).keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 640)
    }

    private func create() {
        let canvases = preset.canvases
        finish(Project(type: type, canvas: canvases[min(canvasIndex, canvases.count - 1)]))
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
