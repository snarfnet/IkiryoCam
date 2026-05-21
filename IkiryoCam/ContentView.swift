import SwiftUI
import PhotosUI
import AVKit

struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var sourceVideoURL: URL?
    @State private var isProcessing = false
    @State private var processedVideoURL: URL?
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @State private var showResult = false
    @State private var thumbnail: UIImage?
    @State private var videoDurationText = ""

    @State private var offsetX: CGFloat = 30
    @State private var offsetY: CGFloat = 0
    @State private var ghostOpacity: Double = 0.7
    @State private var ghostTransparency: Double = 0.45
    @State private var spectralBoost = false
    @State private var faceApparition = false

    var body: some View {
        NavigationStack {
            ZStack {
                IkiryoBackground(pulse: isProcessing)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        header

                        if let thumbnail {
                            selectedVideoCard(thumbnail)
                        } else {
                            importCard
                        }

                        if sourceVideoURL != nil {
                            effectEditor
                            processButton
                        }

                        if isProcessing {
                            processingCard
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(IkiryoTheme.warning)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 22)
                    .padding(.bottom, 38)
                }
            }
            .navigationBarHidden(true)
            .onChange(of: selectedItem) { _, newItem in
                loadVideo(from: newItem)
            }
            .fullScreenCover(isPresented: $showResult) {
                if let url = processedVideoURL {
                    ResultView(videoURL: url)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(IkiryoTheme.bone.opacity(0.78))
            }

            Text("生霊カメラ")
                .font(.system(size: 42, weight: .black, design: .serif))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.white, IkiryoTheme.bone, IkiryoTheme.warning.opacity(0.86)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: IkiryoTheme.warning.opacity(0.38), radius: 14)
                .shadow(color: .black, radius: 2, y: 2)

            Text("動画に潜む気配を映し出す")
                .font(.system(.subheadline, design: .serif).weight(.medium))
                .foregroundStyle(IkiryoTheme.bone.opacity(0.78))

            Rectangle()
                .fill(IkiryoTheme.warning.opacity(0.55))
                .frame(width: 132, height: 1)
                .blur(radius: 0.2)
        }
    }

    private var importCard: some View {
        PhotosPicker(selection: $selectedItem, matching: .videos) {
            IkiryoPanel {
                VStack(spacing: 18) {
                    ZStack {
                        Image("IkiryoHallway")
                            .resizable()
                            .scaledToFill()
                            .frame(height: 210)
                            .clipShape(Rectangle())
                            .overlay(Color.black.opacity(0.18))
                            .overlay(ScanlineOverlay().opacity(0.28))
                            .clipped()

                        Rectangle()
                            .stroke(IkiryoTheme.bone.opacity(0.8), lineWidth: 1)
                            .padding(13)

                        Image(systemName: "figure.walk.motion")
                            .font(.system(size: 48, weight: .thin))
                            .foregroundStyle(IkiryoTheme.bone.opacity(0.72))
                            .shadow(color: IkiryoTheme.sickGreen.opacity(0.5), radius: 16)
                    }

                    Text("動画をインポート")
                        .font(.system(.title3, design: .serif).weight(.black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(IkiryoTheme.oldBlood.opacity(0.86))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(IkiryoTheme.warning.opacity(0.72), lineWidth: 1))
                                .shadow(color: IkiryoTheme.warning.opacity(0.42), radius: 18)
                        )

                    Text("対応形式: MP4 / MOV")
                        .font(.caption.monospaced())
                        .foregroundStyle(IkiryoTheme.ash)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func selectedVideoCard(_ thumb: UIImage) -> some View {
        IkiryoPanel {
            VStack(spacing: 14) {
                ZStack(alignment: .bottomLeading) {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 205)
                        .clipShape(Rectangle())
                        .overlay(Color.black.opacity(0.18))
                        .overlay(ScanlineOverlay().opacity(0.24))
                        .clipped()

                    Rectangle()
                        .stroke(IkiryoTheme.bone.opacity(0.58), lineWidth: 1)
                        .padding(10)

                    HStack {
                        Label(videoDurationText, systemImage: "film")
                        Spacer()
                        Text("解析待機")
                    }
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(IkiryoTheme.bone)
                    .padding(12)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("選択済み")
                            .font(.caption.monospaced())
                            .foregroundStyle(IkiryoTheme.warning)
                        Text("この動画に生霊の残像を重ねます")
                            .font(.caption)
                            .foregroundStyle(IkiryoTheme.ash)
                    }

                    Spacer()

                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        Label("変更", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(IkiryoTheme.bone)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var effectEditor: some View {
        IkiryoPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("エフェクト編集")
                        .font(.system(.headline, design: .serif).weight(.black))
                        .foregroundStyle(IkiryoTheme.bone)
                    Spacer()
                    Button("リセット") {
                        offsetX = 30
                        offsetY = 0
                        ghostOpacity = 0.7
                        ghostTransparency = 0.45
                        spectralBoost = false
                        faceApparition = false
                    }
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(IkiryoTheme.ash)
                }

                settingRow(icon: "figure.wave", title: "生霊の強さ", value: $ghostOpacity, range: 0.1...1.0, displayMultiplier: 100)
                settingRow(icon: "sparkles", title: "透明感", value: $ghostTransparency, range: 0...1, displayMultiplier: 100)
                settingRow(icon: "arrow.left.and.right", title: "横のずれ", value: $offsetX, range: -100...100, suffix: "px")
                settingRow(icon: "arrow.up.and.down", title: "縦のずれ", value: $offsetY, range: -100...100, suffix: "px")
                triggerRow(icon: "flame", title: "霊圧強化", note: "残像とちらつきを強くする", isOn: $spectralBoost)
                triggerRow(icon: "person.crop.circle.badge.exclamationmark", title: "顔の気配", note: "暗い顔のような影を浮かべる", isOn: $faceApparition)
            }
        }
    }

    private var processButton: some View {
        Button {
            processVideo()
        } label: {
            Label("生霊を生成する", systemImage: "eye.trianglebadge.exclamationmark")
        }
        .buttonStyle(IkiryoPrimaryButton(disabled: isProcessing))
        .disabled(isProcessing)
    }

    private var processingCard: some View {
        IkiryoPanel {
            VStack(spacing: 11) {
                ProgressView(value: progress)
                    .tint(IkiryoTheme.warning)
                Text("霊像を焼き込み中... \(Int(progress * 100))%")
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(IkiryoTheme.bone.opacity(0.82))
            }
        }
    }

    private func settingRow(
        icon: String,
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String = "",
        displayMultiplier: Double = 1
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(IkiryoTheme.bone)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.08)))

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(IkiryoTheme.bone.opacity(0.9))
                Slider(value: value, in: range)
                    .tint(IkiryoTheme.warning)
            }

            Text("\(Int(value.wrappedValue * displayMultiplier))\(suffix)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(IkiryoTheme.bone)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func triggerRow(icon: String, title: String, note: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isOn.wrappedValue ? IkiryoTheme.warning : IkiryoTheme.bone)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(isOn.wrappedValue ? 0.14 : 0.08)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(IkiryoTheme.bone.opacity(0.95))
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(IkiryoTheme.ash)
                }
            }
        }
        .tint(IkiryoTheme.warning)
    }

    private func settingRow(
        icon: String,
        title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        suffix: String = ""
    ) -> some View {
        let doubleBinding = Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = CGFloat($0) }
        )
        return settingRow(
            icon: icon,
            title: title,
            value: doubleBinding,
            range: Double(range.lowerBound)...Double(range.upperBound),
            suffix: suffix
        )
    }

    private func loadVideo(from item: PhotosPickerItem?) {
        guard let item else { return }
        item.loadTransferable(type: VideoTransferable.self) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let video):
                    sourceVideoURL = video?.url
                    processedVideoURL = nil
                    errorMessage = nil
                    if let url = video?.url {
                        generateThumbnail(from: url)
                    }
                case .failure(let error):
                    errorMessage = "動画の読み込みに失敗しました: \(error.localizedDescription)"
                }
            }
        }
    }

    private func generateThumbnail(from url: URL) {
        Task {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)

            let duration = try? await asset.load(.duration)
            let seconds = duration.map { CMTimeGetSeconds($0) } ?? 0
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60

            var thumb: UIImage?
            if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                thumb = UIImage(cgImage: cgImage)
            }

            await MainActor.run {
                thumbnail = thumb
                videoDurationText = String(format: "%d:%02d", mins, secs)
            }
        }
    }

    private func processVideo() {
        guard let url = sourceVideoURL else { return }
        isProcessing = true
        progress = 0
        errorMessage = nil

        let processor = GhostProcessor(
            offsetX: offsetX,
            offsetY: offsetY,
            ghostOpacity: ghostOpacity,
            ghostTransparency: ghostTransparency,
            spectralBoost: spectralBoost,
            faceApparition: faceApparition
        )

        Task {
            do {
                let outputURL = try await processor.process(videoURL: url) { p in
                    DispatchQueue.main.async { progress = p }
                }
                DispatchQueue.main.async {
                    processedVideoURL = outputURL
                    isProcessing = false
                    showResult = true
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "処理に失敗しました: \(error.localizedDescription)"
                    isProcessing = false
                }
            }
        }
    }
}

struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let tempDir = FileManager.default.temporaryDirectory
            let filename = "ikiryocam_source_\(UUID().uuidString).mov"
            let dest = tempDir.appendingPathComponent(filename)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Self(url: dest)
        }
    }
}
