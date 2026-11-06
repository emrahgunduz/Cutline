import XCTest
@testable import Cutline

/// The cinemascope bar height: 2.35:1 by default, or the project's own.
@MainActor
final class CinemascopeBarHeightTests: XCTestCase {
    private func project() -> Project {
        var p = Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080))
        p.cinemascope.enabled = true
        p.cinemascope.startMarker = 2
        p.cinemascope.endMarker = 4
        return p
    }

    func testTheDefaultLeavesA235Picture() {
        let p = project()
        let h = Letterbox.fullBarHeight(p)
        XCTAssertEqual(1920 / (1080 - 2 * h), 2.35, accuracy: 1e-9)
        XCTAssertEqual(Letterbox.barHeight(project: p, at: 10), h, accuracy: 1e-9, "fully closed after the end marker")
    }

    func testTheProjectsHeightIsUsedByThePreviewExportAndDummies() {
        var p = project()
        p.cinemascope.barHeight = 200
        XCTAssertEqual(Letterbox.barHeight(project: p, at: 10), 200)
        XCTAssertEqual(Letterbox.barHeight(project: p, at: 1), 0, "still open before the start marker")
        XCTAssertEqual(DummyRenderer.barFraction(for: p), 200 / 1080, accuracy: 1e-9)
        p.cinemascope.barHeight = 5000
        XCTAssertEqual(Letterbox.fullBarHeight(p), Letterbox.maxBarHeight(p.canvas), "never covers the whole frame")
    }

    func testOlderProjectsKeepTheDefaultAndTheRenderKeyChangesWithTheHeight() throws {
        let old = try JSONDecoder().decode(Cinemascope.self, from: Data(#"{"enabled":true,"startMarker":1,"endMarker":3}"#.utf8))
        XCTAssertNil(old.barHeight)
        var a = project(), b = project()
        b.cinemascope.barHeight = 150
        XCTAssertNotEqual(try JSONEncoder().encode(a.cinemascope), try JSONEncoder().encode(b.cinemascope))
        a.cinemascope.barHeight = nil
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(a.cinemascope), as: UTF8.self).contains("barHeight"),
                       "unchanged projects keep their render keys")
    }

    func testTheBarShowsTheHeightOnlyWhileTheBarsAreOn() throws {
        var p = project()
        p.cinemascope.enabled = false
        let doc = ProjectDocument(project: p)
        let e = doc.editor
        let container = try XCTUnwrap(TimelineContainer.make(editor: e) as? TimelineContainer)
        XCTAssertFalse(container.barsShown)
        e.edit("On") { $0.cinemascope.enabled = true }
        container.refreshBars(animated: false)
        XCTAssertTrue(container.barsShown)
        XCTAssertFalse(container.barsGroup.isHidden)
        XCTAssertEqual(container.barsField.integerValue, 131, "the 2.35:1 height, rounded")

        container.barsField.integerValue = 180
        container.barsField.sendAction(container.barsField.action, to: container.barsField.target)
        XCTAssertEqual(e.project.cinemascope.barHeight, 180)

        container.barsField.integerValue = 180   // the same again: no new edit
        container.barsField.sendAction(container.barsField.action, to: container.barsField.target)
        XCTAssertEqual(e.project.cinemascope.barHeight, 180)

        e.edit("Off") { $0.cinemascope.enabled = false }
        container.refreshBars(animated: false)
        XCTAssertFalse(container.barsShown)
        XCTAssertTrue(container.barsGroup.isHidden)
    }

    func testTypingTheShownDefaultKeepsTheDefault() throws {
        let doc = ProjectDocument(project: project())
        let e = doc.editor
        let container = try XCTUnwrap(TimelineContainer.make(editor: e) as? TimelineContainer)
        container.barsField.integerValue = 131
        container.barsField.sendAction(container.barsField.action, to: container.barsField.target)
        XCTAssertNil(e.project.cinemascope.barHeight)
    }
}
