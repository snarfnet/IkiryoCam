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
    let maleApparition: Bool
    private let faceTexture: CIImage?
    private let handTexture: CIImage?
    private let maleTexture: CIImage?

    init(
        offsetX: CGFloat,
        offsetY: CGFloat,
        ghostOpacity: Double,
        ghostTransparency: Double,
        spectralBoost: Bool,
        faceApparition: Bool,
        handApparition: Bool,
        maleApparition: Bool
    ) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.ghostOpacity = ghostOpacity
        self.ghostTransparency = ghostTransparency
        self.spectralBoost = spectralBoost
        self.faceApparition = faceApparition
        self.handApparition = handApparition
        self.maleApparition = maleApparition
        self.faceTexture = Self.loadTexture(named: "GhostFace")
        self.handTexture = Self.loadTexture(named: "GhostHand")
        self.maleTexture = Self.loadTexture(named: "GhostMale")
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
                let maleLayer = self.maleApparition
                    ? self.apparitionMale(bounds: bounds, time: time, opacity: opacity)
                    : CIImage.empty().cropped(to: bounds)

                let result = farTrail
                    .composited(over: trail)
                    .composited(over: ghostAlpha)
                    .composited(over: faceLayer)
                    .composited(over: handLayer)
                    .composited(over: maleLayer)
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

    private static func loadTexture(named name: String) -> CIImage? {
        guard let image = UIImage(named: name) else { return nil }
        return CIImage(image: image)
    }

    private func apparitionFace(bounds: CGRect, time: Double, opacity: Double) -> CIImage {
        if let faceTexture {
            let center = CGPoint(
                x: bounds.midX + bounds.width * 0.06 * sin(time * 0.7),
                y: bounds.midY - bounds.height * 0.06 + bounds.height * 0.02 * cos(time * 0.9)
            )
            return apparitionTexture(
                faceTexture,
                bounds: bounds,
                center: center,
                width: bounds.width * 0.78,
                height: bounds.height * 0.58,
                opacity: CGFloat(min(max(opacity * 0.92, 0.28), 0.82)),
                mirror: false
            )
        }

        let center = CGPoint(
            x: bounds.midX + bounds.width * 0.06 * sin(time * 0.7),
            y: bounds.midY - bounds.height * 0.1 + bounds.height * 0.02 * cos(time * 0.9)
        )
        let radius = min(bounds.width, bounds.height) * 0.42
        let alpha = CGFloat(min(max(opacity * 1.05, 0.28), 0.86))

        let face = ovalLayer(
            center: center,
            xRadius: radius * 0.48,
            yRadius: radius * 0.74,
            color0: CIColor(red: 0.82, green: 0.96, blue: 1.0, alpha: alpha),
            color1: CIColor(red: 0.1, green: 0.16, blue: 0.18, alpha: 0.02),
            bounds: bounds
        )

        let hair = ovalLayer(
            center: CGPoint(x: center.x, y: center.y + radius * 0.05),
            xRadius: radius * 0.62,
            yRadius: radius * 0.94,
            color0: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: alpha * 0.45),
            color1: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0),
            bounds: bounds
        )

        let leftCheek = ovalLayer(
            center: CGPoint(x: center.x - radius * 0.2, y: center.y - radius * 0.12),
            xRadius: radius * 0.2,
            yRadius: radius * 0.32,
            color0: CIColor(red: 0.9, green: 1.0, blue: 1.0, alpha: alpha * 0.28),
            color1: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0),
            bounds: bounds
        )

        let rightCheek = ovalLayer(
            center: CGPoint(x: center.x + radius * 0.2, y: center.y - radius * 0.12),
            xRadius: radius * 0.2,
            yRadius: radius * 0.32,
            color0: CIColor(red: 0.9, green: 1.0, blue: 1.0, alpha: alpha * 0.28),
            color1: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0),
            bounds: bounds
        )

        let forehead = radialLayer(
            center: CGPoint(x: center.x, y: center.y + radius * 0.34),
            radius0: radius * 0.1,
            radius1: radius * 0.42,
            color0: CIColor(red: 0.9, green: 1.0, blue: 1.0, alpha: alpha * 0.45),
            color1: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0),
            bounds: bounds
        )

        let leftEye = radialLayer(
            center: CGPoint(x: center.x - radius * 0.21, y: center.y + radius * 0.12),
            radius0: radius * 0.055,
            radius1: radius * 0.18,
            color0: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: min(alpha * 1.85, 0.95)),
            color1: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0),
            bounds: bounds
        )

        let rightEye = radialLayer(
            center: CGPoint(x: center.x + radius * 0.21, y: center.y + radius * 0.12),
            radius0: radius * 0.055,
            radius1: radius * 0.18,
            color0: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: min(alpha * 1.85, 0.95)),
            color1: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0),
            bounds: bounds
        )

        let noseShadow = radialLayer(
            center: CGPoint(x: center.x, y: center.y - radius * 0.05),
            radius0: radius * 0.026,
            radius1: radius * 0.13,
            color0: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: alpha * 0.72),
            color1: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0),
            bounds: bounds
        )

        let mouth = radialLayer(
            center: CGPoint(x: center.x, y: center.y - radius * 0.31),
            radius0: radius * 0.09,
            radius1: radius * 0.23,
            color0: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: min(alpha * 1.5, 0.92)),
            color1: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0),
            bounds: bounds
        )

        return mouth
            .composited(over: noseShadow)
            .composited(over: rightEye)
            .composited(over: leftEye)
            .composited(over: forehead)
            .composited(over: rightCheek)
            .composited(over: leftCheek)
            .composited(over: face)
            .composited(over: hair)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * 0.018])
            .cropped(to: bounds)
    }

    private func apparitionHand(bounds: CGRect, time: Double, opacity: Double) -> CIImage {
        let side: CGFloat = sin(time * 0.45) > 0 ? 1 : -1
        if let handTexture {
            let center = CGPoint(
                x: bounds.midX + side * bounds.width * 0.2 + bounds.width * 0.025 * sin(time * 0.9),
                y: bounds.midY - bounds.height * 0.02 + bounds.height * 0.035 * cos(time * 0.8)
            )
            return apparitionTexture(
                handTexture,
                bounds: bounds,
                center: center,
                width: bounds.width * 0.78,
                height: bounds.height * 0.66,
                opacity: CGFloat(min(max(opacity * 0.95, 0.3), 0.86)),
                mirror: side < 0
            )
        }

        let palmCenter = CGPoint(
            x: bounds.midX + side * bounds.width * 0.2 + bounds.width * 0.025 * sin(time * 0.9),
            y: bounds.midY - bounds.height * 0.08 + bounds.height * 0.035 * cos(time * 0.8)
        )
        let radius = min(bounds.width, bounds.height) * 0.25
        let alpha = CGFloat(min(max(opacity * 1.0, 0.28), 0.82))

        var hand = ovalLayer(
            center: palmCenter,
            xRadius: radius * 0.56,
            yRadius: radius * 0.72,
            color0: CIColor(red: 0.84, green: 0.96, blue: 1.0, alpha: alpha),
            color1: CIColor(red: 0.05, green: 0.08, blue: 0.09, alpha: 0),
            bounds: bounds
        )

        let fingerOffsets: [(CGFloat, CGFloat, CGFloat)] = [
            (-0.5, 1.0, 1.0),
            (-0.2, 1.42, 1.28),
            (0.1, 1.48, 1.36),
            (0.42, 1.22, 1.1),
            (0.83 * side, 0.44, 0.92)
        ]

        for (xOffset, yOffset, scale) in fingerOffsets {
            let x = palmCenter.x + side * radius * xOffset
            let y = palmCenter.y + radius * yOffset
            let finger = ovalLayer(
                center: CGPoint(x: x, y: y),
                xRadius: radius * 0.14,
                yRadius: radius * 0.46 * scale,
                color0: CIColor(red: 0.88, green: 0.98, blue: 1.0, alpha: alpha),
                color1: CIColor(red: 0.02, green: 0.04, blue: 0.05, alpha: 0),
                bounds: bounds
            )
            hand = finger.composited(over: hand)
        }

        let wrist = ovalLayer(
            center: CGPoint(x: palmCenter.x - side * radius * 0.08, y: palmCenter.y - radius * 0.74),
            xRadius: radius * 0.28,
            yRadius: radius * 0.72,
            color0: CIColor(red: 0.76, green: 0.92, blue: 0.98, alpha: alpha * 0.58),
            color1: CIColor(red: 0.02, green: 0.04, blue: 0.05, alpha: 0),
            bounds: bounds
        )

        return wrist
            .composited(over: hand)
            .applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: radius * 0.1,
                kCIInputAngleKey: side > 0 ? Double.pi * 0.02 : Double.pi * 0.98
            ])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * 0.018])
            .cropped(to: bounds)
    }

    private func apparitionMale(bounds: CGRect, time: Double, opacity: Double) -> CIImage {
        if let maleTexture {
            let center = CGPoint(
                x: bounds.midX - bounds.width * 0.18 + bounds.width * 0.045 * sin(time * 0.55),
                y: bounds.midY - bounds.height * 0.05 + bounds.height * 0.025 * cos(time * 0.75)
            )
            return apparitionTexture(
                maleTexture,
                bounds: bounds,
                center: center,
                width: bounds.width * 0.72,
                height: bounds.height * 0.56,
                opacity: CGFloat(min(max(opacity * 0.94, 0.3), 0.84)),
                mirror: false
            )
        }

        let center = CGPoint(
            x: bounds.midX - bounds.width * 0.18 + bounds.width * 0.045 * sin(time * 0.55),
            y: bounds.midY - bounds.height * 0.05 + bounds.height * 0.025 * cos(time * 0.75)
        )
        return ovalLayer(
            center: center,
            xRadius: min(bounds.width, bounds.height) * 0.26,
            yRadius: min(bounds.width, bounds.height) * 0.38,
            color0: CIColor(red: 0.82, green: 0.96, blue: 1.0, alpha: CGFloat(min(max(opacity, 0.25), 0.76))),
            color1: CIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0),
            bounds: bounds
        )
    }

    private func apparitionTexture(
        _ texture: CIImage,
        bounds: CGRect,
        center: CGPoint,
        width: CGFloat,
        height: CGFloat,
        opacity: CGFloat,
        mirror: Bool
    ) -> CIImage {
        let extent = texture.extent
        guard extent.width > 0, extent.height > 0 else {
            return CIImage.empty().cropped(to: bounds)
        }

        let xScale = width / extent.width * (mirror ? -1 : 1)
        let yScale = height / extent.height
        let xOffset = center.x - (mirror ? -width / 2 : width / 2)
        let yOffset = center.y - height / 2

        let placed = texture
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: xScale, y: yScale))
            .transformed(by: CGAffineTransform(translationX: xOffset, y: yOffset))
            .cropped(to: bounds)

        let lifted = placed
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.08,
                kCIInputBrightnessKey: 0.04,
                kCIInputContrastKey: 1.28
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.8, y: 0.08, z: 0.08, w: 0),
                "inputGVector": CIVector(x: 0.08, y: 0.95, z: 0.08, w: 0),
                "inputBVector": CIVector(x: 0.1, y: 0.2, z: 1.2, w: 0),
                "inputAVector": CIVector(x: opacity * 0.31, y: opacity * 0.36, z: opacity * 0.43, w: 0)
            ])
            .applyingFilter("CIBloom", parameters: [
                kCIInputRadiusKey: min(width, height) * 0.035,
                kCIInputIntensityKey: 0.35
            ])
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: min(width, height) * 0.006
            ])

        return lifted.cropped(to: bounds)
    }

    private func ovalLayer(
        center: CGPoint,
        xRadius: CGFloat,
        yRadius: CGFloat,
        color0: CIColor,
        color1: CIColor,
        bounds: CGRect
    ) -> CIImage {
        let baseRadius = max(xRadius, yRadius)
        let scaledCenter = CGPoint(
            x: center.x * baseRadius / xRadius,
            y: center.y * baseRadius / yRadius
        )

        let ovalBounds = CGRect(
            x: bounds.minX * baseRadius / xRadius,
            y: bounds.minY * baseRadius / yRadius,
            width: bounds.width * baseRadius / xRadius,
            height: bounds.height * baseRadius / yRadius
        )

        let oval = radialLayer(
            center: scaledCenter,
            radius0: baseRadius * 0.18,
            radius1: baseRadius,
            color0: color0,
            color1: color1,
            bounds: ovalBounds
        )

        return oval
            .transformed(by: CGAffineTransform(scaleX: xRadius / baseRadius, y: yRadius / baseRadius))
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
