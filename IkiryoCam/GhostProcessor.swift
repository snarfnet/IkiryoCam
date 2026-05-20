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
        guard let videoTrack = tracks.first else {
            throw ProcessingError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let fps = nominalFrameRate > 0 ? nominalFrameRate : 30.0

        // Determine actual video dimensions after transform
        let videoSize = appliedSize(naturalSize: naturalSize, transform: transform)

        // Phase 1: Extract body poses from all frames
        let poses = try await extractPoses(asset: asset, duration: duration, fps: fps, progress: { p in
            progress(p * 0.4) // 0-40%
        })

        // Phase 2: Render ghost composite
        let outputURL = try await renderComposite(
            asset: asset,
            videoTrack: videoTrack,
            duration: duration,
            fps: fps,
            videoSize: videoSize,
            transform: transform,
            poses: poses,
            progress: { p in progress(0.4 + p * 0.6) } // 40-100%
        )

        return outputURL
    }

    // MARK: - Phase 1: Body Pose Extraction

    private func extractPoses(
        asset: AVURLAsset,
        duration: CMTime,
        fps: Float,
        progress: @escaping (Double) -> Void
    ) async throws -> [Int: [VNHumanBodyPoseObservation]] {
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw ProcessingError.noVideoTrack }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        let totalFrames = Int(CMTimeGetSeconds(duration) * Double(fps))
        var posesByFrame: [Int: [VNHumanBodyPoseObservation]] = [:]
        var frameIndex = 0

        let request = VNDetectHumanBodyPoseRequest()

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                frameIndex += 1
                continue
            }

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try? handler.perform([request])

            if let results = request.results, !results.isEmpty {
                posesByFrame[frameIndex] = results
            }

            frameIndex += 1
            if frameIndex % 5 == 0 {
                progress(Double(frameIndex) / Double(max(totalFrames, 1)))
            }
        }

        reader.cancelReading()
        return posesByFrame
    }

    // MARK: - Phase 2: Ghost Compositing

    private func renderComposite(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        duration: CMTime,
        fps: Float,
        videoSize: CGSize,
        transform: CGAffineTransform,
        poses: [Int: [VNHumanBodyPoseObservation]],
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ikiryocam_\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(url: outputURL, fileType: .mov)
        let writerSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
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

        // Audio passthrough
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioWriterInput: AVAssetWriterInput?
        var audioReaderOutput: AVAssetReaderTrackOutput?
        var audioReader: AVAssetReader?

        if let audioTrack = audioTracks.first {
            let aReader = try AVAssetReader(asset: asset)
            let aOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            aReader.add(aOutput)
            let aWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            aWriterInput.expectsMediaDataInRealTime = false
            writer.add(aWriterInput)
            audioReader = aReader
            audioReaderOutput = aOutput
            audioWriterInput = aWriterInput
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

        let totalFrames = Int(CMTimeGetSeconds(duration) * Double(fps))
        var frameIndex = 0
        var recentFrames: [CIImage] = [] // Ring buffer for delay

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                frameIndex += 1
                continue
            }

            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }

            let originalImage = CIImage(cvPixelBuffer: pixelBuffer)
                .transformed(by: correctionTransform(transform: transform, size: videoSize))

            // Store frame for delay buffer
            recentFrames.append(originalImage)

            // Get delayed frame for ghost
            let delayedIndex = max(0, recentFrames.count - 1 - delayFrames)
            let delayedImage = recentFrames[delayedIndex]

            // Get ghost pose from delayed frame index
            let ghostFrameIdx = max(0, frameIndex - delayFrames)

            // Create ghost from delayed frame with pose data
            let composited: CIImage
            if let _ = poses[ghostFrameIdx] {
                composited = createGhostComposite(
                    original: originalImage,
                    ghostSource: delayedImage,
                    videoSize: videoSize,
                    frameIndex: frameIndex,
                    totalFrames: totalFrames
                )
            } else {
                composited = originalImage
            }

            // Render to pixel buffer
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

            ciContext.render(composited, to: outputBuffer)

            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            adaptor.append(outputBuffer, withPresentationTime: presentationTime)

            // Limit buffer size
            if recentFrames.count > delayFrames + 10 {
                recentFrames.removeFirst()
            }

            frameIndex += 1
            if frameIndex % 3 == 0 {
                progress(Double(frameIndex) / Double(max(totalFrames, 1)))
            }
        }

        writerInput.markAsFinished()

        // Copy audio
        if let aReader = audioReader, let aOutput = audioReaderOutput, let aInput = audioWriterInput {
            aReader.startReading()
            while let audioBuffer = aOutput.copyNextSampleBuffer() {
                while !aInput.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                aInput.append(audioBuffer)
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
        // Offset the ghost source
        let shifted = ghostSource.transformed(by: CGAffineTransform(translationX: offsetX, y: -offsetY))

        // Desaturate ghost
        let desaturated = shifted.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.1,
            kCIInputBrightnessKey: -0.1,
            kCIInputContrastKey: 1.2,
        ])

        // Blue/cold tint
        let tinted = desaturated.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.7, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.75, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.95, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0.03, w: 0),
        ])

        // Gaussian blur for ghostly softness
        let blurred = tinted.applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: 3.0
        ])

        // Fade in/out at start and end
        let fadeInFrames = min(30, totalFrames / 6)
        let fadeOutStart = totalFrames - fadeInFrames
        var opacity = ghostOpacity
        if frameIndex < fadeInFrames {
            let t = Double(frameIndex) / Double(fadeInFrames)
            opacity *= t * t * (3 - 2 * t) // smoothstep
        } else if frameIndex > fadeOutStart {
            let t = Double(totalFrames - frameIndex) / Double(fadeInFrames)
            opacity *= t * t * (3 - 2 * t)
        }

        // Flicker effect
        let flicker = 0.85 + 0.15 * sin(Double(frameIndex) * 0.7) * cos(Double(frameIndex) * 0.3)
        opacity *= flicker

        // Blend ghost over original
        let blendedGhost = blurred.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        ])

        let composited = blendedGhost.composited(over: original)

        // Crop to video bounds
        return composited.cropped(to: CGRect(origin: .zero, size: videoSize))
    }

    // MARK: - Helpers

    private func appliedSize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    private func correctionTransform(transform: CGAffineTransform, size: CGSize) -> CGAffineTransform {
        var t = transform
        if t.a == 0 && t.d == 0 {
            // 90 or 270 degree rotation
            if t.b == 1.0 && t.c == -1.0 {
                // 90 degrees
                t.tx = size.width
                t.ty = 0
            } else if t.b == -1.0 && t.c == 1.0 {
                // 270 degrees
                t.tx = 0
                t.ty = size.height
            }
        } else if t.a == -1.0 && t.d == -1.0 {
            // 180 degrees
            t.tx = size.width
            t.ty = size.height
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
