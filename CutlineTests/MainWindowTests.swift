import SwiftUI
import XCTest
@testable import Cutline

@MainActor
final class MainWindowTests: XCTestCase {
    func testNewProjectOpensEditorWindowWithFourRegions() throws {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        NSDocumentController.shared.addDocument(doc)
        defer { doc.close() }
        doc.makeWindowControllers()
        doc.showWindows()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        XCTAssertTrue(window.isVisible)
        let vertical = try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? NSSplitView }.first)
        XCTAssertTrue(window.contentView?.subviews.contains { $0 is NSHostingView<AnyView> || String(describing: type(of: $0)).contains("Hosting") } ?? false, "status bar")
        XCTAssertEqual(vertical.arrangedSubviews.count, 2)
        XCTAssertEqual((vertical.arrangedSubviews[0] as? NSSplitView)?.arrangedSubviews.count, 3)
    }

    // MARK: Per-project panel sizes and window frame

    private func open(_ layout: LayoutState) throws -> (ProjectDocument, NSWindow, vertical: NSSplitView, horizontal: NSSplitView) {
        let doc = ProjectDocument(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)))
        doc.layout = layout
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))  // the opening layout passes settle
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        let vertical = try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? NSSplitView }.first)
        let horizontal = try XCTUnwrap(vertical.arrangedSubviews.first as? NSSplitView)
        return (doc, window, vertical, horizontal)
    }

    private func widths(_ h: NSSplitView) -> (assets: CGFloat, inspector: CGFloat) {
        (h.arrangedSubviews[0].frame.width, h.arrangedSubviews[2].frame.width)
    }

    func testWindowResizesDontOverwriteThePanelSizes() throws {
        var layout = LayoutState()
        layout.assetsWidth = 420
        layout.inspectorWidth = 460
        layout.timelineHeight = 400
        layout.windowFrame = [100, 100, 1800, 1100]
        let (doc, window, vertical, horizontal) = try open(layout)
        defer { doc.close() }
        XCTAssertEqual(widths(horizontal).assets, 420, accuracy: 1)
        XCTAssertEqual(widths(horizontal).inspector, 460, accuracy: 1)
        XCTAssertEqual(vertical.arrangedSubviews[1].frame.height, 400, accuracy: 1)

        // Shrink to the minimum: the panels may be squeezed, but the saved sizes stay.
        window.setFrame(NSRect(x: 100, y: 100, width: window.minSize.width, height: window.minSize.height), display: true)
        XCTAssertEqual(doc.layout.assetsWidth, 420)
        XCTAssertEqual(doc.layout.inspectorWidth, 460)
        XCTAssertEqual(doc.layout.timelineHeight, 400)

        // Back to a big window: the project's sizes return.
        window.setFrame(NSRect(x: 100, y: 100, width: 1800, height: 1100), display: true)
        XCTAssertEqual(widths(horizontal).assets, 420, accuracy: 1)
        XCTAssertEqual(widths(horizontal).inspector, 460, accuracy: 1)
        XCTAssertEqual(vertical.arrangedSubviews[1].frame.height, 400, accuracy: 1)
        XCTAssertEqual(doc.layout.windowFrame, [100, 100, 1800, 1100])
    }

    func testDraggingADividerSavesThePanelSize() throws {
        var layout = LayoutState()
        layout.windowFrame = [100, 100, 1800, 1100]
        let (doc, _, _, horizontal) = try open(layout)
        defer { doc.close() }
        // What a drag does: the split view tracks the mouse while the divider moves.
        let split = try XCTUnwrap(horizontal as? DividerTrackingSplitView)
        split.isDraggingDivider = true
        horizontal.setPosition(333, ofDividerAt: 0)
        // The split view may apply the position in the next layout pass (it does when the
        // window isn't on screen); the drag lasts until then, as a real one would.
        horizontal.window?.contentView?.layoutSubtreeIfNeeded()
        split.isDraggingDivider = false
        XCTAssertEqual(doc.layout.assetsWidth, 333, accuracy: 1)
        horizontal.setPosition(500, ofDividerAt: 0)  // not a drag: not saved
        XCTAssertEqual(doc.layout.assetsWidth, 333, accuracy: 1)
    }

    func testEachProjectOpensInItsOwnWindowFrame() throws {
        var a = LayoutState(), b = LayoutState()
        a.windowFrame = [80, 90, 1500, 950]
        b.windowFrame = [140, 120, 1700, 1050]
        let (docA, windowA, _, _) = try open(a)
        defer { docA.close() }
        let (docB, windowB, _, _) = try open(b)
        defer { docB.close() }
        XCTAssertEqual(windowA.frame, NSRect(x: 80, y: 90, width: 1500, height: 950))
        XCTAssertEqual(windowB.frame, NSRect(x: 140, y: 120, width: 1700, height: 1050))
        windowA.setFrame(NSRect(x: 60, y: 70, width: 1400, height: 900), display: true)
        XCTAssertEqual(docA.layout.windowFrame, [60, 70, 1400, 900])
        XCTAssertEqual(docB.layout.windowFrame, [140, 120, 1700, 1050])
    }

    func testOlderLayoutsWithoutAWindowFrameStillLoad() throws {
        let old = #"{"assetsWidth":300,"inspectorWidth":310,"timelineHeight":320}"#
        let l = try JSONDecoder().decode(LayoutState.self, from: Data(old.utf8))
        XCTAssertNil(l.windowFrame)
        XCTAssertEqual(l.assetsWidth, 300)
    }
}
