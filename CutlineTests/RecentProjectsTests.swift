import XCTest
@testable import Cutline

final class RecentProjectsTests: XCTestCase {
    private var dir: URL!
    private let suite = "cutline-recent-tests"

    override func setUpWithError() throws {
        dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cutline-recent-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        RecentProjects.defaults = UserDefaults(suiteName: suite)!
        RecentProjects.clear()
    }

    override func tearDownWithError() throws {
        RecentProjects.clear()
        UserDefaults().removePersistentDomain(forName: suite)
        RecentProjects.defaults = .standard
        try? FileManager.default.removeItem(at: dir)
    }

    private func project(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent("\(name).cutline")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testNewestFirstWithoutDuplicatesUpToTen() throws {
        let urls = try (0..<12).map { try project("p\($0)") }
        urls.forEach(RecentProjects.note)
        RecentProjects.note(urls[3])
        let list = RecentProjects.list()
        XCTAssertEqual(list.count, 10)
        XCTAssertEqual(list.first?.lastPathComponent, "p3.cutline")
        XCTAssertEqual(list.filter { $0.lastPathComponent == "p3.cutline" }.count, 1)
    }

    func testMissingProjectsAreHiddenAndClearEmptiesTheList() throws {
        let a = try project("a"), b = try project("b")
        RecentProjects.note(a); RecentProjects.note(b)
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(RecentProjects.list().map(\.lastPathComponent), ["b.cutline"])
        RecentProjects.clear()
        XCTAssertTrue(RecentProjects.list().isEmpty)
    }

    func testOnlyProjectsOutsideTempAreNoted() throws {
        RecentProjects.note(URL(fileURLWithPath: "/tmp/notes.txt"))
        RecentProjects.note(FileManager.default.temporaryDirectory.appendingPathComponent("scratch.cutline"))
        XCTAssertTrue(RecentProjects.list().isEmpty)
    }
}
