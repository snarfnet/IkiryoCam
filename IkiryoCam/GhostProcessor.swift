import AVFoundation
import CoreImage
import UIKit

final class GhostProcessor {
    let offsetX: CGFloat
    let offsetY: CGFloat
    let delayFrames: Int
    let ghostOpacity: Double

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(offsetX: CGFloat, offsetY: CGFloat, delayFrames: Int, ghostOpacity: Double) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.delayFrames = delayFrames
        self.ghostOpacity = ghostOpacity
    }

    func process(videoURL: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else { throw ProcessingError.noVideoTrack }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let fps = try await videoTrack.load(.nominalFrameRate)
        let videoSize = appliedSize(naturalSize: naturalSize, transform: transform)
        let corrTransform = correctionTransform(transform: transform, size: videoSize)
        let totalSeconds = CMTimeGetSeconds(duration)
        let totalFrames = max(1, Int(totalSeconds * Double(fps > 0 ? fps : 30)))
        let timescale = CMTimeScale(fps > 0 ? fps : 30)

        // Output
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ikiryocam_\(UUID().uuidString).mov")

        // Writer
        let writer = try AVAssetWriter(url: outputURL, fileType: .mov)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 5_000_000]
        ])
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(videoSize.width),
                kCVPixelBufferHeightKey as String: Int(videoSize.height),
            ]
        )

        // Audio
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioWriterInput: AVAssetWriterInput?
        var audioReaderOutput: AVAssetReaderTrackOutput?
        var audioReader: AVAssetReader?
        if let audioTrack = audioTracks.first {
            let ar = try AVAssetReader(asset: asset)
            let ao = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            ao.alwaysCopiesSampleData = true
            ar.add(ao)
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            ai.expectsMediaDataInRealTime = false
            writer.add(ai)
            audioReader = ar; audioReaderOutput = ao; audioWriterInput = ai
        }

        // Video reader
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        reader.startReading()
        audioReader?.startReading()

        // Delay buffer: store pixel buffers directly
        var delayRing: [CVPixelBuffer] = []
        var frameIndex = 0

        // Pre-allocate a reusable pixel buffer for ghost rendering
        let bounds = CGRect(origin: .zero, size: videoSize)

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                frameIndex += 1
                continue
            }

            // Wait for writer
            var w = 0
            while !writerInput.isReadyForMoreMediaData && w < 300 {
                Thread.sleep(forTimeInterval: 0.01)
                w += 1
            }
            guard writerInput.isReadyForMoreMediaData else { frameIndex += 1; continue }

            let originalCI = CIImage(cvPixelBuffer: pixelBuffer)
                .transformed(by: corrTransform)
                .cropped(to: bounds)

            // Copy pixel buffer for delay ring
            if delayFrames > 0 {
                var copy: CVPixelBuffer?
                let w = CVPixelBufferGetWidth(pixelBuffer)
                let h = CVPixelBufferGetHeight(pixelBuffer)
                CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &copy)
                if let dst = copy {
                    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                    CVPixelBufferLockBaseAddress(dst, [])
                    let src = CVPixelBufferGetBaseAddress(pixelBuffer)
                    let dstPtr = CVPixelBufferGetBaseAddress(dst)
                    let bytes = CVPixelBufferGetDataSize(pixelBuffer)
                    if let s = src, let d = dstPtr {
                        memcpy(d, s, min(bytes, CVPixelBufferGetDataSize(dst)))
                    }
                    CVPixelBufferUnlockBaseAddress(dst, [])
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                    delayRing.append(dst)
                    if delayRing.count > delayFrames + 2 {
                        delayRing.removeFirst()
                    }
                }
            }

            // Ghost source: delayed frame or current
            let ghostCI: CIImage
            if delayFrames > 0 && delayRing.count > delayFrames {
                let delayIdx = delayRing.count - 1 - delayFrames
                ghostCI = CIImage(cvPixelBuffer: delayRing[delayIdx])
                    .transformed(by: corrTransform)
                    .cropped(to: bounds)
            } else {
                ghostCI = originalCI
            }

            // Composite ghost
            let finalImage = ghostComposite(
                original: originalCI,
                ghost: ghostCI,
                bounds: bounds,
                frame: frameIndex,
                total: totalFrames
            )

            // Write frame
            guard let pool = adaptor.pixelBufferPool else { frameIndex += 1; continue }
            var outBuf: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
            guard let out = outBuf else { frameIndex += 1; continue }

            ciContext.render(finalImage, to: out)
            adaptor.append(out, withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: timescale))

            frameIndex += 1
            if frameIndex % 3 == 0 {
                progress(min(0.95, Double(frameIndex) / Double(totalFrames)))
            }
        }

        writerInput.markAsFinished()

        // Audio
        if let ao = audioReaderOutput, let ai = audioWriterInput {
            while let buf = ao.copyNextSampleBuffer() {
                var w = 0
                while !ai.isReadyForMoreMediaData && w < 300 {
                    Thread.sleep(forTimeInterval: 0.01); w += 1
                }
                if ai.isReadyForMoreMediaData { ai.append(buf) }
            }
            ai.markAsFinished()
        }

        await writer.finishWriting()
        reader.cancelReading()
        audioReader?.cancelReading()

        guard writer.status == .completed else {
            throw writer.error ?? ProcessingError.writeFailed
        }

        progress(1.0)
        return outputURL
    }

    // MARK: - Ghost Composite

    private func ghostComposite(original: CIImage, ghost: CIImage, bounds: CGRect, frame: Int, total: Int) -> CIImage {
        let shifted = ghost.transformed(by: CGAffineTransform(translationX: offsetX, y: -offsetY))

        let processed = shifted
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.1,
                kCIInputBrightnessKey: -0.1,
                kCIInputContrastKey: 1.2,
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.7, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.75, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.95, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0.03, w: 0),
            ])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4.0])

        // Fade + flicker
        let fadeLen = max(1, min(30, total / 6))
        var opacity = ghostOpacity
        if frame < fadeLen {
            let t = Double(frame) / Double(fadeLen)
            opacity *= t * t * (3 - 2 * t)
        } else if frame > total - fadeLen {
            let t = Double(total - frame) / Double(fadeLen)
            opacity *= t * t * (3 - 2 * t)
        }
        opacity *= 0.85 + 0.15 * sin(Double(frame) * 0.7) * cos(Double(frame) * 0.3)

        let ghostAlpha = processed.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        ])

        return ghostAlpha.composited(over: original).cropped(to: bounds)
    }

    // MARK: - Helpers

    private func appliedSize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let r = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    private func correctionTransform(transform: CGAffineTransform, size: CGSize) -> CGAffineTransform {
        var t = transform
        if t.a == 0 && t.d == 0 {
            if t.b == 1.0 && t.c == -1.0 { t.tx = size.width; t.ty = 0 }
            else if t.b == -1.0 && t.c == 1.0 { t.tx = 0; t.ty = size.height }
        } else if t.a == -1.0 && t.d == -1.0 {
            t.tx = size.width; t.ty = size.height
        } else { return .identity }
        return t
    }
}

enum ProcessingError: LocalizedError {
    case noVideoTrack, writeFailed
    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "動画トラックが見つかりません"
        case .writeFailed: return "動画の書き出しに失敗しました"
        }
    }
}
