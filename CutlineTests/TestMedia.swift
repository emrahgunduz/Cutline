import AVFoundation
import CoreGraphics
import Foundation

/// Generates small media files for tests.
enum TestMedia {
    static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cutline-test-\(UUID().uuidString).\(ext)")
    }

    /// Mono 32-bit float WAV of a sine wave.
    static func sineWAV(seconds: Double, frequency: Double = 440, amplitude: Float = 0.5, sampleRate: Double = 48000) throws -> URL {
        let url = tempURL("wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { data[i] = amplitude * Float(sin(2 * .pi * frequency * Double(i) / sampleRate)) }
        try file.write(from: buffer)
        return url
    }

    /// H.264 video of solid gray frames.
    static func video(width: Int = 640, height: Int = 360, fps: Int32 = 24, frames: Int = 24) async throws -> URL {
        let url = tempURL("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            memset(CVPixelBufferGetBaseAddress(pb!), 128, CVPixelBufferGetDataSize(pb!))
            CVPixelBufferUnlockBaseAddress(pb!, [])
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// RGBA PNG: left half transparent, right half opaque red.
    static func halfTransparentPNG(size: Int = 64) throws -> URL {
        let url = tempURL("png")
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: size / 2, y: 0, width: size / 2, height: size))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return url
    }
}
