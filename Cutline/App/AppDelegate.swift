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

    private var controlServer: ControlServer?

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
        HelperProcess.terminateAll()
        // The partial file stays; the next download continues from it.
        MainActor.assumeIsolated { ModelStore.shared.cancelDownload() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        // Window restoration and Finder opens finish just after launch; only offer a new
        // project if nothing was opened by then.
        guard !Self.isTestHost else { return }
        // The control channel (Claude and other local programs, with the user's approval).
        let server = ControlServer { request in await ControlService.shared.handle(request) }
        do { try server.start(); controlServer = server } catch { NSLog("Cutline control channel unavailable: \(error)") }
        do { try ControlClientLink.publish() } catch { NSLog("Cutline: couldn't link cutline-ctl: \(error)") }
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

/// Asks for the project type and resolution before creating a new project. Until the
/// analysis models are downloaded, projects aren't opened: an open (a Finder double-click,
/// Open Recent, window restoration) shows the New Project window with the download instead,
/// and the project goes into its recent list to open once the models are ready.
final class CutlineDocumentController: NSDocumentController {
    private var modelsReady: Bool {
        AppDelegate.isTestHost || MainActor.assumeIsolated { ModelStore.shared.isReady }
    }

    private var promptScheduled = false

    override func newDocument(_ sender: Any?) {
        if let window = NewProjectPrompt.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // The window runs modally. Started from inside a main-queue block (a GCD timer or
        // async call), it would hold the main queue, so main-actor work such as the model
        // download couldn't run until it closed. A run-loop block runs outside the queue.
        guard !promptScheduled else { return }
        promptScheduled = true
        RunLoop.main.perform(inModes: [.default, .modalPanel]) { [weak self] in
            guard let self else { return }
            self.promptScheduled = false
            self.runNewProjectPrompt()
        }
    }

    private func runNewProjectPrompt() {
        guard NewProjectPrompt.window == nil else { return }
        switch NewProjectPrompt.run() {
        case .none: return
        case .open: openDocument(nil)
        case .openRecent(let url):
            openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSAlert(error: error).runModal() }
            }
        case .create(let project):
            show(ProjectDocument(project: project))
        case .importFrom(let url, let type, let canvas, let fps):
            do { show(try ProjectImport.document(importing: url, type: type, canvas: canvas, fps: fps)) } catch { NSAlert(error: error).runModal() }
        }
    }

    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        guard modelsReady || document(for: url) != nil else {
            deferOpen(url)
            completionHandler(nil, false, nil)
            return
        }
        super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
    }

    override func reopenDocument(for urlOrNil: URL?, withContentsOf contentsURL: URL, display displayDocument: Bool,
                                 completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        guard modelsReady else {
            deferOpen(urlOrNil ?? contentsURL)
            completionHandler(nil, false, nil)
            return
        }
        super.reopenDocument(for: urlOrNil, withContentsOf: contentsURL, display: displayDocument, completionHandler: completionHandler)
    }

    /// Remembers the project in the recent list and shows New Project with the model download.
    private func deferOpen(_ url: URL) {
        RecentProjects.note(url)
        newDocument(nil)
    }

    private func show(_ doc: ProjectDocument) {
        addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
    }
}
