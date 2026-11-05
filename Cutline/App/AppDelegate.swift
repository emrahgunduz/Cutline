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
        // Window restoration and Finder opens finish just after launch; only offer a new
        // project if nothing was opened by then.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if NSDocumentController.shared.documents.isEmpty { NSDocumentController.shared.newDocument(nil) }
        }
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
        switch NewProjectPrompt.run() {
        case .none: return
        case .open: openDocument(nil)
        case .create(let project):
            let doc = ProjectDocument(project: project)
            addDocument(doc)
            doc.makeWindowControllers()
            doc.showWindows()
        }
    }
}
