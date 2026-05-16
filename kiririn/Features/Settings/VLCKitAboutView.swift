import SwiftUI

struct VLCKitAboutView: View {
    private let sourceCodeURL = URL(string: "https://code.videolan.org/videolan/VLCKit")!

    var body: some View {
        Form {
            Section("概要") {
                Text(
                    "本アプリは、VideoLANプロジェクトによって開発されたオープンソースライブラリ VLCKit を使用しています。\n\n本アプリはLGPL v2.1の規定に基づき、VLCKitを動的にリンクして使用しています。ユーザーは、LGPLの条項に従ってVLCKitのソースコードを入手、改変、および再配布する権利を有します。"
                )
                .font(.body)
                .accessibilityLabel("VLCKitの利用についての説明")
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("詳細") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ライセンス")
                        .font(.headline)
                    Text("GNU Lesser General Public License (LGPL) version 2.1")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("著作権")
                        .font(.headline)
                    Text("Copyright (c) 1996-2026 VideoLAN and its Authors")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("ソースコード")
                        .font(.headline)
                    Link("VLCKitリポジトリを開く", destination: sourceCodeURL)
                    Text(sourceCodeURL.absoluteString)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("VLCKitについて")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
