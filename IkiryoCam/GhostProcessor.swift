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

            let composition = AVMutableVideoComposition(asset: asset) { request in
                let source = request.sourceImage.clampedToExtent()
                let bounds = CGRect(origin: .zero, size: request.renderSize)

                // Ghost: offset + color shift + transparency
                let ghost = source
                    .transformed(by: CGAffineTransform(translationX: self.offsetX, y: -self.offsetY))
                    .applyingFilter("CIColorControls", parameters: [
                        kCIInputSaturationKey: 0.1,
                        kCIInputBrightnessKey: -0.1,
                    ])
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 0.7, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 0.75, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0.95, w: 0),
                        "inputBiasVector": CIVector(x: 0, y: 0, z: 0.03, w: 0),
                    ])
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(self.ghostOpacity))
                    ])

                let result = ghost.composited(over: source).cropped(to: bounds)
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
