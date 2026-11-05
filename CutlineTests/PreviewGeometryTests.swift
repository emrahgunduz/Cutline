import CoreImage
import XCTest
@testable import Cutline

final class PreviewGeometryTests: XCTestCase {
    func testFitCentersCanvas() {
        let g = PreviewGeometry(viewSize: CGSize(width: 1000, height: 1000), canvas: CGSize(width: 1920, height: 1080), zoom: nil, pan: .zero)
        XCTAssertEqual(g.scale, 1000 / 1920.0, accuracy: 1e-9)
        XCTAssertEqual(g.canvasRect.midY, 500, accuracy: 1e-9)
    }

    func testPointRoundTripWithZoomAndPan() {
        let g = PreviewGeometry(viewSize: CGSize(width: 800, height: 600), canvas: CGSize(width: 1920, height: 1080), zoom: 2, pan: CGPoint(x: 40, y: -30))
        let c = CGPoint(x: 300, y: 700)
        let back = g.canvasPoint(g.viewPoint(c))
        XCTAssertEqual(back.x, c.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, c.y, accuracy: 1e-9)
    }

    func testClipRectMatchesRendererPlacement() {
        let canvas = CGSize(width: 1920, height: 1080)
        var t = ClipTransform(); t.scale = 0.5; t.offsetX = 100; t.offsetY = -50
        let r = PreviewGeometry.clipRect(source: CGSize(width: 2560, height: 1440), transform: t, canvas: canvas)
        let src = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let placed = FrameRenderer.place(src, transform: t, canvas: CGRect(origin: .zero, size: canvas)).extent
        XCTAssertEqual(r.minX, placed.minX, accuracy: 0.01)
        XCTAssertEqual(r.minY, placed.minY, accuracy: 0.01)
        XCTAssertEqual(r.width, placed.width, accuracy: 0.01)
    }
}
