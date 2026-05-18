import SwiftUI

struct VLCKitAboutView: View {
    private let sourceCodeURL = URL(string: "https://code.videolan.org/videolan/VLCKit")!
    private let modifiedSourceCodeURL = URL(string: "https://github.com/vivid-lapin/vlckit")!

    var body: some View {
        Form {
            Section("概要") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "本アプリは、VideoLANプロジェクトによって開発されたオープンソースライブラリVLCKitを本アプリ向けに改変したものを使用しています。"
                    )
                    Text(
                        "本アプリはGNU Lesser General Public License v2.1の規定に基づき、VLCKitを動的にリンクして使用しています。ユーザーは、LGPLの条項に従ってVLCKitのソースコードを入手、改変、および再配布する権利を有します。"
                    )
                }
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading) {
                    Text("VLCKit ソースコード")
                        .font(.callout).bold()
                    Link(destination: sourceCodeURL) {
                        Text(sourceCodeURL.absoluteString)
                    }
                }
                VStack(alignment: .leading) {
                    Text("改変版 VLCKit ソースコード")
                        .font(.callout).bold()
                    Link(destination: modifiedSourceCodeURL) {
                        Text(modifiedSourceCodeURL.absoluteString)
                    }
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

#Preview {
    NavigationStack {
        VLCKitAboutView()
    }
}
