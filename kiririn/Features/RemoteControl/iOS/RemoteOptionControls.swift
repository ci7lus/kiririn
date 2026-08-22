#if os(iOS)
    import SwiftUI

    struct RemoteOptionControls: View, Equatable {
        let player: RemotePlayerSnapshot
        let send: (RemoteControlCommand) -> Void

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.player.id == rhs.player.id
                && lhs.player.capabilities == rhs.player.capabilities
                && lhs.player.rate == rhs.player.rate
                && lhs.player.audioTracks == rhs.player.audioTracks
                && lhs.player.selectedAudioTrackSelection
                    == rhs.player.selectedAudioTrackSelection
                && lhs.player.videoTracks == rhs.player.videoTracks
                && lhs.player.selectedVideoTrackID == rhs.player.selectedVideoTrackID
        }

        var body: some View {
            HStack(spacing: 8) {
                if player.capabilities.contains(.rate) {
                    Menu {
                        Picker(
                            "再生速度",
                            selection: Binding<Float>(
                                get: { player.rate },
                                set: { send(.setRate($0)) }
                            )
                        ) {
                            ForEach(PlayerPlaybackOptionCatalog.rateOptions, id: \.self) { rate in
                                Text(PlayerPlaybackOptionCatalog.rateLabel(rate))
                                    .tag(rate)
                            }
                        }
                        .labelsHidden()
                    } label: {
                        optionLabel(
                            title: "速度",
                            value: PlayerPlaybackOptionCatalog.rateLabel(player.rate),
                            systemImage: "speedometer"
                        )
                    }
                }

                if player.capabilities.contains(.audioTrack) {
                    Menu {
                        Picker(
                            "音声トラック",
                            selection: Binding<RemoteAudioTrackSelection?>(
                                get: { player.selectedAudioTrackSelection },
                                set: { send(.selectAudioTrack($0)) }
                            )
                        ) {
                            Text("トラックなし")
                                .tag(RemoteAudioTrackSelection?.none)
                                .disabled(true)
                                .selectionDisabled()
                            ForEach(player.audioTracks) { track in
                                Text(track.label)
                                    .tag(RemoteAudioTrackSelection?.some(track.selection))
                            }
                        }
                        .labelsHidden()
                    } label: {
                        optionLabel(
                            title: "音声",
                            value: selectedAudioTrackName,
                            systemImage: "waveform"
                        )
                    }
                }

                if player.capabilities.contains(.videoTrack) {
                    Menu {
                        Picker(
                            "映像トラック",
                            selection: Binding<String?>(
                                get: { player.selectedVideoTrackID },
                                set: {
                                    guard let trackID = $0 else { return }
                                    send(.selectVideoTrack(trackID))
                                }
                            )
                        ) {
                            Text("トラックなし")
                                .tag(String?.none)
                                .disabled(true)
                                .selectionDisabled()
                            ForEach(player.videoTracks) { track in
                                Text(track.name)
                                    .tag(String?.some(track.id))
                            }
                        }
                        .labelsHidden()
                    } label: {
                        optionLabel(
                            title: "映像",
                            value: selectedVideoTrackName,
                            systemImage: "film"
                        )
                    }
                }
            }
            .remoteControlCard()
        }

        private func optionLabel(
            title: String,
            value: String,
            systemImage: String
        ) -> some View {
            VStack(spacing: 4) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }

        private var selectedAudioTrackName: String {
            player.audioTracks.first {
                $0.selection == player.selectedAudioTrackSelection
            }?.label ?? "トラックなし"
        }

        private var selectedVideoTrackName: String {
            player.videoTracks.first { $0.id == player.selectedVideoTrackID }?.name
                ?? "トラックなし"
        }
    }
#endif
