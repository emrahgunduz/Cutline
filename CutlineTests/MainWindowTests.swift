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
}
