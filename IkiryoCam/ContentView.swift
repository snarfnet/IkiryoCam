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

    // Ghost settings
    @State private var offsetX: CGFloat = 30
    @State private var offsetY: CGFloat = 0
    @State private var delayFrames: Double = 8
    @State private var ghostOpacity: Double = 0.35

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Title
                        VStack(spacing: 4) {
                            Text("生霊カメラ")
                                .font(.system(size: 36, weight: .thin))
                                .foregroundColor(.white)
                            Text("IkiryoCam")
                                .font(.system(size: 14, weight: .light, design: .monospaced))
                                .foregroundColor(.gray)
                        }
                        .padding(.top, 20)

                        // Video picker
                        PhotosPicker(selection: $selectedItem, matching: .videos) {
                            VStack(spacing: 12) {
                                Image(systemName: "film.stack")
                                    .font(.system(size: 48))
                                    .foregroundColor(.white.opacity(0.6))
                                Text("動画を選択")
                                    .font(.headline)
                                    .foregroundColor(.white.opacity(0.8))
                                Text("カメラロールから人物が映った動画を選んでください")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 180)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.white.opacity(0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .strokeBorder(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [8]))
                                    )
                            )
                        }
                        .padding(.horizontal)

                        if sourceVideoURL != nil {
                            // Settings
                            VStack(alignment: .leading, spacing: 16) {
                                Text("生霊の設定")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)

                                settingRow(title: "横ずれ", value: $offsetX, range: -100...100, unit: "px")
                                settingRow(title: "縦ずれ", value: $offsetY, range: -100...100, unit: "px")
                                settingRow(title: "遅延", value: $delayFrames, range: 0...30, unit: "F")
                                settingRow(title: "透明度", value: $ghostOpacity, range: 0.1...0.7, unit: "")
                            }
                            .padding()
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                            .padding(.horizontal)

                            // Process button
                            Button {
                                processVideo()
                            } label: {
                                HStack {
                                    Image(systemName: "person.fill.questionmark")
                                    Text("生霊を生成")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.purple.opacity(0.7))
                                )
                                .foregroundColor(.white)
                            }
                            .disabled(isProcessing)
                            .padding(.horizontal)
                        }

                        if isProcessing {
                            VStack(spacing: 8) {
                                ProgressView(value: progress)
                                    .tint(.purple)
                                Text("生霊を召喚中... \(Int(progress * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            .padding(.horizontal)
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
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

    private func settingRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 60, alignment: .leading)
            Slider(value: value, in: range)
                .tint(.purple)
            Text("\(Int(value.wrappedValue))\(unit)")
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 50, alignment: .trailing)
                .font(.caption.monospacedDigit())
        }
    }

    private func settingRow(title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, unit: String) -> some View {
        let doubleBinding = Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = CGFloat($0) }
        )
        return settingRow(title: title, value: doubleBinding, range: Double(range.lowerBound)...Double(range.upperBound), unit: unit)
    }

    private func loadVideo(from item: PhotosPickerItem?) {
        guard let item else { return }
        item.loadTransferable(type: VideoTransferable.self) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let video):
                    self.sourceVideoURL = video?.url
                    self.processedVideoURL = nil
                    self.errorMessage = nil
                case .failure(let error):
                    self.errorMessage = "動画の読み込みに失敗: \(error.localizedDescription)"
                }
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
            delayFrames: Int(delayFrames),
            ghostOpacity: ghostOpacity
        )

        Task {
            do {
                let outputURL = try await processor.process(videoURL: url) { p in
                    DispatchQueue.main.async { self.progress = p }
                }
                DispatchQueue.main.async {
                    self.processedVideoURL = outputURL
                    self.isProcessing = false
                    self.showResult = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "処理失敗: \(error.localizedDescription)"
                    self.isProcessing = false
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
