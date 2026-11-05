import XCTest
@testable import Cutline

/// Runs the repo's helper source with a fake models folder. Uses the bundled runtime
/// when it was built, else any Python 3 on the machine (the protocol needs only stdlib).
@MainActor
final class JobRunnerTests: XCTestCase {
    private var root: URL!
    private var models: URL!

    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    static var python: URL? {
        let candidates = [repo.appendingPathComponent("build/ml/python/bin/python3").path,
                          "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
                          "/opt/homebrew/bin/python3", "/usr/bin/python3"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jobrunner-\(UUID())", isDirectory: true)
        models = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data("1234".utf8).write(to: models.appendingPathComponent("weights.bin"))
        try Data(#"{"version":1}"#.utf8).write(to: models.appendingPathComponent(".complete"))
        try Data(#"{"version":1,"total_bytes":4,"items":[{"id":"w","label":"W","bytes":4,"files":[{"path":"weights.bin","url":"https://example.invalid/w","size":4,"sha256":"x"}]}]}"#.utf8)
            .write(to: root.appendingPathComponent("models.json"))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func runner() throws -> JobRunner {
        let py = try XCTUnwrap(Self.python, "no python3 found")
        let config = HelperConfig(python: py, helperDir: Self.repo.appendingPathComponent("helper"), modelsDir: models,
                                  manifest: root.appendingPathComponent("models.json"))
        return JobRunner(config: config, scratchRoot: root.appendingPathComponent("jobs"))
    }

    func testParsesProgressAndResult() async throws {
        let r = try runner()
        struct Pong: Decodable { var pong: Bool; var echo: String }
        var seen: [Double] = []
        let sub = r.$active.sink { jobs in if let f = jobs.first?.fraction, f > 0 { seen.append(f) } }
        let pong = try await r.run("Ping", command: "ping", args: ["steps": 3, "delay": 0.05, "echo": "hi"]) { data, _ in
            try JSONDecoder().decode(Pong.self, from: data)
        }
        sub.cancel()
        XCTAssertTrue(pong.pong)
        XCTAssertEqual(pong.echo, "hi")
        XCTAssertFalse(seen.isEmpty, "progress should reach the runner")
        XCTAssertTrue(r.active.isEmpty)
    }

    func testUnknownCommandIsStructuredError() async throws {
        do {
            _ = try await runner().run("Bad", command: "frobnicate") { _, _ in () }
            XCTFail("expected an error")
        } catch HelperError.failed(let code, let message) {
            XCTAssertEqual(code, "unknown_command")
            XCTAssertTrue(message.contains("frobnicate"))
        }
    }

    func testMissingModelFailsFastAndNamesFile() async throws {
        try FileManager.default.removeItem(at: models.appendingPathComponent("weights.bin"))
        do {
            _ = try await runner().run("Align", command: "align_lyrics") { _, _ in () }
            XCTFail("expected an error")
        } catch HelperError.failed(let code, let message) {
            XCTAssertEqual(code, "model_missing")
            XCTAssertTrue(message.contains("weights.bin"))
        }
    }

    func testCancelKillsProcessAndLeavesNoPartialResult() async throws {
        let r = try runner()
        var accepted = false
        let task = Task { @MainActor in
            try await r.run("Slow", command: "ping", args: ["steps": 100, "delay": 0.1, "write": true]) { _, _ in accepted = true }
        }
        for _ in 0..<100 where (r.active.first?.fraction ?? 0) == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertGreaterThan(r.active.first?.fraction ?? 0, 0, "job should have started")
        let started = Date()
        task.cancel()
        do { try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "cancel should stop the process promptly")
        XCTAssertFalse(accepted)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: r.scratchRoot.path)) ?? []
        XCTAssertEqual(left, [], "the job folder (with its partial file) should be deleted")
        XCTAssertTrue(r.active.isEmpty)
    }

    func testMissingRuntimeReportsNotInstalled() async {
        let r = JobRunner(config: nil)
        do { _ = try await r.run("X", command: "ping") { _, _ in () }; XCTFail() } catch {
            XCTAssertEqual(error as? HelperError, .notInstalled)
        }
    }

    func testMessageParsing() {
        XCTAssertEqual(HelperMessage.parse(Data(#"{"type":"progress","fraction":0.25,"message":"a"}"#.utf8)), .progress(0.25, "a"))
        XCTAssertEqual(HelperMessage.parse(Data(#"{"type":"error","code":"x","message":"m"}"#.utf8)), .error(code: "x", message: "m"))
        XCTAssertEqual(HelperMessage.parse(Data(#"{"type":"result","data":{"b":1,"a":2}}"#.utf8)), .result(Data(#"{"a":2,"b":1}"#.utf8)))
        XCTAssertNil(HelperMessage.parse(Data("noise".utf8)))
    }

    /// The real bundle: offline runtime, torch importable (the models aren't bundled).
    func testBundledRuntimeRunsOffline() async throws {
        guard let config = HelperConfig.bundled else { throw XCTSkip("app built without build/ml") }
        let r = JobRunner(config: config, scratchRoot: root.appendingPathComponent("jobs"))
        struct Probe: Decodable { var blocked: Bool }
        let probe = try await r.run("Net", command: "network_probe") { d, _ in try JSONDecoder().decode(Probe.self, from: d) }
        XCTAssertTrue(probe.blocked)
        struct Versions: Decodable { var python: String; var torch: String }
        let v = try await r.run("Versions", command: "versions") { d, _ in try JSONDecoder().decode(Versions.self, from: d) }
        XCTAssertTrue(v.python.hasPrefix("3.12"))
        XCTAssertTrue(v.torch.hasPrefix("2.8"))
    }
}
