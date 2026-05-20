import AVFoundation
import CoreImage
import UIKit

final class GhostProcessor {
    let offsetX: CGFloat
    let offsetY: CGFloat
    let ghostOpacity: Double

    init(offsetX: CGFloat, offsetY: CGFloat, ghostOpacity: Double) {
        self.offsetX = offsetX
        self.offsetY = offsetY
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

        // Use AVAssetExportSession for reliable export on all devices
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProcessingError.writeFailed
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ikiryocam_\(UUID().uuidString).mov")

        export.outputURL = outputURL
        export.outputFileType = .mov

        // Apply ghost effect via video composition
        let videoTrack = asset.tracks(withMediaType: .video).first
        if let videoTrack = videoTrack {
            let naturalSize = videoTrack.naturalSize
            let transform = videoTrack.preferredTransform
            let rawSize = appliedSize(naturalSize: naturalSize, transform: transform)

            let duration = asset.duration
            let totalSeconds = CMTimeGetSeconds(duration)
            let fadeSeconds = min(1.0, totalSeconds / 3)

            let composition = AVMutableVideoComposition(asset: asset) { request in
                let source = request.sourceImage.clampedToExtent()
                let bounds = CGRect(origin: .zero, size: request.renderSize)
                let time = CMTimeGetSeconds(request.compositionTime)

                // Ghost: offset + desaturate + blue tint + blur
                let ghost = source
                    .transformed(by: CGAffineTransform(translationX: self.offsetX, y: -self.offsetY))
                    .applyingFilter("CIColorControls", parameters: [
                        kCIInputSaturationKey: 0.1,
                        kCIInputBrightnessKey: -0.1,
                        kCIInputContrastKey: 1.1,
                    ])
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 0.7, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 0.75, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0.95, w: 0),
                        "inputBiasVector": CIVector(x: 0, y: 0, z: 0.03, w: 0),
                    ])
                    .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: 8.0])

                // Fade in/out
                var opacity = self.ghostOpacity
                if time < fadeSeconds {
                    let t = time / fadeSeconds
                    opacity *= t * t * (3 - 2 * t)
                } else if time > totalSeconds - fadeSeconds {
                    let t = (totalSeconds - time) / fadeSeconds
                    opacity *= t * t * (3 - 2 * t)
                }

                // Flicker (more visible)
                opacity *= 0.65 + 0.35 * sin(time * 11) * cos(time * 4.3)

                let ghostAlpha = ghost.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
                ])

                let result = ghostAlpha.composited(over: source).cropped(to: bounds)
                request.finish(with: result, context: nil)
            }

            // Downscale if needed
            let scale: CGFloat = {
                let maxSide = max(rawSize.width, rawSize.height)
                return maxSide > Self.maxDimension ? Self.maxDimension / maxSide : 1.0
            }()
            composition.renderSize = CGSize(
                width: (rawSize.width * scale).rounded(.down),
                height: (rawSize.height * scale).rounded(.down)
            )

            export.videoComposition = composition
        }

        // Export synchronously with progress polling
        let semaphore = DispatchSemaphore(value: 0)
        export.exportAsynchronously { semaphore.signal() }

        while semaphore.wait(timeout: .now() + 0.2) == .timedOut {
            progress(min(0.95, Double(export.progress)))
        }

        guard export.status == .completed else {
            throw export.error ?? ProcessingError.writeFailed
        }

        progress(1.0)
        return outputURL
    }

    // MARK: - Helpers

    private func appliedSize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let r = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
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
