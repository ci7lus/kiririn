#if os(iOS)
    import SwiftUI

    struct RemotePlayerControlPanel: View {
        let service: RemoteControlService
        let player: RemotePlayerSnapshot
        let send: (RemoteControlCommand) -> Void

        var body: some View {
            VStack(spacing: 12) {
                RemotePlayerHeaderView(player: player)
                    .equatable()
                RemotePlaybackControls(player: player, send: send)
                RemoteVolumeControls(player: player, send: send)
                    .equatable()
                RemoteOptionControls(player: player, send: send)
                    .equatable()
                RemoteQuickActionsView(
                    service: service,
                    player: player,
                    send: send
                )
                .equatable()
            }
        }
    }
#endif
