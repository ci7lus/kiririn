#if os(macOS)
    import AppKit
    import Logging
    import SwiftUI

    struct PlayerWindowView_macOS: View {
        private let logger = Logger(label: "PlayerWindowView_macOS")
        private static let minimumWindowSize = NSSize(width: 640, height: 360)
        private static let contentAspectRatio = NSSize(width: 16, height: 9)
        let initialPlayable: Playable?
        @Environment(AppModel.self) private var appModel
        @Environment(\.dismiss) private var dismiss
        @Environment(\.openWindow) private var openWindow
        @State private var playerState = PlayerState()
        @State private var playerWindowReference = WindowReference_macOS()
        @State private var isAlwaysOnTop = false
        @State private var titlebarController = PlayerTitlebarController_macOS()
        @State private var isControllerVisible = true
        @State private var isPointerOverTitlebar = false
        @State private var volumeFeedbackRequestID: UUID?
        @State private var restorationWaitTask: Task<Void, Never>?
        @State private var remoteEndpoint: PlayerWindowRemoteEndpoint_macOS?

        var body: some View {
            ZStack {
                if playerState.player != nil {
                    DetachedPlayerOverlayView_macOS(
                        playerState: playerState,
                        appModel: appModel,
                        pluginStore: appModel.pluginStore,
                        isAlwaysOnTop: $isAlwaysOnTop,
                        isControllerVisible: $isControllerVisible,
                        isPointerOverTitlebar: isPointerOverTitlebar,
                        playerWindowReference: playerWindowReference,
                        volumeFeedbackRequestID: volumeFeedbackRequestID,
                        onToggleFullscreen: {
                            playerWindow?.toggleFullScreen(nil)
                        }
                    )
                } else {
                    ProgressView()
                }
            }
            .background(Color.clear)
            .frame(minWidth: 640, minHeight: 360)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(titlebarContent.title)
            .navigationSubtitle(titlebarContent.subtitle)
            .toolbar { playerToolbar }
            .windowToolbarFullScreenVisibility(.onHover)
            .overlay {
                WindowConfigurator_macOS { window in
                    configureWindow(window)
                }
                .allowsHitTesting(false)
            }
            .onChange(of: isAlwaysOnTop) { _, newValue in
                updateAlwaysOnTop(newValue)
            }
            .onChange(of: titlebarContent) { _, newValue in
                titlebarController.update(newValue)
            }
            .onChange(of: isControllerVisible) { _, newValue in
                titlebarController.setControlsVisible(newValue)
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
                appModel.registerActivePlayerState(playerState)
                appModel.focusedPlayerID = playerState.id
                appModel.setupIfNeeded()
                appModel.configureDetachedPlayerState(playerState)
                registerRemoteEndpointIfNeeded()
                logWindowContext(trigger: "onAppear", playable: initialPlayable)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification))
            {
                notification in
                guard let window = notification.object as? NSWindow, window === playerWindow else {
                    return
                }
                if playerState.currentPlayable?.id != nil {
                    appModel.focusedPlayerID = playerState.id
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .requestFocusPlayerWindow)
            ) { notification in
                guard notification.object as? String == playerState.id else { return }
                focusWindow()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)
            ) { notification in
                guard let window = notification.object as? NSWindow, window === playerWindow else {
                    return
                }
                prepareWindowForFullscreen(window)
            }
            .task(id: initialPlayable?.id) {
                appModel.configureDetachedPlayerState(playerState)
                startPlaybackIfPossible(trigger: "task", playable: initialPlayable)
                scheduleRestorationFallbackIfNeeded()
            }
            .onDisappear {
                appModel.remoteControlService.unregisterWindowEndpoint(playerID: playerState.id)
                remoteEndpoint = nil
                appModel.unregisterActivePlayerState(playerState)
                if appModel.focusedPlayerID == playerState.id {
                    appModel.focusedPlayerID = nil
                }
                restorationWaitTask?.cancel()
                restorationWaitTask = nil
                titlebarController.detach()
                playerWindowReference.window = nil
                if playerState.currentPlayable != nil {
                    playerState.close()
                }
            }
        }

        @ToolbarContentBuilder
        private var playerToolbar: some ToolbarContent {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appModel.focusedPlayerID = playerState.id
                    openWindow(id: AppWindowID.caption.rawValue)
                } label: {
                    Label("字幕履歴", systemImage: "captions.bubble")
                }
                .labelStyle(.iconOnly)
                .help("字幕履歴を開く")

                Button {
                    appModel.focusedPlayerID = playerState.id
                    openWindow(id: AppWindowID.programInfo.rawValue)
                } label: {
                    Label("番組情報", systemImage: "info.circle")
                }
                .labelStyle(.iconOnly)
                .help("番組情報を開く")
            }
        }

        private var playerWindow: NSWindow? {
            playerWindowReference.window
        }

        private func focusWindow() {
            guard let window = playerWindow else { return }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            appModel.focusedPlayerID = playerState.id
        }

        private func registerRemoteEndpointIfNeeded() {
            guard remoteEndpoint == nil else { return }
            let endpoint = PlayerWindowRemoteEndpoint_macOS(
                windowReference: playerWindowReference,
                isAlwaysOnTop: { isAlwaysOnTop },
                setAlwaysOnTop: { isAlwaysOnTop = $0 },
                showVolumeFeedback: { volumeFeedbackRequestID = UUID() },
                close: { dismiss() }
            )
            remoteEndpoint = endpoint
            appModel.remoteControlService.registerWindowEndpoint(
                endpoint,
                playerID: playerState.id
            )
        }

        private var titlebarContent: PlayerTitlebarContent_macOS {
            let playable = playerState.currentPlayable
            let timeRange: String?
            if let program = playable?.displayProgram {
                let start = program.startAt.formatted(.displayDateTimeFull)
                if program.duration <= 0 || program.duration == 604_065
                    || program.endAt <= program.startAt
                {
                    timeRange = "\(start) - (終了時刻未定)"
                } else {
                    timeRange = "\(start) - \(program.endAt.formatted(.displayTime))"
                }
            } else {
                timeRange = nil
            }
            let detail: String?
            switch playable?.source {
            case .liveService?:
                detail = nextProgramText
            case .recordedFile?, .fileURL?, .directURL?, nil:
                detail = playable?.subtitle
            }
            return PlayerTitlebarContent_macOS(
                title: playable?.title,
                serviceName: playable?.serviceName,
                timeRange: timeRange,
                nextProgram: detail
            )
        }

        private var nextProgramText: String? {
            guard let program = playerState.nextProgram,
                program.duration > 0, program.duration != 604_065,
                program.endAt > program.startAt
            else { return nil }
            let name = program.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let start = program.startAt.formatted(.displayTime)
            let end = program.endAt.formatted(.displayTime)
            return "次の番組 \(start)-\(end) \(name)"
        }

        private func configureWindow(_ window: NSWindow) {
            if playerWindow !== window {
                playerWindowReference.window = window
            }
            titlebarController.update(titlebarContent)
            titlebarController.attach(to: window) { [hover = $isPointerOverTitlebar] isHovered in
                hover.wrappedValue = isHovered
            }
            titlebarController.setControlsVisible(isControllerVisible)
            applyWindowSizing(window: window)
            applyWindowLevel(window: window, isAlwaysOnTop: isAlwaysOnTop)
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

        private func applyWindowLevel(window: NSWindow?, isAlwaysOnTop: Bool) {
            guard let window else { return }
            let level: NSWindow.Level = isAlwaysOnTop ? .floating : .normal
            if window.level != level {
                window.level = level
            }
        }

        private func updateAlwaysOnTop(_ isEnabled: Bool) {
            if isEnabled, playerWindow?.styleMask.contains(.fullScreen) == true {
                isAlwaysOnTop = false
                return
            }
            applyWindowLevel(window: playerWindow, isAlwaysOnTop: isEnabled)
        }

        private func prepareWindowForFullscreen(_ window: NSWindow) {
            if isAlwaysOnTop {
                isAlwaysOnTop = false
            }
            applyWindowLevel(window: window, isAlwaysOnTop: false)
        }

        private func startPlaybackIfPossible(trigger: String, playable: Playable?) {
            guard let playable else {
                logger.warning("playback not started (\(trigger)): initialPlayable is nil")
                return
            }
            restorationWaitTask?.cancel()
            restorationWaitTask = nil
            if playerState.currentPlayable?.id == playable.id {
                appModel.openRequestCoordinator.markOpenRequestStarted(for: playable)
                logger.debug("playback already active (\(trigger)): id=\(playable.id)")
                return
            }
            logWindowContext(trigger: trigger, playable: playable)
            playerState.play(playable: playable)
            appModel.openRequestCoordinator.markOpenRequestStarted(for: playable)
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
#endif
