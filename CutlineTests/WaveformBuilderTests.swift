import XCTest
@testable import Cutline

final class WaveformBuilderTests: XCTestCase {
    func testSinePeaksMatchAmplitude() async throws {
        let url = try TestMedia.sineWAV(seconds: 1, amplitude: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let wf = try await WaveformBuilder.build(url: url)
        XCTAssertEqual(wf.sampleRate, 48000)
        XCTAssertEqual(wf.levels.map(\.samplesPerBucket), [256, 2048, 16384])
        let level = wf.levels[1]
        XCTAssertEqual(level.maxs.count, (48000 + 2047) / 2048)
        for i in 0..<(level.maxs.count - 1) {
            XCTAssertEqual(level.maxs[i], 0.5, accuracy: 0.01)
            XCTAssertEqual(level.mins[i], -0.5, accuracy: 0.01)
            XCTAssertEqual(level.rms[i], 0.5 / 2.0.squareRoot().float, accuracy: 0.01)
        }
    }

    func testLevelChoosesCoarsestFittingBucket() {
        let wf = Waveform(sampleRate: 48000, levels: WaveformBuilder.bucketSizes.map {
            WaveformLevel(samplesPerBucket: $0, mins: [], maxs: [], rms: [])
        })
        XCTAssertEqual(wf.level(secondsPerPixel: 0.001)?.samplesPerBucket, 256)
        XCTAssertEqual(wf.level(secondsPerPixel: 0.1)?.samplesPerBucket, 2048)
        XCTAssertEqual(wf.level(secondsPerPixel: 1)?.samplesPerBucket, 16384)
    }
}

private extension Double { var float: Float { Float(self) } }
