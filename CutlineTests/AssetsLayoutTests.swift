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

    private let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

    func testTheUsualPanelShowsThreeTilesWithRoomForTheScrollBar() {
        let legacy = shape(AssetsPanelView.columns(panelWidth: 371, scrollerStyle: .legacy))
        XCTAssertEqual(legacy.count, 3)
        XCTAssertGreaterThanOrEqual(legacy.width, CGFloat(AssetsPanelView.defaultTileSize))
        XCTAssertLessThanOrEqual(CGFloat(legacy.count) * legacy.width + CGFloat(legacy.count - 1) * 8 + 28 + scroller, 371)
    }

    func testOverlayScrollBarsNeedNoRoom() {
        let overlay = shape(AssetsPanelView.columns(panelWidth: 371, scrollerStyle: .overlay))
        let legacy = shape(AssetsPanelView.columns(panelWidth: 371, scrollerStyle: .legacy))
        XCTAssertEqual(overlay.count, 3)
        XCTAssertGreaterThan(overlay.width, legacy.width)
    }

    /// A narrow panel drops to two tiles a row, then one (narrower than the chosen size).
    func testNarrowPanelsDropColumns() {
        XCTAssertEqual(shape(AssetsPanelView.columns(panelWidth: 280, scrollerStyle: .legacy)).count, 2)
        let one = shape(AssetsPanelView.columns(panelWidth: 150, scrollerStyle: .legacy))
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.width, 150 - 28 - scroller, accuracy: 1, "fills the panel")
    }

    /// The size slider: bigger tiles, fewer a row; every row filled.
    func testTheTileSizeSetsHowManyFit() {
        let small = shape(AssetsPanelView.columns(panelWidth: 600, tileSize: 80, scrollerStyle: .overlay))
        let large = shape(AssetsPanelView.columns(panelWidth: 600, tileSize: 192, scrollerStyle: .overlay))
        XCTAssertGreaterThan(small.count, large.count)
        XCTAssertGreaterThanOrEqual(large.width, 192)
        for s in [small, large] { XCTAssertEqual(CGFloat(s.count) * s.width + CGFloat(s.count - 1) * 8, 600 - 28, accuracy: CGFloat(s.count)) }
    }

    func testPicturesScaleAndNamesHideOnSmallTiles() {
        XCTAssertGreaterThan(AssetTileMetrics.pictureHeight(190), AssetTileMetrics.pictureHeight(100))
        XCTAssertFalse(AssetTileMetrics.showsName(90))
        XCTAssertTrue(AssetTileMetrics.showsName(104))
    }

    func testTheTileSizeIsSavedWithTheLayout() throws {
        var l = LayoutState()
        l.assetTileSize = 150
        XCTAssertEqual(try JSONDecoder().decode(LayoutState.self, from: JSONEncoder().encode(l)).assetTileSize, 150)
    }
}
