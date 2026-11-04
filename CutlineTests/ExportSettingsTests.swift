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

    func testSocialAndAdDefaultToBitrateH264() {
        for type in [ProjectType.social, .ad] {
            let s = ExportSettings.defaults(for: Project(type: type, canvas: .init(width: 1080, height: 1920)))
            XCTAssertEqual(s.codec, .h264)
            XCTAssertEqual(s.rateMode, .bitrate)
            XCTAssertGreaterThan(s.bitrateMbps, 0)
        }
    }
}
