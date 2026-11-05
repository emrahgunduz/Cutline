import XCTest
@testable import Cutline

final class ExportSettingsTests: XCTestCase {
    func testMusicVideoDefaultsToMaxQualityHEVC() {
        let s = ExportSettings.defaults(for: Project(type: .musicVideo, canvas: .init(width: 3840, height: 2160)))
        XCTAssertEqual(s.codec, .hevc)
        XCTAssertEqual(s.rateMode, .quality)
        XCTAssertEqual(s.quality, 1)
        XCTAssertTrue(s.tenBit)
    }

    /// Social defaults to a bitrate; ads to the preset's size target. Both are H.264.
    func testSocialAndAdDefaultsAreH264() {
        for type in [ProjectType.social, .ad] {
            let s = ExportSettings.defaults(for: Project(type: type, canvas: .init(width: 1080, height: 1920)))
            XCTAssertEqual(s.codec, .h264)
            XCTAssertEqual(s.rateMode, Presets.preset(for: type).defaultSizeTargetMB == nil ? .bitrate : .size)
            XCTAssertGreaterThan(s.bitrateMbps, 0)
        }
    }
}
