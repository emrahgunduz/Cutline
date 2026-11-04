import CoreImage
import XCTest
@testable import Cutline

final class FilterChainTests: XCTestCase {
    static let ctx = CIContext()

    static func meanLuma(_ image: CIImage, _ rect: CGRect? = nil) -> Double {
        let r = rect ?? image.extent
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (0.2126 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.0722 * Double(px[2])) / 255
    }

    private let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))

    func testDisabledFilterLeavesImageUnchanged() {
        var f = FilterSettings()
        f.color.brightness = 0.5               // configured but switched off
        let out = FilterChain.apply(f, to: gray)
        XCTAssertEqual(Self.meanLuma(out), Self.meanLuma(gray), accuracy: 0.001)
    }

    func testBrightnessRaisesLuma() {
        var f = FilterSettings()
        f.color.enabled = true
        f.color.brightness = 0.2
        XCTAssertGreaterThan(Self.meanLuma(FilterChain.apply(f, to: gray)), Self.meanLuma(gray) + 0.05)
    }

    func testFadeOpacity() {
        let fade = FadeFilter(enabled: true, fadeIn: 1, fadeOut: 2)
        XCTAssertEqual(FilterChain.fadeOpacity(fade, localTime: 0.5, duration: 10), 0.5)
        XCTAssertEqual(FilterChain.fadeOpacity(fade, localTime: 5, duration: 10), 1)
        XCTAssertEqual(FilterChain.fadeOpacity(fade, localTime: 9, duration: 10), 0.5)
        XCTAssertEqual(FilterChain.fadeOpacity(FadeFilter(), localTime: 0, duration: 10), 1)
    }

    func testEmptyFrameIsBlack() {
        let p = Project(type: .musicVideo, canvas: .init(width: 64, height: 36))
        let img = FrameRenderer.render(RenderSnapshot(project: p, images: [:], lyrics: nil), at: 0) { _ in nil }
        XCTAssertEqual(img.extent, CGRect(x: 0, y: 0, width: 64, height: 36))
        XCTAssertEqual(Self.meanLuma(img), 0, accuracy: 0.001)
    }

    func testPNGOnTopTrackCompositesWithAlpha() throws {
        var p = Project(type: .musicVideo, canvas: .init(width: 64, height: 64))
        let base = Asset(kind: .image, name: "base", path: "/base")
        let png = Asset(kind: .image, name: "png", path: "/png")
        p.assets = [base, png]
        p.addVideoTrack()
        p.addClip(assetID: base.id, track: 0, at: 0)
        p.addClip(assetID: png.id, track: 1, at: 0)
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let pngURL = try TestMedia.halfTransparentPNG(size: 64)
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let half = try XCTUnwrap(CIImage(contentsOf: pngURL))
        let img = FrameRenderer.render(RenderSnapshot(project: p, images: [base.id: white, png.id: half], lyrics: nil), at: 1) { _ in nil }
        // Left half shows the white base through the transparent PNG; right half is red.
        XCTAssertEqual(Self.meanLuma(img, CGRect(x: 0, y: 0, width: 32, height: 64)), 1, accuracy: 0.01)
        XCTAssertEqual(Self.meanLuma(img, CGRect(x: 32, y: 0, width: 32, height: 64)), 0.2126, accuracy: 0.02)
    }
}
