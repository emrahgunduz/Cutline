import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True when the app is only hosting unit tests.
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static func main() {
        if isTestHost {
            // Never reopen the user's projects (or autosave them) while hosting tests.
            UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        }
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

    func applicationWillTerminate(_ notification: Notification) {
        HelperProcess.terminateAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        // Window restoration and Finder opens finish just after launch; only offer a new
        // project if nothing was opened by then.
        guard !Self.isTestHost else { return }
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
        case .openRecent(let url):
            openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSAlert(error: error).runModal() }
            }
        case .create(let project):
            show(ProjectDocument(project: project))
        case .importFrom(let url, let type, let canvas):
            do { show(try ProjectImport.document(importing: url, type: type, canvas: canvas)) } catch { NSAlert(error: error).runModal() }
        }
    }

    private func show(_ doc: ProjectDocument) {
        addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
    }
}
