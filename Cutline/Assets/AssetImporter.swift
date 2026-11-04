import AppKit
import UniformTypeIdentifiers

enum AssetImporter {
    static func presentOpenPanel(for editor: EditorModel, window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .image, .audio, .plainText]
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            _ = panel.urls
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }
}
