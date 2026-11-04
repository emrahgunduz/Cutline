import AppKit

/// Saved panel sizes, stored per project in `layout.json`.
struct LayoutState: Codable, Equatable {
    var assetsWidth: Double = 280
    var inspectorWidth: Double = 300
    var timelineHeight: Double = 320
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

    func folder(_ name: String) -> URL {
        let url = packageURL.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    convenience init(project: Project) {
        self.init()
        editor.replaceWithoutUndo(project)
    }

    override class var autosavesInPlace: Bool { true }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    override func makeWindowControllers() {
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
        let project = try JSONDecoder().decode(Project.self, from: data)
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
        try? enc.encode(layout).write(to: fileURL.appendingPathComponent("layout.json"), options: .atomic)
    }
}
