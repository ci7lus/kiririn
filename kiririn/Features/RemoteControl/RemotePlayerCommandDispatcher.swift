import Foundation
import VLCKit

@MainActor
protocol RemotePlayerWindowEndpoint: AnyObject {
    var snapshot: RemoteWindowSnapshot { get }

    func showVolumeFeedback()
    func setFullscreen(_ enabled: Bool) -> RemoteCommandError?
    func setAlwaysOnTop(_ enabled: Bool) -> RemoteCommandError?
    func close() -> RemoteCommandError?
}

@MainActor
final class RemotePlayerCommandDispatcher {
    private final class WindowEndpointReference {
        weak var value: (any RemotePlayerWindowEndpoint)?

        init(_ value: any RemotePlayerWindowEndpoint) {
            self.value = value
        }
    }

    private weak var appModel: AppModel?
    private var windowEndpoints: [String: WindowEndpointReference] = [:]

    func configure(appModel: AppModel) {
        self.appModel = appModel
    }

    func register(
        _ endpoint: any RemotePlayerWindowEndpoint,
        forPlayerID playerID: String
    ) {
        windowEndpoints[playerID] = WindowEndpointReference(endpoint)
    }

    func unregisterWindowEndpoint(forPlayerID playerID: String) {
        windowEndpoints.removeValue(forKey: playerID)
    }

    func snapshots() -> [RemotePlayerSnapshot] {
        guard let appModel else { return [] }
        return appModel.activePlayerStates.compactMap { state in
            guard state.currentPlayable != nil else { return nil }
            return makeSnapshot(for: state)
        }
    }

    func execute(_ request: RemotePlayerCommandRequest) -> RemoteCommandError? {
        guard let state = playerState(id: request.playerID) else {
            return .playerNotFound
        }

        switch request.command {
        case .setPlaying(let enabled):
            guard state.player != nil else { return .unavailable }
            state.setPlaying(enabled)
        case .seekToTime(let time):
            guard time.isFinite, time >= 0 else { return .invalidValue }
            guard state.player?.isSeekable == true else { return .unavailable }
            state.seek(toTime: time)
        case .skipBy(let seconds):
            guard seconds.isFinite else { return .invalidValue }
            guard state.player?.isSeekable == true else { return .unavailable }
            state.skip(by: seconds)
        case .setRate(let rate):
            guard PlayerPlaybackOptionCatalog.rateOptions.contains(rate) else {
                return .invalidValue
            }
            state.setRate(rate)
        case .setVolume(let volume):
            guard volume.isFinite, (0...200).contains(volume) else { return .invalidValue }
            state.setVolume(volume)
            windowEndpoint(for: request.playerID)?.showVolumeFeedback()
        case .setMuted(let enabled):
            state.setMuted(enabled)
            windowEndpoint(for: request.playerID)?.showVolumeFeedback()
        case .selectAudioTrack(let remoteSelection):
            if let remoteSelection {
                guard
                    let track = state.availableAudioTracks.first(where: {
                        $0.id == remoteSelection.trackID
                    }),
                    let selection = playerAudioTrackSelection(
                        remoteSelection,
                        track: track
                    )
                else {
                    return .invalidValue
                }
                state.selectAudioTrack(selection)
            } else {
                state.selectAudioTrack(nil)
            }
        case .selectVideoTrack(let trackID):
            guard let track = state.availableVideoTracks.first(where: { $0.id == trackID }) else {
                return .invalidValue
            }
            state.selectVideoTrack(track)
        case .setSubtitleEnabled(let enabled):
            state.setSubtitleEnabled(enabled)
        case .setPipEnabled(let enabled):
            guard state.isPipAvailable else { return .unavailable }
            state.setPipEnabled(enabled)
        case .takeCapture:
            guard state.player != nil else { return .unavailable }
            state.takeCapture()
        case .setRecording(let enabled):
            guard !enabled || state.isPlaying else { return .unavailable }
            state.setRecording(enabled)
        case .reload:
            state.reloadCurrentPlayable()
        case .pressBMLKey(let keyCode):
            guard state.pressBMLKey(keyCode) else { return .unavailable }
        case .setFullscreen(let enabled):
            guard let endpoint = windowEndpoint(for: request.playerID) else {
                return .unsupported
            }
            return endpoint.setFullscreen(enabled)
        case .setAlwaysOnTop(let enabled):
            guard let endpoint = windowEndpoint(for: request.playerID) else {
                return .unsupported
            }
            return endpoint.setAlwaysOnTop(enabled)
        case .close:
            guard let endpoint = windowEndpoint(for: request.playerID) else {
                return .unsupported
            }
            return endpoint.close()
        }
        return nil
    }

    private func playerState(id: String) -> PlayerState? {
        appModel?.activePlayerStates.first { state in
            state.id == id && state.currentPlayable != nil
        }
    }

    private func windowEndpoint(for playerID: String) -> (any RemotePlayerWindowEndpoint)? {
        guard let reference = windowEndpoints[playerID] else { return nil }
        guard let endpoint = reference.value else {
            windowEndpoints.removeValue(forKey: playerID)
            return nil
        }
        return endpoint
    }

    private func makeSnapshot(for state: PlayerState) -> RemotePlayerSnapshot {
        let windowSnapshot = windowEndpoint(for: state.id)?.snapshot
        let status = state.playbackStatus
        let duration = state.currentPlayable?.length ?? 0

        var capabilities: Set<RemoteControlCapability> = [
            .playback, .rate, .volume, .subtitle, .capture, .recording, .reload,
        ]
        if state.player?.isSeekable == true {
            capabilities.insert(.seek)
        }
        if !state.availableAudioTracks.isEmpty {
            capabilities.insert(.audioTrack)
        }
        if !state.availableVideoTracks.isEmpty {
            capabilities.insert(.videoTrack)
        }
        if state.isPipAvailable {
            capabilities.insert(.pictureInPicture)
        }
        if state.bmlAvailable {
            capabilities.insert(.dataBroadcast)
        }
        if windowSnapshot != nil {
            capabilities.formUnion([.fullscreen, .alwaysOnTop, .close])
        }

        return RemotePlayerSnapshot(
            id: state.id,
            title: state.currentPlayable?.title ?? "プレイヤー",
            serviceName: state.currentPlayable?.serviceName,
            isPlaying: state.isPlaying,
            isSeekable: state.player?.isSeekable ?? false,
            time: status.time,
            duration: duration,
            rate: state.playbackRate,
            volume: state.volume,
            isMuted: state.isMuted,
            isRecording: state.isRecording,
            isSubtitleEnabled: state.isSubtitleEnabled,
            isPipEnabled: state.isPipEnabled,
            isDataBroadcastVisible: state.bmlContentVisible,
            isFullscreen: windowSnapshot?.isFullscreen,
            isAlwaysOnTop: windowSnapshot?.isAlwaysOnTop,
            capabilities: capabilities,
            audioTracks: state.availableAudioTracks.enumerated().flatMap { index, track in
                PlayerAudioTrackSelection.options(for: track).map { selection in
                    RemoteControlAudioTrackOption(
                        selection: remoteAudioTrackSelection(selection),
                        label: PlayerPlaybackOptionCatalog.audioTrackLabel(
                            index: index,
                            selection: selection
                        )
                    )
                }
            },
            selectedAudioTrackSelection: state.selectedAudioTrackSelection.map(
                remoteAudioTrackSelection
            ),
            videoTracks: state.availableVideoTracks.enumerated().map { index, track in
                RemoteControlTrack(
                    id: track.id,
                    name: PlayerPlaybackOptionCatalog.videoTrackLabel(
                        index: index,
                        track: track
                    ),
                    detail: nil
                )
            },
            selectedVideoTrackID: state.selectedVideoTrack?.id,
            bmlKeyGroups: state.bmlContentVisible
                ? Set(
                    state.dataBroadcastSession?.usedKeyGroups.compactMap(
                        BMLKeyGroup.init(rawValue:)
                    ) ?? []
                )
                : []
        )
    }

    private func playerAudioTrackSelection(
        _ selection: RemoteAudioTrackSelection,
        track: PlayerAudioTrack
    ) -> PlayerAudioTrackSelection? {
        switch (track.isDualMono, selection.role) {
        case (false, nil):
            PlayerAudioTrackSelection.current(track: track, stereoMode: .unset)
        case (true, .main):
            PlayerAudioTrackSelection.current(track: track, stereoMode: .left)
        case (true, .sub):
            PlayerAudioTrackSelection.current(track: track, stereoMode: .right)
        case (false, .main), (false, .sub), (true, nil):
            nil
        }
    }

    private func remoteAudioTrackSelection(
        _ selection: PlayerAudioTrackSelection
    ) -> RemoteAudioTrackSelection {
        let role: RemoteAudioTrackSelection.Role? =
            switch selection.dualMonoRole {
            case .main:
                .main
            case .sub:
                .sub
            case nil:
                nil
            }
        return RemoteAudioTrackSelection(
            trackID: selection.track.id,
            role: role
        )
    }
}
