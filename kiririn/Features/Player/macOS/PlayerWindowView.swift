import ARIBStandardKit
import AppKit
import Logging
import SwiftUI

struct PlayerWindowView_macOS: View {
    private let logger = Logger(label: "PlayerWindowView_macOS")
    private static let defaultWindowTitle = "プレイヤー"
    private static let minimumWindowSize = NSSize(width: 640, height: 360)
    private static let contentAspectRatio = NSSize(width: 16, height: 9)
    let initialPlayable: Playable?
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var playerState = PlayerState()
    @State private var playerWindow: NSWindow?
    @State private var isAlwaysOnTop = false
    @State private var isOverlayVisible = true
    @State private var restorationWaitTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if playerState.player != nil {
                DetachedPlayerOverlayView_macOS(
                    playerState: playerState,
                    appModel: appModel,
                    pluginStore: appModel.pluginStore,
                    isAlwaysOnTop: $isAlwaysOnTop,
                    playerWindow: playerWindow,
                    onToggleFullscreen: {
                        playerWindow?.toggleFullScreen(nil)
                    },
                    onControlsVisibilityChanged: { visible in
                        isOverlayVisible = visible
                    }
                )
            } else {
                ProgressView()
            }
        }
        .background(Color.clear)
        .frame(minWidth: 640, minHeight: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .overlay {
            WindowConfigurator_macOS { window in
                configureWindow(window)
            }
            .allowsHitTesting(false)
        }
        .onChange(of: isAlwaysOnTop) { _, newValue in
            applyWindowLevel(window: playerWindow, isAlwaysOnTop: newValue)
        }
        .onChange(of: isOverlayVisible) { _, _ in
            applyTrafficLightVisibility(window: playerWindow)
        }
        .onChange(of: playerState.currentPlayable?.title) { _, _ in
            applyWindowTitle(window: playerWindow)
        }
        .onChange(of: playerState.currentPlayable?.id) { oldID, newID in
            if newID == nil {
                dismiss()
            }
            if oldID != nil, appModel.focusedPlayerID == playerState.id {
                // Focus is already on this player instance, no change to focusedPlayerID needed here
            }
        }
        .onChange(of: appModel.pluginStore.plugins) { _, newPlugins in
            playerState.plugins = newPlugins
        }
        .onAppear {
            appModel.activePlayerStates.append(playerState)
            appModel.focusedPlayerID = playerState.id
            appModel.setupIfNeeded()
            appModel.configureDetachedPlayerState(playerState)
            logWindowContext(trigger: "onAppear", playable: initialPlayable)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            notification in
            guard let window = notification.object as? NSWindow, window === playerWindow else {
                return
            }
            if playerState.currentPlayable?.id != nil {
                appModel.focusedPlayerID = playerState.id
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)
        ) {
            notification in
            guard let window = notification.object as? NSWindow, window === playerWindow else {
                return
            }
            applyTrafficLightVisibility(window: window)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)
        ) {
            notification in
            guard let window = notification.object as? NSWindow, window === playerWindow else {
                return
            }
            applyTrafficLightVisibility(window: window)
        }
        .task(id: initialPlayable?.id) {
            appModel.configureDetachedPlayerState(playerState)
            startPlaybackIfPossible(trigger: "task", playable: initialPlayable)
            scheduleRestorationFallbackIfNeeded()
        }
        .onDisappear {
            appModel.activePlayerStates.removeAll { $0 === playerState }
            if appModel.focusedPlayerID == playerState.id {
                appModel.focusedPlayerID = nil
            }
            restorationWaitTask?.cancel()
            restorationWaitTask = nil
            if playerState.currentPlayable != nil {
                playerState.close()
            }
        }
    }

    private func configureWindow(_ window: NSWindow) {
        if playerWindow !== window {
            playerWindow = window
        }
        applyWindowTitle(window: window)
        applyWindowSizing(window: window)
        applyWindowLevel(window: window, isAlwaysOnTop: isAlwaysOnTop)
        applyTrafficLightVisibility(window: window)
    }

    private func applyWindowSizing(window: NSWindow) {
        if window.minSize != Self.minimumWindowSize {
            window.minSize = Self.minimumWindowSize
        }
        if window.contentMinSize != Self.minimumWindowSize {
            window.contentMinSize = Self.minimumWindowSize
        }
        if window.contentAspectRatio != Self.contentAspectRatio {
            window.contentAspectRatio = Self.contentAspectRatio
        }
    }

    private func applyWindowTitle(window: NSWindow?) {
        guard let window else { return }
        let currentTitle =
            playerState.currentPlayable?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingARIBEnclosedGlyphsForDisplay()
        if let currentTitle, !currentTitle.isEmpty {
            setWindowTitle(currentTitle, window: window)
        } else {
            setWindowTitle(Self.defaultWindowTitle, window: window)
        }
    }

    private func applyWindowLevel(window: NSWindow?, isAlwaysOnTop: Bool) {
        guard let window else { return }
        let level: NSWindow.Level = isAlwaysOnTop ? .floating : .normal
        if window.level != level {
            window.level = level
        }
    }

    private func applyTrafficLightVisibility(window: NSWindow?) {
        guard let window else { return }
        let isVisible = isOverlayVisible || window.styleMask.contains(.fullScreen)
        let buttonTypes: [NSWindow.ButtonType] = [
            .closeButton,
            .miniaturizeButton,
            .zoomButton,
        ]

        for buttonType in buttonTypes {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            let isHidden = !isVisible
            if button.isHidden != isHidden {
                button.isHidden = isHidden
            }
        }
    }

    private func setWindowTitle(_ title: String, window: NSWindow) {
        if window.title != title {
            window.title = title
        }
    }

    private func startPlaybackIfPossible(trigger: String, playable: Playable?) {
        guard let playable else {
            logger.warning("playback not started (\(trigger)): initialPlayable is nil")
            return
        }
        restorationWaitTask?.cancel()
        restorationWaitTask = nil
        if playerState.currentPlayable?.id == playable.id {
            logger.debug("playback already active (\(trigger)): id=\(playable.id)")
            return
        }
        logWindowContext(trigger: trigger, playable: playable)
        playerState.play(playable: playable)
    }

    private func scheduleRestorationFallbackIfNeeded() {
        restorationWaitTask?.cancel()
        restorationWaitTask = nil

        guard initialPlayable == nil else { return }
        restorationWaitTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            guard initialPlayable == nil, playerState.currentPlayable == nil else { return }
            logger.warning(
                "closing player window: initialPlayable is still nil after restore wait")
            dismiss()
        }
    }

    private func logWindowContext(trigger: String, playable: Playable?) {
        let serverID = playable?.serverId ?? "nil"
        let sourceDescription: String
        switch playable?.source {
        case .liveService(let serviceUniqueId):
            sourceDescription = "liveService(\(serviceUniqueId))"
        case .recordedFile(let recordId, let variantId, let serverId):
            sourceDescription =
                "recordedFile(recordId=\(recordId), variantId=\(variantId), serverId=\(serverId))"
        case .fileURL(let url, _):
            sourceDescription = "fileURL(\(url.absoluteString))"
        case .directURL(let url):
            sourceDescription = "directURL(\(url.absoluteString))"
        case nil:
            sourceDescription = "nil"
        }
        let serverState =
            appModel.manager.connectionStates[serverID]?.status.rawValue ?? "unknown"
        logger.info(
            "window context (\(trigger)): playableID=\(playable?.id ?? "nil"), source=\(sourceDescription), serverId=\(serverID), serverState=\(serverState), providerExists=\(appModel.manager.providers[serverID] != nil)"
        )
    }
}
