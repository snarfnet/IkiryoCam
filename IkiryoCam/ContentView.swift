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
    @State private var showSettings = false

    @State private var offsetX: CGFloat = 30
    @State private var offsetY: CGFloat = 0
    @State private var ghostOpacity: Double = 0.7
    @State private var ghostTransparency: Double = 0.45
    @State private var spectralBoost = false
    @State private var femaleApparition = false
    @State private var handApparition = false
    @State private var maleApparition = false

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
            .sheet(isPresented: $showSettings) {
                settingsSheet
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(IkiryoTheme.bone.opacity(0.86))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.black.opacity(0.34)))
                        .overlay(Circle().stroke(IkiryoTheme.bone.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
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

    private var settingsSheet: some View {
        NavigationStack {
            ZStack {
                IkiryoTheme.void.ignoresSafeArea()
                ScanlineOverlay()
                    .opacity(0.12)
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 18) {
                    IkiryoPanel {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("設定")
                                .font(.system(.title2, design: .serif).weight(.black))
                                .foregroundStyle(IkiryoTheme.bone)

                            Button {
                                resetEffects()
                            } label: {
                                Label("エフェクトを初期値に戻す", systemImage: "arrow.counterclockwise")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(IkiryoTheme.bone)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.white.opacity(0.08))
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(IkiryoTheme.bone.opacity(0.18), lineWidth: 1))
                                    )
                            }
                            .buttonStyle(.plain)

                            Text("エフェクトの細かい調整は、動画を選択したあとに表示されます。")
                                .font(.caption)
                                .foregroundStyle(IkiryoTheme.ash)
                        }
                    }

                    IkiryoPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("現在の設定")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(IkiryoTheme.bone)
                            settingSummary(title: "生霊の強さ", value: "\(Int(ghostOpacity * 100))")
                            settingSummary(title: "透明感", value: "\(Int(ghostTransparency * 100))")
                            settingSummary(title: "霊圧強化", value: spectralBoost ? "ON" : "OFF")
                            settingSummary(title: "女の気配", value: femaleApparition ? "ON" : "OFF")
                            settingSummary(title: "手の気配", value: handApparition ? "ON" : "OFF")
                            settingSummary(title: "男の気配", value: maleApparition ? "ON" : "OFF")
                        }
                    }

                    Spacer()
                }
                .padding(18)
            }
            .navigationTitle("生霊カメラ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        showSettings = false
                    }
                    .foregroundStyle(IkiryoTheme.bone)
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }

    private func settingSummary(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(IkiryoTheme.ash)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(IkiryoTheme.warning)
        }
        .font(.caption)
    }

    private func resetEffects() {
        offsetX = 30
        offsetY = 0
        ghostOpacity = 0.7
        ghostTransparency = 0.45
        spectralBoost = false
        femaleApparition = false
        handApparition = false
        maleApparition = false
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

                        ImportApparitionMark()
                            .frame(width: 118, height: 150)
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
                        resetEffects()
                    }
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(IkiryoTheme.ash)
                }

                settingRow(icon: "figure.wave", title: "生霊の強さ", value: $ghostOpacity, range: 0.1...1.0, displayMultiplier: 100)
                settingRow(icon: "sparkles", title: "透明感", value: $ghostTransparency, range: 0...1, displayMultiplier: 100)
                settingRow(icon: "arrow.left.and.right", title: "横のずれ", value: $offsetX, range: -100...100, suffix: "px")
                settingRow(icon: "arrow.up.and.down", title: "縦のずれ", value: $offsetY, range: -100...100, suffix: "px")
                triggerRow(icon: "flame", title: "霊圧強化", note: "残像とちらつきを強くする", isOn: $spectralBoost)
                triggerRow(icon: "person.crop.circle.badge.exclamationmark", title: "女の気配", note: "女性霊の顔を左側に浮かべる", isOn: $femaleApparition)
                triggerRow(icon: "hand.raised", title: "手の気配", note: "画面端に白い手形を浮かべる", isOn: $handApparition)
                triggerRow(icon: "person.fill.viewfinder", title: "男の気配", note: "男性霊の顔を別に浮かべる", isOn: $maleApparition)
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
            femaleApparition: femaleApparition,
            handApparition: handApparition,
            maleApparition: maleApparition
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

private struct ImportApparitionMark: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate

            ZStack {
                Ellipse()
                    .fill(IkiryoTheme.sickGreen.opacity(0.12))
                    .frame(width: 92, height: 132)
                    .blur(radius: 18)

                VStack(spacing: 0) {
                    Circle()
                        .fill(IkiryoTheme.bone.opacity(0.72))
                        .frame(width: 32, height: 38)
                        .blur(radius: 2.4)
                        .offset(y: 4)

                    ZStack {
                        Ellipse()
                            .fill(IkiryoTheme.bone.opacity(0.5))
                            .frame(width: 54, height: 86)
                            .blur(radius: 3.4)

                        HStack(spacing: 28) {
                            Capsule()
                                .fill(IkiryoTheme.bone.opacity(0.34))
                                .frame(width: 13, height: 78)
                                .rotationEffect(.degrees(-12))
                            Capsule()
                                .fill(IkiryoTheme.bone.opacity(0.34))
                                .frame(width: 13, height: 78)
                                .rotationEffect(.degrees(12))
                        }
                        .offset(y: 16)
                        .blur(radius: 2.2)

                        VStack(spacing: 9) {
                            HStack(spacing: 16) {
                                Circle().fill(Color.black.opacity(0.42)).frame(width: 6, height: 8)
                                Circle().fill(Color.black.opacity(0.42)).frame(width: 6, height: 8)
                            }
                            Capsule()
                                .fill(Color.black.opacity(0.34))
                                .frame(width: 16, height: 4)
                        }
                        .offset(y: -38)
                        .blur(radius: 0.6)
                    }

                    HStack(spacing: 18) {
                        Capsule()
                            .fill(IkiryoTheme.bone.opacity(0.28))
                            .frame(width: 14, height: 56)
                            .rotationEffect(.degrees(8))
                        Capsule()
                            .fill(IkiryoTheme.bone.opacity(0.28))
                            .frame(width: 14, height: 56)
                            .rotationEffect(.degrees(-8))
                    }
                    .offset(y: -12)
                    .blur(radius: 2.6)
                }
                .offset(x: 3 * sin(t * 1.2), y: 2 * cos(t * 1.6))
                .shadow(color: IkiryoTheme.sickGreen.opacity(0.75), radius: 18)

                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(IkiryoTheme.bone.opacity(0.08))
                        .frame(width: 8, height: 82)
                        .rotationEffect(.degrees(Double(index) * 13 - 18))
                        .offset(
                            x: CGFloat(index - 2) * 18 + CGFloat(sin(t + Double(index))) * 8,
                            y: 14 + CGFloat(cos(t * 0.9 + Double(index))) * 5
                        )
                        .blur(radius: 5)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
