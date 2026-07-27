#if os(iOS)
    import SwiftUI

    struct RemoteDataBroadcastNavigationButton: View {
        let service: RemoteControlService
        let playerID: String
        let isAvailable: Bool

        var body: some View {
            NavigationLink {
                RemoteDataBroadcastControlView(
                    service: service,
                    playerID: playerID
                )
            } label: {
                VStack(spacing: 5) {
                    Text("d")
                        .italic()
                        .bold()
                        .font(.title3)
                        .frame(height: 22)
                    Text("データ")
                        .font(.caption)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 58)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .disabled(!isAvailable)
            .accessibilityLabel("データ放送リモコン")
        }
    }
#endif
