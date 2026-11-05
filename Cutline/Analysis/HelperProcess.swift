import Foundation

/// Where the bundled Python runtime and helper source live, and the models folder it uses.
struct HelperConfig: Sendable {
    var python: URL
    /// Folder that contains the `cutline_helper` package.
    var helperDir: URL
    var modelsDir: URL
    /// The pinned model list to check against (nil: the helper's own models.json).
    var manifest: URL? = nil

    /// The runtime inside the app (`Contents/Resources/ml/{python, helper}`) with the models
    /// folder the user chose or downloaded into (ModelStore). The models aren't bundled.
    static var bundled: HelperConfig? {
        guard let ml = Bundle.main.resourceURL?.appendingPathComponent("ml", isDirectory: true) else { return nil }
        let config = HelperConfig(python: ml.appendingPathComponent("python/bin/python3"),
                                  helperDir: ml.appendingPathComponent("helper", isDirectory: true),
                                  modelsDir: ModelStore.currentFolder())
        return FileManager.default.isExecutableFile(atPath: config.python.path) ? config : nil
    }
}

enum HelperError: LocalizedError, Equatable {
    /// The app was built without `scripts/build_python_runtime.sh`.
    case notInstalled
    /// The helper reported a structured error (`unknown_command`, `model_missing`, ...).
    case failed(code: String, message: String)
    /// The process ended without a result line.
    case crashed(status: Int32, log: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "The analysis runtime is not in this build. Run scripts/build_python_runtime.sh and rebuild Cutline."
        case .failed(_, let message): message
        case .crashed(let status, let log): "The analysis helper stopped (status \(status)).\n" + log.suffix(600)
        }
    }
}

/// One line from the helper's stdout.
enum HelperMessage: Equatable {
    case progress(Double, String?)
    /// The raw JSON of the result's `data` object.
    case result(Data)
    case error(code: String, message: String)

    static func parse(_ line: Data) -> HelperMessage? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = obj["type"] as? String else { return nil }
        switch type {
        case "progress":
            return .progress((obj["fraction"] as? NSNumber)?.doubleValue ?? 0, obj["message"] as? String)
        case "result":
            let data = (try? JSONSerialization.data(withJSONObject: obj["data"] ?? [String: Any](), options: [.sortedKeys])) ?? Data("{}".utf8)
            return .result(data)
        case "error":
            return .error(code: obj["code"] as? String ?? "internal", message: obj["message"] as? String ?? "Unknown helper error")
        default:
            return nil
        }
    }
}

/// Runs one helper job in its own process: writes the request line, streams progress,
/// and returns the result. Cancelling the calling task terminates the process.
final class HelperProcess: @unchecked Sendable {
    let config: HelperConfig

    init(config: HelperConfig) { self.config = config }

    /// Helpers still running, so the app can stop them when it quits.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var running: [ObjectIdentifier: Process] = [:]

    static func terminateAll() {
        registryLock.lock(); let all = Array(running.values); registryLock.unlock()
        all.forEach { $0.terminate() }
    }

    /// - Parameters:
    ///   - outputDir: where the job writes its files.
    ///   - scratchDir: the process's TMPDIR and XDG cache, so libraries never write to ~/.cache.
    func run(command: String, args: [String: Any] = [:], outputDir: URL, scratchDir: URL,
             progress: @escaping @Sendable (Double, String?) -> Void = { _, _ in }) async throws -> Data {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let cache = scratchDir.appendingPathComponent("cache", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)

        var request: [String: Any] = ["command": command, "args": args, "output_dir": outputDir.path]
        if args.isEmpty { request["args"] = [String: Any]() }
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)

        let process = Process()
        process.executableURL = config.python
        // -E ignores PYTHON* variables, -s skips the user site, -B writes no .pyc into the bundle.
        process.arguments = ["-E", "-s", "-B", "-m", "cutline_helper"]
        process.currentDirectoryURL = config.helperDir
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
            "TMPDIR": scratchDir.path,
            "XDG_CACHE_HOME": cache.path,
            "CUTLINE_MODELS": config.modelsDir.path,
            "TORCH_HOME": config.modelsDir.appendingPathComponent("torch").path,
            "HF_HOME": config.modelsDir.appendingPathComponent("hf").path,
            "HF_HUB_OFFLINE": "1",
        ]
        if let manifest = config.manifest { process.environment?["CUTLINE_MODELS_MANIFEST"] = manifest.path }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let state = RunState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                state.continuation = cont
                // Done once stdout is drained (every line handled) and the process has exited.
                let done = DispatchGroup()
                done.enter(); done.enter()
                process.terminationHandler = { _ in done.leave() }
                done.notify(queue: .global()) {
                    Self.unregister(process)
                    state.finish(status: process.terminationStatus)
                }
                stderr.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil } else { state.appendLog(d) }
                }
                stdout.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty {
                        h.readabilityHandler = nil
                        done.leave()
                        return
                    }
                    for message in state.feed(d) {
                        if case .progress(let f, let m) = message { progress(f, m) }
                    }
                }
                do {
                    try process.run()
                    Self.register(process)
                    if state.isCancelled { process.terminate() }
                    stdin.fileHandleForWriting.write(line)
                    try? stdin.fileHandleForWriting.close()
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    state.fail(error)
                }
            }
        } onCancel: {
            state.markCancelled()
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private static func register(_ p: Process) { registryLock.lock(); running[ObjectIdentifier(p)] = p; registryLock.unlock() }
    private static func unregister(_ p: Process) { registryLock.lock(); running[ObjectIdentifier(p)] = nil; registryLock.unlock() }
}

/// Shared state between the pipe handlers and the awaiting task.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var log = Data()
    private var outcome: HelperMessage?
    private var cancelled = false
    var continuation: CheckedContinuation<Data, Error>?

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func markCancelled() { lock.lock(); cancelled = true; lock.unlock() }

    func appendLog(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        log.append(d)
        if log.count > 64_000 { log = log.suffix(32_000) }
    }

    /// Split complete lines out of the stream; remembers the final result or error.
    func feed(_ d: Data) -> [HelperMessage] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        var out: [HelperMessage] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let m = HelperMessage.parse(Data(line)) else { continue }
            switch m {
            case .result, .error: if outcome == nil { outcome = m }
            case .progress: if outcome == nil { out.append(m) }
            }
        }
        return out
    }

    func finish(status: Int32) {
        lock.lock()
        let cont = continuation; continuation = nil
        let outcome = outcome, cancelled = cancelled
        let text = String(decoding: log, as: UTF8.self)
        lock.unlock()
        if cancelled { cont?.resume(throwing: CancellationError()); return }
        switch outcome {
        case .result(let data)?: cont?.resume(returning: data)
        case .error(let code, let message)?: cont?.resume(throwing: HelperError.failed(code: code, message: message))
        default: cont?.resume(throwing: HelperError.crashed(status: status, log: text))
        }
    }

    func fail(_ error: Error) {
        lock.lock(); let cont = continuation; continuation = nil; lock.unlock()
        cont?.resume(throwing: error)
    }
}
