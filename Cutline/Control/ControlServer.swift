import Darwin
import Foundation

/// Listens on the control socket and passes each request line to the ControlService.
/// The socket lives in a folder only the user can open (0700) and is itself 0600, so only the
/// user's own programs can connect; everything still needs the user's approval (hello).
final class ControlServer {
    let url: URL
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "cutline.control", attributes: .concurrent)
    private let handle: (ControlRequest) async -> ControlResponse
    private(set) var isRunning = false

    init(url: URL = ControlProtocol.socketURL(pid: getpid()), handle: @escaping (ControlRequest) async -> ControlResponse) {
        self.url = url
        self.handle = handle
    }

    deinit { stop() }

    /// Start listening (removes sockets left by Cutlines that are no longer running).
    func start() throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        Self.removeStaleSockets(in: dir)
        unlink(url.path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = url.path
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { close(fd); throw POSIXError(.EIO) }
        isRunning = true
        let listener = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { if errno == EINTR { continue } else { return } }
                guard let self else { close(client); return }
                self.queue.async { self.serve(client) }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        close(fd)
        fd = -1
        unlink(url.path)
    }

    /// One connection: read lines, answer each; bye or end of input closes it.
    private func serve(_ client: Int32) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > ControlProtocol.maxMessageBytes { write(client, ControlResponse.error("Message too large")); return }
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.isEmpty else { continue }
                let response: ControlResponse
                if let req = try? JSONDecoder().decode(ControlRequest.self, from: line) {
                    response = Self.wait { await self.handle(req) }
                } else {
                    response = .error("Not a JSON request")
                }
                write(client, response)
                if response.type == "bye" || response.type == "denied" { return }
            }
        }
    }

    private func write(_ client: Int32, _ r: ControlResponse) {
        let data = ControlProtocol.encodeLine(r)
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(client, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    /// Run an async handler from this connection's thread and wait for its answer.
    private static func wait(_ body: @escaping () async -> ControlResponse) -> ControlResponse {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out = ControlResponse.error("No answer")
        Task { out = await body(); done.signal() }
        done.wait()
        return out
    }

    /// Sockets whose Cutline is gone (named by process id).
    static func removeStaleSockets(in dir: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".sock") {
            guard let pid = Int32(name.dropLast(5)) else { continue }
            if pid != getpid() && kill(pid, 0) != 0 && errno == ESRCH { unlink(dir.appendingPathComponent(name).path) }
        }
    }
}
