import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
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
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let fps = nominalFrameRate > 0 ? nominalFrameRate : 30.0
        let videoSize = appliedSize(naturalSize: naturalSize, transform: transform)
        let corrTransform = correctionTransform(transform: transform, size: videoSize)

        let totalFrames = Int(CMTimeGetSeconds(duration) * Double(fps))

        // Output
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ikiryocam_\(UUID().uuidString).mov")

        // Writer
        let writer = try AVAssetWriter(url: outputURL, fileType: .mov)
        let writerSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 5_000_000
            ]
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
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

        // Audio setup (must be added before starting)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioWriterInput: AVAssetWriterInput?
        var audioReaderOutput: AVAssetReaderTrackOutput?
        var audioReader: AVAssetReader?
        if let audioTrack = audioTracks.first {
            let aReader = try AVAssetReader(asset: asset)
            let aOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            aOutput.alwaysCopiesSampleData = true
            aReader.add(aOutput)
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            aInput.expectsMediaDataInRealTime = false
            writer.add(aInput)
            audioReader = aReader
            audioReaderOutput = aOutput
            audioWriterInput = aInput
        }

        // Video reader
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        readerOutput.alwaysCopiesSampleData = true
        reader.add(readerOutput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        reader.startReading()
        audioReader?.startReading()

        // Ring buffer for delayed frames (store as CGImage, not CIImage)
        var delayBuffer: [CGImage] = []
        let maxBuffer = delayFrames + 2
        var frameIndex = 0

        while reader.status == .reading {
            guard let sampleBuffer = readerOutput.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                if reader.status == .reading { continue }
                break
            }

            // Wait for writer to be ready (with timeout)
            var waitCount = 0
            while !writerInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.01)
                waitCount += 1
                if waitCount > 500 { break } // 5 second max wait
            }
            if !writerInput.isReadyForMoreMediaData {
                frameIndex += 1
                continue
            }

            let originalCI = CIImage(cvPixelBuffer: pixelBuffer)
                .transformed(by: corrTransform)
                .cropped(to: CGRect(origin: .zero, size: videoSize))

            // Render current frame to CGImage for delay buffer
            if let cgImg = ciContext.createCGImage(originalCI, from: CGRect(origin: .zero, size: videoSize)) {
                delayBuffer.append(cgImg)
                if delayBuffer.count > maxBuffer {
                    delayBuffer.removeFirst()
                }
            }

            // Get delayed frame
            let delayIdx = max(0, delayBuffer.count - 1 - delayFrames)
            let hasDelayedFrame = delayIdx < delayBuffer.count && delayBuffer.count > delayFrames

            // Composite
            let finalImage: CIImage
            if hasDelayedFrame {
                let delayedCI = CIImage(cgImage: delayBuffer[delayIdx])
                finalImage = createGhostComposite(
                    original: originalCI,
                    ghostSource: delayedCI,
                    videoSize: videoSize,
                    frameIndex: frameIndex,
                    totalFrames: totalFrames
                )
            } else {
                finalImage = originalCI
            }

            // Write
            guard let pool = adaptor.pixelBufferPool else {
                frameIndex += 1
                continue
            }
            var outBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
            guard let outputBuffer = outBuffer else {
                frameIndex += 1
                continue
            }

            ciContext.render(finalImage, to: outputBuffer)
            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            adaptor.append(outputBuffer, withPresentationTime: pts)

            frameIndex += 1
            if frameIndex % 2 == 0 {
                progress(Double(frameIndex) / Double(max(totalFrames, 1)))
            }
        }

        writerInput.markAsFinished()

        // Audio passthrough (already set up before writing started)
        if let aOutput = audioReaderOutput, let aInput = audioWriterInput {
            while let buf = aOutput.copyNextSampleBuffer() {
                var w = 0
                while !aInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.01)
                    w += 1; if w > 500 { break }
                }
                if aInput.isReadyForMoreMediaData {
                    aInput.append(buf)
                }
            }
            aInput.markAsFinished()
        }

        await writer.finishWriting()
        reader.cancelReading()

        if writer.status == .failed {
            throw writer.error ?? ProcessingError.writeFailed
        }

        return outputURL
    }

    // MARK: - Ghost Composite

    private func createGhostComposite(
        original: CIImage,
        ghostSource: CIImage,
        videoSize: CGSize,
        frameIndex: Int,
        totalFrames: Int
    ) -> CIImage {
        let shifted = ghostSource.transformed(by: CGAffineTransform(translationX: offsetX, y: -offsetY))

        // Desaturate + darken
        let desaturated = shifted.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.1,
            kCIInputBrightnessKey: -0.1,
            kCIInputContrastKey: 1.2,
        ])

        // Cold blue tint
        let tinted = desaturated.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.7, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.75, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.95, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0.03, w: 0),
        ])

        // Soft blur
        let blurred = tinted.applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: 4.0
        ])

        // Fade envelope
        let fadeLen = min(30, totalFrames / 6)
        let fadeOutStart = totalFrames - fadeLen
        var opacity = ghostOpacity
        if frameIndex < fadeLen {
            let t = Double(frameIndex) / Double(max(fadeLen, 1))
            opacity *= t * t * (3 - 2 * t)
        } else if frameIndex > fadeOutStart {
            let t = Double(totalFrames - frameIndex) / Double(max(fadeLen, 1))
            opacity *= t * t * (3 - 2 * t)
        }

        // Flicker
        let flicker = 0.85 + 0.15 * sin(Double(frameIndex) * 0.7) * cos(Double(frameIndex) * 0.3)
        opacity *= flicker

        // Alpha blend
        let ghostAlpha = blurred.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        ])

        return ghostAlpha
            .composited(over: original)
            .cropped(to: CGRect(origin: .zero, size: videoSize))
    }

    // MARK: - Helpers

    private func appliedSize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    private func correctionTransform(transform: CGAffineTransform, size: CGSize) -> CGAffineTransform {
        var t = transform
        if t.a == 0 && t.d == 0 {
            if t.b == 1.0 && t.c == -1.0 {
                t.tx = size.width; t.ty = 0
            } else if t.b == -1.0 && t.c == 1.0 {
                t.tx = 0; t.ty = size.height
            }
        } else if t.a == -1.0 && t.d == -1.0 {
            t.tx = size.width; t.ty = size.height
        } else {
            return .identity
        }
        return t
    }
}

enum ProcessingError: LocalizedError {
    case noVideoTrack
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "動画トラックが見つかりません"
        case .writeFailed: return "動画の書き出しに失敗しました"
        }
    }
}
