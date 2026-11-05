import CryptoKit
import XCTest
@testable import Cutline

/// The model folder rules, the store's folder choices, and the resumable, verified download
/// (served by a stub URL protocol, so no network).
@MainActor
final class ModelStoreTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private let suite = "ModelStoreTests-\(UUID())"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)
        StubServer.reset()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Fixtures

    nonisolated static let a = Data((0..<5000).map { UInt8($0 % 251) })
    nonisolated static let b = Data("tokenizer".utf8)

    nonisolated static func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    nonisolated static func manifest(version: Int = 1, shaA: String? = nil) -> ModelManifest {
        let json = """
        {"version": \(version), "total_bytes": \(a.count + b.count), "items": [
          {"id": "big", "label": "Big", "bytes": \(a.count), "files": [
            {"path": "torch/a.ckpt", "url": "https://models.test/a", "size": \(a.count), "sha256": "\(shaA ?? hex(a))"}]},
          {"id": "small", "label": "Small", "bytes": \(b.count), "files": [
            {"path": "w/b.txt", "url": "https://models.test/b", "size": \(b.count), "sha256": "\(hex(b))"}]}]}
        """
        return try! JSONDecoder().decode(ModelManifest.self, from: Data(json.utf8))
    }

    private func store(_ manifest: ModelManifest = ModelStoreTests.manifest()) -> ModelStore {
        let s = ModelStore(defaults: defaults, manifest: manifest, standardFolder: root.appendingPathComponent("std"), observeSystem: false)
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubServer.self]
        s.downloadConfiguration = c
        return s
    }

    /// A complete folder made of sparse files (no real disk use).
    private func fill(_ folder: URL, _ manifest: ModelManifest = ModelStoreTests.manifest(), marker: Int? = 1) throws {
        for f in manifest.files {
            let url = folder.appendingPathComponent(f.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: UInt64(f.size))
            try h.close()
        }
        if let marker { try ModelFolderStatus.writeMarker(folder, version: marker) }
    }

    // MARK: Folder status

    func testFolderStatusRules() throws {
        let m = Self.manifest()
        let f = root.appendingPathComponent("f")
        XCTAssertEqual(ModelFolderStatus.check(f, manifest: m).state, .missing)
        try fill(f, marker: nil)
        XCTAssertEqual(ModelFolderStatus.check(f, manifest: m).state, .partial, "every byte but no marker")
        try ModelFolderStatus.writeMarker(f, version: 1)
        XCTAssertEqual(ModelFolderStatus.check(f, manifest: m), ModelFolderStatus(state: .ready, haveBytes: m.totalBytes, totalBytes: m.totalBytes))
        XCTAssertEqual(ModelFolderStatus.check(f, manifest: Self.manifest(version: 2)).state, .partial, "an older model set")
        try Data("x".utf8).write(to: f.appendingPathComponent("w/b.txt"))
        XCTAssertEqual(ModelFolderStatus.check(f, manifest: m).haveBytes, Int64(Self.a.count))
    }

    func testBundledManifestIsConsistent() throws {
        let m = try ModelManifest.loadBundled()
        XCTAssertEqual(m.totalBytes, m.files.reduce(0) { $0 + $1.size })
        for item in m.items { XCTAssertEqual(item.bytes, item.files.reduce(0) { $0 + $1.size }, item.id) }
        XCTAssertTrue(m.files.allSatisfy { $0.url.scheme == "https" && $0.sha256.count == 64 })
        XCTAssertTrue(m.files.contains { $0.path == "whisper-medium/model.bin" })
    }

    // MARK: Choosing folders

    func testChosenFolderIsRememberedAndUsedByTheHelper() throws {
        let s = store()
        XCTAssertEqual(s.source, .standard)
        XCTAssertEqual(s.state, .missing)
        let chosen = root.appendingPathComponent("disk/Cutline Models")
        try fill(chosen)
        s.use(folder: chosen)
        XCTAssertTrue(s.isReady)
        XCTAssertEqual(ModelStore.currentFolder(defaults).path, chosen.path)
        let again = store()
        XCTAssertEqual(again.source, .chosen)
        XCTAssertTrue(again.isReady)
        again.useStandardFolder()
        XCTAssertEqual(ModelStore.currentFolder(defaults), ModelStore.standardFolder)
        XCTAssertEqual(again.state, .missing)
    }

    func testUnreachableChosenFolder() {
        defaults.set("/Volumes/NotConnected-\(UUID())/Cutline Models", forKey: ModelStore.chosenKey)
        XCTAssertEqual(store().state, .unavailable)
    }

    func testModelsFolderInPickedAndUseExisting() throws {
        let s = store()
        let picked = root.appendingPathComponent("picked")
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        XCTAssertEqual(s.modelsFolder(in: picked).lastPathComponent, ModelStore.folderName)
        XCTAssertFalse(s.useExisting(picked))
        XCTAssertNotNil(s.lastError)
        try fill(picked.appendingPathComponent(ModelStore.folderName))
        XCTAssertTrue(s.useExisting(picked))
        XCTAssertTrue(s.isReady)
        XCTAssertEqual(s.folder.lastPathComponent, ModelStore.folderName)
    }

    func testMoveIntoAnotherFolder() async throws {
        let s = store()
        try fill(s.folder)
        s.refresh()
        XCTAssertTrue(s.isReady)
        let disk = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        await s.move(into: disk)
        XCTAssertEqual(s.folder.path, disk.appendingPathComponent(ModelStore.folderName).path)
        XCTAssertTrue(s.isReady)
    }

    // MARK: Download

    func testDownloadVerifiesAndMarksComplete() async throws {
        let s = store()
        s.startDownload()
        await s.download?.wait()
        XCTAssertEqual(s.download?.phase, .finished)
        XCTAssertTrue(s.isReady)
        XCTAssertEqual(try Data(contentsOf: s.folder.appendingPathComponent("torch/a.ckpt")), Self.a)
        XCTAssertEqual(s.download?.doneItems, ["big", "small"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("torch/a.ckpt.part").path))
    }

    func testDownloadResumesFromThePartFile() async throws {
        let s = store()
        let part = s.folder.appendingPathComponent("torch/a.ckpt.part")
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.a.prefix(1200).write(to: part)
        let paused = ModelFolderStatus.check(s.folder, manifest: Self.manifest())
        XCTAssertEqual(paused.state, .partial, "a part file alone counts as started")
        XCTAssertEqual(paused.downloadedBytes, 1200)
        s.startDownload()
        await s.download?.wait()
        XCTAssertTrue(s.isReady)
        XCTAssertEqual(StubServer.ranges["/a"], "bytes=1200-")
        XCTAssertEqual(try Data(contentsOf: s.folder.appendingPathComponent("torch/a.ckpt")), Self.a)
    }

    func testServerIgnoringRangeRestartsTheFile() async throws {
        StubServer.honorRange = false
        let s = store()
        let part = s.folder.appendingPathComponent("torch/a.ckpt.part")
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 9, count: 700).write(to: part)
        s.startDownload()
        await s.download?.wait()
        XCTAssertTrue(s.isReady)
        XCTAssertEqual(try Data(contentsOf: s.folder.appendingPathComponent("torch/a.ckpt")), Self.a)
    }

    func testChecksumMismatchFailsAndDeletesTheFile() async throws {
        let s = store(Self.manifest(shaA: String(repeating: "0", count: 64)))
        s.startDownload()
        await s.download?.wait()
        guard case .failed(let message)? = s.download?.phase else { return XCTFail("\(String(describing: s.download?.phase))") }
        XCTAssertTrue(message.contains("checksum"), message)
        XCTAssertEqual(s.lastError, message)
        XCTAssertFalse(s.isReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("torch/a.ckpt.part").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.folder.appendingPathComponent(".complete").path))
    }

    func testServerErrorIsReported() async throws {
        StubServer.status = 404
        let s = store()
        s.startDownload()
        await s.download?.wait()
        guard case .failed(let message)? = s.download?.phase else { return XCTFail() }
        XCTAssertTrue(message.contains("404"), message)
        XCTAssertEqual(s.state, .missing)
    }

    func testCancelKeepsThePartialFile() async throws {
        StubServer.delay = 0.5
        let s = store()
        s.startDownload()
        try await Task.sleep(for: .milliseconds(100))
        s.cancelDownload()
        await s.download?.wait()
        XCTAssertEqual(s.download?.phase, .cancelled)
        XCTAssertFalse(s.isReady)
    }

    func testRemainingTimeWording() {
        XCTAssertEqual(ByteFormat.remaining(30), "less than a minute left")
        XCTAssertEqual(ByteFormat.remaining(185), "about 3 minutes left")
        XCTAssertEqual(ByteFormat.remaining(.nan), "")
    }
}

/// Serves the fixture files, honouring Range requests (206) unless told not to.
final class StubServer: URLProtocol {
    nonisolated(unsafe) static var honorRange = true
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var delay: TimeInterval = 0
    nonisolated(unsafe) static var ranges: [String: String] = [:]

    static func reset() { honorRange = true; status = 200; delay = 0; ranges = [:] }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "models.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let body = url.path == "/a" ? ModelStoreTests.a : ModelStoreTests.b
        var start = 0
        var code = Self.status
        if let range = request.value(forHTTPHeaderField: "Range") {
            Self.ranges[url.path] = range
            if Self.honorRange, code == 200, let n = Int(range.dropFirst(6).dropLast()) { start = n; code = 206 }
        }
        let slice = code >= 400 ? Data() : body.subdata(in: start..<body.count)
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(slice.count)"])!
        let deliver = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: slice)
            client?.urlProtocolDidFinishLoading(self)
        }
        if Self.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}
