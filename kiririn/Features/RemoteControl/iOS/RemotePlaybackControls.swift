#if os(iOS)
    import SwiftUI

    struct RemotePlaybackControls: View {
        let player: RemotePlayerSnapshot
        let send: (RemoteControlCommand) -> Void
        @State private var seekTime = 0.0
        @State private var isSeeking = false

        var body: some View {
            VStack(spacing: 10) {
                if player.isSeekable {
                    HStack {
                        Text(seekTime.playerTimeString)
                        Spacer()
                        Text(player.duration.playerTimeString)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    Slider(
                        value: $seekTime,
                        in: 0...max(player.duration, 1),
                        onEditingChanged: seekEditingChanged
                    )
                    .accessibilityLabel("再生位置")
                }

                HStack(spacing: 14) {
                    RemoteTransportButton(
                        title: "10秒戻る",
                        systemImage: "gobackward.10",
                        isDisabled: !player.isSeekable,
                        action: skipBackward
                    )

                    RemoteTransportButton(
                        title: player.isPlaying ? "一時停止" : "再生",
                        systemImage: player.isPlaying ? "pause.fill" : "play.fill",
                        isPrimary: true,
                        action: togglePlayback
                    )

                    RemoteTransportButton(
                        title: "10秒進む",
                        systemImage: "goforward.10",
                        isDisabled: !player.isSeekable,
                        action: skipForward
                    )
                }
            }
            .onAppear {
                seekTime = player.time
            }
            .onChange(of: player.time) { _, time in
                if !isSeeking {
                    seekTime = time
                }
            }
            .remoteControlCard()
        }

        private func seekEditingChanged(_ editing: Bool) {
            isSeeking = editing
            if !editing {
                send(.seekToTime(seekTime))
            }
        }

        private func skipBackward() {
            send(.skipBy(-10))
        }

        private func togglePlayback() {
            send(.setPlaying(!player.isPlaying))
        }

        private func skipForward() {
            send(.skipBy(10))
        }
    }

#endif
