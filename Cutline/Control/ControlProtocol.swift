import Foundation

/// The control channel: how another program on this Mac (Claude, through `cutline-ctl`) talks
/// to a running Cutline. One JSON object per line, request then response.
///
///     hello {client, purpose}      → Cutline asks the user → welcome {token, projects} | denied
///     use {token, project}         → ok {project}
///     tools {token}                → tools {tools}
///     call {token, tool, args}     → result {result} | error {message}
///     bye {token}                  → bye
///
/// The channel is a Unix socket in the user's Application Support folder that only the user
/// can open. Nothing works before the user approves the hello; approval lasts until bye or
/// `ControlProtocol.idleTimeout` of silence, and is never remembered.
enum ControlProtocol {
    static let version = 1
    static let idleTimeout: TimeInterval = 15 * 60
    static let maxMessageBytes = 4 * 1024 * 1024

    /// ~/Library/Application Support/Cutline/control (only the user can enter it).
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cutline/control", isDirectory: true)
    }

    /// One socket per running Cutline, named by its process id.
    static func socketURL(pid: Int32) -> URL { directory.appendingPathComponent("\(pid).sock") }

    /// ~/Library/Application Support/Cutline/cutline-ctl: a link to the client inside the Cutline
    /// that was opened last, wherever it's installed. Claude (the cutline-dummies skill) runs it
    /// from here, so it needs no app path.
    static var clientLink: URL {
        directory.deletingLastPathComponent().appendingPathComponent("cutline-ctl")
    }
}

/// Any JSON value (tool arguments and results).
enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(_ key: String) -> JSONValue? { if case .object(let o) = self { return o[key] } else { return nil } }
    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var number: Double? { if case .number(let n) = self { return n } else { return nil } }
    var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }

    /// Round-trip any Encodable into a JSONValue.
    static func from<T: Encodable>(_ value: T) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))) ?? .null
    }
}

struct ControlRequest: Codable, Equatable {
    var type: String
    var client: String?
    var purpose: String?
    var token: String?
    var project: String?
    var tool: String?
    var args: JSONValue?
    var version: Int?
}

struct ControlProjectSummary: Codable, Equatable {
    var id: String
    var name: String
    var path: String?
    var type: String
    var width: Int
    var height: Int
    var fps: Double
    var duration: Double
    /// Where the song starts on the timeline (seconds), when there is one.
    var songStart: Double?
    var songLength: Double?
}

struct ControlToolInfo: Codable, Equatable {
    var name: String
    var description: String
    /// Argument name → what it is.
    var arguments: [String: String]
}

struct ControlResponse: Codable, Equatable {
    var type: String
    var message: String?
    var token: String?
    var projects: [ControlProjectSummary]?
    var project: ControlProjectSummary?
    var tools: [ControlToolInfo]?
    var result: JSONValue?

    static func error(_ m: String) -> ControlResponse { ControlResponse(type: "error", message: m) }
}

extension ControlProtocol {
    static func encodeLine<T: Encodable>(_ value: T) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var d = (try? enc.encode(value)) ?? Data("{}".utf8)
        d.append(0x0A)
        return d
    }
}
