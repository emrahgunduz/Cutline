import Foundation

/// Runs analysis jobs on the bundled helper and publishes their progress for the UI.
/// Each job writes into a fresh scratch folder; its files are handed to `accept` only
/// when the job succeeds, and the folder is deleted afterwards, so a failed or cancelled
/// job leaves no partial result behind.
@MainActor
final class JobRunner: ObservableObject {
    struct Job: Identifiable, Equatable {
        let id: UUID
        let title: String
        var fraction: Double = 0
        var message: String?
    }

    @Published private(set) var active: [Job] = []
    let config: HelperConfig?
    /// Parent of the per-job scratch folders.
    let scratchRoot: URL

    init(config: HelperConfig? = .bundled,
         scratchRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-jobs", isDirectory: true)) {
        self.config = config
        self.scratchRoot = scratchRoot
    }

    /// Run `command` and pass its result JSON and output folder to `accept`, which should
    /// move the files it keeps into the project. Cancel by cancelling the calling task.
    func run<T>(_ title: String, command: String, args: [String: Any] = [:],
                accept: (_ result: Data, _ outputDir: URL) throws -> T) async throws -> T {
        guard let config else { throw HelperError.notInstalled }
        let id = UUID()
        let jobDir = scratchRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let outputDir = jobDir.appendingPathComponent("out", isDirectory: true)
        let scratch = jobDir.appendingPathComponent("tmp", isDirectory: true)
        active.append(Job(id: id, title: title))
        defer {
            active.removeAll { $0.id == id }
            try? FileManager.default.removeItem(at: jobDir)
        }
        let data = try await HelperProcess(config: config).run(command: command, args: args, outputDir: outputDir, scratchDir: scratch) { [weak self] f, m in
            Task { @MainActor in self?.update(id, fraction: f, message: m) }
        }
        try Task.checkCancellation()
        return try accept(data, outputDir)
    }

    private func update(_ id: UUID, fraction: Double, message: String?) {
        guard let i = active.firstIndex(where: { $0.id == id }) else { return }
        active[i].fraction = fraction
        if let message { active[i].message = message }
    }
}
