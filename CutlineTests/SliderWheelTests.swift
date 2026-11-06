import AppKit
import XCTest
@testable import Cutline

/// Inspector sliders step by one on each scroll wheel click.
final class SliderWheelTests: XCTestCase {
    func testOneStepIsTheSmallestChangeTheFieldShows() {
        XCTAssertEqual(ValueRow.displayStep("%.0f px"), 1)
        XCTAssertEqual(ValueRow.displayStep("%.1f%%"), 0.1, accuracy: 1e-12)
        XCTAssertEqual(ValueRow.displayStep("%.2fs"), 0.01, accuracy: 1e-12)
        XCTAssertEqual(ValueRow.displayStep("%.0f°"), 1)
    }

    func testAStepMovesExactlyOneAndStaysInRange() {
        XCTAssertEqual(ValueRow.stepped(60, direction: 1, step: 1, range: 0...200), 61)
        XCTAssertEqual(ValueRow.stepped(60, direction: -1, step: 1, range: 0...200), 59)
        XCTAssertEqual(ValueRow.stepped(3.4, direction: 1, step: 0.1, range: 0...10), 3.5, accuracy: 1e-9)
        XCTAssertEqual(ValueRow.stepped(0.26, direction: -1, step: 0.01, range: 0...2), 0.25, accuracy: 1e-9)
        XCTAssertEqual(ValueRow.stepped(200, direction: 1, step: 1, range: 0...200), 200, "stops at the top")
        XCTAssertEqual(ValueRow.stepped(0, direction: -1, step: 1, range: 0...200), 0, "stops at the bottom")
        XCTAssertEqual(ValueRow.stepped(60.4, direction: 1, step: 1, range: 0...200), 61, "lands on the step grid")
    }

    private func wheel(lines: Int32) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
        return NSEvent(cgEvent: cg)!
    }

    func testEachWheelClickIsOneStepWhateverItsSize() throws {
        let view = ScrollWheelSteps.WheelView()
        var steps: [Int] = []
        var ended = 0
        view.onStep = { steps.append($0) }
        view.onEnd = { ended += 1 }
        let up = wheel(lines: 5), down = wheel(lines: -1)
        view.handle(up)
        view.handle(up)
        view.handle(down)
        let natural = up.isDirectionInvertedFromDevice
        XCTAssertEqual(steps, natural ? [-1, -1, 1] : [1, 1, -1], "one step a click, by its direction")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(ended, 1, "one commit when the scrolling stops")
    }
}
