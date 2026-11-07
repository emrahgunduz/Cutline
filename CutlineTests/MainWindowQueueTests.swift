import XCTest
@testable import Cutline

/// The window tests again, run from inside a main-queue block, where a nested run loop can't
/// run other main-queue blocks. XCTest on Xcode 26 (CI) runs tests that way, so the window's
/// follow-up work must be on the run loop, not the main queue.
@MainActor
final class MainWindowQueueTests: XCTestCase {
    private func insideMainQueueBlock(_ body: @escaping () throws -> Void) throws {
        var done = false, failure: Error?
        DispatchQueue.main.async {
            do { try body() } catch { failure = error }
            done = true
        }
        let deadline = Date().addingTimeInterval(20)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(done)
        if let failure { throw failure }
    }

    func testADividerDragIsSaved() throws {
        let t = MainWindowTests()
        try insideMainQueueBlock { try t.testDraggingADividerSavesThePanelSize() }
    }

    func testEachProjectKeepsItsWindowFrame() throws {
        let t = MainWindowTests()
        try insideMainQueueBlock { try t.testEachProjectOpensInItsOwnWindowFrame() }
    }
}
