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

    /// The main screen's visible area. AppKit keeps windows inside it, and CI machines have
    /// small displays, so every frame in these tests is made to fit.
    private func screen() throws -> NSRect {
        let v = try XCTUnwrap(NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame, "no screen")
        let min = NSSize(width: 1000, height: 640)   // the editor window's minimum size
        guard v.width >= min.width + 10, v.height >= min.height + 10 else {
            throw XCTSkip("the screen (\(v.size)) is smaller than the editor window's minimum size")
        }
        return v
    }

    private func saved(_ r: NSRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }

    private func widths(_ h: NSSplitView) -> (assets: CGFloat, inspector: CGFloat) {
        (h.arrangedSubviews[0].frame.width, h.arrangedSubviews[2].frame.width)
    }

    func testWindowResizesDontOverwriteThePanelSizes() throws {
        let v = try screen()
        let big = NSRect(x: v.minX + 5, y: v.minY + 5, width: min(1800, v.width - 10), height: min(1100, v.height - 10)).integral
        // Panel sizes that fit the window (and the panels' limits) on any screen.
        let assets = (big.width * 0.22).rounded(), inspector = (big.width * 0.26).rounded(), timeline = (big.height * 0.35).rounded()
        var layout = LayoutState()
        layout.assetsWidth = assets
        layout.inspectorWidth = inspector
        layout.timelineHeight = timeline
        layout.windowFrame = saved(big)
        let (doc, window, vertical, horizontal) = try open(layout)
        defer { doc.close() }
        XCTAssertEqual(window.frame, big)
        XCTAssertEqual(widths(horizontal).assets, assets, accuracy: 1)
        XCTAssertEqual(widths(horizontal).inspector, inspector, accuracy: 1)
        XCTAssertEqual(vertical.arrangedSubviews[1].frame.height, timeline, accuracy: 1)

        // Shrink to the minimum: the panels may be squeezed, but the saved sizes stay.
        window.setFrame(NSRect(x: big.minX, y: big.minY, width: window.minSize.width, height: window.minSize.height), display: true)
        XCTAssertEqual(doc.layout.assetsWidth, assets)
        XCTAssertEqual(doc.layout.inspectorWidth, inspector)
        XCTAssertEqual(doc.layout.timelineHeight, timeline)

        // Back to a big window: the project's sizes return.
        window.setFrame(big, display: true)
        XCTAssertEqual(widths(horizontal).assets, assets, accuracy: 1)
        XCTAssertEqual(widths(horizontal).inspector, inspector, accuracy: 1)
        XCTAssertEqual(vertical.arrangedSubviews[1].frame.height, timeline, accuracy: 1)
        XCTAssertEqual(doc.layout.windowFrame, saved(big))
    }

    func testDraggingADividerSavesThePanelSize() throws {
        let v = try screen()
        var layout = LayoutState()
        layout.windowFrame = saved(NSRect(x: v.minX + 5, y: v.minY + 5, width: min(1800, v.width - 10), height: min(1100, v.height - 10)).integral)
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
        horizontal.setPosition(380, ofDividerAt: 0)  // not a drag: not saved
        XCTAssertEqual(doc.layout.assetsWidth, 333, accuracy: 1)
    }

    func testEachProjectOpensInItsOwnWindowFrame() throws {
        let v = try screen()
        let frameA = NSRect(x: v.minX, y: v.minY, width: min(1500, v.width - 10), height: min(950, v.height - 10)).integral
        let frameB = NSRect(x: v.minX + 10, y: v.minY + 10, width: min(1700, v.width - 10), height: min(1050, v.height - 10)).integral
        let moved = NSRect(x: v.minX + 5, y: v.minY + 5, width: 1000, height: 640).integral
        var a = LayoutState(), b = LayoutState()
        a.windowFrame = saved(frameA)
        b.windowFrame = saved(frameB)
        let (docA, windowA, _, _) = try open(a)
        defer { docA.close() }
        let (docB, windowB, _, _) = try open(b)
        defer { docB.close() }
        XCTAssertEqual(windowA.frame, frameA)
        XCTAssertEqual(windowB.frame, frameB)
        windowA.setFrame(moved, display: true)
        XCTAssertEqual(docA.layout.windowFrame, saved(moved))
        XCTAssertEqual(docB.layout.windowFrame, saved(frameB))
    }

    func testOlderLayoutsWithoutAWindowFrameStillLoad() throws {
        let old = #"{"assetsWidth":300,"inspectorWidth":310,"timelineHeight":320}"#
        let l = try JSONDecoder().decode(LayoutState.self, from: Data(old.utf8))
        XCTAssertNil(l.windowFrame)
        XCTAssertEqual(l.assetsWidth, 300)
    }
}
