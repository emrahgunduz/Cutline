import AppKit
import Combine
import Foundation

/// The control channel's sessions and handshake (no sockets here; ControlServer feeds it).
/// A client says hello; Cutline asks the user; only after approval does it see the open
/// projects, pick one, list the tools and call them. Bye or 15 minutes of silence ends it.
@MainActor
final class ControlService: ObservableObject {
    static let shared = ControlService()

    struct Session: Equatable {
        var token: String
        var client: String
        var purpose: String
        var projectID: String?
        var lastUsed: Date
    }

    /// Approved sessions, by token. The status bar shows them with a Disconnect button.
    @Published private(set) var sessions: [String: Session] = [:]

    /// Asks the user (the app shows an alert); tests answer directly.
    var approve: (_ client: String, _ purpose: String) async -> Bool = ControlService.askUser
    /// The open projects (the app: every open project document).
    var documents: () -> [ProjectDocument] = { NSDocumentController.shared.documents.compactMap { $0 as? ProjectDocument } }
    var now: () -> Date = Date.init

    func handle(_ r: ControlRequest) async -> ControlResponse {
        expireIdleSessions()
        if r.type == "hello" { return await hello(r) }
        guard let token = r.token, var session = sessions[token] else {
            return .error("Not connected: say hello first and wait for the user to approve.")
        }
        session.lastUsed = now()
        sessions[token] = session
        switch r.type {
        case "projects":
            return ControlResponse(type: "projects", projects: summaries())
        case "use":
            guard let id = r.project, let doc = documents().first(where: { $0.controlID == id }) else {
                return .error("No open project with id \(r.project ?? "(none)"). Projects: " + summaries().map { "\($0.id) \($0.name)" }.joined(separator: ", "))
            }
            sessions[token]?.projectID = id
            return ControlResponse(type: "ok", project: ControlTools.summary(id, doc))
        case "tools":
            return ControlResponse(type: "tools", tools: ControlTools.all)
        case "call":
            guard let id = session.projectID, let doc = documents().first(where: { $0.controlID == id }) else {
                return .error("Choose a project first (use).")
            }
            guard let tool = r.tool else { return .error("call needs a tool") }
            do {
                return ControlResponse(type: "result", result: try ControlTools.call(tool, args: r.args, on: doc.editor, client: session.client))
            } catch {
                return .error(error.localizedDescription)
            }
        case "bye":
            sessions[token] = nil
            return ControlResponse(type: "bye", message: "Bye.")
        default:
            return .error("Unknown request \"\(r.type)\"")
        }
    }

    private func hello(_ r: ControlRequest) async -> ControlResponse {
        let client = String((r.client ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !client.isEmpty else { return .error("hello needs a client name") }
        let purpose = String((r.purpose ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        guard await approve(client, purpose) else { return ControlResponse(type: "denied", message: "The user didn't allow the connection.") }
        let token = Self.makeToken()
        sessions[token] = Session(token: token, client: client, purpose: purpose, projectID: nil, lastUsed: now())
        return ControlResponse(type: "welcome", message: "You are good to go. Choose a project with use.", token: token, projects: summaries())
    }

    /// The user ends a session (status bar Disconnect).
    func disconnect(_ token: String) { sessions[token] = nil }

    func disconnectAll() { sessions = [:] }

    private func expireIdleSessions() {
        let cutoff = now().addingTimeInterval(-ControlProtocol.idleTimeout)
        sessions = sessions.filter { $0.value.lastUsed >= cutoff }
    }

    private func summaries() -> [ControlProjectSummary] { documents().map { ControlTools.summary($0.controlID, $0) } }

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The approval prompt: Cutline comes to the front and asks.
    static func askUser(client: String, purpose: String) async -> Bool {
        NSApp.activate()
        NSApp.requestUserAttention(.criticalRequest)
        let alert = NSAlert()
        alert.messageText = "Allow “\(client)” to connect to Cutline?"
        alert.informativeText = (purpose.isEmpty ? "" : "It says: “\(purpose)”\n\n")
            + "If you allow it, it can see the names of your open projects and use Cutline's tools on the project it picks (adding or removing dummies). It can't change audio or lyrics. The connection ends when it says goodbye, after 15 minutes without activity, or when you click Disconnect in the status bar."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        // Deny is the safe default for Return/Escape.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
