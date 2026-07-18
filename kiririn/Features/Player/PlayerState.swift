import Foundation
import KppxKit
import Logging
import OrderedCollections
import SwiftUI
import VLCKit
import VLCKitAssets

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

nonisolated enum PlayerMode: Sendable {
    case expanded
    case mini
    case fullscreen
}

nonisolated struct PlayerAudioTrack: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let channels: Int
    let isDualMono: Bool
}

nonisolated struct PlayerVideoTrack: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

// VLCAudioStereoMode libvlc_audio_output_stereomode_t
nonisolated enum PlayerAudioStereoMode: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case unset = 0
    case stereo = 1
    case reverseStereo = 2
    case left = 3
    case right = 4
    case dolbySurround = 5
    case mono = 7

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .unset: return "自動"
        case .stereo: return "ステレオ"
        case .reverseStereo: return "反転ステレオ"
        case .left: return "左チャンネルのみ"
        case .right: return "右チャンネルのみ"
        case .dolbySurround: return "ドルビーサラウンド"
        case .mono: return "モノラル"
        }
    }

    init(vlcMode: VLCMediaPlayer.AudioStereoMode) {
        if let mapped = Self(rawValue: Int(vlcMode.rawValue)) {
            self = mapped
        } else {
            self = .unset
        }
    }

    var vlcMode: VLCMediaPlayer.AudioStereoMode {
        VLCMediaPlayer.AudioStereoMode(rawValue: .init(rawValue)) ?? .unset
    }
}

// VLCAudioMixMode libvlc_audio_output_mixmode_t
nonisolated enum PlayerAudioMixMode: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case unset = 0
    case stereo = 1
    case binaural = 2
    case surround4Point0 = 3
    case surround5Point1 = 4
    case surround7Point1 = 5

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .unset: return "自動"
        case .stereo: return "ステレオ"
        case .binaural: return "仮想サラウンド"
        case .surround4Point0: return "4.0サラウンド"
        case .surround5Point1: return "5.1サラウンド"
        case .surround7Point1: return "7.1サラウンド"
        }
    }

    init(vlcMode: VLCMediaPlayer.AudioMixMode) {
        if let mapped = Self(rawValue: Int(vlcMode.rawValue)) {
            self = mapped
        } else {
            self = .unset
        }
    }

    var vlcMode: VLCMediaPlayer.AudioMixMode {
        VLCMediaPlayer.AudioMixMode(rawValue: .init(rawValue)) ?? .modeUnset
    }
}

nonisolated struct PlayerPlaybackStatus: Sendable, Codable, Equatable {
    var playerID: String?
    var playableID: String?
    var isPlaying: Bool
    var time: Double
    var position: Float
    var bytePosition: Float = 0
    var rate: Float = 1.0
}

nonisolated private enum ArtworkPayload: Sendable {
    case fileURL(String)
    case data(Data, description: String)

    var logDescription: String {
        switch self {
        case .fileURL(let value):
            return value
        case .data(_, let description):
            return description
        }
    }
}

private final class VLCLogForwarder: NSObject, VLCLogging {
    var level: VLCLogLevel = .debug

    private let logger: Logger

    override init() {
        self.logger = Logger(label: "PlayerState.VLC")
        super.init()
    }

    func handleMessage(
        _ message: String,
        logLevel: VLCLogLevel,
        context: VLCLogContext?
    ) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }

        let metadata = metadata(context: context)
        let fullMessage = formattedMessage(message: trimmedMessage, context: context)

        logToSwiftLog(message: fullMessage, level: logLevel, metadata: metadata)
    }

    private func logToSwiftLog(message: String, level: VLCLogLevel, metadata: Logger.Metadata) {
        switch level {
        case .error:
            logger.error("\(message)", metadata: metadata)
        case .warning:
            logger.warning("\(message)", metadata: metadata)
        case .info:
            logger.info("\(message)", metadata: metadata)
        default:
            #if false
                logger.debug("\(message)", metadata: metadata)
            #endif
        }
    }

    private func formattedMessage(message: String, context: VLCLogContext?) -> String {
        guard let context else { return message }

        var components: [String] = []
        if !context.module.isEmpty {
            components.append(context.module)
        }
        if !context.objectType.isEmpty {
            components.append(context.objectType)
        }

        if components.isEmpty {
            return message
        }
        return "[\(components.joined(separator: "/"))] \(message)"
    }

    private func metadata(context: VLCLogContext?) -> Logger.Metadata {
        guard let context else { return [:] }

        var metadata: Logger.Metadata = [
            "vlc.object_id": .stringConvertible(context.objectId),
            "vlc.thread_id": .stringConvertible(context.threadId),
        ]
        if !context.module.isEmpty {
            metadata["vlc.module"] = .string(context.module)
        }
        if !context.objectType.isEmpty {
            metadata["vlc.object_type"] = .string(context.objectType)
        }
        if let header = context.header, !header.isEmpty {
            metadata["vlc.header"] = .string(header)
        }
        if let file = context.file, !file.isEmpty {
            metadata["vlc.file"] = .string(file)
        }
        if context.line >= 0 {
            metadata["vlc.line"] = .stringConvertible(context.line)
        }
        if let function = context.function, !function.isEmpty {
            metadata["vlc.function"] = .string(function)
        }
        return metadata
    }
}

@MainActor
@Observable
final class PlayerState: NSObject, VLCMediaPlayerDelegate, VLCMediaDelegate {
    let id: String = UUID().uuidString
    weak var manager: ServerManager?
    var cacheStore: CacheStore?
    var currentPlayable: Playable?
    var nextProgram: Program?
    var mode: PlayerMode = .expanded
    var player: VLCMediaPlayer?
    var isPlaying = false
    var isPlaybackLoading = false
    var isPlaybackSeeking = false
    var showControls = true
    var playbackRate: Float = 1.0
    var volume: Float = 100
    var isMuted = false
    var isSubtitleEnabled = true
    var isPipEnabled = false
    var isPipAvailable = false
    var availableAudioTracks: [PlayerAudioTrack] = []
    var selectedAudioTrack: PlayerAudioTrack?
    var selectedAudioTrackSelection: PlayerAudioTrackSelection? {
        guard let selectedAudioTrack else { return nil }
        return .current(
            track: selectedAudioTrack,
            stereoMode: selectedAudioStereoMode
        )
    }
    var availableVideoTracks: [PlayerVideoTrack] = []
    var selectedVideoTrack: PlayerVideoTrack?
    var selectedAudioStereoMode: PlayerAudioStereoMode = .unset
    var selectedAudioMixMode: PlayerAudioMixMode = .unset
    var showingPluginOverlay = true
    var plugins: [PluginDefinition] = []
    var dataBroadcastSession: DataBroadcastSession?
    var bmlAvailable: Bool {
        guard let session = dataBroadcastSession else { return false }
        switch session.status {
        case .unsupported, .failed:
            return false
        default:
            return true
        }
    }
    /// Whether the BML content is currently presenting itself. Visibility is
    /// content-driven (ARIB receivers auto-start data broadcasting in an
    /// invisible state; the content shows itself upon receiving the
    /// DataButton key), so this mirrors web-bml's `invisible` state rather
    /// than any native toggle.
    var bmlContentVisible: Bool {
        guard let session = dataBroadcastSession else { return false }
        return session.status == .active && !session.isInvisible
    }
    var isRecording = false
    var caption: String = ""
    var captionHistory: [CaptionHistoryItem] = []
    var playbackStatus: PlayerPlaybackStatus = .init(
        playableID: nil, isPlaying: false, time: 0, position: 0)
    var pluginReloadToken = 0
    var perPluginReloadTokens: [String: Int] = [:]
    var playbackErrorMessage: String?
    var isScrubbing = false {
        didSet {
            if !isScrubbing && showControls {
                startControlsAutoHide()
            }
        }
    }

    func reloadPlugins() {
        pluginReloadToken += 1
    }

    func reloadPlugin(id: String) {
        perPluginReloadTokens[id, default: 0] += 1
    }

    private var refreshTimer: Timer?
    private var controlsTimer: Timer?
    private var selectedAudioTrackID: String?
    private var selectedVideoTrackID: String?
    private var aribSubtitleTrackID: String?
    private var selectedTextTrackID: String?
    private var securityScopedPlaybackURL: URL?
    private var playbackPositionBuffers: (Float, Float) = (-1, -1)
    private var playbackPositionLastRotationTime: Double?
    private var playbackPositionActiveBuffer: Int = 0
    private var didStartPlayback = false
    private var didApplyInitialPlaybackRestore = false
    private var didObservePlayingForRestore = false
    private var didObservePlaybackProgressForRestore = false
    private var restoreAfterPlayingTask: Task<Void, Never>?
    private var programBootstrapRefreshTask: Task<Void, Never>?
    private var recordingStartBroadcastTime: Date?
    private let logger = Logger(label: "PlayerState")
    private let fallbackPlaybackErrorMessage = "メディアの読み込みに失敗しました"

    private static let mediaPlayerOptions: [String] = {
        var options = [
            "--hw-dec",
            "--no-sub-autodetect-file",
            "--no-save-recentplay",
            "--no-keyboard-events",
            "--no-mouse-events",
            "--ts-standard=arib",
            "--no-snapshot-preview",
            "--snapshot-format=jpg",
            "--aribcaption-font=Hiragino Maru Gothic ProN,Rounded M+ 1m WadaLab comp ARIB,Apple Symbols",
            "--verbose=1",
        ]
        #if os(macOS)
            options.append("--vout=samplebufferdisplay")
        #endif
        return options
    }()

    override init() {
        self.player = nil
        super.init()
    }

    var isActive: Bool { currentPlayable != nil }

    var showsPlaybackLoadingIndicator: Bool {
        player == nil || isPlaybackLoading || isPlaybackSeeking
    }

    private var pendingCapturePath: URL?
    private var pendingPluginOverlayTask: Task<CGImage?, Never>?
    private var pendingDataBroadcastSnapshotTask: Task<DataBroadcastCaptureSnapshot?, Never>?
    private var pendingDataBroadcastLayout: DataBroadcastCaptureLayout?
    private var pendingOverlayManifestIDs: [String] = []
    private let vlcLogForwarder = VLCLogForwarder()

    var displayProgram: Program? {
        currentPlayable?.displayProgram
    }

    func play(playable: Playable) {
        let previousPlayableID = currentPlayable?.id
        cleanup(releasePlayer: true)
        clearPlaybackError()
        isPlaybackLoading = true
        var playableForPlayback = playable
        playableForPlayback.normalizeIdentity()
        if let previousPlayableID, previousPlayableID != playableForPlayback.id {
            resetPlaybackRateToDefault()
        }
        switch playableForPlayback.source {
        case .fileURL(let url, let bookmarkData):
            var actualURL = url
            if securityScopedPlaybackURL != url {
                releaseSecurityScopedPlaybackURL()
                var isStale = false
                if let bookmarkData = bookmarkData,
                    let resolvedURL = try? URL(
                        resolvingBookmarkData: bookmarkData, options: .securityScoped,
                        relativeTo: nil, bookmarkDataIsStale: &isStale)
                {
                    actualURL = resolvedURL
                }
                if actualURL.startAccessingSecurityScopedResource() {
                    securityScopedPlaybackURL = actualURL
                }
            }
            playableForPlayback.streamURL = actualURL
        case .liveService, .recordedFile, .directURL:
            releaseSecurityScopedPlaybackURL()
        }
        if case .liveService = playableForPlayback.source {
            // 復元時に保持されている古い番組情報を信用せず、再取得を前提に初期化する
            playableForPlayback.program = nil
            playableForPlayback.overriddenProgram = nil
        }
        currentPlayable = playableForPlayback
        captionHistory = []
        nextProgram = nil
        setupDataBroadcastSessionIfNeeded()
        startPeriodicRefresh()
        startProgramBootstrapRefreshLoop()
        Task { @MainActor [weak self] in
            await self?.refreshProgramInfo()
        }
        playbackStatus.playableID = playableForPlayback.id
        playbackStatus.rate = playbackRate
        playbackPositionBuffers = (-1, -1)
        playbackPositionLastRotationTime = nil
        playbackPositionActiveBuffer = 0
        didApplyInitialPlaybackRestore = false
        didStartPlayback = false
        didObservePlayingForRestore = false
        didObservePlaybackProgressForRestore = false
        restoreAfterPlayingTask?.cancel()
        restoreAfterPlayingTask = nil
        mode = .expanded

        if player == nil {
            player = makePlayer()
        }

        Task { @MainActor in
            // Fetch fresh auth headers before starting playback.
            // Not gated by isCacheReady; token refresh can happen anytime.
            if let serverId = currentPlayable?.serverId,
                let provider = manager?.providers[serverId]
            {
                do {
                    let freshHeaders = try await provider.fetchHeaders()
                    if currentPlayable?.serverId == serverId {
                        currentPlayable?.headers = freshHeaders
                    }
                } catch {
                    logger.warning(
                        "pre-play header refresh failed, proceeding with existing headers: \(error)"
                    )
                }
            }

            guard let activePlayable = currentPlayable,
                let media = VLCMedia(url: activePlayable.streamURL)
            else {
                isPlaying = false
                isPlaybackLoading = false
                return
            }
            logger.debug("play(playable: \(activePlayable.streamURL))")

            for (key, value) in activePlayable.headers {
                media.addHTTPHeader(withName: key, value: value)
            }

            media.addOption(
                ":http-user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) VLC/4.0.0-dev LibVLC/4.0.0-dev kiririn/0.1.0"
            )

            player?.media = media
            player?.media?.delegate = self
            player?.rate = playbackRate
            applyAudioOutput()
            player?.play()
            isPlaying = true
            selectedAudioTrackID = nil
            selectedVideoTrackID = nil
            aribSubtitleTrackID = nil
            selectedTextTrackID = nil

            startControlsAutoHide()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.loadAudioTracks()
                    self.loadVideoTracks()
                    self.refreshSubtitleTrack()
                    self.applySubtitleSelection()
                }
            }

            // Refresh server metadata (record info etc.) asynchronously after playback starts.
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshCurrentPlayableForPlaybackIfReady(
                    expectedPlayableID: activePlayable.id)
                await self.refreshProgramInfo()
            }
        }
    }

    func reloadCurrentPlayable() {
        guard let playable = currentPlayable else { return }
        let currentMode = mode
        play(playable: playable)
        mode = currentMode
    }

    func togglePlayPause() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            playbackStatus.isPlaying = false
        } else {
            Task {
                await refreshCurrentPlayableHeaders()
                if let media = player.media, let headers = currentPlayable?.headers {
                    media.removeAllHTTPHeaders()
                    for (key, value) in headers {
                        media.addHTTPHeader(withName: key, value: value)
                    }
                }

                player.rate = playbackRate
                if player.isSeekable {
                    player.play()
                } else {
                    player.stop()
                    player.play()
                }
                isPlaying = true
                playbackStatus.isPlaying = true
                playbackStatus.rate = playbackRate
            }
        }
    }

    private func refreshCurrentPlayableHeaders() async {
        guard let manager = manager,
            var playable = currentPlayable,
            let serverId = playable.serverId,
            let provider = manager.providers[serverId]
        else {
            logger.warning(
                "Failed to fetch fresh headers: No manager, playable, serverId, or provider")
            return
        }
        do {
            playable.headers = try await provider.fetchHeaders()
            self.currentPlayable = playable
        } catch {
            logger.error("Failed to fetch fresh headers: \(error)")
        }
    }

    private func refreshCurrentPlayableForPlaybackIfReady(expectedPlayableID: String) async {
        guard currentPlayable?.id == expectedPlayableID else { return }
        guard let manager, manager.isCacheReady else {
            logger.debug("skip server refresh before playback: cache not ready")
            return
        }
        await refreshCurrentPlayableForPlayback()
    }

    private func refreshCurrentPlayableForPlayback() async {
        guard let manager = manager,
            var playable = currentPlayable
        else { return }
        guard manager.isCacheReady else { return }

        if case .recordedFile(let recordId, let variantId, let sourceServerId) = playable.source {
            let serverId = playable.serverId ?? sourceServerId
            if let provider = manager.recordingProvider(for: serverId) {
                do {
                    let record = try await provider.fetchRecord(id: recordId)
                    let variant =
                        record.variants.first(where: { $0.id == variantId })
                        ?? record.variants.first
                    if let variant {
                        var refreshed = try provider.buildRecordedPlayable(
                            record: record, variant: variant)
                        // Keep stable identity so window restore / resume key does not change.
                        refreshed.id = playable.id
                        refreshed.overriddenProgram = playable.overriddenProgram
                        refreshed.overriddenService = playable.overriddenService
                        refreshed.initialNetworkTime = playable.initialNetworkTime
                        refreshed.isSeekable = playable.isSeekable
                        refreshed.length = playable.length
                        playable = refreshed
                    }
                } catch {
                    logger.warning("Failed to refresh recorded playable before playback: \(error)")
                }
            } else {
                logger.debug(
                    "Recording provider unavailable for server=\(serverId); skipping recorded metadata refresh"
                )
            }
        }

        if let serverId = playable.serverId,
            let provider = manager.providers[serverId]
        {
            do {
                playable.headers = try await provider.fetchHeaders()
            } catch {
                logger.error("Failed to fetch fresh headers: \(error)")
            }
        }

        currentPlayable = playable
    }

    private func resetPlaybackRateToDefault() {
        playbackRate = 1.0
        playbackStatus.rate = 1.0
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        playbackStatus.rate = rate
        if isPlaying {
            player?.rate = rate
        }
    }

    func seek(to position: Float) {
        guard let player, player.isSeekable else { return }
        player.position = Double(position)
        playbackStatus.position = position
    }

    func seek(toTime time: Double) {
        guard let player, player.isSeekable, time.isFinite else { return }
        let duration = currentPlayable?.length ?? 0
        let clampedTime =
            duration.isFinite && duration > 0
            ? min(max(0, time), duration)
            : max(0, time)
        let milliseconds = min((clampedTime * 1000).rounded(), Double(Int32.max))
        let appliedTime = milliseconds / 1000
        player.time = VLCTime(int: Int32(milliseconds))
        playbackStatus.time = appliedTime
        if duration.isFinite && duration > 0 {
            playbackStatus.position = Float(min(max(0, appliedTime / duration), 1))
        }
    }

    func setVolume(_ value: Float) {
        volume = min(max(0, value), 200)
        applyAudioOutput()
    }

    func toggleMute() {
        isMuted.toggle()
        applyAudioOutput()
    }

    func selectAudioTrack(_ selection: PlayerAudioTrackSelection?) {
        guard let player else { return }

        if let selection {
            let track = selection.track
            if selectedAudioTrackID != track.id {
                guard let index = player.audioTracks.firstIndex(where: { $0.trackId == track.id })
                else { return }
                player.selectTrack(at: index, type: .audio)
            }
            selectedAudioTrack = track
            selectedAudioTrackID = track.id
            if let stereoMode = selection.stereoMode {
                selectAudioStereoMode(stereoMode)
            }
            return
        }

        player.deselectAllAudioTracks()
        selectedAudioTrack = nil
        selectedAudioTrackID = nil
    }

    func selectVideoTrack(_ option: PlayerVideoTrack?) {
        guard let player,
            let option,
            let index = player.videoTracks.firstIndex(where: { $0.trackId == option.id })
        else {
            return
        }

        player.selectTrack(at: index, type: .video)
        selectedVideoTrack = option
        selectedVideoTrackID = option.id
    }

    func selectAudioStereoMode(_ mode: PlayerAudioStereoMode) {
        selectedAudioStereoMode = mode
        applyAudioStereoMode()
    }

    func selectAudioMixMode(_ mode: PlayerAudioMixMode) {
        selectedAudioMixMode = mode
        applyAudioMixMode()
    }

    func setSubtitleEnabled(_ enabled: Bool) {
        isSubtitleEnabled = enabled
        applySubtitleSelection()
    }

    func togglePip() {
        guard isPipAvailable else { return }
        isPipEnabled.toggle()
    }

    private func loadAudioTracks() {
        guard let player else {
            if !availableAudioTracks.isEmpty { availableAudioTracks = [] }
            if selectedAudioTrack != nil { selectedAudioTrack = nil }
            return
        }

        let tracks = player.audioTracks
            .filter { !$0.trackId.isEmpty }
            .map(makeAudioTrack)
        // トラック更新イベントは高頻度で発火するため、変化時のみ書き込む
        // （@Observable は同値でも代入のたびに通知し、メニュー等の UI を作り直してしまう）
        if availableAudioTracks != tracks {
            availableAudioTracks = tracks
        }

        let selected = tracks.first(where: { $0.id == selectedAudioTrackID })
        if selectedAudioTrack != selected {
            selectedAudioTrack = selected
        }
    }

    private func makeAudioTrack(_ track: VLCMediaPlayer.Track) -> PlayerAudioTrack {
        let audio = track.audio
        return PlayerAudioTrack(
            id: track.trackId,
            name: track.trackName,
            channels: audio.map { Int($0.channelsNumber) } ?? 0,
            isDualMono: audio?.isDualMono ?? false
        )
    }

    private func updateAudioTrack(withID trackID: String) {
        guard let player,
            let track = player.audioTracks.first(where: { $0.trackId == trackID }),
            let index = availableAudioTracks.firstIndex(where: { $0.id == trackID })
        else {
            loadAudioTracks()
            return
        }

        let updatedTrack = makeAudioTrack(track)
        if availableAudioTracks[index] != updatedTrack {
            availableAudioTracks[index] = updatedTrack
        }
        if selectedAudioTrackID == trackID, selectedAudioTrack != updatedTrack {
            selectedAudioTrack = updatedTrack
        }
    }

    private func refreshAudioTrackState(updatedTrackID: String? = nil) {
        if let updatedTrackID {
            updateAudioTrack(withID: updatedTrackID)
        } else {
            loadAudioTracks()
        }
        syncAudioModesFromVLC()
        applyAudioOutput()
    }

    private func loadVideoTracks() {
        guard let player else {
            if !availableVideoTracks.isEmpty { availableVideoTracks = [] }
            if selectedVideoTrack != nil { selectedVideoTrack = nil }
            return
        }

        let tracks = player.videoTracks
            .filter { !$0.trackId.isEmpty }
            .map { PlayerVideoTrack(id: $0.trackId, name: $0.trackName) }
        if availableVideoTracks != tracks {
            availableVideoTracks = tracks
        }
        let selected = tracks.first(where: { $0.id == selectedVideoTrackID })
        if selectedVideoTrack != selected {
            selectedVideoTrack = selected
        }
    }

    private func refreshSubtitleTrack() {
        guard let player else {
            aribSubtitleTrackID = nil
            return
        }

        aribSubtitleTrackID =
            player.textTracks.first(where: {
                $0.trackName.localizedCaseInsensitiveContains("ARIB subtitles")
            })?.trackId
    }

    private func applySubtitleSelection() {
        guard let player else { return }

        if isSubtitleEnabled,
            let trackId = aribSubtitleTrackID,
            let track = player.textTracks.first(where: { $0.trackId == trackId }),
            selectedTextTrackID != trackId
        {
            player.selectTextTracks([track])
            return
        }

        if !isSubtitleEnabled, selectedTextTrackID != nil {
            player.deselectAllTextTracks()
            selectedTextTrackID = nil
        }
    }

    private func updateOverriddenProgram(from metadata: [String: String]) {
        guard currentPlayable != nil else { return }
        let presentEventItemsPrefix = "PresentEventItems:"

        let serviceId = Int(metadata["ServiceId"] ?? "")
        let networkId = Int(metadata["ServiceNetworkId"] ?? "")
        let presentEventName = metadata["PresentEventName"]?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let presentEventDesc = metadata["PresentEventDesc"]?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        var presentEventExtended = OrderedDictionary<String, String>()
        let sortedPresentEventExtendedItems =
            metadata
            .filter { $0.key.hasPrefix(presentEventItemsPrefix) }
            .compactMap { item -> (order: String, title: String, value: String)? in
                let rawKey = String(item.key.dropFirst(presentEventItemsPrefix.count))
                guard !rawKey.isEmpty else { return nil }
                let segments = rawKey.split(
                    separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if segments.count == 2,
                    segments[0].allSatisfy(\.isNumber)
                {
                    let title = String(segments[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return nil }
                    return (order: String(segments[0]), title: title, value: item.value)
                }
                return (order: "99", title: rawKey, value: item.value)
            }
            .sorted { $0.order < $1.order || ($0.order == $1.order && $0.title < $1.title) }

        for item in sortedPresentEventExtendedItems {
            presentEventExtended[item.title] = item.value
        }

        let startAt: Date? = {
            guard let raw = metadata["PresentEventStartAt"], let value = Double(raw) else {
                return nil
            }
            return Date(timeIntervalSince1970: value)
        }()

        let duration: TimeInterval? = {
            guard let raw = metadata["PresentEventDuration"], let value = TimeInterval(raw) else {
                return nil
            }
            return max(0, value)
        }()

        let hasMetadataProgram =
            (presentEventName?.isEmpty == false)
            || (presentEventDesc?.isEmpty == false)
            || !presentEventExtended.isEmpty
            || startAt != nil
            || duration != nil

        guard hasMetadataProgram else { return }

        let nextProgramOverride = PlayableProgramOverride(
            eventId: nil,
            serviceId: serviceId,
            networkId: networkId,
            startAt: startAt,
            endAt: {
                guard let startAt, let duration else { return nil }
                return startAt.addingTimeInterval(duration)
            }(),
            duration: duration,
            name: presentEventName,
            desc: presentEventDesc,
            extended: presentEventExtended,
            genres: nil
        )
        currentPlayable?.overriddenProgram = nextProgramOverride
    }

    private func updateOverriddenService(from metadata: [String: String]) {
        guard currentPlayable != nil else { return }

        let candidateKeys = [
            "ServiceName",
            "Service",
            "ChannelName",
            "ServiceTitle",
        ]
        let serviceName =
            candidateKeys
            .compactMap { metadata[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })

        let serviceId = Int(metadata["ServiceId"] ?? "")
        let networkId = Int(metadata["ServiceNetworkId"] ?? metadata["NetworkId"] ?? "")
        guard serviceName != nil || serviceId != nil || networkId != nil else { return }

        currentPlayable?.overriddenService = PlayableServiceOverride(
            serviceId: serviceId,
            networkId: networkId,
            name: serviceName
        )
    }

    private func updateInitialNetworkTime(from metadata: [String: String]) {
        guard currentPlayable != nil else { return }
        if let initialNetworkTimeStr = metadata["InitialNetworkTime"],
            let initialNetworkTime = Double(initialNetworkTimeStr)
        {
            currentPlayable?.initialNetworkTime = Date(timeIntervalSince1970: initialNetworkTime)
        }
    }

    private func updateArtworkLogoIfNeeded(
        artwork: ArtworkPayload?,
        metadata: [String: String],
        media: VLCMedia
    ) {
        guard let artwork else { return }
        guard let expectedPlayableID = currentPlayable?.id else { return }
        guard let targetService = resolvedArtworkLogoTargetService(from: metadata) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }

            let data: Data
            do {
                switch artwork {
                case .fileURL(let artworkURL):
                    data = try await Task.detached(priority: .utility) {
                        try Self.loadArtworkData(from: artworkURL)
                    }.value
                case .data(let artworkData, _):
                    data = artworkData
                }
            } catch {
                self.logger.error(
                    "Failed to load service logo artwork: service=\(targetService.networkId)-\(targetService.serviceId), artwork=\(artwork.logDescription), error=\(error)"
                )
                return
            }

            guard self.currentPlayable?.id == expectedPlayableID,
                let currentMedia = self.player?.media,
                currentMedia === media
            else {
                self.logger.debug("ignored artwork update for stale media")
                return
            }

            guard
                let updatedLogo = await self.cacheStore?.cacheLogo(
                    serviceId: targetService.serviceId,
                    networkId: targetService.networkId,
                    data: data,
                    preferredID: targetService.preferredLogoID
                )
            else {
                return
            }

            self.logger.info(
                "Updated service logo from artwork: service=\(targetService.networkId)-\(targetService.serviceId)"
            )

            guard self.currentPlayable?.id == expectedPlayableID,
                let currentMedia = self.player?.media,
                currentMedia === media
            else {
                self.logger.debug("skipped live logo refresh for stale media after cache update")
                return
            }

            self.manager?.updateLogo(updatedLogo)
        }
    }

    private func resolvedArtworkLogoTargetService(from metadata: [String: String]) -> (
        serviceId: Int,
        networkId: Int,
        preferredLogoID: String?
    )? {
        if let displayService = currentPlayable?.displayService {
            return (
                serviceId: displayService.serviceId,
                networkId: displayService.networkId,
                preferredLogoID: currentPlayable?.service?.id
            )
        }

        guard let serviceId = Int(metadata["ServiceId"] ?? ""),
            let networkId = Int(metadata["ServiceNetworkId"] ?? metadata["NetworkId"] ?? "")
        else {
            return nil
        }

        return (
            serviceId: serviceId,
            networkId: networkId,
            preferredLogoID: currentPlayable?.service?.id
        )
    }

    nonisolated private static func loadArtworkData(from artwork: String) throws -> Data {
        guard let url = URL(string: artwork), url.isFileURL else {
            throw URLError(.badURL)
        }
        return try Data(contentsOf: url)
    }

    @MainActor
    private static func resolvedArtworkPayload(from rawArtwork: Any?) -> ArtworkPayload? {
        guard let rawArtwork else { return nil }

        if let artworkURL = rawArtwork as? URL {
            let absoluteString = artworkURL.absoluteString.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !absoluteString.isEmpty else { return nil }
            return .fileURL(absoluteString)
        }

        if let artworkString = rawArtwork as? String {
            let trimmed = artworkString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .fileURL(trimmed)
        }

        if let artworkData = rawArtwork as? Data, !artworkData.isEmpty {
            return .data(artworkData, description: "Data(\(artworkData.count) bytes)")
        }

        #if canImport(UIKit)
            if let artworkImage = rawArtwork as? UIImage,
                let artworkData = artworkImage.pngData(),
                !artworkData.isEmpty
            {
                return .data(artworkData, description: "UIImage")
            }
        #elseif canImport(AppKit)
            if let artworkImage = rawArtwork as? NSImage,
                let artworkData = pngData(from: artworkImage),
                !artworkData.isEmpty
            {
                return .data(artworkData, description: "NSImage")
            }
        #endif

        return nil
    }

    #if canImport(AppKit)
        nonisolated private static func pngData(from image: NSImage) -> Data? {
            var proposedRect = CGRect(origin: .zero, size: image.size)
            if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
            {
                return NSBitmapImageRep(cgImage: cgImage).representation(
                    using: .png, properties: [:])
            }

            guard let tiffData = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiffData)
            else {
                return nil
            }
            return bitmap.representation(using: .png, properties: [:])
        }
    #endif

    func startPeriodicRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard let playable = currentPlayable,
            case .liveService = playable.source
        else {
            nextProgram = nil
            return
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshProgramInfo()
            }
        }
    }

    func refreshProgramInfo() async {
        guard let manager = manager, let playable = currentPlayable else { return }
        let expectedPlayableID = playable.id
        switch playable.source {
        case .liveService(let serviceUniqueId):
            let resolvedService =
                playable.displayService ?? manager.service(serviceUniqueId: serviceUniqueId)
            guard let resolvedService else {
                guard currentPlayable?.id == expectedPlayableID else { return }
                nextProgram = nil
                return
            }
            let current = await manager.currentProgram(for: resolvedService)
            guard currentPlayable?.id == expectedPlayableID else { return }
            currentPlayable?.program = current
            dataBroadcastSession?.refreshProgramInfo()

            let next = await manager.nextProgram(for: resolvedService, currentProgram: current)
            guard currentPlayable?.id == expectedPlayableID else { return }
            nextProgram = next
        default:
            guard currentPlayable?.id == expectedPlayableID else { return }
            nextProgram = nil
            break
        }
    }

    func collapse() {
        mode = .mini
    }

    func expand() {
        mode = .expanded
    }

    func enterFullscreen() {
        mode = .fullscreen
    }

    func exitFullscreen() {
        mode = .expanded
    }

    func tapControls() {
        setControlsVisible(!showControls)
    }

    func setControlsVisible(_ visible: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls = visible
        }
        if visible {
            startControlsAutoHide()
        } else {
            controlsTimer?.invalidate()
            controlsTimer = nil
        }
    }

    private func startControlsAutoHide() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.isScrubbing {
                    self.startControlsAutoHide()
                    return
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.showControls = false
                }
            }
        }
    }

    func close() {
        savePlaybackPositionIfNeeded()
        cleanup(releasePlayer: true, releaseSecurityScope: true)
        currentPlayable = nil
        nextProgram = nil
        didApplyInitialPlaybackRestore = false
        playbackStatus = .init(
            playerID: nil, playableID: nil, isPlaying: false, time: 0, position: 0,
            rate: playbackRate)
    }

    func stop() {
        player?.stop()
        isPlaybackLoading = false
        isPlaybackSeeking = false
        playbackStatus = .init(
            playerID: self.id, playableID: nil, isPlaying: false, time: 0, position: 0,
            rate: playbackRate)
    }

    func cleanup(releasePlayer: Bool = false, releaseSecurityScope: Bool = false) {
        dataBroadcastSession?.stop()
        dataBroadcastSession = nil
        savePlaybackPositionIfNeeded()
        restoreAfterPlayingTask?.cancel()
        restoreAfterPlayingTask = nil
        didObservePlayingForRestore = false
        didStartPlayback = false
        didObservePlaybackProgressForRestore = false
        playbackPositionBuffers = (-1, -1)
        playbackPositionLastRotationTime = nil
        playbackPositionActiveBuffer = 0
        refreshTimer?.invalidate()
        refreshTimer = nil
        programBootstrapRefreshTask?.cancel()
        programBootstrapRefreshTask = nil
        controlsTimer?.invalidate()
        controlsTimer = nil

        if releasePlayer {
            player?.media?.delegate = nil
        }
        player?.stop()
        if isRecording {
            player?.stopRecording()
            isRecording = false
        }

        isPlaying = false
        isPlaybackLoading = false
        isPlaybackSeeking = false
        isPipEnabled = false
        isPipAvailable = false
        availableAudioTracks = []
        selectedAudioTrack = nil
        selectedAudioTrackID = nil
        availableVideoTracks = []
        selectedVideoTrack = nil
        selectedVideoTrackID = nil
        aribSubtitleTrackID = nil
        selectedTextTrackID = nil

        if releasePlayer {
            player?.delegate = nil
            player?.drawable = nil
            player = nil
        }

        if releaseSecurityScope {
            releaseSecurityScopedPlaybackURL()
        }
    }

    /// データ放送(BML)対応。実験的機能につき既定はオフ - see
    /// kiririn/Features/Settings/DataBroadcastSettingsView.swift for the
    /// toggle backing this key.
    private func setupDataBroadcastSessionIfNeeded() {
        dataBroadcastSession?.stop()
        dataBroadcastSession = nil

        guard UserDefaults.standard.bool(forKey: DataBroadcastSettings.enabledKey) else {
            return
        }
        guard case .liveService = currentPlayable?.source else { return }
        guard let serverId = currentPlayable?.serverId,
            let provider = manager?.providers[serverId] as? (any DataBroadcastProviding),
            let service = currentPlayable?.displayService,
            let endpoint = provider.dataBroadcastEndpoint(for: service)
        else { return }

        let session = DataBroadcastSession(
            endpoint: endpoint,
            postalCode: DataBroadcastSettings.postalCode(),
            programInfoProvider: { [weak self] in
                self?.makeBMLProgramInfoPayload()
            },
            tuneHandler: { [weak self] request in
                self?.handleBMLTuneRequest(request)
            },
            audioStreamHandler: { [weak self] request in
                self?.handleBMLAudioStreamRequest(request)
            }
        )
        session.setAudioOutput(volume: volume, isMuted: isMuted)
        dataBroadcastSession = session
    }

    private func handleBMLTuneRequest(_ request: BMLTuneRequest) {
        let expectedPlayableID = currentPlayable?.id
        Task { @MainActor [weak self] in
            guard let self, let expectedPlayableID,
                self.currentPlayable?.id == expectedPlayableID
            else { return }

            if let currentService = self.currentPlayable?.displayService,
                request.matches(currentService)
            {
                return
            }

            guard let manager = self.manager,
                let service = manager.bmlTuneService(
                    for: request, preferredServerId: self.currentPlayable?.serverId)
            else {
                self.logger.warning("BML tune target is unavailable")
                return
            }

            guard let provider = manager.liveProvider(for: service.serverId) else { return }
            let currentProgram = await manager.currentProgram(for: service)
            guard self.currentPlayable?.id == expectedPlayableID else { return }

            do {
                let playable = try provider.buildLiveStreamPlayable(
                    service: service, currentProgram: currentProgram)
                self.play(playable: playable)
            } catch {
                self.logger.warning("BML tune failed: \(error)")
            }
        }
    }

    /// BMLコンテンツからの音声ES切替 (object.setMainAudioStream)。VLCの音声
    /// トラックをPID(または序数フォールバック)で選び、デュアルモノの主/副は
    /// ステレオモード(左右チャンネル)へマップする。
    private func handleBMLAudioStreamRequest(_ request: BMLAudioStreamRequest) {
        guard let player else { return }
        let tracks = player.audioTracks
        guard
            let index = Self.bmlTrackIndex(
                trackIds: tracks.map { $0.trackId },
                pid: request.pid, ordinal: request.audioIndex)
        else {
            logger.warning(
                "BML setMainAudioStream: no matching audio track (componentId=\(request.componentId) pid=\(String(describing: request.pid)) trackIds=\(tracks.map { $0.trackId }))"
            )
            return
        }
        logger.info(
            "BML setMainAudioStream: selecting audio track \(index) (trackId=\(tracks[index].trackId) channelId=\(String(describing: request.channelId)))"
        )
        player.selectTrack(at: index, type: .audio)
        selectedAudioTrackID = tracks[index].trackId
        selectedAudioTrack = availableAudioTracks.first(where: { $0.id == tracks[index].trackId })

        // TR-B14の音声チャンネルID: 1=主(デュアルモノ左), 2=副(右), 3=主+副
        switch request.channelId {
        case 1:
            selectAudioStereoMode(.left)
        case 2:
            selectAudioStereoMode(.right)
        case 3:
            selectAudioStereoMode(.stereo)
        default:
            // チャンネル指定なし: 以前のBML切替で左右に振っていた場合のみ戻す
            // (ユーザーが選んだその他のモードには触らない)。
            if selectedAudioStereoMode == .left || selectedAudioStereoMode == .right {
                selectAudioStereoMode(.unset)
            }
        }
    }

    /// VLC 4のTrackIdはTS demuxではESのID(=PID)由来の安定ID ("audio/362"の
    /// ような形式)。まずPIDの一致で照合し、TrackIdの形式が想定と違った場合は
    /// PMT内の同種ES序数で照合する。テスト容易性のためnonisolated static。
    nonisolated static func bmlTrackIndex(trackIds: [String], pid: Int?, ordinal: Int?) -> Int? {
        if let pid {
            let pidString = String(pid)
            if let index = trackIds.firstIndex(where: { trackId in
                trackId == pidString
                    || trackId.split(separator: "/").last.map(String.init) == pidString
            }) {
                return index
            }
        }
        if let ordinal, trackIds.indices.contains(ordinal) {
            return ordinal
        }
        return nil
    }

    private func makeBMLProgramInfoPayload() -> BMLProgramInfoPayload? {
        guard let service = currentPlayable?.displayService else { return nil }
        let program = currentPlayable?.displayProgram
        return BMLProgramInfoPayload(
            originalNetworkId: service.networkId,
            transportStreamId: service.transportStreamId,
            serviceId: service.serviceId,
            eventId: program?.eventId,
            eventName: program?.name,
            startTimeUnixMillis: program.map { $0.startAt.timeIntervalSince1970 * 1000 },
            durationSeconds: program?.duration,
            indefiniteDuration: false,
            networkId: service.networkId
        )
    }

    /// Forwards the dボタン to the BML content as an ARIB DataButton key
    /// press. The content itself toggles between invisible/visible in
    /// response (DataButtonPressed event), exactly like a hardware receiver.
    func pressBMLDataButton() {
        guard let session = dataBroadcastSession, session.status == .active else { return }
        session.sendKey(down: true, aribKeyCode: 20)  // AribKeyCode.DataButton
        session.sendKey(down: false, aribKeyCode: 20)
    }

    private func savePlaybackPositionIfNeeded() {
        guard let playable = currentPlayable,
            playable.source.isRestorablePositionSource
        else { return }
        guard didApplyInitialPlaybackRestore else {
            return
        }
        let liveBytePosition = player.map { Float($0.bytePosition) } ?? 0
        let basePosition: Float = {
            // 採用順
            // player.bytePosition > 0 (MPEG-TS のみ)
            // playbackStatus.bytePosition > 0 (MPEG-TS のみ)
            // player.position > 0
            // playbackStatus.position > 0
            if liveBytePosition > 0 { return liveBytePosition }
            if playbackStatus.bytePosition > 0 { return playbackStatus.bytePosition }
            let livePosition = player.map { Float($0.position) } ?? 0
            if livePosition > 0 { return livePosition }
            return playbackStatus.position
        }()
        let position = min(max(basePosition, 0), 1)
        guard position > 0 else { return }

        // timeが0の場合はバッファへの記録ごとスキップ
        let time = playbackStatus.time
        guard time > 0 else { return }

        // 現在posをアクティブバッファに記録する
        if playbackPositionActiveBuffer == 0 {
            playbackPositionBuffers.0 = position
        } else {
            playbackPositionBuffers.1 = position
        }

        // 初回はtimeを記録して終了
        guard let lastRotationTime = playbackPositionLastRotationTime else {
            playbackPositionLastRotationTime = time
            return
        }

        // 前回timeから10秒以上変化していればローテーション
        guard abs(time - lastRotationTime) >= 10 else { return }

        // 古いposを復元位置として記録する
        let staleBuffer = playbackPositionActiveBuffer == 0 ? 1 : 0
        let stalePosition =
            staleBuffer == 0 ? playbackPositionBuffers.0 : playbackPositionBuffers.1
        if stalePosition > 0 {
            Task {
                await cacheStore?.savePlaybackPosition(
                    playableID: playable.id, position: stalePosition)
            }
        }

        // バッファをローテーション
        playbackPositionActiveBuffer = staleBuffer
        playbackPositionLastRotationTime = time
    }

    private func startProgramBootstrapRefreshLoop() {
        programBootstrapRefreshTask?.cancel()
        programBootstrapRefreshTask = nil
        guard let playable = currentPlayable,
            case .liveService = playable.source
        else { return }

        programBootstrapRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(30)
            while !Task.isCancelled {
                await self.refreshProgramInfo()

                if self.currentPlayable?.program != nil {
                    break
                }
                if Date() >= deadline {
                    break
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func requestPlaybackRestoreIfPossible(trigger: String) {
        guard !didApplyInitialPlaybackRestore else { return }
        guard restoreAfterPlayingTask == nil else { return }
        guard didObservePlayingForRestore else { return }
        guard let playable = currentPlayable,
            playable.source.isRestorablePositionSource
        else { return }

        let hasKnownDuration =
            (playable.length ?? 0) > 0
            || (player?.media?.length.intValue ?? 0) > 0
        let hasLoadCompletedSignal = didObservePlaybackProgressForRestore
        guard hasKnownDuration || hasLoadCompletedSignal else {
            logger.debug(
                "restore waiting for duration/progress: id=\(playable.id), trigger=\(trigger), length=\(playable.length ?? 0), progress=\(didObservePlaybackProgressForRestore)"
            )
            return
        }

        let expectedID = playable.id
        restoreAfterPlayingTask = Task { @MainActor in
            defer { restoreAfterPlayingTask = nil }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await restorePlaybackPositionOnce(for: expectedID)
            logger.debug(
                "restore task finished: id=\(expectedID), trigger=\(trigger), didApply=\(didApplyInitialPlaybackRestore)"
            )
        }
    }

    /// `.playing` 状態遷移後に1回だけ呼ばれる再生位置リストア。ポーリングなし。
    private func restorePlaybackPositionOnce(for playableID: String) async {
        guard !didApplyInitialPlaybackRestore else { return }
        guard currentPlayable?.id == playableID else { return }
        didApplyInitialPlaybackRestore = true

        guard let cacheStore else {
            logger.info("playback restore skipped: cacheStore not ready id=\(playableID)")
            return
        }
        guard let position = await cacheStore.loadPlaybackPosition(playableID: playableID) else {
            logger.info("no playback position found: id=\(playableID)")
            return
        }
        guard position > 0, position < 1 else {
            logger.info(
                "playback position skipped by range: id=\(playableID), position=\(position)")
            return
        }
        guard currentPlayable?.id == playableID, let player else { return }
        player.position = Double(position)
        logger.info(
            "restored playback position: id=\(playableID), requested=\(position)"
        )
    }

    func adoptSecurityScopedPlaybackURL(_ url: URL?) {
        guard securityScopedPlaybackURL != url else { return }
        releaseSecurityScopedPlaybackURL()
        securityScopedPlaybackURL = url
    }

    private func releaseSecurityScopedPlaybackURL() {
        guard let securityScopedPlaybackURL else { return }
        securityScopedPlaybackURL.stopAccessingSecurityScopedResource()
        self.securityScopedPlaybackURL = nil
    }

    func takeCapture() {
        guard let player else { return }
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = UUID().uuidString + ".jpg"
        let tempURL = tempDir.appendingPathComponent(fileName)
        pendingCapturePath = tempURL

        let videoSize = player.videoSize
        let snapshotHeight: Int32 = videoSize.height > 0 ? Int32(videoSize.height) : 1080

        let displayAspectRatio = Self.calculateDisplayAspectRatio(
            pixelWidth: videoSize.width,
            pixelHeight: videoSize.height,
            media: player.media
        )
        let snapshotWidth: Int32 = max(1, Int32(Double(snapshotHeight) * displayAspectRatio))

        let dataBroadcastLayout: DataBroadcastCaptureLayout?
        if bmlContentVisible, let session = dataBroadcastSession {
            dataBroadcastLayout = session.captureLayout(outputHeight: CGFloat(snapshotHeight))
            if let dataBroadcastLayout {
                pendingDataBroadcastSnapshotTask = Task { @MainActor in
                    await session.takeCaptureSnapshot(layout: dataBroadcastLayout)
                }
                pendingDataBroadcastLayout = dataBroadcastLayout
            } else {
                pendingDataBroadcastSnapshotTask = nil
                pendingDataBroadcastLayout = nil
            }
        } else {
            dataBroadcastLayout = nil
            pendingDataBroadcastSnapshotTask = nil
            pendingDataBroadcastLayout = nil
        }

        if CaptureService.shared.shouldCompositePluginOverlay && !visibleOverlayPlugins.isEmpty {
            let playerID = self.id
            pendingOverlayManifestIDs = visibleOverlayPlugins.map(\.manifestID)
            let snapshotSize = CGSize(
                width: CGFloat(snapshotWidth), height: CGFloat(snapshotHeight))
            pendingPluginOverlayTask = Task { @MainActor in
                await PluginOverlaySnapshotRegistry.shared.takeCompositeSnapshot(
                    for: playerID,
                    targetSize: snapshotSize,
                    targetAspectRatio: displayAspectRatio,
                    targetFrame: nil
                )
            }
        } else {
            pendingPluginOverlayTask = nil
            pendingOverlayManifestIDs = []
        }

        // 常に通常サイズで動画スナップショットを取得する
        let videoSnapshotWidth = snapshotWidth
        let videoSnapshotHeight = snapshotHeight

        player.saveVideoSnapshot(
            at: tempURL.path, withWidth: videoSnapshotWidth, andHeight: videoSnapshotHeight)
    }

    nonisolated private static func calculateDisplayAspectRatio(
        pixelWidth: CGFloat,
        pixelHeight: CGFloat,
        media: VLCMedia?
    ) -> Double {
        guard pixelWidth > 0, pixelHeight > 0 else {
            return 16.0 / 9.0
        }

        let parRatio = pixelWidth / pixelHeight
        let sarRatio = extractSampleAspectRatio(from: media?.videoTracks ?? [])

        return Double(parRatio) * sarRatio
    }

    nonisolated private static func extractSampleAspectRatio(from videoTracks: [VLCMedia.Track])
        -> Double
    {
        let candidates = videoTracks.compactMap { track -> VLCMedia.VideoTrack? in
            guard track.type == .video else { return nil }
            return track.video
        }
        let selectedVideoTrack = candidates.first(where: { $0.frameRate >= 1 }) ?? candidates.first

        guard let selectedVideoTrack else {
            return 1.0
        }

        let denominator = numericValue(from: selectedVideoTrack.sourceAspectRatioDenominator) ?? 0
        let numerator = numericValue(from: selectedVideoTrack.sourceAspectRatio) ?? 0

        guard denominator > 0, numerator > 0 else {
            return 1.0
        }

        return numerator / denominator
    }

    nonisolated private static func numericValue(from value: Any) -> Double? {
        switch value {
        case let double as Double:
            return double
        case let float as Float:
            return Double(float)
        case let int as Int:
            return Double(int)
        case let int32 as Int32:
            return Double(int32)
        case let int64 as Int64:
            return Double(int64)
        case let uint as UInt:
            return Double(uint)
        case let uint32 as UInt32:
            return Double(uint32)
        case let uint64 as UInt64:
            return Double(uint64)
        default:
            return nil
        }
    }

    func toggleRecording() {
        guard let player, isPlaying else { return }
        if isRecording {
            player.stopRecording()
        } else {
            let playbackTime = Double(max(0, player.time.intValue)) / 1000.0
            recordingStartBroadcastTime =
                (currentPlayable?.isSeekable ?? false)
                ? currentPlayable?.initialNetworkTime?.addingTimeInterval(playbackTime) : Date()
            let tempDir = FileManager.default.temporaryDirectory
            player.startRecording(atPath: tempDir.path)
            isRecording = true
        }
    }

    private func makePlayer() -> VLCMediaPlayer {
        var options = Self.mediaPlayerOptions
        if let hrtfPath = VLCKitAssets.resolveSofaPath() {
            options.append("--hrtf-file=\(hrtfPath)")
            logger.debug("SOFA HRTF file resolved: \(hrtfPath)")
        } else {
            logger.warning(
                "SOFA HRTF file not found; binaural mode will be unavailable")
        }

        let player = VLCMediaPlayer(options: options)
        player.delegate = self
        player.audio?.volume = Int32(volume.rounded())
        player.audio?.isMuted = isMuted
        player.libraryInstance.loggers = [vlcLogForwarder]
        return player
    }

    private func applyAudioOutput() {
        player?.audio?.volume = Int32(volume.rounded())
        player?.audio?.isMuted = isMuted
        dataBroadcastSession?.setAudioOutput(volume: volume, isMuted: isMuted)
    }

    private func applyAudioStereoMode() {
        guard let player else { return }
        let target = selectedAudioStereoMode.vlcMode
        if player.audioStereoMode != target {
            player.audioStereoMode = target
        }
    }

    private func applyAudioMixMode() {
        guard let player else { return }
        let target = selectedAudioMixMode.vlcMode
        if player.audioMixMode != target {
            player.audioMixMode = target
        }
    }

    private func syncAudioModesFromVLC() {
        guard let player else { return }
        let vlcStereoMode = player.audioStereoMode
        let mappedStereo = PlayerAudioStereoMode(vlcMode: vlcStereoMode)
        if selectedAudioStereoMode != mappedStereo {
            selectedAudioStereoMode = mappedStereo
        }
        let vlcMixMode = player.audioMixMode
        let mappedMix = PlayerAudioMixMode(vlcMode: vlcMixMode)
        if selectedAudioMixMode != mappedMix {
            selectedAudioMixMode = mappedMix
        }
    }

    private func clearPlaybackError() {
        if playbackErrorMessage != nil {
            playbackErrorMessage = nil
        }
    }

    // @Observable は同値でも代入のたびに通知するため、変化時のみ書き込むヘルパー。
    private func setPlaybackLoadingIfChanged(_ value: Bool) {
        if isPlaybackLoading != value {
            isPlaybackLoading = value
        }
    }

    private func setPlaybackSeekingIfChanged(_ value: Bool) {
        if isPlaybackSeeking != value {
            isPlaybackSeeking = value
        }
    }

    private func setPlayingIfChanged(_ value: Bool) {
        if isPlaying != value {
            isPlaying = value
        }
    }

    private func resolvePlaybackErrorMessage(preferredMessage: String?) -> String {
        if let raw = preferredMessage {
            let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty {
                return message
            }
        }
        return fallbackPlaybackErrorMessage
    }

    private func syncCurrentPlayableSeekability() {
        guard let player else { return }
        let seekable = player.isSeekable
        if currentPlayable?.isSeekable != seekable {
            currentPlayable?.isSeekable = seekable
        }
    }

    var availableOverlayPlugins: [PluginDefinition] {
        plugins.filter {
            $0.isEnabled && $0.supports(area: .overlay)
        }
    }

    var visibleOverlayPlugins: [PluginDefinition] {
        guard showingPluginOverlay else { return [] }
        return availableOverlayPlugins
    }

    var availablePanelPlugins: [PluginDefinition] {
        plugins.filter {
            $0.isEnabled && $0.supports(area: .panel)
        }
    }
}

extension PlayerState {
    nonisolated func mediaPlayerStateChanged(_ state: VLCMediaPlayerState) {
        // VLCLibrary.currentErrorMessage is thread-local and must be read on the callback thread.
        let errorMessageOnCallbackThread = (state == .error) ? VLCLibrary.currentErrorMessage : nil
        Task { @MainActor in
            // @Observable は同値でも代入のたびに通知するため、値が変わるときだけ書き込む。
            // （.buffering はライブ視聴中に高頻度で発火する）
            switch state {
            case .opening:
                setPlaybackLoadingIfChanged(!didStartPlayback)
            case .playing:
                didStartPlayback = true
                setPlaybackLoadingIfChanged(false)
                setPlayingIfChanged(true)
                clearPlaybackError()
                didObservePlayingForRestore = true
                syncAudioModesFromVLC()
                applyAudioOutput()
                requestPlaybackRestoreIfPossible(trigger: "state.playing")
                // SSE connects only after VLC actually starts pulling the
                // stream, so it joins the tuner session `play()` created
                // instead of racing it into creating a second one.
                dataBroadcastSession?.startIfIdle()
            case .error:
                setPlaybackLoadingIfChanged(false)
                setPlayingIfChanged(false)
                playbackErrorMessage = resolvePlaybackErrorMessage(
                    preferredMessage: errorMessageOnCallbackThread)
            case .paused, .stopped, .stopping:
                setPlaybackLoadingIfChanged(false)
                setPlayingIfChanged(false)
                if state == .paused {
                    savePlaybackPositionIfNeeded()
                }
            default:
                break
            }
            if playbackStatus.isPlaying != isPlaying {
                playbackStatus.isPlaying = isPlaying
            }
            syncCurrentPlayableSeekability()
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
        Task { @MainActor in
            guard let player = player else { return }
            logger.debug(
                "playback time changed: position=\(player.position), bytePosition=\(player.bytePosition), time=\(player.time.intValue), duration=\(currentPlayable?.length ?? -1)"
            )
            let time = max(0, Double(player.time.intValue) / 1000.0)
            let duration = max(0, currentPlayable?.length ?? 0)
            // @Observable は同値でも代入のたびに通知するため、値が変わるときだけ書き込む。
            // （毎ティックの無条件代入は開いているメニュー等の UI を毎秒作り直してしまう）
            if duration == 0 || time <= duration {
                if playbackStatus.time != time {
                    playbackStatus.time = time
                }
            }
            let bytePosition = Float(player.bytePosition)
            if bytePosition.isFinite {
                let clampedBytePosition = min(max(bytePosition, 0), 1)
                if playbackStatus.bytePosition != clampedBytePosition {
                    playbackStatus.bytePosition = clampedBytePosition
                }
            }
            let position = Float(player.position)
            if position < 0 {
                setPlaybackSeekingIfChanged(true)
            } else if position.isFinite {
                setPlaybackSeekingIfChanged(false)
                let clampedPosition = min(max(position, 0), 1)
                if playbackStatus.position != clampedPosition {
                    playbackStatus.position = clampedPosition
                }
            }
            if playbackStatus.time > 0 || playbackStatus.position > 0.001 {
                didStartPlayback = true
                if isPlaybackLoading {
                    isPlaybackLoading = false
                }
                didObservePlaybackProgressForRestore = true
                requestPlaybackRestoreIfPossible(trigger: "time.changed")
            }
            syncCurrentPlayableSeekability()
            savePlaybackPositionIfNeeded()
        }
    }

    nonisolated func mediaPlayerTrackAdded(_ trackId: String, with trackType: VLCMedia.TrackType) {
        Task { @MainActor in
            if trackType == .audio {
                refreshAudioTrackState()
            } else if trackType == .video {
                loadVideoTracks()
            } else if trackType == .text {
                refreshSubtitleTrack()
                applySubtitleSelection()
            }
        }
    }

    nonisolated func mediaPlayerTrackRemoved(_ trackId: String, with trackType: VLCMedia.TrackType)
    {
        Task { @MainActor in
            if trackType == .audio {
                refreshAudioTrackState()
            } else if trackType == .video {
                loadVideoTracks()
            } else if trackType == .text {
                refreshSubtitleTrack()
                applySubtitleSelection()
            }
        }
    }

    nonisolated func mediaPlayerTrackUpdated(_ trackId: String, with trackType: VLCMedia.TrackType)
    {
        Task { @MainActor in
            if trackType == .text {
                refreshSubtitleTrack()
                applySubtitleSelection()
            } else if trackType == .audio {
                refreshAudioTrackState(updatedTrackID: trackId)
            }
        }
    }

    nonisolated func mediaPlayerTrackSelected(
        _ trackType: VLCMedia.TrackType,
        selectedId: String,
        unselectedId: String
    ) {
        Task { @MainActor in
            if trackType == .audio {
                selectedAudioTrackID = selectedId
                refreshAudioTrackState()
            } else if trackType == .text {
                selectedTextTrackID = selectedId.isEmpty ? nil : selectedId
                if selectedId.isEmpty && !unselectedId.isEmpty {
                    selectedTextTrackID = nil
                }
                refreshSubtitleTrack()
                applySubtitleSelection()
            } else if trackType == .video {
                selectedVideoTrackID = selectedId.isEmpty ? nil : selectedId
                loadVideoTracks()
            }
        }
    }

    nonisolated func mediaPlayerLengthChanged(_ length: Int64) {
        logger.debug("media player length changed: length=\(length)")
        Task { @MainActor in
            if length > 0 {
                currentPlayable?.length = Double(length) / 1000.0
                requestPlaybackRestoreIfPossible(trigger: "length.changed")
            } else {
                currentPlayable?.length = 0
            }
            syncCurrentPlayableSeekability()
        }
    }

    nonisolated func mediaMetaDataDidChange(_ aMedia: VLCMedia) {
        let metadata: [String: String] = {
            guard let raw = aMedia.metaData.extra else { return [:] }
            return raw.reduce(into: [:]) { result, element in
                let key = String(describing: element.key)
                let value = String(describing: element.value)
                result[key] = value
            }
        }()
        let sortedMetadata = metadata.keys.sorted().map { "\($0)=\(metadata[$0] ?? "")" }.joined(
            separator: ", ")
        logger.trace("media metadata changed: [\(sortedMetadata)]")

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let currentMedia = self.player?.media, currentMedia === aMedia else {
                self.logger.trace("ignored metadata update for stale media")
                return
            }
            let artwork = Self.resolvedArtworkPayload(from: aMedia.metaData.artwork)
            updateOverriddenProgram(from: metadata)
            updateOverriddenService(from: metadata)
            updateArtworkLogoIfNeeded(artwork: artwork, metadata: metadata, media: aMedia)
            updateInitialNetworkTime(from: metadata)
            if let program = self.currentPlayable?.displayProgram {
                self.logger.trace(
                    "overridden program updated: title=\(program.name), startAt=\(program.startAt.timeIntervalSince1970), duration=\(program.duration)"
                )
            } else {
                self.logger.trace("overridden program was not updated from metadata")
            }
        }
    }

    nonisolated func mediaPlayerStartedRecording(_ player: VLCMediaPlayer) {
        Task { @MainActor in
            isRecording = true
        }
    }

    nonisolated func mediaPlayerSnapshot(_ notification: Notification) {
        Task { @MainActor in
            if let path = pendingCapturePath {
                let playbackTime = Double(max(0, player?.time.intValue ?? 0)) / 1000.0
                let broadcastTime =
                    (currentPlayable?.isSeekable ?? false)
                    ? currentPlayable?.initialNetworkTime?.addingTimeInterval(playbackTime)
                        ?? Date() : Date()

                var overlayImage: CGImage? = nil
                if let overlayTask = pendingPluginOverlayTask {
                    overlayImage = await overlayTask.value
                    pendingPluginOverlayTask = nil
                }
                let overlayManifestIDs = pendingOverlayManifestIDs

                var dataBroadcastOverlayImage: CGImage?
                var dataBroadcastLayout: DataBroadcastCaptureLayout? = nil
                if CaptureService.shared.shouldCompositeDataBroadcast,
                    let snapshotTask = pendingDataBroadcastSnapshotTask,
                    let snapshot = await snapshotTask.value
                {
                    dataBroadcastOverlayImage = snapshot.image
                    dataBroadcastLayout = snapshot.layout
                }
                pendingDataBroadcastSnapshotTask = nil
                pendingDataBroadcastLayout = nil

                try? await CaptureService.shared.saveCapture(
                    tempURL: path,
                    programName: currentPlayable?.title,
                    serviceName: currentPlayable?.serviceName,
                    playerID: id,
                    caption: caption,
                    broadcastTime: broadcastTime,
                    overlayImage: overlayImage,
                    overlayPluginManifestIDs: overlayManifestIDs,
                    dataBroadcastOverlayImage: dataBroadcastOverlayImage,
                    dataBroadcastLayout: dataBroadcastLayout
                )
                pendingCapturePath = nil
                pendingOverlayManifestIDs = []
            }
        }
    }

    @objc(mediaPlayer:recordingStoppedAtURL:)
    nonisolated func mediaPlayer(_ player: VLCMediaPlayer, recordingStoppedAtURL url: URL?) {
        Task { @MainActor in
            isRecording = false
            if let url = url {
                try? await CaptureService.shared.saveRecording(
                    tempURL: url,
                    programName: currentPlayable?.title,
                    serviceName: currentPlayable?.serviceName,
                    caption: caption,
                    broadcastTime: recordingStartBroadcastTime
                )
            }
        }
    }

    @objc(mediaPlayer:didUpdateAribText:)
    nonisolated func mediaPlayer(_ player: VLCMediaPlayer, didUpdateAribText text: String) {
        Task { @MainActor in
            let time = playbackStatus.time
            let position = playbackStatus.position
            let broadcastTime: Date? = {
                if case .liveService = currentPlayable?.source { return Date() }
                return nil
            }()
            try? await Task.sleep(for: .seconds(1))
            if self.caption != text {
                self.caption = text
                if !text.isEmpty {
                    let item = CaptionHistoryItem(
                        text: text, time: time, position: position, broadcastTime: broadcastTime)
                    captionHistory.append(item)
                    if captionHistory.count > 100 {
                        let itemsToRemove = captionHistory.count - 100
                        captionHistory.removeFirst(itemsToRemove)
                    }
                }
            }
        }
    }

    // Alternative variant just in case the selector is different in this VLCKit version
    @objc(mediaPlayer:stoppedRecordingAtURL:)
    nonisolated func mediaPlayer(_ player: VLCMediaPlayer, stoppedRecordingAtURL url: URL?) {
        self.mediaPlayer(player, recordingStoppedAtURL: url)
    }
}
