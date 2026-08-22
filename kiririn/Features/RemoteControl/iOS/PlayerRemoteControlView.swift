#if os(iOS)
    import SwiftUI

    struct PlayerRemoteControlView: View {
        @Environment(\.dismiss) private var dismiss

        let service: RemoteControlService
        let playerID: String

        var body: some View {
            Group {
                if let player {
                    ScrollView {
                        RemotePlayerControlPanel(
                            service: service,
                            player: player,
                            send: { command in
                                service.sendCommand(command, playerID: playerID)
                            }
                        )
                        .disabled(service.isReconnecting)
                        .overlay(alignment: .top) {
                            if service.isReconnecting {
                                AppFeedbackLabel(
                                    text: "再接続中…",
                                    showsProgress: true
                                )
                                .padding(.top)
                                .allowsHitTesting(false)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom)
                    }
                } else {
                    ContentUnavailableView(
                        "プレイヤーを操作できません",
                        systemImage: "play.slash",
                        description: Text("プレイヤーが終了した可能性があります")
                    )
                }
            }
            .navigationTitle("リモコン")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: isPlayerAvailable, initial: true) { _, isAvailable in
                guard !isAvailable else { return }
                dismiss()
            }
        }

        private var player: RemotePlayerSnapshot? {
            service.remotePlayers.first { $0.id == playerID }
        }

        private var isPlayerAvailable: Bool {
            player != nil
        }
    }
#endif
