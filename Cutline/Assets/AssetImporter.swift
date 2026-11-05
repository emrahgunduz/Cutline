import AppKit

enum AssetImporter {
    static func presentOpenPanel(for editor: EditorModel, window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .image, .audio, .plainText]
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            let urls = panel.urls
            if editor.project.assets.contains(where: { $0.kind == .lyrics }),
               urls.contains(where: { AssetLibrary.kind(of: $0) == .lyrics }) {
                let alert = NSAlert()
                alert.messageText = "Replace the lyrics file?"
                alert.informativeText = "A project has one lyrics TXT. The new file replaces the current one."
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            Task { @MainActor in
                let errors = await editor.importFiles(urls)
                if let first = errors.first { NSAlert(error: first).runModal() }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }
}
