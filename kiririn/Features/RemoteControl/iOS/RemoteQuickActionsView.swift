#if os(iOS)
    import SwiftUI

    struct RemoteQuickActionsView: View {
        let service: RemoteControlService
        let player: RemotePlayerSnapshot
        let send: (RemoteControlCommand) -> Void
        @State private var isCloseConfirmationPresented = false

        private let columns = [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
        ]

        var body: some View {
            LazyVGrid(columns: columns, spacing: 8) {
                if player.capabilities.contains(.subtitle) {
                    RemoteActionButton(
                        title: "字幕",
                        systemImage: "captions.bubble",
                        isActive: player.isSubtitleEnabled
                    ) {
                        send(.setSubtitleEnabled(!player.isSubtitleEnabled))
                    }
                }

                if player.capabilities.contains(.pictureInPicture) {
                    RemoteActionButton(
                        title: "PiP",
                        systemImage: "pip",
                        isActive: player.isPipEnabled
                    ) {
                        send(.setPipEnabled(!player.isPipEnabled))
                    }
                }

                if player.capabilities.contains(.capture) {
                    RemoteActionButton(title: "撮影", systemImage: "camera") {
                        send(.takeCapture)
                    }
                }

                if player.capabilities.contains(.recording) {
                    RemoteActionButton(
                        title: "録画",
                        systemImage: player.isRecording ? "stop.circle.fill" : "record.circle",
                        isActive: player.isRecording
                    ) {
                        send(.setRecording(!player.isRecording))
                    }
                }

                if player.capabilities.contains(.reload) {
                    RemoteActionButton(title: "再読込", systemImage: "arrow.clockwise") {
                        send(.reload)
                    }
                }

                if player.capabilities.contains(.fullscreen),
                    let isFullscreen = player.isFullscreen
                {
                    RemoteActionButton(
                        title: "全画面",
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        isActive: isFullscreen
                    ) {
                        send(.setFullscreen(!isFullscreen))
                    }
                }

                if player.capabilities.contains(.alwaysOnTop),
                    let isAlwaysOnTop = player.isAlwaysOnTop
                {
                    RemoteActionButton(
                        title: "最前面",
                        systemImage: "macwindow.on.rectangle",
                        isActive: isAlwaysOnTop,
                        isDisabled: player.isFullscreen == true
                    ) {
                        send(.setAlwaysOnTop(!isAlwaysOnTop))
                    }
                }

                RemoteDataBroadcastNavigationButton(
                    service: service,
                    playerID: player.id,
                    isAvailable: player.capabilities.contains(.dataBroadcast)
                )

                if player.capabilities.contains(.close) {
                    RemoteActionButton(
                        title: "閉じる",
                        systemImage: "power",
                        role: .destructive
                    ) {
                        isCloseConfirmationPresented = true
                    }
                }
            }
            .confirmationDialog(
                "プレイヤーを閉じますか？",
                isPresented: $isCloseConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("閉じる", role: .destructive) {
                    send(.close)
                }
                Button("キャンセル", role: .cancel) {}
            }
            .remoteControlCard()
        }
    }
#endif
