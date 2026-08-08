import Foundation
import MediaPlayer
import Observation
import VLCKit

@MainActor
final class MediaPlaybackCoordinator {
    private weak var appModel: AppModel?
    private let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var hasConfiguredCommands = false
    private var observationTask: Task<Void, Never>?

    func configure(appModel: AppModel) {
        guard self.appModel == nil else { return }
        self.appModel = appModel
        configureRemoteCommands()
        observePlaybackState()
    }

    private func observePlaybackState() {
        withObservationTracking {
            guard let appModel else { return }
            _ = appModel.focusedPlayerID
            _ = appModel.activePlayerStates
            guard let playerState = selectedPlayerState(in: appModel) else { return }
            _ = playerState.currentPlayable
            _ = playerState.isPlaying
            _ = playerState.playbackStatus
            _ = playerState.playbackRate
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedulePlaybackObservation()
            }
        }

        updateNowPlayingInfo()
    }

    private func schedulePlaybackObservation() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.observePlaybackState()
        }
    }

    private func configureRemoteCommands() {
        guard !hasConfiguredCommands else { return }
        hasConfiguredCommands = true

        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.setPlaying(true) ?? .noSuchContent
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.setPlaying(false) ?? .noSuchContent
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause() ?? .noSuchContent
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            self?.changePlaybackPosition(event) ?? .noSuchContent
        }
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            self?.skip(event, fallbackInterval: 15) ?? .noSuchContent
        }
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            self?.skip(event, fallbackInterval: -15) ?? .noSuchContent
        }
        commandCenter.changePlaybackRateCommand.supportedPlaybackRates =
            PlayerPlaybackOptionCatalog.rateOptions.map(NSNumber.init(value:))
        commandCenter.changePlaybackRateCommand.addTarget { [weak self] event in
            self?.changePlaybackRate(event) ?? .noSuchContent
        }
    }

    private func updateNowPlayingInfo() {
        guard let appModel,
            let playerState = selectedPlayerState(in: appModel),
            let playable = playerState.currentPlayable
        else {
            nowPlayingInfoCenter.nowPlayingInfo = nil
            nowPlayingInfoCenter.playbackState = .stopped
            updateCommandAvailability(for: nil)
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: playable.title,
            MPMediaItemPropertyArtist: playable.serviceName ?? "kiririn",
            MPNowPlayingInfoPropertyExternalContentIdentifier: playable.id,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playerState.playbackStatus.time,
            MPNowPlayingInfoPropertyPlaybackRate: playerState.isPlaying
                ? Double(playerState.playbackRate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(playerState.playbackRate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: isLiveStream(playable),
        ]

        if let duration = playable.length, duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyPlaybackProgress] = min(
                max(Double(playerState.playbackStatus.position), 0),
                1
            )
        }

        nowPlayingInfoCenter.nowPlayingInfo = info
        nowPlayingInfoCenter.playbackState = playerState.isPlaying ? .playing : .paused
        updateCommandAvailability(for: playerState)
    }

    private func updateCommandAvailability(for playerState: PlayerState?) {
        let hasContent = playerState?.currentPlayable != nil && playerState?.player != nil
        let isPlaying = playerState?.isPlaying == true
        let isSeekable = playerState?.player?.isSeekable == true

        commandCenter.playCommand.isEnabled = hasContent && !isPlaying
        commandCenter.pauseCommand.isEnabled = hasContent && isPlaying
        commandCenter.togglePlayPauseCommand.isEnabled = hasContent
        commandCenter.changePlaybackPositionCommand.isEnabled = hasContent && isSeekable
        commandCenter.skipForwardCommand.isEnabled = hasContent && isSeekable
        commandCenter.skipBackwardCommand.isEnabled = hasContent && isSeekable
        commandCenter.changePlaybackRateCommand.isEnabled = hasContent
    }

    private func setPlaying(_ enabled: Bool) -> MPRemoteCommandHandlerStatus {
        guard let playerState = selectedPlayerState(), playerState.player != nil else {
            return .noSuchContent
        }
        playerState.setPlaying(enabled)
        return .success
    }

    private func togglePlayPause() -> MPRemoteCommandHandlerStatus {
        guard let playerState = selectedPlayerState(), playerState.player != nil else {
            return .noSuchContent
        }
        playerState.togglePlayPause()
        return .success
    }

    private func changePlaybackPosition(
        _ event: MPRemoteCommandEvent
    ) -> MPRemoteCommandHandlerStatus {
        guard let event = event as? MPChangePlaybackPositionCommandEvent,
            let playerState = selectedPlayerState(),
            playerState.player?.isSeekable == true
        else {
            return .noSuchContent
        }
        playerState.seek(toTime: event.positionTime)
        return .success
    }

    private func skip(
        _ event: MPRemoteCommandEvent,
        fallbackInterval: TimeInterval
    ) -> MPRemoteCommandHandlerStatus {
        guard let event = event as? MPSkipIntervalCommandEvent,
            let playerState = selectedPlayerState(),
            playerState.player?.isSeekable == true
        else {
            return .noSuchContent
        }
        let interval = event.interval.isFinite ? event.interval : abs(fallbackInterval)
        playerState.skip(by: fallbackInterval < 0 ? -interval : interval)
        return .success
    }

    private func changePlaybackRate(
        _ event: MPRemoteCommandEvent
    ) -> MPRemoteCommandHandlerStatus {
        guard let event = event as? MPChangePlaybackRateCommandEvent,
            let playerState = selectedPlayerState(),
            PlayerPlaybackOptionCatalog.rateOptions.contains(event.playbackRate)
        else {
            return .noSuchContent
        }
        playerState.setRate(event.playbackRate)
        return .success
    }

    private func selectedPlayerState() -> PlayerState? {
        guard let appModel else { return nil }
        return selectedPlayerState(in: appModel)
    }

    private func selectedPlayerState(in appModel: AppModel) -> PlayerState? {
        if let focusedPlayer = appModel.focusedPlayerState,
            focusedPlayer.currentPlayable != nil
        {
            return focusedPlayer
        }
        return appModel.activePlayerStates.first { $0.currentPlayable != nil }
    }

    private func isLiveStream(_ playable: Playable) -> Bool {
        if case .liveService = playable.source {
            return true
        }
        return false
    }
}
