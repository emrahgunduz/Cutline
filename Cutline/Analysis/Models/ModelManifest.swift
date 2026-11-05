import Foundation

/// The pinned model set (helper/cutline_helper/models.json, bundled into the app and read
/// by the helper too): every file with its download URL, size and SHA-256.
struct ModelManifest: Decodable, Sendable {
    struct File: Decodable, Sendable, Equatable {
        let path: String
        let url: URL
        let size: Int64
        let sha256: String
    }

    struct Item: Decodable, Sendable, Identifiable {
        let id: String
        let label: String
        let bytes: Int64
        let files: [File]
    }

    let version: Int
    let totalBytes: Int64
    let items: [Item]

    enum CodingKeys: String, CodingKey {
        case version, items
        case totalBytes = "total_bytes"
    }

    var files: [File] { items.flatMap(\.files) }

    static func load(from url: URL) throws -> ModelManifest {
        try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: url))
    }

    static func loadBundled(_ bundle: Bundle = .main) throws -> ModelManifest {
        guard let url = bundledURL(bundle) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "models.json is missing from the app"])
        }
        return try load(from: url)
    }

    static func bundledURL(_ bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "models", withExtension: "json")
    }
}

/// What a models folder holds, compared with the manifest (the same rules as the helper's
/// `models.status()`): a file counts only when its size matches; "ready" needs every byte
/// and a `.complete` marker naming the manifest's version.
struct ModelFolderStatus: Equatable, Sendable {
    enum State: Equatable, Sendable { case ready, partial, missing }

    static let marker = ".complete"

    let state: State
    /// Bytes of complete files (what the state is judged by).
    let haveBytes: Int64
    let totalBytes: Int64
    /// Bytes already in `.part` files that a download continues from.
    var partBytes: Int64 = 0

    /// Everything on disk, including the partial files.
    var downloadedBytes: Int64 { min(totalBytes, haveBytes + partBytes) }
    var fraction: Double { totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0 }

    static func check(_ folder: URL, manifest: ModelManifest, fileManager: FileManager = .default) -> ModelFolderStatus {
        var have: Int64 = 0, part: Int64 = 0
        func size(_ url: URL) -> Int64? {
            (try? fileManager.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)[.size] as? NSNumber)?.int64Value
        }
        for file in manifest.files {
            let url = folder.appendingPathComponent(file.path)
            if size(url) == file.size {
                have += file.size
            } else if let p = size(url.appendingPathExtension("part")) {
                part += min(p, file.size)
            }
        }
        let markerURL = folder.appendingPathComponent(marker)
        let state: State
        if have == manifest.totalBytes && installedVersion(folder) == manifest.version {
            state = .ready
        } else if have == 0 && part == 0 && !fileManager.fileExists(atPath: markerURL.path) {
            state = .missing
        } else {
            state = .partial
        }
        return ModelFolderStatus(state: state, haveBytes: have, totalBytes: manifest.totalBytes, partBytes: part)
    }

    static func installedVersion(_ folder: URL) -> Int? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(marker)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj["version"] as? NSNumber)?.intValue
    }

    /// Written last, after every file is in place and verified.
    static func writeMarker(_ folder: URL, version: Int) throws {
        let obj: [String: Any] = ["version": version, "installed": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: obj).write(to: folder.appendingPathComponent(marker), options: .atomic)
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func remaining(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "about 1 minute left" : "about \(minutes) minutes left"
    }
}

extension URL {
    /// Path with the home folder shown as ~.
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
