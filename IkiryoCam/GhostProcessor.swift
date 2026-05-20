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

    /// Max output dimension to prevent memory issues on large videos
    private static let maxDimension: CGFloat = 1080

    func process(videoURL: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            processingQueue.async {
                do {
                    let url = try self.processSync(videoURL: videoURL, progress: progress)
                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private let processingQueue = DispatchQueue(label: "com.tokyonasu.ikiryocam.processing", qos: .userInitiated)

    private func processSync(videoURL: URL, progress: @escaping (Double) -> Void) throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let duration = asset.duration
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw ProcessingError.noVideoTrack
        }

        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        let fps = videoTrack.nominalFrameRate
        let rawSize = appliedSize(naturalSize: naturalSize, transform: transform)

        // Downscale if larger than maxDimension
        let scale: CGFloat = {
            let maxSide = max(rawSize.width, rawSize.height)
            return maxSide > Self.maxDimension ? Self.maxDimension / maxSide : 1.0
        }()
        let videoSize = CGSize(
            width: (rawSize.width * scale).rounded(.down),
            height: (rawSize.height * scale).rounded(.down)
        )
        let corrTransform: CGAffineTransform = {
            let base = correctionTransform(transform: transform, size: rawSize)
            if scale < 1.0 {
                return base.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            }
            return base
        }()
        let totalSeconds = CMTimeGetSeconds(duration)
        let totalFrames = max(1, Int(totalSeconds * Double(fps > 0 ? fps : 30)))
        let timescale = CMTimeScale(fps > 0 ? fps : 30)

        // Output
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ikiryocam_\(UUID().uuidString).mov")

        // Writer (passthrough - no re-encoding)
        let writer = try AVAssetWriter(url: outputURL, fileType: .mov)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        // Audio
        let audioTracks = asset.tracks(withMediaType: .audio)
        var audioWriterInput: AVAssetWriterInput?
        var audioReaderOutput: AVAssetReaderTrackOutput?
        var audioReader: AVAssetReader?
        if let audioTrack = audioTracks.first {
            let ar = try AVAssetReader(asset: asset)
            let ao = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            ar.add(ao)
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            ai.expectsMediaDataInRealTime = false
            writer.add(ai)
            audioReader = ar; audioReaderOutput = ao; audioWriterInput = ai
        }

        // Video reader (passthrough - no pixel format conversion)
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        reader.add(readerOutput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        reader.startReading()
        audioReader?.startReading()

        var frameIndex = 0

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            // Wait for writer
            while !writerInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.01)
            }

            writerInput.append(sampleBuffer)

            frameIndex += 1
            if frameIndex % 5 == 0 {
                progress(min(0.95, Double(frameIndex) / Double(totalFrames)))
            }
        }

        // Check if reader failed
        if reader.status == .failed {
            throw reader.error ?? ProcessingError.writeFailed
        }

        writerInput.markAsFinished()

        // Audio
        if let ao = audioReaderOutput, let ai = audioWriterInput {
            while let buf = ao.copyNextSampleBuffer() {
                var waitCount = 0
                while !ai.isReadyForMoreMediaData && waitCount < 300 {
                    Thread.sleep(forTimeInterval: 0.01); waitCount += 1
                }
                if ai.isReadyForMoreMediaData { ai.append(buf) }
            }
            ai.markAsFinished()
        }

        // Finish writing (synchronous wait)
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

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
            .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: 3.0])

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
