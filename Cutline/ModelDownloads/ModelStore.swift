import AppKit
import Foundation
import Observation

/// Where the analysis models live, whether they are ready, and the download that fetches them.
/// The app ships without them; until they're ready, no project can be created or opened.
///
/// Which folder is used: the one the user chose (remembered), else
/// ~/Library/Application Support/Cutline/models.
@MainActor
@Observable
final class ModelStore {
    enum Source: Equatable { case chosen, standard }

    enum State: Equatable {
        case checking
        case ready
        /// Some files are there (an interrupted download, or an older model set).
        case partial(ModelFolderStatus)
        case missing
        /// The chosen folder can't be reached (e.g. its disk is not connected).
        case unavailable
        case broken(String)
    }

    static let shared = ModelStore()

    static let folderName = "Cutline Models"
    nonisolated static let chosenKey = "models.folder"

    let manifest: ModelManifest?
    private(set) var folder: URL
    private(set) var source: Source
    private(set) var state: State = .checking
    private(set) var download: ModelDownloader?
    /// Set while files are being moved to another folder.
    private(set) var moving = false
    var lastError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let standard: URL
    @ObservationIgnored var downloadConfiguration: URLSessionConfiguration = ModelDownloader.defaultConfiguration

    nonisolated static var standardFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cutline/models", isDirectory: true)
    }

    /// The folder in use, readable off the main actor (the helper gets it as CUTLINE_MODELS).
    nonisolated static func currentFolder(_ defaults: UserDefaults = .standard) -> URL {
        defaults.string(forKey: chosenKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? standardFolder
    }

    init(defaults: UserDefaults = .standard, manifest: ModelManifest? = try? ModelManifest.loadBundled(),
         standardFolder: URL = ModelStore.standardFolder, observeSystem: Bool = true) {
        self.defaults = defaults
        self.manifest = manifest
        standard = standardFolder
        folder = standardFolder
        source = .standard
        resolve()
        guard observeSystem else { return }
        // Notice a reconnected disk (or files restored meanwhile) without the user pressing Try Again.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckIfNotReady() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckIfNotReady() }
        }
    }

    private func recheckIfNotReady() {
        guard !isReady, !isDownloading, !moving else { return }
        refresh()
    }

    var isReady: Bool { state == .ready }
    var isDownloading: Bool { download?.isRunning ?? false }

    // MARK: - Resolving and checking

    func resolve() {
        guard manifest != nil else {
            state = .broken("The app is missing its model list (models.json).")
            return
        }
        if let path = defaults.string(forKey: Self.chosenKey) {
            folder = URL(fileURLWithPath: path, isDirectory: true)
            source = .chosen
        } else {
            folder = standard
            source = .standard
        }
        refresh()
    }

    /// Re-checks the current folder (e.g. after the user reconnects a disk).
    func refresh() {
        guard let manifest else { return }
        if source == .chosen && !Self.isReachable(folder) {
            state = .unavailable
            return
        }
        let st = ModelFolderStatus.check(folder, manifest: manifest)
        switch st.state {
        case .ready: state = .ready
        case .missing: state = .missing
        case .partial: state = .partial(st)
        }
    }

    /// A chosen folder counts as reachable if it, or the folder it will be created in, exists.
    static func isReachable(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path) || fm.fileExists(atPath: url.deletingLastPathComponent().path)
    }

    // MARK: - Choosing folders

    /// The models folder to use inside a folder the user picked: the picked folder itself if it
    /// already holds models, otherwise a "Cutline Models" folder inside it.
    func modelsFolder(in picked: URL) -> URL {
        guard let manifest else { return picked }
        if ModelFolderStatus.check(picked, manifest: manifest).state != .missing { return picked }
        let inside = picked.appendingPathComponent(Self.folderName, isDirectory: true)
        return inside
    }

    func use(folder url: URL) {
        defaults.set(url.path, forKey: Self.chosenKey)
        folder = url
        source = .chosen
        refresh()
    }

    func useStandardFolder() {
        defaults.removeObject(forKey: Self.chosenKey)
        folder = standard
        source = .standard
        refresh()
    }

    // MARK: - Download

    func startDownload() {
        guard let manifest, !isDownloading, !moving else { return }
        lastError = nil
        let d = ModelDownloader(folder: folder, manifest: manifest, configuration: downloadConfiguration)
        d.onFinish = { [weak self] phase in
            guard let self else { return }
            if case .failed(let message) = phase { self.lastError = message }
            self.refresh()
        }
        download = d
        d.start()
    }

    func cancelDownload() { download?.cancel() }

    /// Clears a finished, cancelled or failed download so the card shows the folder state again.
    func dismissDownload() {
        if !isDownloading { download = nil }
    }

    // MARK: - Managing the folder

    /// Moves the models into a "Cutline Models" folder inside `picked` and uses them there.
    func move(into picked: URL) async {
        let source = folder
        let target = picked.appendingPathComponent(Self.folderName, isDirectory: true)
        guard target.standardizedFileURL != source.standardizedFileURL else { return }
        if FileManager.default.fileExists(atPath: target.path) {
            lastError = "\(target.path) already exists. Choose another folder, or use it with Use Existing Folder…"
            return
        }
        moving = true
        defer { moving = false }
        do {
            try await Task.detached {
                try FileManager.default.moveItem(at: source, to: target)  // copies, then deletes, across disks
            }.value
            use(folder: target)
        } catch {
            lastError = "Moving the models failed: \(error.localizedDescription)"
            refresh()
        }
    }

    /// Switches to a folder that already holds a complete set.
    @discardableResult
    func useExisting(_ picked: URL) -> Bool {
        guard let manifest else { return false }
        for candidate in [picked, picked.appendingPathComponent(Self.folderName, isDirectory: true)]
        where ModelFolderStatus.check(candidate, manifest: manifest).state == .ready {
            use(folder: candidate)
            return true
        }
        lastError = "No complete set of models in \(picked.path). Choose the folder that contains “\(Self.folderName)”, or download the models there."
        return false
    }

    /// Moves the models folder to the Trash (recoverable); they must be downloaded again.
    func moveToTrash() {
        do {
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            }
        } catch {
            lastError = "Could not move the models to the Trash: \(error.localizedDescription)"
        }
        refresh()
    }

    var bytesOnDisk: Int64 {
        guard let manifest else { return 0 }
        return ModelFolderStatus.check(folder, manifest: manifest).haveBytes
    }
}
