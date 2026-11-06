import SwiftUI
import XCTest
@testable import Cutline

/// Collapsed assets-panel sections are saved per project, in layout.json.
final class AssetsLayoutTests: XCTestCase {
    func testCollapsedSectionsAreSavedAndLoadedWithTheProject() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("assets-layout-\(UUID()).cutline", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var layout = LayoutState()
        layout.collapsedAssetGroups = [.video, .dummy]
        try ProjectDocument.save(project: Project(type: .musicVideo, canvas: .init(width: 1920, height: 1080)), layout: layout, to: dir)
        let json = try String(contentsOf: dir.appendingPathComponent("layout.json"), encoding: .utf8)
        XCTAssertTrue(json.contains(#""collapsedAssetGroups" : ["#), json)
        XCTAssertTrue(json.contains(#""video""#) && json.contains(#""dummy""#), json)
        let (_, loaded) = try ProjectDocument.load(from: dir)
        XCTAssertEqual(loaded.collapsedAssetGroups, [.video, .dummy])
    }

    func testOlderLayoutsOpenWithEverySectionOpen() throws {
        let l = try JSONDecoder().decode(LayoutState.self, from: Data(#"{"assetsWidth":300,"inspectorWidth":310,"timelineHeight":320}"#.utf8))
        XCTAssertNil(l.collapsedAssetGroups)
    }

    func testEveryAssetKindHasASavedName() {
        XCTAssertEqual(AssetGroup.allCases.map(\.rawValue), ["video", "image", "dummy", "audio", "lyrics"])
    }
}

/// The tiles' columns come from the panel's width, not the scroll view's, so a scroll bar
/// appearing doesn't change how many tiles fit in a row or their size.
final class AssetsGridColumnTests: XCTestCase {
    private func shape(_ columns: [GridItem]) -> (count: Int, width: CGFloat) {
        guard case .fixed(let w) = columns.first?.size else { return (columns.count, -1) }
        return (columns.count, w)
    }

    func testTheGridKeepsRoomForAScrollBarThatTakesSpace() {
        let legacy = shape(AssetsPanelView.columns(panelWidth: 371, scrollerStyle: .legacy))
        XCTAssertEqual(legacy.count, 3)
        XCTAssertGreaterThanOrEqual(legacy.width, 96)
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        // Every tile and gap plus the room for the scroll bar fits in the panel.
        XCTAssertLessThanOrEqual(CGFloat(legacy.count) * legacy.width + CGFloat(legacy.count - 1) * 8 + 28 + scroller, 371)
    }

    func testOverlayScrollBarsNeedNoRoom() {
        let overlay = shape(AssetsPanelView.columns(panelWidth: 371, scrollerStyle: .overlay))
        let legacy = shape(AssetsPanelView.columns(panelWidth: 371, scrollerStyle: .legacy))
        XCTAssertEqual(overlay.count, 3)
        XCTAssertGreaterThan(overlay.width, legacy.width)
    }

    func testNarrowPanelsKeepOneColumnAtTheMinimumSize() {
        let narrow = shape(AssetsPanelView.columns(panelWidth: 120, scrollerStyle: .legacy))
        XCTAssertEqual(narrow.count, 1)
        XCTAssertEqual(narrow.width, 96)
    }
}
