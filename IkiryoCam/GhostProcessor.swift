import AVFoundation
import CoreImage
import UIKit

final class GhostProcessor {
    let offsetX: CGFloat
    let offsetY: CGFloat
    let ghostOpacity: Double
    let ghostTransparency: Double
    let spectralBoost: Bool
    let faceApparition: Bool
    let handApparition: Bool

    init(
        offsetX: CGFloat,
        offsetY: CGFloat,
        ghostOpacity: Double,
        ghostTransparency: Double,
        spectralBoost: Bool,
        faceApparition: Bool,
        handApparition: Bool
    ) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.ghostOpacity = ghostOpacity
        self.ghostTransparency = ghostTransparency
        self.spectralBoost = spectralBoost
        self.faceApparition = faceApparition
        self.handApparition = handApparition
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

                // Ghost: offset + desaturate + cold tint + blur
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
                let boost = self.spectralBoost ? 1.35 : 1.0
                let transparency = min(max(self.ghostTransparency, 0), 1)
                var opacity = min(self.ghostOpacity * boost, 1.15)
                opacity *= 1.0 - transparency * 0.42
                if time < fadeSeconds {
                    let t = time / fadeSeconds
                    opacity *= t * t * (3 - 2 * t)
                } else if time > totalSeconds - fadeSeconds {
                    let t = (totalSeconds - time) / fadeSeconds
                    opacity *= t * t * (3 - 2 * t)
                }

                // Flicker (more visible)
                let flickerDepth = self.spectralBoost ? 0.52 : 0.35
                opacity *= (1.0 - flickerDepth) + flickerDepth * sin(time * 11) * cos(time * 4.3)
                opacity = min(max(opacity, 0), 1.0)

                let ghostAlpha = ghost
                    .applyingFilter("CIBloom", parameters: [
                        kCIInputRadiusKey: 5.0 + transparency * 12.0,
                        kCIInputIntensityKey: 0.22 + transparency * 0.5
                    ])
                    .applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
                ])

                let motionAngle = atan2(Double(-self.offsetY), Double(max(abs(self.offsetX), 1.0)))
                let trail = ghost
                    .transformed(by: CGAffineTransform(translationX: self.offsetX * 0.65, y: -self.offsetY * 0.65))
                    .applyingFilter("CIMotionBlur", parameters: [
                        kCIInputRadiusKey: self.spectralBoost ? 30.0 : 18.0,
                        kCIInputAngleKey: motionAngle
                    ])
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity * (self.spectralBoost ? 0.62 : 0.42)))
                    ])

                let farTrail = ghost
                    .transformed(by: CGAffineTransform(translationX: self.offsetX * -0.55, y: self.offsetY * 0.4))
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: self.spectralBoost ? 22.0 : 14.0])
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 1.2, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 0.3, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0.34, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity * (self.spectralBoost ? 0.36 : 0.22)))
                    ])

                let faceLayer = self.faceApparition
                    ? self.apparitionFace(bounds: bounds, time: time, opacity: opacity)
                    : CIImage.empty().cropped(to: bounds)
                let handLayer = self.handApparition
                    ? self.apparitionHand(bounds: bounds, time: time, opacity: opacity)
                    : CIImage.empty().cropped(to: bounds)

                let result = farTrail
                    .composited(over: trail)
                    .composited(over: ghostAlpha)
                    .composited(over: faceLayer)
                    .composited(over: handLayer)
                    .composited(over: source)
                    .applyingFilter("CIVignette", parameters: [
                        kCIInputIntensityKey: 0.72,
                        kCIInputRadiusKey: min(bounds.width, bounds.height) * 0.82
                    ])
                    .cropped(to: bounds)
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

    private func apparitionFace(bounds: CGRect, time: Double, opacity: Double) -> CIImage {
        let center = CGPoint(
            x: bounds.midX + bounds.width * 0.08 * sin(time * 0.7),
            y: bounds.midY - bounds.height * 0.16 + bounds.height * 0.025 * cos(time * 0.9)
        )
        let radius = min(bounds.width, bounds.height) * 0.23
        let alpha = CGFloat(min(max(opacity * 0.78, 0.16), 0.68))

        let face = radialLayer(
            center: center,
            radius0: radius * 0.16,
            radius1: radius,
            color0: CIColor(red: 0.82, green: 0.96, blue: 1.0, alpha: alpha),
            color1: CIColor(red: 0.1, green: 0.16, blue: 0.18, alpha: 0),
            bounds: bounds
        )

        let forehead = radialLayer(
            center: CGPoint(x: center.x, y: center.y + radius * 0.36),
            radius0: radius * 0.08,
            radius1: radius * 0.36,
            color0: CIColor(red: 0.9, green: 1.0, blue: 1.0, alpha: alpha * 0.45),
            color1: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0),
            bounds: bounds
        )

        let leftEye = radialLayer(
            center: CGPoint(x: center.x - radius * 0.28, y: center.y + radius * 0.12),
            radius0: radius * 0.055,
            radius1: radius * 0.21,
            color0: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: min(alpha * 1.65, 0.9)),
            color1: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0),
            bounds: bounds
        )

        let rightEye = radialLayer(
            center: CGPoint(x: center.x + radius * 0.28, y: center.y + radius * 0.12),
            radius0: radius * 0.055,
            radius1: radius * 0.21,
            color0: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: min(alpha * 1.65, 0.9)),
            color1: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0),
            bounds: bounds
        )

        let noseShadow = radialLayer(
            center: CGPoint(x: center.x, y: center.y - radius * 0.06),
            radius0: radius * 0.035,
            radius1: radius * 0.16,
            color0: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: alpha * 0.62),
            color1: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0),
            bounds: bounds
        )

        let mouth = radialLayer(
            center: CGPoint(x: center.x, y: center.y - radius * 0.34),
            radius0: radius * 0.065,
            radius1: radius * 0.24,
            color0: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: min(alpha * 1.2, 0.78)),
            color1: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0),
            bounds: bounds
        )

        return mouth
            .composited(over: noseShadow)
            .composited(over: rightEye)
            .composited(over: leftEye)
            .composited(over: forehead)
            .composited(over: face)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * 0.032])
            .cropped(to: bounds)
    }

    private func apparitionHand(bounds: CGRect, time: Double, opacity: Double) -> CIImage {
        let side: CGFloat = sin(time * 0.45) > 0 ? 1 : -1
        let palmCenter = CGPoint(
            x: bounds.midX + side * bounds.width * 0.32 + bounds.width * 0.025 * sin(time * 0.9),
            y: bounds.midY - bounds.height * 0.2 + bounds.height * 0.035 * cos(time * 0.8)
        )
        let radius = min(bounds.width, bounds.height) * 0.105
        let alpha = CGFloat(min(max(opacity * 0.74, 0.14), 0.58))

        var hand = radialLayer(
            center: palmCenter,
            radius0: radius * 0.24,
            radius1: radius * 1.05,
            color0: CIColor(red: 0.84, green: 0.96, blue: 1.0, alpha: alpha),
            color1: CIColor(red: 0.05, green: 0.08, blue: 0.09, alpha: 0),
            bounds: bounds
        )

        let fingerOffsets: [(CGFloat, CGFloat, CGFloat)] = [
            (-0.5, 0.92, 0.82),
            (-0.18, 1.16, 1.0),
            (0.14, 1.12, 0.96),
            (0.45, 0.92, 0.78),
            (0.78 * side, 0.36, 0.64)
        ]

        for (xOffset, yOffset, scale) in fingerOffsets {
            let x = palmCenter.x + side * radius * xOffset
            let y = palmCenter.y + radius * yOffset
            let finger = radialLayer(
                center: CGPoint(x: x, y: y),
                radius0: radius * 0.12,
                radius1: radius * 0.42 * scale,
                color0: CIColor(red: 0.88, green: 0.98, blue: 1.0, alpha: alpha * 0.92),
                color1: CIColor(red: 0.02, green: 0.04, blue: 0.05, alpha: 0),
                bounds: bounds
            )
            hand = finger.composited(over: hand)
        }

        let wrist = radialLayer(
            center: CGPoint(x: palmCenter.x - side * radius * 0.08, y: palmCenter.y - radius * 0.78),
            radius0: radius * 0.16,
            radius1: radius * 0.6,
            color0: CIColor(red: 0.76, green: 0.92, blue: 0.98, alpha: alpha * 0.5),
            color1: CIColor(red: 0.02, green: 0.04, blue: 0.05, alpha: 0),
            bounds: bounds
        )

        return wrist
            .composited(over: hand)
            .applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: radius * 0.24,
                kCIInputAngleKey: side > 0 ? Double.pi * 0.02 : Double.pi * 0.98
            ])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * 0.035])
            .cropped(to: bounds)
    }

    private func radialLayer(
        center: CGPoint,
        radius0: CGFloat,
        radius1: CGFloat,
        color0: CIColor,
        color1: CIColor,
        bounds: CGRect
    ) -> CIImage {
        CIFilter(
            name: "CIRadialGradient",
            parameters: [
                "inputCenter": CIVector(x: center.x, y: center.y),
                "inputRadius0": radius0,
                "inputRadius1": radius1,
                "inputColor0": color0,
                "inputColor1": color1
            ]
        )?.outputImage?.cropped(to: bounds) ?? CIImage.empty().cropped(to: bounds)
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
