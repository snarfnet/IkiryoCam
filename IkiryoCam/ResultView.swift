import SwiftUI
import AVKit
import Photos

struct ResultView: View {
    let videoURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var saved = false
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    Spacer()
                    Text("生霊動画")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Color.clear.frame(width: 30)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                if let player {
                    VideoPlayer(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                        .onAppear {
                            player.play()
                            NotificationCenter.default.addObserver(
                                forName: .AVPlayerItemDidPlayToEndTime,
                                object: player.currentItem,
                                queue: .main
                            ) { _ in
                                player.seek(to: .zero)
                                player.play()
                            }
                        }
                } else {
                    ProgressView()
                        .tint(.purple)
                }

                HStack(spacing: 16) {
                    // Save button
                    Button {
                        saveToLibrary()
                    } label: {
                        HStack {
                            Image(systemName: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                            Text(saved ? "保存済み" : "カメラロールに保存")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.7)))
                        .foregroundColor(.white)
                    }
                    .disabled(saved || saving)

                    // Share button
                    ShareLink(item: videoURL) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("共有")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                        .foregroundColor(.white)
                    }
                }
                .padding(.horizontal)

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Spacer()
            }
        }
        .onAppear {
            player = AVPlayer(url: videoURL)
        }
    }

    private func saveToLibrary() {
        saving = true
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    errorMessage = "写真ライブラリへのアクセスが許可されていません"
                    saving = false
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        saved = true
                    } else {
                        errorMessage = error?.localizedDescription ?? "保存に失敗しました"
                    }
                    saving = false
                }
            }
        }
    }
}
