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

    /// The editor window's real minimum size. It's set to 1000×640, and AppKit adds the
    /// toolbar's height once the toolbar is in (674 pt tall on macOS 26).
    private func minimumWindowSize() throws -> NSSize {
        let (doc, window, _, _) = try open(LayoutState())
        defer { doc.close() }
        return window.minSize
    }

    /// The main screen's visible area and the editor window's minimum size. AppKit keeps
    /// windows inside the visible area and at least the minimum size, and CI machines have
    /// small displays (1024×677 pt usable), so every frame in these tests is made to fit.
    private func screen() throws -> (visible: NSRect, minimum: NSSize) {
        let v = try XCTUnwrap(NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame, "no screen")
        let min = try minimumWindowSize()
        guard v.width >= min.width + 2, v.height >= min.height + 2 else {
            throw XCTSkip("the screen (\(v.size)) is smaller than the editor window's minimum size (\(min))")
        }
        return (v, min)
    }

    private func saved(_ r: NSRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }

    private func widths(_ h: NSSplitView) -> (assets: CGFloat, inspector: CGFloat) {
        (h.arrangedSubviews[0].frame.width, h.arrangedSubviews[2].frame.width)
    }

    func testWindowResizesDontOverwriteThePanelSizes() throws {
        let (v, _) = try screen()
        let big = NSRect(x: v.minX, y: v.minY, width: min(1800, v.width), height: min(1100, v.height))
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
        let (v, _) = try screen()
        var layout = LayoutState()
        layout.windowFrame = saved(NSRect(x: v.minX, y: v.minY, width: min(1800, v.width), height: min(1100, v.height)))
        let (doc, _, _, horizontal) = try open(layout)
        defer { doc.close() }
        // What a drag does: the split view tracks the mouse while the divider moves.
        let split = try XCTUnwrap(horizontal as? DividerTrackingSplitView)
        split.isDraggingDivider = true
        horizontal.setPosition(333, ofDividerAt: 0)
        // The split view may apply the position in a later layout pass (it does when the
        // window isn't on screen, and later still on a slow machine); the drag lasts until
        // then, as a real one would.
        let deadline = Date().addingTimeInterval(2)
        while abs(doc.layout.assetsWidth - 333) > 1, Date() < deadline {
            horizontal.window?.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        split.isDraggingDivider = false
        XCTAssertEqual(doc.layout.assetsWidth, 333, accuracy: 1)
        horizontal.setPosition(380, ofDividerAt: 0)  // not a drag: not saved
        horizontal.window?.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(doc.layout.assetsWidth, 333, accuracy: 1)
    }

    func testEachProjectOpensInItsOwnWindowFrame() throws {
        let (v, m) = try screen()
        // Two frames and a third to move to, all different, each at least the minimum size and
        // inside the visible area (the CI screen leaves only a few points to spare).
        let spareW = ((v.width - m.width) / 2).rounded(.down), spareH = ((v.height - m.height) / 2).rounded(.down)
        let frameA = NSRect(x: v.minX, y: v.minY, width: min(1500, v.width - spareW), height: min(950, v.height - spareH))
        let frameB = NSRect(x: v.minX + spareW, y: v.minY + spareH, width: min(1700, v.width - spareW), height: min(1050, v.height - spareH))
        let moved = NSRect(x: v.minX + (spareW / 2).rounded(.down), y: v.minY + (spareH / 2).rounded(.down), width: m.width, height: m.height)
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
