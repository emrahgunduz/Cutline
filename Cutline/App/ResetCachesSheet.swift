import AppKit
import SwiftUI

/// Reset Media Caches (R43): pick which slow caches to rebuild, with their sizes.
enum ResetCachesSheet {
    static func present(editor: EditorModel, window: NSWindow?) {
        guard let window, window.attachedSheet == nil else { return }
        if editor.mediaResetTask != nil {
            // One reset at a time: say what is running and offer to stop it.
            let alert = NSAlert()
            alert.messageText = "Media caches are being rebuilt"
            alert.informativeText = (editor.mediaResetMessage ?? "Working…") + " You can keep editing meanwhile, or stop after the current step."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Stop")
            alert.beginSheetModal(for: window) { r in if r == .alertSecondButtonReturn { MainActor.assumeIsolated { editor.stopMediaReset() } } }
            return
        }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: ResetCachesView(editor: editor) { choice in
            window.endSheet(sheet)
            guard let choice, !choice.kinds.isEmpty else { return }
            MainActor.assumeIsolated { editor.startMediaReset(choice.kinds, removeProxies: choice.removeProxies) }
        })
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }
}

struct ResetCachesView: View {
    let editor: EditorModel
    let finish: ((kinds: Set<MediaCacheKind>, removeProxies: Bool)?) -> Void
    @State private var chosen = Set(MediaCacheKind.allCases)
    @State private var removeProxies = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill").font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reset Media Caches").font(.title2.bold())
                    Text("Delete and rebuild the caches below. Your edits and lyric timing are not touched.").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(MediaCacheKind.allCases) { kind in
                Toggle(isOn: Binding(get: { chosen.contains(kind) }, set: { on in if on { chosen.insert(kind) } else { chosen.remove(kind) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(kind.title)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: editor.mediaCacheBytes(kind), countStyle: .file))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Text(kind.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                if kind == .proxies && chosen.contains(.proxies) {
                    Picker("", selection: $removeProxies) {
                        Text("Rebuild at their current size").tag(false)
                        Text("Remove them").tag(true)
                    }
                    .pickerStyle(.radioGroup).labelsHidden().padding(.leading, 20)
                }
            }
            Text("The render cache (preview frames and export segments) is separate: use Clear Cache for it.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button(chosen == [.proxies] && removeProxies ? "Remove" : "Rebuild") { finish((chosen, removeProxies)) }
                    .keyboardShortcut(.defaultAction).controlSize(.large).disabled(chosen.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
