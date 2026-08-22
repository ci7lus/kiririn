#if os(iOS)
    import SwiftUI

    struct RemoteQuickActionsView: View, Equatable {
        let service: RemoteControlService
        let player: RemotePlayerSnapshot
        let send: (RemoteControlCommand) -> Void
        @State private var isReloadConfirmationPresented = false
        @State private var isCloseConfirmationPresented = false

        private let columns = [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
        ]

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.player.id == rhs.player.id
                && lhs.player.capabilities == rhs.player.capabilities
                && lhs.player.isSubtitleEnabled == rhs.player.isSubtitleEnabled
                && lhs.player.isPipEnabled == rhs.player.isPipEnabled
                && lhs.player.isRecording == rhs.player.isRecording
                && lhs.player.isFullscreen == rhs.player.isFullscreen
                && lhs.player.isAlwaysOnTop == rhs.player.isAlwaysOnTop
        }

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
                        isReloadConfirmationPresented = true
                    }
                    .confirmationDialog(
                        "プレイヤーを再読み込みしますか？",
                        isPresented: $isReloadConfirmationPresented,
                        titleVisibility: .visible
                    ) {
                        Button("再読み込み") {
                            send(.reload)
                        }
                        Button("キャンセル", role: .cancel) {}
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
