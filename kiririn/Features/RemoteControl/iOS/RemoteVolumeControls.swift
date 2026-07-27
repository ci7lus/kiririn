#if os(iOS)
    import SwiftUI

    struct RemoteVolumeControls: View {
        let player: RemotePlayerSnapshot
        let send: (RemoteControlCommand) -> Void
        @State private var volume = 100.0
        @State private var isAdjustingVolume = false

        var body: some View {
            HStack(spacing: 10) {
                Button("音量を下げる", systemImage: "minus", action: decreaseVolume)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .frame(minWidth: 44, minHeight: 44)

                Slider(
                    value: $volume,
                    in: 0...200,
                    onEditingChanged: volumeEditingChanged
                )
                .accessibilityLabel("音量")
                .accessibilityValue("\(Int(volume.rounded()))パーセント")

                Button("音量を上げる", systemImage: "plus", action: increaseVolume)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .frame(minWidth: 44, minHeight: 44)

                Button(
                    player.isMuted ? "ミュート解除" : "ミュート",
                    systemImage: player.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    action: toggleMute
                )
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .frame(minWidth: 44, minHeight: 44)
            }
            .onAppear {
                volume = Double(player.volume)
            }
            .onChange(of: player.volume) { _, newVolume in
                if !isAdjustingVolume {
                    volume = Double(newVolume)
                }
            }
            .remoteControlCard()
        }

        private func toggleMute() {
            send(.setMuted(!player.isMuted))
        }

        private func decreaseVolume() {
            updateVolume(to: volume - 5)
        }

        private func increaseVolume() {
            updateVolume(to: volume + 5)
        }

        private func updateVolume(to newValue: Double) {
            volume = min(max(newValue, 0), 200)
            send(.setVolume(Float(volume)))
        }

        private func volumeEditingChanged(_ editing: Bool) {
            isAdjustingVolume = editing
            if !editing {
                send(.setVolume(Float(volume)))
            }
        }
    }
#endif
