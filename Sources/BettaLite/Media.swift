// For the README: the tank as a video (H.264) or an animated GIF, rendered offscreen frame by frame,
// with the same choices as --snap.

import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// a frame drawn smaller, `width` pixels across (and an even number of pixels each way, for video)
func shrink(_ image: CGImage, width: Int) -> CGImage {
    let w = width / 2 * 2, h = Int(Double(image.height) * Double(w) / Double(image.width)) / 2 * 2
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

/// `seconds` of the tank from `from`, 30 frames a second, as an MP4
func film(_ file: String, from: Double, seconds: Double, width: Int) {
    let (tank, setup, before) = toolScene()
    let first = Int(from * 30), last = first + Int(seconds * 30)
    try? FileManager.default.removeItem(atPath: file)
    var writer: AVAssetWriter?, input: AVAssetWriterInput?, adaptor: AVAssetWriterInputPixelBufferAdaptor?
    render(tank, frames: Set(first...last), scale: 1, setup: setup, before: before) { n, _, image in
        let frame = shrink(image, width: width)
        if writer == nil {
            let w = try! AVAssetWriter(outputURL: URL(fileURLWithPath: file), fileType: .mp4)
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: frame.width, AVVideoHeightKey: frame.height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: frame.width * frame.height * 4],
            ])
            i.expectsMediaDataInRealTime = false
            let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: frame.width, kCVPixelBufferHeightKey as String: frame.height,
            ])
            w.add(i)
            w.startWriting()
            w.startSession(atSourceTime: .zero)
            writer = w; input = i; adaptor = a
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor!.pixelBufferPool!, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: frame.width, height: frame.height, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input!.isReadyForMoreMediaData { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        adaptor!.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(n - first), timescale: 30))
    }
    input?.markAsFinished()
    var done = false
    writer?.finishWriting { done = true }
    while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    print("wrote \(file)")
}

/// `seconds` of the tank from `from`, `fps` frames a second, as an animated GIF that loops
func gif(_ file: String, from: Double, seconds: Double, fps: Int, width: Int) {
    let (tank, setup, before) = toolScene()
    let step = max(30 / fps, 1), first = Int(from * 30), last = first + Int(seconds * 30)
    let frames = Set(stride(from: first, through: last, by: step))
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: file) as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let delay = Double(step) / 30
    render(tank, frames: frames, scale: 1, setup: setup, before: before) { _, _, image in
        CGImageDestinationAddImage(dest, shrink(image, width: width),
                                   [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }
    CGImageDestinationFinalize(dest)
    print("wrote \(file)")
}
