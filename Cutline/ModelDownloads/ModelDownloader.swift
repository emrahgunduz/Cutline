import CryptoKit
import Foundation
import Observation

/// Downloads the pinned model files into a folder and publishes progress, speed and time
/// left. Each file goes to `<file>.part` first and continues from there after a cancel, a
/// lost connection or a crash; it is checked against its SHA-256 before it's moved into
/// place, and `.complete` is written only after every file is in.
@MainActor
@Observable
final class ModelDownloader {
    enum Phase: Equatable {
        case starting
        case downloading
        case finished
        case cancelled
        case failed(String)
    }

    let folder: URL
    private(set) var phase: Phase = .starting
    private(set) var bytes: Int64 = 0
    private(set) var total: Int64
    private(set) var items: [ModelManifest.Item]
    private(set) var currentItem: String?
    private(set) var doneItems: Set<String> = []
    /// Smoothed download speed in bytes per second (0 until measurable).
    private(set) var speed: Double = 0

    @ObservationIgnored private let manifest: ModelManifest
    @ObservationIgnored private let configuration: URLSessionConfiguration
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastSample: (time: Date, bytes: Int64)?
    @ObservationIgnored var onFinish: ((Phase) -> Void)?

    init(folder: URL, manifest: ModelManifest, configuration: URLSessionConfiguration = ModelDownloader.defaultConfiguration) {
        self.folder = folder
        self.manifest = manifest
        self.configuration = configuration
        total = manifest.totalBytes
        items = manifest.items
    }

    nonisolated static var defaultConfiguration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60          // no data for a minute: give up (resumable)
        c.timeoutIntervalForResource = 24 * 3600
        c.waitsForConnectivity = false
        return c
    }

    var fraction: Double { total > 0 ? min(1, Double(bytes) / Double(total)) : 0 }
    /// Derived from the observed phase, so views update when it ends.
    var isRunning: Bool { phase == .starting || phase == .downloading }
    var secondsLeft: Double { speed > 1 ? Double(total - bytes) / speed : .nan }

    func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    /// Stops now; the partial file stays and the next download continues from it.
    func cancel() { task?.cancel() }

    /// Waits for the download to end (tests).
    func wait() async { await task?.value }

    private func run() async {
        let fm = FileManager.default
        var label = ""
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fm.removeItem(at: folder.appendingPathComponent(ModelFolderStatus.marker))
            var done: Int64 = 0
            bytes = manifest.files.reduce(0) { sum, f in
                let dst = folder.appendingPathComponent(f.path)
                if Self.size(dst) == f.size { return sum + f.size }
                return sum + min(f.size, Self.size(dst.appendingPathExtension("part")) ?? 0)
            }
            phase = .downloading
            for item in manifest.items {
                currentItem = item.id
                label = item.label
                for file in item.files {
                    let dst = folder.appendingPathComponent(file.path)
                    if Self.size(dst) == file.size {
                        done += file.size
                        continue
                    }
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let part = dst.appendingPathExtension("part")
                    if let s = Self.size(part), s > file.size { try fm.removeItem(at: part) }
                    if Self.size(part) != file.size {
                        let base = done
                        try await FileFetcher.fetch(file.url, into: part, configuration: configuration) { [weak self] n in
                            Task { @MainActor in self?.update(bytes: base + n) }
                        }
                    }
                    try Task.checkCancellation()
                    guard Self.size(part) == file.size else {
                        try? fm.removeItem(at: part)
                        throw DownloadError("\(file.path) arrived with the wrong size. Try again.")
                    }
                    let digest = try await Task.detached(priority: .utility) { try Self.sha256(part) }.value
                    guard digest == file.sha256 else {
                        try? fm.removeItem(at: part)
                        throw DownloadError("\(file.path) didn't match its checksum and was deleted. Try again.")
                    }
                    try? fm.removeItem(at: dst)
                    try fm.moveItem(at: part, to: dst)
                    done += file.size
                    update(bytes: done)
                }
                doneItems.insert(item.id)
            }
            currentItem = nil
            guard ModelFolderStatus.check(folder, manifest: manifest).haveBytes == manifest.totalBytes else {
                throw DownloadError("Some model files went missing during the download. Try again.")
            }
            try ModelFolderStatus.writeMarker(folder, version: manifest.version)
            bytes = total
            finish(.finished)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                finish(.cancelled)
            } else if let e = error as? DownloadError {
                finish(.failed(e.message))
            } else {
                finish(.failed("Downloading \(label.isEmpty ? "the models" : label) failed: \(error.localizedDescription)"))
            }
        }
    }

    private func update(bytes newBytes: Int64) {
        guard isRunning else { return }
        let now = Date()
        if let last = lastSample {
            let dt = now.timeIntervalSince(last.time)
            if dt >= 0.5 {
                let instant = Double(newBytes - last.bytes) / dt
                if instant >= 0 { speed = speed == 0 ? instant : speed * 0.8 + instant * 0.2 }
                lastSample = (now, newBytes)
            }
        } else {
            lastSample = (now, newBytes)
        }
        bytes = max(bytes, newBytes)
    }

    private func finish(_ p: Phase) {
        phase = p
        speed = 0
        task = nil
        onFinish?(p)
    }

    nonisolated static func size(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    nonisolated static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data? = try autoreleasepool { try h.read(upToCount: 8 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct DownloadError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Downloads one URL into a `.part` file, continuing from the part's current size with an
/// HTTP Range request (a server that ignores the range sends everything; the part restarts).
final class FileFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let part: URL
    private let offset: Int64
    private let onBytes: @Sendable (Int64) -> Void
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var lastReport = Date.distantPast
    private var failure: Error?
    /// The server says the requested range starts at the end: the part is already whole.
    private var alreadyWhole = false
    private var continuation: CheckedContinuation<Void, Error>?

    private init(part: URL, offset: Int64, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.part = part
        self.offset = offset
        self.onBytes = onBytes
    }

    /// `onBytes` gets the part file's size as it grows (throttled).
    static func fetch(_ url: URL, into part: URL, configuration: URLSessionConfiguration,
                      onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let offset = ModelDownloader.size(part) ?? 0
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let fetcher = FileFetcher(part: part, offset: offset, onBytes: onBytes)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: fetcher, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                fetcher.lock.lock(); fetcher.continuation = cont; fetcher.lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.lock(); defer { lock.unlock() }
        do {
            switch status {
            case 206:
                let h = try FileHandle(forWritingTo: part)
                try h.seekToEnd()
                handle = h
                received = offset
            case 200:
                let h = try FileHandle(forWritingTo: part)
                try h.truncate(atOffset: 0)
                handle = h
                received = 0
            case 416 where offset > 0:
                alreadyWhole = true
                completionHandler(.cancel)
                return
            default:
                failure = DownloadError("The server answered \(status) for \(response.url?.host() ?? "a model file").")
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        do {
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
        } catch {
            failure = error
            lock.unlock()
            dataTask.cancel()
            return
        }
        let now = Date(), n = received
        let report = now.timeIntervalSince(lastReport) >= 0.15
        if report { lastReport = now }
        lock.unlock()
        if report { onBytes(n) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        try? handle?.close()
        handle = nil
        let cont = continuation; continuation = nil
        let failure = failure, whole = alreadyWhole, n = received
        lock.unlock()
        onBytes(whole ? offset : n)
        if let failure { cont?.resume(throwing: failure) }
        else if whole { cont?.resume() }
        else if let error { cont?.resume(throwing: error) }
        else { cont?.resume() }
    }
}
