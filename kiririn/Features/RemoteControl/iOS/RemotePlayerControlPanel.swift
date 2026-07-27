#if os(iOS)
    import SwiftUI

    struct RemotePlayerControlPanel: View {
        let service: RemoteControlService
        let player: RemotePlayerSnapshot
        let send: (RemoteControlCommand) -> Void

        var body: some View {
            VStack(spacing: 12) {
                RemotePlayerHeaderView(player: player)
                RemotePlaybackControls(player: player, send: send)
                RemoteVolumeControls(player: player, send: send)
                RemoteOptionControls(player: player, send: send)
                RemoteQuickActionsView(
                    service: service,
                    player: player,
                    send: send
                )
            }
        }
    }
#endif
