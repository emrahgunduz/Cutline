import AppKit

/// Saved panel sizes, stored per project in `layout.json`.
struct LayoutState: Codable, Equatable {
    var assetsWidth: Double = 280
    var inspectorWidth: Double = 300
    var timelineHeight: Double = 320
    /// Timeline row heights keyed by track id ("audio" for the audio row).
    var trackHeights: [String: Double]?
    var snapping: Bool?
}

enum ProjectFileError: LocalizedError {
    case missingProjectJSON
    case unsupportedSchema(Int)
    var errorDescription: String? {
        switch self {
        case .missingProjectJSON: "The project package has no project.json."
        case .unsupportedSchema(let v): "This project was saved by a newer Cutline (schema \(v)). Update Cutline to open it."
        }
    }
}

/// A `.cutline` package directory: project.json, layout.json and cache folders
/// (analysis/, thumbnails/, proxies/, cache/). Media is referenced, never copied.
final class ProjectDocument: NSDocument {
    static let cacheFolders = ["analysis", "thumbnails", "proxies", "cache"]

    private(set) lazy var editor = EditorModel(document: self)
    var layout = LayoutState()

    /// Where cache folders live before the first save.
    private lazy var scratchPackage: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-\(UUID().uuidString).cutline", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Root of the package on disk (the saved file, or a scratch folder for untitled projects).
    var packageURL: URL { fileURL ?? scratchPackage }

    /// A cache folder inside the package, created when missing. Saves create all of them,
    /// so creating one later is rare (for example after it was deleted by hand).
    func folder(_ name: String) -> URL {
        let url = packageURL.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        if Thread.isMainThread {
            internalPackageWrite { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        } else {
            let before = onDiskModificationDate
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let after = onDiskModificationDate
            DispatchQueue.main.async { [weak self] in self?.adoptInternalWrite(before: before, after: after) }
        }
        return url
    }

    // MARK: Outside edits

    /// Modification date of the package directory on disk.
    var onDiskModificationDate: Date? {
        guard let fileURL else { return nil }
        var url = fileURL
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Run a write Cutline makes at the package root between saves (layout.json, a new
    /// cache folder). Such writes change the package's modification date; adopting the new
    /// date keeps NSDocument from reporting them as an outside edit. The date is adopted
    /// only when the package was unchanged since the last save or read, so a real edit by
    /// another app (or a sync tool) is still detected.
    func internalPackageWrite(_ body: () -> Void) {
        let before = onDiskModificationDate
        body()
        adoptInternalWrite(before: before, after: onDiskModificationDate)
    }

    private func adoptInternalWrite(before: Date?, after: Date?) {
        guard let before, let after, let recorded = fileModificationDate,
              Self.sameDate(before, recorded),
              let now = onDiskModificationDate, Self.sameDate(now, after) else { return }
        fileModificationDate = after
    }

    private static func sameDate(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 0.000_5 }

    convenience init(project: Project) {
        self.init()
        editor.replaceWithoutUndo(project)
    }

    override class var autosavesInPlace: Bool { true }

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    override func makeWindowControllers() {
        // Older packages may lack some cache folders; create them now, on the main thread.
        for name in Self.cacheFolders { _ = folder(name) }
        addWindowController(MainWindowController(document: self))
    }

    // MARK: Reading

    override func read(from url: URL, ofType typeName: String) throws {
        let (project, layout) = try Self.load(from: url)
        self.layout = layout
        editor.replaceWithoutUndo(project)
    }

    static func load(from url: URL) throws -> (Project, LayoutState) {
        let projectURL = url.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL) else { throw ProjectFileError.missingProjectJSON }
        struct Header: Decodable { var schemaVersion: Int }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.schemaVersion <= projectSchemaVersion else { throw ProjectFileError.unsupportedSchema(header.schemaVersion) }
        var project = try JSONDecoder().decode(Project.self, from: data)
        project.migrateFrameRate()
        var layout = LayoutState()
        if let ld = try? Data(contentsOf: url.appendingPathComponent("layout.json")),
           let l = try? JSONDecoder().decode(LayoutState.self, from: ld) {
            layout = l
        }
        return (project, layout)
    }

    // MARK: Writing

    /// Saving in place writes only the JSON files, so large caches (stems, proxies)
    /// are never rewritten. Save-as copies the cache folders to the new package.
    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        if let fileURL, fileURL.standardizedFileURL == url.standardizedFileURL, saveOperation != .saveAsOperation {
            try write(to: url, ofType: typeName, for: saveOperation, originalContentsURL: fileURL)
        } else {
            try write(to: url, ofType: typeName, for: saveOperation, originalContentsURL: packageURL)
        }
    }

    override func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, originalContentsURL: URL?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        defer {
            // Create every cache folder during the save, so later cache writes only touch
            // subfolders and never change the package's own modification date.
            for name in Self.cacheFolders { try? fm.createDirectory(at: url.appendingPathComponent(name), withIntermediateDirectories: true) }
        }
        if let original = originalContentsURL, original.standardizedFileURL != url.standardizedFileURL {
            for name in Self.cacheFolders {
                let src = original.appendingPathComponent(name)
                let dst = url.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
                try fm.copyItem(at: src, to: dst)
            }
        }
        try Self.save(project: editor.project, layout: layout, to: url)
    }

    static func save(project: Project, layout: LayoutState, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(project).write(to: url.appendingPathComponent("project.json"), options: .atomic)
        try enc.encode(layout).write(to: url.appendingPathComponent("layout.json"), options: .atomic)
    }

    /// Panel resizes are saved straight to disk without marking the project edited.
    func persistLayout() {
        guard let fileURL else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(layout) else { return }
        internalPackageWrite { try? data.write(to: fileURL.appendingPathComponent("layout.json"), options: .atomic) }
    }
}
