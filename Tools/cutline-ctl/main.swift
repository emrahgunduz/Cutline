import Darwin
import Foundation

/// cutline-ctl: talk to a running Cutline over its control channel (see ControlProtocol).
///
///   cutline-ctl apps
///   cutline-ctl hello --client Claude --purpose "Place dummies from the treatment" [--pid N]
///   cutline-ctl projects --session S
///   cutline-ctl use      --session S --project ID
///   cutline-ctl tools    --session S
///   cutline-ctl call     --session S --tool NAME [--args JSON | --args-file PATH | --args -]
///   cutline-ctl bye      --session S
///
/// hello waits until the user answers Cutline's prompt and prints a "session" (pid:token) to
/// pass to the other commands. Output is JSON. Exit 0 = ok, 1 = refused or error, 2 = no
/// Cutline (or several: pass --pid).

func fail(_ message: String, code: Int32 = 1, extra: [String: Any] = [:]) -> Never {
    var o = extra
    o["type"] = "error"; o["message"] = message
    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: d, as: UTF8.self)) }
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: cutline-ctl apps | hello | projects | use | tools | call | bye (see the source header)") }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// Running Cutlines: sockets whose process is alive.
func runningApps() -> [(pid: Int32, url: URL)] {
    let dir = ControlProtocol.directory
    return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { name in
        guard name.hasSuffix(".sock"), let pid = Int32(name.dropLast(5)), kill(pid, 0) == 0 else { return nil }
        return (pid, dir.appendingPathComponent(name))
    }.sorted { $0.pid < $1.pid }
}

func appName(_ pid: Int32) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
}

func connect(_ url: URL) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("can't create a socket") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: url.path.utf8); raw[url.path.utf8.count] = 0 }
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard ok == 0 else { fail("can't reach Cutline (is it running?)", code: 2) }
    return fd
}

/// Send one request and read one response line (waits as long as Cutline takes: the user may
/// be deciding).
func send(_ request: ControlRequest, to url: URL) -> (ControlResponse, Data) {
    let fd = connect(url)
    defer { close(fd) }
    let data = ControlProtocol.encodeLine(request)
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    var buffer = Data(), chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while buffer.firstIndex(of: 0x0A) == nil {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        buffer.append(contentsOf: chunk[0..<n])
    }
    guard let nl = buffer.firstIndex(of: 0x0A), let r = try? JSONDecoder().decode(ControlResponse.self, from: buffer[..<nl]) else {
        fail("Cutline closed the connection without an answer")
    }
    return (r, Data(buffer[..<nl]))
}

func printResponse(_ raw: Data, adding extra: [String: Any] = [:]) {
    guard var o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { print(String(decoding: raw, as: UTF8.self)); return }
    for (k, v) in extra { o[k] = v }
    let d = try! JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: d, as: UTF8.self))
}

/// The Cutline to talk to: --pid, or the only one running.
func targetApp() -> (pid: Int32, url: URL) {
    let apps = runningApps()
    if let p = option("pid").flatMap(Int32.init) {
        guard let a = apps.first(where: { $0.pid == p }) else { fail("no Cutline with pid \(p) is running", code: 2) }
        return a
    }
    guard !apps.isEmpty else { fail("Cutline isn't running", code: 2) }
    guard apps.count == 1 else {
        fail("several Cutlines are running; ask the user which one and pass --pid", code: 2,
             extra: ["apps": apps.map { ["pid": Int($0.pid), "app": appName($0.pid)] }])
    }
    return apps[0]
}

/// --session pid:token
func session() -> (url: URL, token: String) {
    guard let s = option("session"), let colon = s.firstIndex(of: ":"), let pid = Int32(s[..<colon]) else {
        fail("pass --session (the \"session\" value hello printed)")
    }
    guard let app = runningApps().first(where: { $0.pid == pid }) else { fail("that Cutline is no longer running", code: 2) }
    return (app.url, String(s[s.index(after: colon)...]))
}

func exitCode(_ r: ControlResponse) -> Int32 { r.type == "error" || r.type == "denied" ? 1 : 0 }

switch command {
case "apps":
    let apps = runningApps().map { ["pid": Int($0.pid), "app": appName($0.pid)] as [String: Any] }
    let d = try! JSONSerialization.data(withJSONObject: ["type": "apps", "apps": apps], options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: d, as: UTF8.self))
case "hello":
    guard let client = option("client") else { fail("hello needs --client NAME") }
    let app = targetApp()
    let (r, raw) = send(ControlRequest(type: "hello", client: client, purpose: option("purpose"), version: ControlProtocol.version), to: app.url)
    printResponse(raw, adding: r.token.map { ["session": "\(app.pid):\($0)"] } ?? [:])
    exit(exitCode(r))
case "projects", "tools", "bye":
    let s = session()
    let (r, raw) = send(ControlRequest(type: command, token: s.token), to: s.url)
    printResponse(raw); exit(exitCode(r))
case "use":
    let s = session()
    guard let project = option("project") else { fail("use needs --project ID") }
    let (r, raw) = send(ControlRequest(type: "use", token: s.token, project: project), to: s.url)
    printResponse(raw); exit(exitCode(r))
case "call":
    let s = session()
    guard let tool = option("tool") else { fail("call needs --tool NAME") }
    var json: Data?
    if let a = option("args") { json = a == "-" ? FileHandle.standardInput.readDataToEndOfFile() : Data(a.utf8) }
    if let f = option("args-file") { json = FileManager.default.contents(atPath: f) ?? { fail("can't read \(f)") }() }
    var parsed: JSONValue?
    if let json { guard let v = try? JSONDecoder().decode(JSONValue.self, from: json) else { fail("--args isn't valid JSON") }; parsed = v }
    let (r, raw) = send(ControlRequest(type: "call", token: s.token, tool: tool, args: parsed), to: s.url)
    printResponse(raw); exit(exitCode(r))
default:
    fail("unknown command \(command)")
}
