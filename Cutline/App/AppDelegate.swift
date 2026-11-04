import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Show tooltips quickly (system default is about a second).
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 250])
        // The first NSDocumentController instantiated becomes the shared one.
        _ = CutlineDocumentController()
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.newDocument(nil) }
        return true
    }
}

/// Asks for the project type and resolution before creating a new project.
final class CutlineDocumentController: NSDocumentController {
    override func newDocument(_ sender: Any?) {
        guard let project = NewProjectPrompt.run() else { return }
        let doc = ProjectDocument(project: project)
        addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
    }
}

enum NewProjectPrompt {
    static func run() -> Project? {
        let alert = NSAlert()
        alert.messageText = "New Cutline Project"
        alert.informativeText = "Choose what you are making. Portrait projects use 1080×1920."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        ProjectType.allCases.forEach { typePopup.addItem(withTitle: $0.title) }
        let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)

        func refreshSizes() {
            let type = ProjectType.allCases[typePopup.indexOfSelectedItem]
            sizePopup.removeAllItems()
            for c in Presets.preset(for: type).canvases {
                let label = c.height == 2160 || c.width == 2160 ? "4K \(c.width)×\(c.height)" : "\(c.width)×\(c.height)"
                sizePopup.addItem(withTitle: label)
            }
            sizePopup.isEnabled = sizePopup.numberOfItems > 1
        }
        refreshSizes()
        let handler = PopupHandler(refreshSizes)
        typePopup.target = handler
        typePopup.action = #selector(PopupHandler.changed)

        let stack = NSStackView(views: [labeled("Type", typePopup), labeled("Resolution", sizePopup)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 64)
        alert.accessoryView = stack

        let response = withExtendedLifetime(handler) { alert.runModal() }
        guard response == .alertFirstButtonReturn else { return nil }
        let type = ProjectType.allCases[typePopup.indexOfSelectedItem]
        let canvas = Presets.preset(for: type).canvases[max(0, sizePopup.indexOfSelectedItem)]
        return Project(type: type, canvas: canvas)
    }

    private static func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        return row
    }

    private final class PopupHandler: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func changed() { action() }
    }
}
