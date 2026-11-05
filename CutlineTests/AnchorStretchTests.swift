import XCTest
@testable import Cutline

final class AnchorStretchTests: XCTestCase {
    typealias S = AnchorStretch.Span

    /// AE1: w1-w5 unconfirmed; taps put w1 at 10 s and w5 at 12 s. w2-w4 fit in order
    /// between them, keeping their relative timing, and the anchors stay put.
    func testAE1AnchorsRetimeTheWordsBetweenThem() {
        let before = [S(start: 9, end: 9.4), S(start: 9.5, end: 9.9), S(start: 10, end: 10.4), S(start: 10.5, end: 10.9), S(start: 11, end: 11.4)]
        var after = before
        after[0] = S(start: 10, end: 10.4)
        after[4] = S(start: 12, end: 12.4)
        let anchored = [true, false, false, false, true]
        let out = AnchorStretch.stretch(before: before, after: after, anchored: anchored, minLength: 1.0 / 24)
        XCTAssertEqual(out[0], after[0])
        XCTAssertEqual(out[4], after[4])
        // Old anchors 9 -> 10 and 11 -> 12: scale 1, shift +1.
        XCTAssertEqual(out[1].start, 10.5, accuracy: 1e-9)
        XCTAssertEqual(out[2].start, 11.0, accuracy: 1e-9)
        XCTAssertEqual(out[3].start, 11.5, accuracy: 1e-9)
        for (a, b) in zip(out, out.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start + 1e-9) }
        XCTAssertTrue(out[1...3].allSatisfy { $0.start >= 10 && $0.end <= 12 })
    }

    func testStretchIsProportional() {
        let before = [S(start: 0, end: 1), S(start: 1, end: 2), S(start: 4, end: 5)]
        var after = before
        after[2] = S(start: 8, end: 9)   // gap doubles
        let out = AnchorStretch.stretch(before: before, after: after, anchored: [true, false, true], minLength: 0.04)
        XCTAssertEqual(out[1].start, 2, accuracy: 1e-9)
        XCTAssertEqual(out[1].end, 4, accuracy: 1e-9)
    }

    func testRunWithNoRightAnchorKeepsItsOffsetsAfterTheLeftAnchor() {
        let before = [S(start: 5, end: 5.5), S(start: 6, end: 6.5), S(start: 7.25, end: 8)]
        var after = before
        after[0] = S(start: 5.5, end: 6)
        let out = AnchorStretch.stretch(before: before, after: after, anchored: [true, false, false], minLength: 0.04)
        XCTAssertEqual(out[1].start, 6.5, accuracy: 1e-9)
        XCTAssertEqual(out[2].start - out[0].start, before[2].start - before[0].start, accuracy: 1e-9)
    }

    func testNoAnchorsChangesNothing() {
        let w = [S(start: 1, end: 2), S(start: 3, end: 4)]
        XCTAssertEqual(AnchorStretch.stretch(before: w, after: w, anchored: [false, false], minLength: 0.04), w)
    }

    func testConfirmedWordsNeverMove() {
        let before = [S(start: 0, end: 1), S(start: 2, end: 3), S(start: 3.5, end: 4), S(start: 6, end: 7)]
        var after = before
        after[0] = S(start: 2.5, end: 3.4)   // dragged past its neighbours
        let anchored = [true, false, true, true]
        let out = AnchorStretch.stretch(before: before, after: after, anchored: anchored, minLength: 0.04)
        XCTAssertEqual(out[0], after[0]); XCTAssertEqual(out[2], after[2]); XCTAssertEqual(out[3], after[3])
    }

    func testAlignedWordsAfterTheLastAnchorStayPut() {
        let before = [S(start: 5, end: 5.5), S(start: 6, end: 6.5), S(start: 8, end: 8.5)]
        var after = before
        after[0] = S(start: 7, end: 7.4)   // a late tap
        let out = AnchorStretch.stretch(before: before, after: after, anchored: [true, false, false],
                                        follows: [false, false, false], minLength: 0.04)
        XCTAssertEqual(out[2], before[2], "a well-aligned word later in the song does not move")
        XCTAssertGreaterThanOrEqual(out[1].start, out[0].end - 1e-9, "the overlapped neighbour is pushed past the tap")
    }
}
