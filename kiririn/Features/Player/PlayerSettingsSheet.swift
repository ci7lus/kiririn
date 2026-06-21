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
