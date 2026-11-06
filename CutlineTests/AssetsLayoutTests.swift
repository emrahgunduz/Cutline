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
