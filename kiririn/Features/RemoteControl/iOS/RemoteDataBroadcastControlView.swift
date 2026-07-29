#if os(iOS)
    import SwiftUI

    struct RemoteDataBroadcastControlView: View {
        let service: RemoteControlService
        let playerID: String

        var body: some View {
            Group {
                if let player {
                    ScrollView {
                        BMLRemoteControlPad(
                            layout: .touch,
                            availability: availability(for: player)
                        ) { key in
                            service.sendCommand(.pressBMLKey(key), playerID: playerID)
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "プレイヤーを操作できません",
                        systemImage: "play.slash",
                        description: Text("プレイヤーが終了した可能性があります")
                    )
                }
            }
            .navigationTitle("データ放送")
            .navigationBarTitleDisplayMode(.inline)
        }

        private var player: RemotePlayerSnapshot? {
            service.remotePlayers.first { $0.id == playerID }
        }

        private func availability(
            for player: RemotePlayerSnapshot
        ) -> BMLRemoteControlAvailability {
            let isAvailable = player.capabilities.contains(.dataBroadcast)
            return BMLRemoteControlAvailability(
                isDataButtonEnabled: isAvailable,
                enabledGroups: isAvailable && player.isDataBroadcastVisible
                    ? player.bmlKeyGroups : []
            )
        }
    }
#endif
