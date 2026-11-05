import AppKit
import SwiftUI

/// Reset Media Caches (R43): pick which slow caches to rebuild, with their sizes.
enum ResetCachesSheet {
    static func present(editor: EditorModel, window: NSWindow?) {
        guard let window, window.attachedSheet == nil, editor.mediaResetMessage == nil else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: ResetCachesView(editor: editor) { kinds in
            window.endSheet(sheet)
            guard let kinds, !kinds.isEmpty else { return }
            Task { @MainActor in await editor.resetMediaCaches(kinds) }
        })
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }
}

struct ResetCachesView: View {
    let editor: EditorModel
    let finish: (Set<MediaCacheKind>?) -> Void
    @State private var chosen = Set(MediaCacheKind.allCases)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill").font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reset Media Caches").font(.title2.bold())
                    Text("Delete and rebuild the caches below. Your edits and lyric timing are not touched.").foregroundStyle(.secondary)
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
            }
            Text("The render cache (preview frames and export segments) is separate: use Clear Cache for it.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Rebuild") { finish(chosen) }.keyboardShortcut(.defaultAction).controlSize(.large).disabled(chosen.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
