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
            IkiryoBackground(pulse: true)

            VStack(spacing: 18) {
                topBar

                IkiryoPanel {
                    VStack(spacing: 12) {
                        if let player {
                            VideoPlayer(player: player)
                                .frame(maxWidth: .infinity)
                                .aspectRatio(9.0 / 12.0, contentMode: .fit)
                                .clipShape(Rectangle())
                                .overlay(Rectangle().stroke(IkiryoTheme.bone.opacity(0.52), lineWidth: 1))
                                .overlay(ScanlineOverlay().opacity(0.18))
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
                                .tint(IkiryoTheme.warning)
                                .frame(height: 360)
                        }

                        Button {
                            player?.seek(to: .zero)
                            player?.play()
                        } label: {
                            Label("もう一度見る", systemImage: "play.circle")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(IkiryoTheme.bone)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
                        }
                    }
                }

                VStack(spacing: 12) {
                    Button {
                        saveToLibrary()
                    } label: {
                        Label(saved ? "保存済み" : saving ? "保存中..." : "保存する", systemImage: saved ? "checkmark.circle.fill" : "arrow.down.to.line")
                    }
                    .buttonStyle(IkiryoPrimaryButton(disabled: saved || saving))
                    .disabled(saved || saving)

                    ShareLink(item: videoURL) {
                        Label("シェアする", systemImage: "square.and.arrow.up")
                            .font(.system(.headline, design: .serif).weight(.bold))
                            .foregroundStyle(IkiryoTheme.bone)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.black.opacity(0.46))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(IkiryoTheme.bone.opacity(0.22), lineWidth: 1))
                            )
                    }

                    Button {
                        dismiss()
                    } label: {
                        Label("新しい動画を編集", systemImage: "plus")
                            .font(.system(.headline, design: .serif).weight(.bold))
                            .foregroundStyle(IkiryoTheme.bone.opacity(0.88))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.black.opacity(0.32))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(IkiryoTheme.bone.opacity(0.16), lineWidth: 1))
                            )
                    }
                }
                .padding(.horizontal, 18)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(IkiryoTheme.warning)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }
        .onAppear {
            player = AVPlayer(url: videoURL)
        }
        .onDisappear {
            player?.pause()
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(IkiryoTheme.bone)
                    .frame(width: 38, height: 38)
            }

            Spacer()

            VStack(spacing: 2) {
                Text("完成")
                    .font(.system(.headline, design: .serif).weight(.black))
                    .foregroundStyle(IkiryoTheme.bone)
                Text("霊像を書き出しました")
                    .font(.caption2.monospaced())
                    .foregroundStyle(IkiryoTheme.ash)
            }

            Spacer()

            Image(systemName: "house")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(IkiryoTheme.bone.opacity(0.82))
                .frame(width: 38, height: 38)
        }
        .padding(.horizontal, 16)
    }

    private func saveToLibrary() {
        saving = true
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    errorMessage = "写真ライブラリへの保存が許可されていません。"
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
                        errorMessage = error?.localizedDescription ?? "保存に失敗しました。"
                    }
                    saving = false
                }
            }
        }
    }
}
