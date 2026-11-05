import XCTest

/// The user's sample project (gitignored). Tests that need it skip when it is absent.
enum SampleMedia {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Example_Music_Video")
    static var song: URL { root.appendingPathComponent("Zamansız Yazgılar.wav") }
    static var lyrics: URL { root.appendingPathComponent("Zamansiz Yazgilar.txt") }
    static var footage: URL { root.appendingPathComponent("Footage") }

    static func require(_ url: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Sample media not found at \(url.path)")
        }
        return url
    }
}
