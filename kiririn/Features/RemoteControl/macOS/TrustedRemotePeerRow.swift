#if os(macOS)
    import SwiftUI

    struct TrustedRemotePeerRow: View {
        let peer: RemoteTrustedPeer
        let onForget: () -> Void
        @State private var isForgetConfirmationPresented = false

        var body: some View {
            LabeledContent {
                Button("解除", role: .destructive) {
                    isForgetConfirmationPresented = true
                }
                .confirmationDialog(
                    "「\(peer.displayName)」の信頼を解除しますか？",
                    isPresented: $isForgetConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button("解除", role: .destructive, action: onForget)
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("次回の接続時にPINコードの入力が必要になります。")
                }
            } label: {
                VStack(alignment: .leading) {
                    Text(peer.displayName)
                    Text(peer.pairedAt, format: .dateTime.year().month().day())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
#endif
