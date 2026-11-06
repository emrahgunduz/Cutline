import XCTest
@testable import Cutline

/// The link Claude runs cutline-ctl from (~/Library/Application Support/Cutline/cutline-ctl),
/// tested in a temporary folder.
final class ControlClientLinkTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctl-link-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func client(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\necho \(name)\n".utf8).write(to: url)
        chmod(url.path, 0o755)
        return url
    }

    private var link: URL { dir.appendingPathComponent("Cutline/cutline-ctl") }

    func testLinksToTheRunningAppsClientAndRunsIt() throws {
        let a = try client("a")
        try ControlClientLink.publish(client: a, at: link)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), a.path)
        let p = Process()
        p.executableURL = link
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "a\n")
    }

    func testAnotherCopyOfCutlineTakesTheLinkOver() throws {
        try ControlClientLink.publish(client: try client("a"), at: link)
        let b = try client("b")
        try ControlClientLink.publish(client: b, at: link)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), b.path)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: link.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["cutline-ctl"])
    }

    func testABuildWithoutTheClientLeavesTheLinkAlone() throws {
        let a = try client("a")
        try ControlClientLink.publish(client: a, at: link)
        try ControlClientLink.publish(client: dir.appendingPathComponent("missing"), at: link)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), a.path)
    }

    func testARealFileThereIsNotReplaced() throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: link)
        try ControlClientLink.publish(client: try client("a"), at: link)
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "mine")
    }

    func testTheLinkSitsNextToTheControlFolder() {
        XCTAssertEqual(ControlProtocol.clientLink.deletingLastPathComponent(), ControlProtocol.directory.deletingLastPathComponent())
        XCTAssertEqual(ControlProtocol.clientLink.lastPathComponent, "cutline-ctl")
    }
}
