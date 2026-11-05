import Foundation

/// Loads the format presets. The bundled table is copied into Application Support on
/// first launch so the user can edit it; the editable copy wins afterwards.
enum Presets {
    static var editableURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cutline", isDirectory: true)
        return dir.appendingPathComponent("presets.json")
    }

    static var bundledURL: URL? { Bundle.main.url(forResource: "presets", withExtension: "json") }

    private static var cached: [FormatPreset]?

    static func all() -> [FormatPreset] {
        if let cached { return cached }
        let loaded = load()
        cached = loaded
        return loaded
    }

    static func preset(for type: ProjectType) -> FormatPreset {
        all().first { $0.type == type } ?? fallback.first { $0.type == type }!
    }

    static func save(_ presets: [FormatPreset]) throws {
        try FileManager.default.createDirectory(at: editableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(presets).write(to: editableURL, options: .atomic)
        cached = presets
    }

    private static func load() -> [FormatPreset] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: editableURL.path), let bundledURL {
            try? fm.createDirectory(at: editableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: bundledURL, to: editableURL)
        }
        for url in [editableURL, bundledURL].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode([FormatPreset].self, from: data) {
                return p
            }
        }
        return fallback
    }

    /// Used only if both preset files are unreadable.
    static let fallback: [FormatPreset] = [
        FormatPreset(type: .musicVideo, canvases: [.init(width: 1920, height: 1080), .init(width: 3840, height: 2160)], maxDuration: nil, codec: .hevc),
        FormatPreset(type: .social, canvases: [.init(width: 1080, height: 1920)], maxDuration: 180, codec: .h264, defaultBitrateMbps: 16),
        FormatPreset(type: .ad, canvases: [.init(width: 1080, height: 1920)], maxDuration: 30, codec: .h264, defaultBitrateMbps: 12, defaultSizeTargetMB: 50),
    ]
}
