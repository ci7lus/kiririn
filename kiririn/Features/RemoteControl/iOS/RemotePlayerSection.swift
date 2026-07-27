#if os(iOS)
    import SwiftUI

    struct RemotePlayerSection: View {
        let service: RemoteControlService

        var body: some View {
            Section("プレイヤー") {
                if service.remotePlayers.isEmpty {
                    ContentUnavailableView(
                        "プレイヤーがありません",
                        systemImage: "play.slash",
                        description: Text("接続先で番組またはファイルを再生してください")
                    )
                } else {
                    ForEach(service.remotePlayers) { player in
                        NavigationLink {
                            PlayerRemoteControlView(
                                service: service,
                                playerID: player.id
                            )
                        } label: {
                            HStack(spacing: 12) {
                                Image(
                                    systemName: player.isPlaying
                                        ? "play.circle.fill"
                                        : "pause.circle"
                                )
                                .font(.title2)
                                .foregroundStyle(player.isPlaying ? Color.accentColor : .secondary)

                                VStack(alignment: .leading, spacing: 3) {
                                    BroadcastText(player.title)
                                        .lineLimit(2)
                                    if let serviceName = player.serviceName {
                                        Text(serviceName)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }
#endif
