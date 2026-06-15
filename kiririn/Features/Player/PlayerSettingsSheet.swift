import SwiftUI

enum PlayerPlaybackOptionCatalog {
    static let rateOptions: [Float] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    static func rateLabel(_ rate: Float) -> String {
        if rate == floor(rate) { return "\(Int(rate))x" }
        return "\(String(format: "%.2g", rate))x"
    }

    static func audioTrackLabel(index: Int, track: PlayerAudioTrack) -> String {
        let base = "トラック\(index + 1)"
        guard track.channels > 0 else { return base }
        return "\(base)（\(track.channels)ch）"
    }

    static func videoTrackLabel(index: Int, track: PlayerVideoTrack) -> String {
        "トラック\(index + 1)"
    }
}

@ViewBuilder
func playerPlaybackOptionMenuEntries(playerState: PlayerState, isSeekActionAvailable: Bool)
    -> some View
{
    if isSeekActionAvailable {
        Menu("再生速度") {
            Picker(
                "再生速度",
                selection: Binding(
                    get: { playerState.playbackRate },
                    set: { playerState.setRate($0) }
                )
            ) {
                ForEach(PlayerPlaybackOptionCatalog.rateOptions, id: \.self) { rate in
                    Text(PlayerPlaybackOptionCatalog.rateLabel(rate)).tag(rate)
                }
            }
            .labelsHidden()
        }
    }

    Menu("映像トラック") {
        Picker(
            "映像トラック",
            selection: Binding(
                get: { playerState.selectedVideoTrack },
                set: { if let track = $0 { playerState.selectVideoTrack(track) } }
            )
        ) {
            Text("トラックなし").tag(PlayerVideoTrack?.none).disabled(true).selectionDisabled()
            ForEach(Array(playerState.availableVideoTracks.enumerated()), id: \.element.id) {
                index, track in
                Text(PlayerPlaybackOptionCatalog.videoTrackLabel(index: index, track: track))
                    .tag(PlayerVideoTrack?.some(track))
            }
        }
        .labelsHidden()
    }

    Menu("音声トラック") {
        Picker(
            "音声トラック",
            selection: Binding(
                get: { playerState.selectedAudioTrack },
                set: { if let track = $0 { playerState.selectAudioTrack(track) } }
            )
        ) {
            Text("トラックなし").tag(PlayerAudioTrack?.none).disabled(true).selectionDisabled()
            ForEach(Array(playerState.availableAudioTracks.enumerated()), id: \.element.id) {
                index, track in
                Text(PlayerPlaybackOptionCatalog.audioTrackLabel(index: index, track: track))
                    .tag(PlayerAudioTrack?.some(track))
            }
        }
        .labelsHidden()
    }

    #if DEBUG
        Menu("ステレオモード") {
            Picker(
                "ステレオモード",
                selection: Binding(
                    get: { playerState.selectedAudioStereoMode },
                    set: { playerState.selectAudioStereoMode($0) }
                )
            ) {
                ForEach(PlayerAudioStereoMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
        }
    #endif

    Menu("音声ミックスモード") {
        Picker(
            "音声ミックスモード",
            selection: Binding(
                get: { playerState.selectedAudioMixMode },
                set: { playerState.selectAudioMixMode($0) }
            )
        ) {
            ForEach(PlayerAudioMixMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
    }

    if !playerState.availableOverlayPlugins.isEmpty {
        Button {
            playerState.showingPluginOverlay.toggle()
        } label: {
            Label(
                playerState.showingPluginOverlay ? "プラグイン非表示" : "プラグイン表示",
                systemImage: playerState.showingPluginOverlay
                    ? "puzzlepiece.extension.fill" : "puzzlepiece.extension"
            )
        }
    }
}

struct PlayerSettingsSheet: View {
    @State var playerState: PlayerState
    @Environment(\.dismiss) private var dismiss

    private struct AudioTrackItem: Identifiable {
        let id: Int
        let option: PlayerAudioTrack
    }

    private struct VideoTrackItem: Identifiable {
        let id: Int
        let option: PlayerVideoTrack
    }

    var body: some View {
        NavigationStack {
            List {
                playbackRateSection
                audioTrackSection
                videoTrackSection
                audioModeSection
            }
            .navigationTitle("設定")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }

    private var playbackRateSection: some View {
        Section("再生速度") {
            ForEach(PlayerPlaybackOptionCatalog.rateOptions, id: \.self) { rate in
                Button {
                    playerState.setRate(rate)
                } label: {
                    HStack {
                        Text(PlayerPlaybackOptionCatalog.rateLabel(rate))
                            .foregroundStyle(.primary)
                        Spacer()
                        if playerState.playbackRate == rate {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var audioTrackSection: some View {
        let tracks = audioTrackItems
        if !tracks.isEmpty {
            Section("音声トラック") {
                ForEach(tracks) { track in
                    Button {
                        playerState.selectAudioTrack(track.option)
                    } label: {
                        HStack {
                            Text(
                                PlayerPlaybackOptionCatalog.audioTrackLabel(
                                    index: track.id, track: track.option)
                            )
                            .foregroundStyle(.primary)
                            Spacer()
                            if playerState.selectedAudioTrack == track.option {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
        }
    }

    private var audioTrackItems: [AudioTrackItem] {
        playerState.availableAudioTracks.enumerated().map { index, option in
            AudioTrackItem(id: index, option: option)
        }
    }

    @ViewBuilder
    private var videoTrackSection: some View {
        let tracks = videoTrackItems
        if !tracks.isEmpty {
            Section("映像トラック") {
                ForEach(tracks) { track in
                    Button {
                        playerState.selectVideoTrack(track.option)
                    } label: {
                        HStack {
                            Text(
                                PlayerPlaybackOptionCatalog.videoTrackLabel(
                                    index: track.id, track: track.option)
                            )
                            .foregroundStyle(.primary)
                            Spacer()
                            if playerState.selectedVideoTrack == track.option {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
        }
    }

    private var videoTrackItems: [VideoTrackItem] {
        playerState.availableVideoTracks.enumerated().map { index, option in
            VideoTrackItem(id: index, option: option)
        }
    }

    private var audioModeSection: some View {
        Section("音声モード") {
            ForEach(PlayerAudioStereoMode.allCases) { mode in
                Button {
                    playerState.selectAudioStereoMode(mode)
                } label: {
                    HStack {
                        Text(mode.displayName)
                            .foregroundStyle(.primary)
                        Spacer()
                        if playerState.selectedAudioStereoMode == mode {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
            ForEach(PlayerAudioMixMode.allCases) { mode in
                Button {
                    playerState.selectAudioMixMode(mode)
                } label: {
                    HStack {
                        Text(mode.displayName)
                            .foregroundStyle(.primary)
                        Spacer()
                        if playerState.selectedAudioMixMode == mode {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
        }
    }
}
