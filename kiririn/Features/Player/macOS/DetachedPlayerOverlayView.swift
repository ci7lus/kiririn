#if os(macOS)
    import AppKit
    import Combine
    import KppxKit
    import SwiftUI
    import VLCKit

    struct DetachedPlayerOverlayView_macOS: View {
        private static let overlayCoordinateSpaceName = "DetachedPlayerOverlay"

        @State var playerState: PlayerState
        let appModel: AppModel
        let pluginStore: PluginStore
        @Binding var isAlwaysOnTop: Bool
        let playerWindow: NSWindow?
        let onToggleFullscreen: () -> Void
        let onControlsVisibilityChanged: (Bool) -> Void

        @Environment(\.openWindow) private var openWindow
        @State private var isControllerVisible = true
        @State private var hideControllerTask: DispatchWorkItem?
        @State private var isPointerOverTitleController = false
        @State private var isPointerOverBottomController = false
        @State private var titleControllerFrame = CGRect.zero
        @State private var isPlayerFullscreen = false
        @State private var isSeeking = false
        @State private var seekValue: Double = 0
        @State private var isCursorHidden = false
        @State private var seekFeedbackText = ""
        @State private var isSeekFeedbackVisible = false
        @State private var seekFeedbackHideTask: DispatchWorkItem?
        @State private var volumeFeedbackText = ""
        @State private var isVolumeFeedbackVisible = false
        @State private var volumeFeedbackHideTask: DispatchWorkItem?
        @State private var captureFeedbackText = ""
        @State private var captureFeedbackSystemImage = ""
        @State private var isCaptureFeedbackVisible = false
        @State private var captureFeedbackHideTask: DispatchWorkItem?
        @State private var isPlaybackErrorAlertPresented = false
        @State private var playbackErrorAlertMessage = ""
        @State private var bmlKeyMonitor: BMLKeyMonitor?
        @State private var bmlRemotePanel: BMLRemotePanelController?

        private var displayDuration: Double { playerState.currentPlayable?.length ?? 0 }
        private var displayProgress: Double {
            if isSeeking { return seekValue }
            return Double(playerState.playbackStatus.position)
        }
        private var displayTime: Double {
            if isSeeking, displayDuration > 0 { return displayDuration * seekValue }
            return playerState.playbackStatus.time
        }

        var body: some View {
            GeometryReader { geometry in
                let overlayScale = controlScale(for: geometry.size)
                ZStack {
                    Color.black

                    GeometryReader { videoGeo in
                        let videoFrame = bmlVideoFrame(in: videoGeo.size)
                        ZStack {
                            if let player = playerState.player {
                                PlayerLayerView(
                                    player: player,
                                    isPipEnabled: playerState.isPipEnabled,
                                    isPlaying: playerState.isPlaying,
                                    onPipAvailableChanged: { available in
                                        if playerState.isPipAvailable != available {
                                            playerState.isPipAvailable = available
                                        }
                                    },
                                    onPipEnabledChanged: { enabled in
                                        if playerState.isPipEnabled != enabled {
                                            playerState.isPipEnabled = enabled
                                        }
                                    }
                                )
                                .frame(width: videoFrame.width, height: videoFrame.height)
                                .position(x: videoFrame.midX, y: videoFrame.midY)
                            } else {
                                Color.black
                            }

                            if !playerState.availableOverlayPlugins.isEmpty {
                                ForEach(playerState.availableOverlayPlugins) { plugin in
                                    PluginOverlayView(
                                        pluginDefinition: plugin,
                                        appModel: appModel,
                                        reloadToken: playerState.pluginReloadToken
                                            + playerState.perPluginReloadTokens[
                                                plugin.id.uuidString, default: 0],
                                        displayArea: .overlay,
                                        playerID: playerState.id
                                    )
                                    .id(plugin.id)
                                    .frame(width: videoFrame.width, height: videoFrame.height)
                                    .position(x: videoFrame.midX, y: videoFrame.midY)
                                    .opacity(playerState.showingPluginOverlay ? 1 : 0)
                                    .allowsHitTesting(false)
                                }
                            }

                            if let session = playerState.dataBroadcastSession {
                                // Visibility is content-driven (ARIB invisible state):
                                // the content shows itself on DataButton. Mouse input
                                // never reaches this layer anyway - WindowDragSurface
                                // sits above it in the ZStack; BML is keyboard-only.
                                BMLOverlayView_macOS(session: session)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .opacity(playerState.bmlContentVisible ? 1 : 0)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    }

                    if playerState.showsPlaybackLoadingIndicator {
                        playbackLoadingIndicator
                    }

                    bmlReceivingOverlay(scale: overlayScale)

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(WindowDragGesture())
                        .simultaneousGesture(
                            TapGesture(count: 2)
                                .onEnded {
                                    onToggleFullscreen()
                                }
                        )
                        .allowsWindowActivationEvents()
                        .contextMenu {
                            Button {
                                isAlwaysOnTop.toggle()
                            } label: {
                                HStack {
                                    if isAlwaysOnTop {
                                        Image(systemName: "checkmark")
                                    }
                                    Text("最前面に固定")
                                }
                            }
                            .disabled(isPlayerFullscreen)
                            .selectionDisabled(isPlayerFullscreen)
                        }

                    controllerOverlay(scale: overlayScale)
                        .opacity(isControllerVisible ? 1 : 0)
                        .allowsHitTesting(isControllerVisible)

                    if let session = playerState.dataBroadcastSession,
                        let request = session.inputRequest
                    {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                        BMLTextInputView(
                            request: request,
                            onSubmit: { session.submitInput($0, requestId: request.id) },
                            onCancel: { session.cancelInput(requestId: request.id) }
                        )
                        .id(request.id)
                    }

                    seekFeedbackOverlay(scale: overlayScale)
                    volumeFeedbackOverlay(scale: overlayScale)
                    captureFeedbackOverlay(scale: overlayScale)
                    playbackErrorOverlay(scale: overlayScale)

                    keyboardShortcuts
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .coordinateSpace(name: Self.overlayCoordinateSpaceName)
                .onContinuousHover(perform: handleWindowHover)
                .animation(
                    .easeInOut(duration: 0.18),
                    value: playerState.showsPlaybackLoadingIndicator
                )
                .onAppear {
                    isPlayerFullscreen = playerWindow?.styleMask.contains(.fullScreen) ?? false
                    onControlsVisibilityChanged(isControllerVisible)
                    scheduleControllerHide()
                }
                .onDisappear {
                    hideControllerTask?.cancel()
                    hideControllerTask = nil
                    setCursorHidden(false)
                    seekFeedbackHideTask?.cancel()
                    seekFeedbackHideTask = nil
                    volumeFeedbackHideTask?.cancel()
                    volumeFeedbackHideTask = nil
                    captureFeedbackHideTask?.cancel()
                    captureFeedbackHideTask = nil
                    onControlsVisibilityChanged(true)
                }
                .onReceive(CaptureService.shared.didAddCapture) { (playerID, item) in
                    guard playerID == playerState.id else { return }
                    if item.type == .image {
                        showCaptureFeedback(text: "キャプチャを撮影しました", systemImage: "camera.fill")
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSWindow.didEnterFullScreenNotification)
                ) { notification in
                    updateFullscreenState(true, from: notification)
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSWindow.didExitFullScreenNotification)
                ) { notification in
                    updateFullscreenState(false, from: notification)
                }
                .onChange(of: playerState.isRecording) { oldValue, newValue in
                    if newValue {
                        showCaptureFeedback(text: "録画開始", systemImage: "record.circle.fill")
                    } else if oldValue {
                        showCaptureFeedback(text: "録画終了", systemImage: "stop.circle.fill")
                    }
                }
                .onChange(of: playerState.playbackErrorMessage) { _, newValue in
                    guard let raw = newValue else { return }
                    let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !message.isEmpty else { return }
                    playbackErrorAlertMessage = message
                    isPlaybackErrorAlertPresented = true
                }
                .onAppear { syncBMLKeyMonitor() }
                .onChange(of: playerState.dataBroadcastSession?.status) { _, _ in
                    syncBMLKeyMonitor()
                }
                .onChange(of: playerState.dataBroadcastSession?.inputRequest) { _, _ in
                    syncBMLKeyMonitor()
                }
                .onDisappear {
                    bmlKeyMonitor?.stop()
                    bmlKeyMonitor = nil
                    bmlRemotePanel?.close()
                    bmlRemotePanel = nil
                }
                .alert("再生エラー", isPresented: $isPlaybackErrorAlertPresented) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(playbackErrorAlertMessage)
                }
            }
            .buttonStyle(.plain)
        }

        private func controllerOverlay(scale: CGFloat) -> some View {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        BroadcastText(
                            playerState.currentPlayable?.title ?? "",
                            size: 14 * scale,
                            weight: .semibold
                        )
                        .lineLimit(1)
                        HStack {
                            if let serviceName = playerState.currentPlayable?.serviceName {
                                Text(serviceName)
                                    .font(.system(size: 12 * scale, weight: .regular))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let program = playerState.currentPlayable?.displayProgram {
                                if program.duration == 604_065 {
                                    Text(
                                        "\(program.startAt.formatted(.displayDateTimeFull)) - (終了時刻未定)"
                                    )
                                    .font(.system(size: 12 * scale, weight: .regular))
                                    .foregroundStyle(.secondary)
                                } else {
                                    Text(
                                        "\(program.startAt.formatted(.displayDateTimeFull)) - \(program.endAt.formatted(.displayTime))"
                                    )
                                    .font(.system(size: 12 * scale, weight: .regular))
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let subtitle = playerState.currentPlayable?.subtitle,
                            !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            BroadcastText(subtitle, size: 12 * scale)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let nextProgramText {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                BroadcastText(nextProgramText, size: 12 * scale)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 12 * scale, weight: .regular))
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12 * scale)
                .padding(.vertical, 8 * scale)
                .padding(.leading, 76 * scale)
                .background(.ultraThinMaterial)
                .allowsHitTesting(false)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(Self.overlayCoordinateSpaceName))
                } action: { frame in
                    titleControllerFrame = frame
                }

                Spacer()

                HStack(spacing: 12 * scale) {
                    if playerState.player?.isSeekable ?? false {
                        Button {
                            jump(seconds: -10)
                        } label: {
                            Image(systemName: "gobackward.10")
                                .frame(width: 20 * scale, height: 20 * scale)
                        }
                    }

                    Button {
                        playerState.togglePlayPause()
                    } label: {
                        Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18 * scale, weight: .bold))
                            .frame(width: 24 * scale, height: 24 * scale)
                    }

                    if playerState.player?.isSeekable ?? false {
                        Button {
                            jump(seconds: 10)
                        } label: {
                            Image(systemName: "goforward.10")
                                .frame(width: 20 * scale, height: 20 * scale)
                        }
                    }

                    if playerState.player?.isSeekable ?? false {
                        Text(displayTime.playerTimeString)
                            .font(.system(size: 12 * scale, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 56 * scale, alignment: .leading)
                            .lineLimit(1)

                        PlayerSlider(
                            value: Binding(
                                get: { displayProgress },
                                set: { newValue in
                                    seekValue = newValue
                                }
                            ),
                            range: 0...1,
                            scale: scale,
                            onEditingChanged: { editing in
                                if editing {
                                    isSeeking = true
                                } else {
                                    finishSeek()
                                }
                            }
                        )
                        .frame(height: 24 * scale)
                        .disabled(!(playerState.player?.isSeekable ?? false))

                        if displayDuration > 0 {
                            Text(displayDuration.playerTimeString)
                                .font(
                                    .system(size: 12 * scale, weight: .medium, design: .monospaced)
                                )
                                .foregroundStyle(.secondary)
                                .frame(width: 56 * scale, alignment: .trailing)
                                .lineLimit(1)
                        } else {
                            Spacer(minLength: 0)
                        }
                    } else {
                        Spacer(minLength: 0)
                    }

                    Button {
                        playerState.toggleMute()
                        showVolumeFeedback()
                    } label: {
                        Image(
                            systemName: playerState.isMuted
                                ? "speaker.slash.fill" : "speaker.wave.2.fill"
                        )
                        .frame(width: 20 * scale, height: 20 * scale)
                    }

                    PlayerSlider(
                        value: Binding(
                            get: { Double(playerState.volume) },
                            set: {
                                playerState.setVolume(Float($0))
                                showVolumeFeedback()
                            }
                        ),
                        range: 0...200,
                        scale: scale
                    )
                    .frame(width: 120 * scale, height: 24 * scale)
                    .opacity(playerState.isMuted ? 0.45 : 1)

                    if playerState.isPipAvailable {
                        Button {
                            playerState.togglePip()
                        } label: {
                            Image(systemName: playerState.isPipEnabled ? "pip.exit" : "pip.enter")
                                .frame(width: 20 * scale, height: 20 * scale)
                        }
                    }

                    if playerState.dataBroadcastSession != nil {
                        Button {
                            playerState.pressBMLDataButton()
                        } label: {
                            Image(
                                systemName:
                                    "d.circle\(playerState.bmlContentVisible ? ".fill" : "")"
                            )
                            .frame(width: 20 * scale, height: 20 * scale)
                        }
                        .disabled(!playerState.bmlAvailable)
                        .opacity(playerState.bmlAvailable ? 1 : 0.4)
                        .help("データ放送")

                        Button {
                            toggleBMLRemotePanel()
                        } label: {
                            Image(
                                systemName: bmlRemotePanel != nil
                                    ? "appletvremote.gen4.fill" : "appletvremote.gen4"
                            )
                            .frame(width: 20 * scale, height: 20 * scale)
                        }
                        .disabled(!playerState.bmlAvailable)
                        .opacity(playerState.bmlAvailable ? 1 : 0.4)
                        .help("リモコン")
                    }

                    Button {
                        playerState.setSubtitleEnabled(!playerState.isSubtitleEnabled)
                    } label: {
                        Image(
                            systemName: playerState.isSubtitleEnabled
                                ? "captions.bubble.fill" : "captions.bubble"
                        )
                        .frame(width: 20 * scale, height: 20 * scale)
                    }

                    Button {
                        playerState.takeCapture()
                    } label: {
                        Image(systemName: "camera.fill")
                            .frame(width: 20 * scale, height: 20 * scale)
                    }

                    Button {
                        playerState.toggleRecording()
                    } label: {
                        Image(
                            systemName: playerState.isRecording
                                ? "record.circle.fill" : "record.circle"
                        )
                        .foregroundStyle(playerState.isRecording ? .red : .primary)
                        .frame(width: 20 * scale, height: 20 * scale)
                    }

                    DetachedPlayerOptionsMenu(
                        playerState: playerState,
                        pluginStore: pluginStore,
                        scale: scale
                    )
                }
                .font(.system(size: 15 * scale, weight: .semibold))
                .padding(.horizontal, 12 * scale)
                .padding(.vertical, 8 * scale)
                .background(playerControlBackground(scale: scale))
                .onHover(perform: handleBottomControllerHover)
                .padding(8 * scale)
            }
            .contextMenu {
                Button {
                    isAlwaysOnTop.toggle()
                } label: {
                    HStack {
                        if isAlwaysOnTop {
                            Image(systemName: "checkmark")
                        }
                        Text("最前面に固定")
                    }
                }
                .disabled(isPlayerFullscreen)
                .selectionDisabled(isPlayerFullscreen)
            }
            .ignoresSafeArea()
        }

        private func playerControlBackground(scale: CGFloat) -> some View {
            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                .fill(.ultraThinMaterial)
        }

        private var playbackLoadingIndicator: some View {
            ProgressView()
                .tint(.white)
                .controlSize(.regular)
                .allowsHitTesting(false)
                .accessibilityLabel("動画を読み込み中")
                .transition(.opacity)
        }

        /// 実機の画面下に出る「データ取得中...」「通信中...」表示。BMLコンテンツが
        /// 表示中で、かつ待ちのモジュール取得または通信コンテンツのHTTP通信がある
        /// あいだだけ、受信機風に右下へ出す。両方進行中なら通信中を優先。
        @ViewBuilder
        private func bmlReceivingOverlay(scale: CGFloat) -> some View {
            let isNetworking =
                playerState.bmlContentVisible
                && playerState.dataBroadcastSession?.isNetworking == true
            let isReceiving =
                playerState.bmlContentVisible
                && playerState.dataBroadcastSession?.isReceiving == true
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if isNetworking || isReceiving {
                        Text(isNetworking ? "通信中..." : "データ取得中...")
                            .font(.system(size: 21 * scale, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 15 * scale)
                            .padding(.vertical, 8 * scale)
                            .background(
                                RoundedRectangle(cornerRadius: 3 * scale)
                                    .fill(.black.opacity(0.7))
                            )
                            .padding(.trailing, 24 * scale)
                            .padding(.bottom, 24 * scale)
                            .transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.15), value: isNetworking || isReceiving)
            .allowsHitTesting(false)
        }

        /// The rect (in `videoGeo`-local points) the video should occupy. BML's
        /// `videochanged` rect is reported in the same point space as the BML
        /// WKWebView, which is itself sized to fill `videoGeo` 1:1 - so it's
        /// usable here without any extra scaling. Falls back to full-bleed when
        /// there's no active plane rect (overlay hidden, `invisible` state, or
        /// no session).
        private func bmlVideoFrame(in size: CGSize) -> CGRect {
            let fullFrame = CGRect(origin: .zero, size: size)
            guard playerState.bmlContentVisible,
                let session = playerState.dataBroadcastSession,
                let rect = session.videoRect
            else {
                return fullFrame
            }
            return rect
        }

        private func toggleBMLRemotePanel() {
            if let panel = bmlRemotePanel {
                bmlRemotePanel = nil
                panel.close()
            } else {
                let panel = BMLRemotePanelController(playerState: playerState) {
                    bmlRemotePanel = nil
                }
                panel.show(near: playerWindow)
                bmlRemotePanel = panel
            }
        }

        private func syncBMLKeyMonitor() {
            bmlKeyMonitor?.stop()
            bmlKeyMonitor = nil
            // Stays installed across ARIB visibility changes (the monitor checks
            // visibility per-event) so that a keyUp arriving after the content
            // hid itself is still delivered - web-bml wedges its key handling
            // otherwise. Torn down during text input so typing reaches the field.
            // The dボタン itself goes through the native button/shortcut
            // (pressBMLDataButton) and works regardless of this monitor.
            guard let session = playerState.dataBroadcastSession,
                session.status == .active,
                session.inputRequest == nil
            else { return }
            let monitor = BMLKeyMonitor(session: session, targetWindow: { playerWindow })
            monitor.start()
            bmlKeyMonitor = monitor
        }

        private func controlScale(for containerSize: CGSize) -> CGFloat {
            let baseScale = min(containerSize.width / 1920, containerSize.height / 1080)
            let clampedScale = min(max(baseScale, 1.0), 1.7)
            if isPlayerFullscreen {
                return clampedScale
            }
            return min(clampedScale, 1.15)
        }

        private func updateFullscreenState(_ isFullscreen: Bool, from notification: Notification) {
            guard let window = notification.object as? NSWindow, window === playerWindow else {
                return
            }
            isPlayerFullscreen = isFullscreen
        }

        /// 全キーボードショートカットの置き場。コントロールバーのボタンには
        /// 付けない: controllerOverlayは自動非表示で.opacity(0)になり、SwiftUIは
        /// opacity 0のビューのkeyboardShortcutを無効化するため、コントロールが
        /// 隠れている間はキーが未処理になりbeepが鳴ってしまう(この置き場自体が
        /// 0.001なのも同じ理由)。
        private var keyboardShortcuts: some View {
            Group {
                Button("") { playerState.togglePlayPause() }
                    .buttonStyle(.plain)
                    .keyboardShortcut("p", modifiers: [])

                Button("") { playerState.togglePlayPause() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])

                Button("") { jump(seconds: -10) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.leftArrow, modifiers: [])

                Button("") { jump(seconds: 10) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.rightArrow, modifiers: [])

                Button("") {
                    playerState.setVolume(playerState.volume + 5)
                    showVolumeFeedback()
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.upArrow, modifiers: [])

                Button("") {
                    playerState.setVolume(playerState.volume - 5)
                    showVolumeFeedback()
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.downArrow, modifiers: [])

                Button("") {
                    playerState.toggleMute()
                    showVolumeFeedback()
                }
                .buttonStyle(.plain)
                .keyboardShortcut("m", modifiers: [])

                Button("") {
                    playerState.setSubtitleEnabled(!playerState.isSubtitleEnabled)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("t", modifiers: [])

                Button("") { playerState.pressBMLDataButton() }
                    .buttonStyle(.plain)
                    .keyboardShortcut("d", modifiers: [])

                Button("") { playerState.takeCapture() }
                    .buttonStyle(.plain)
                    .keyboardShortcut("s", modifiers: .command)

                Button("") { playerState.toggleRecording() }
                    .buttonStyle(.plain)
                    .keyboardShortcut("r", modifiers: .command)
            }
            .opacity(0.001)
            .allowsHitTesting(false)
        }

        private func jump(seconds: Double) {
            guard let player = playerState.player else { return }
            player.jump(withOffset: Int32(seconds) * 1000)
            showSeekFeedback(for: seconds)
        }

        private func scheduleControllerHide() {
            hideControllerTask?.cancel()
            guard !isPointerOverController else {
                hideControllerTask = nil
                return
            }
            let task = DispatchWorkItem {
                guard !isPointerOverController else { return }
                setControllerVisible(false, animated: true)
            }
            hideControllerTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: task)
        }

        private var isPointerOverController: Bool {
            isPointerOverTitleController || isPointerOverBottomController
        }

        private func handleBottomControllerHover(_ isHovering: Bool) {
            isPointerOverBottomController = isHovering
            if isHovering {
                hideControllerTask?.cancel()
                hideControllerTask = nil
            } else if isControllerVisible {
                scheduleControllerHide()
            }
        }

        private func handleWindowHover(_ phase: HoverPhase) {
            switch phase {
            case .active(let location):
                if !isControllerVisible {
                    setControllerVisible(true, animated: true)
                }
                isPointerOverTitleController = titleControllerFrame.contains(location)
                scheduleControllerHide()
            case .ended:
                hideControllerTask?.cancel()
                hideControllerTask = nil
                isPointerOverTitleController = false
                isPointerOverBottomController = false
                setControllerVisible(false, animated: true, manageCursor: false)
                setCursorHidden(false)
            }
        }

        private func setControllerVisible(
            _ visible: Bool, animated: Bool, manageCursor: Bool = true
        ) {
            let didChange = isControllerVisible != visible
            if animated {
                withAnimation(.easeInOut(duration: 0.22)) {
                    isControllerVisible = visible
                }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isControllerVisible = visible
                }
            }
            if manageCursor {
                setCursorHidden(!visible)
            }
            if didChange {
                onControlsVisibilityChanged(visible)
            }
        }

        private func setCursorHidden(_ hidden: Bool) {
            guard hidden != isCursorHidden else { return }
            if hidden {
                let mouseLocation = NSEvent.mouseLocation
                guard let playerWindow, playerWindow.isVisible,
                    playerWindow.frame.contains(mouseLocation)
                else { return }

                NSCursor.hide()
            } else {
                NSCursor.unhide()
            }
            isCursorHidden = hidden
        }

        private var volumeIconName: String {
            if playerState.isMuted {
                return "speaker.slash.fill"
            } else if playerState.volume == 0 {
                return "speaker.fill"
            } else if playerState.volume < 50 {
                return "speaker.wave.1.fill"
            } else {
                return "speaker.wave.2.fill"
            }
        }

        private var playbackErrorBannerText: String? {
            guard let raw = playerState.playbackErrorMessage else { return nil }
            let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return nil }
            return message
        }

        private var nextProgramText: String? {
            guard let program = playerState.nextProgram else { return nil }
            let name = program.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !isUnknownEndTime(program) else { return nil }
            let start = program.startAt.formatted(.dateTime.hour().minute())
            let end = program.endAt.formatted(.dateTime.hour().minute())
            return "\(start)-\(end) \(name)"
        }

        private func isUnknownEndTime(_ program: Program) -> Bool {
            program.duration <= 0 || program.duration == 604_065 || program.endAt <= program.startAt
        }

        private var feedbackOverlayTransition: AnyTransition {
            .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            )
        }

        @ViewBuilder
        private func feedbackOverlay<Content: View>(
            isVisible: Bool,
            scale: CGFloat,
            @ViewBuilder content: () -> Content
        ) -> some View {
            if isVisible {
                VStack {
                    content()
                        .padding(.top, 34 * scale)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(feedbackOverlayTransition)
                .allowsHitTesting(false)
            }
        }

        @ViewBuilder
        private func feedbackLabel(
            text: String,
            systemImage: String? = nil,
            iconTint: Color = .white.opacity(0.94),
            scale: CGFloat
        ) -> some View {
            let label = HStack(spacing: 8 * scale) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(iconTint)
                }

                Text(text)
                    .lineLimit(1)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16 * scale)
            .padding(.vertical, 8 * scale)
            .frame(minHeight: 34 * scale)
            .shadow(color: .black.opacity(0.28), radius: 4, y: 1)

            if #available(macOS 26, *) {
                label
                    .glassEffect(.regular.tint(.black.opacity(0.18)), in: .capsule)
            } else {
                label
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
            }
        }

        @ViewBuilder
        private func seekFeedbackOverlay(scale: CGFloat) -> some View {
            feedbackOverlay(isVisible: isSeekFeedbackVisible, scale: scale) {
                feedbackLabel(text: seekFeedbackText, scale: scale)
            }
        }

        @ViewBuilder
        private func volumeFeedbackOverlay(scale: CGFloat) -> some View {
            feedbackOverlay(isVisible: isVolumeFeedbackVisible, scale: scale) {
                feedbackLabel(text: volumeFeedbackText, systemImage: volumeIconName, scale: scale)
            }
        }

        @ViewBuilder
        private func captureFeedbackOverlay(scale: CGFloat) -> some View {
            feedbackOverlay(isVisible: isCaptureFeedbackVisible, scale: scale) {
                feedbackLabel(
                    text: captureFeedbackText,
                    systemImage: captureFeedbackSystemImage,
                    iconTint: captureFeedbackText == "録画開始" ? .red : .white.opacity(0.94),
                    scale: scale
                )
            }
        }

        @ViewBuilder
        private func playbackErrorOverlay(scale: CGFloat) -> some View {
            if let message = playbackErrorBannerText {
                ContentUnavailableView {
                    Label("再生エラー", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                }
                .padding(24 * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }

        private func showSeekFeedback(for delta: Double) {
            guard abs(delta) >= 0.5 else { return }
            let sign = delta > 0 ? "+" : "−"
            seekFeedbackText = "\(sign)\(Int(abs(delta).rounded()))秒"
            seekFeedbackHideTask?.cancel()
            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                isSeekFeedbackVisible = true
            }
            let task = DispatchWorkItem {
                withAnimation(.easeIn(duration: 0.22)) {
                    isSeekFeedbackVisible = false
                }
            }
            seekFeedbackHideTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: task)
        }

        private func finishSeek() {
            if isSeeking {
                playerState.seek(toTime: displayTime)
            }
            isSeeking = false
        }

        private func showVolumeFeedback() {
            if playerState.isMuted {
                volumeFeedbackText = "ミュート"
            } else {
                volumeFeedbackText = "音量\(Int(playerState.volume.rounded()))%"
            }
            volumeFeedbackHideTask?.cancel()
            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                isVolumeFeedbackVisible = true
            }
            let task = DispatchWorkItem {
                withAnimation(.easeIn(duration: 0.22)) {
                    isVolumeFeedbackVisible = false
                }
            }
            volumeFeedbackHideTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: task)
        }

        private func showCaptureFeedback(text: String, systemImage: String) {
            captureFeedbackText = text
            captureFeedbackSystemImage = systemImage
            captureFeedbackHideTask?.cancel()
            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                isCaptureFeedbackVisible = true
            }
            let task = DispatchWorkItem {
                withAnimation(.easeIn(duration: 0.22)) {
                    isCaptureFeedbackVisible = false
                }
            }
            captureFeedbackHideTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: task)
        }

    }

    /// 再生オプションメニュー（macOS 分離プレイヤー用）。
    ///
    /// SwiftUI の `Menu` を使うと、再生中の状態更新（VLC から毎秒数回）でホスト側の再評価が走った
    /// 際に、macOS 26 では開いているメニューごと再構築されてサブメニューのマークが点滅し、
    /// クリックも受け付けなくなる。素の `NSMenu` をクリック時に一度だけ構築してポップアップする
    /// ことで、SwiftUI の更新サイクルから完全に切り離す（表示中の内容は開いた時点のスナップショット）。
    private struct DetachedPlayerOptionsMenu: View {
        let playerState: PlayerState
        let pluginStore: PluginStore
        let scale: CGFloat

        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Button {
                presentMenu()
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20 * scale, height: 20 * scale)
                    .contentShape(.rect)
            }
        }

        private func presentMenu() {
            let menu = NSMenu()
            menu.autoenablesItems = false

            if playerState.player?.isSeekable ?? false {
                let rateMenu = NSMenu()
                let currentRate = playerState.playbackRate
                for rate in PlayerPlaybackOptionCatalog.rateOptions {
                    let item = ClosureMenuItem(
                        title: PlayerPlaybackOptionCatalog.rateLabel(rate)
                    ) { [playerState] in
                        playerState.setRate(rate)
                    }
                    item.state = currentRate == rate ? .on : .off
                    rateMenu.addItem(item)
                }
                menu.addItem(submenuItem(title: "再生速度", submenu: rateMenu))
            }

            let videoMenu = NSMenu()
            let noVideoItem = NSMenuItem(title: "トラックなし", action: nil, keyEquivalent: "")
            noVideoItem.isEnabled = false
            noVideoItem.state = playerState.selectedVideoTrack == nil ? .on : .off
            videoMenu.addItem(noVideoItem)
            for (index, track) in playerState.availableVideoTracks.enumerated() {
                let item = ClosureMenuItem(
                    title: PlayerPlaybackOptionCatalog.videoTrackLabel(index: index, track: track)
                ) { [playerState] in
                    playerState.selectVideoTrack(track)
                }
                item.state = playerState.selectedVideoTrack == track ? .on : .off
                videoMenu.addItem(item)
            }
            menu.addItem(submenuItem(title: "映像トラック", submenu: videoMenu))

            let audioMenu = NSMenu()
            let noAudioItem = NSMenuItem(title: "トラックなし", action: nil, keyEquivalent: "")
            noAudioItem.isEnabled = false
            noAudioItem.state = playerState.selectedAudioTrack == nil ? .on : .off
            audioMenu.addItem(noAudioItem)
            for (index, track) in playerState.availableAudioTracks.enumerated() {
                for selection in PlayerAudioTrackSelection.options(for: track) {
                    let item = ClosureMenuItem(
                        title: PlayerPlaybackOptionCatalog.audioTrackLabel(
                            index: index,
                            selection: selection
                        )
                    ) { [playerState] in
                        playerState.selectAudioTrack(selection)
                    }
                    item.state = playerState.selectedAudioTrackSelection == selection ? .on : .off
                    audioMenu.addItem(item)
                }
            }
            menu.addItem(submenuItem(title: "音声トラック", submenu: audioMenu))

            #if DEBUG
                let stereoMenu = NSMenu()
                for mode in PlayerAudioStereoMode.allCases {
                    let item = ClosureMenuItem(title: mode.displayName) { [playerState] in
                        playerState.selectAudioStereoMode(mode)
                    }
                    item.state = playerState.selectedAudioStereoMode == mode ? .on : .off
                    stereoMenu.addItem(item)
                }
                menu.addItem(submenuItem(title: "ステレオモード", submenu: stereoMenu))
            #endif

            let mixMenu = NSMenu()
            for mode in PlayerAudioMixMode.allCases {
                let item = ClosureMenuItem(title: mode.displayName) { [playerState] in
                    playerState.selectAudioMixMode(mode)
                }
                item.state = playerState.selectedAudioMixMode == mode ? .on : .off
                mixMenu.addItem(item)
            }
            menu.addItem(submenuItem(title: "音声ミックスモード", submenu: mixMenu))

            menu.addItem(
                ClosureMenuItem(title: "再読み込み") { [playerState] in
                    playerState.reloadCurrentPlayable()
                }
            )

            if !playerState.availableOverlayPlugins.isEmpty {
                let toggleItem = ClosureMenuItem(title: "プラグインを表示") { [playerState] in
                    playerState.showingPluginOverlay.toggle()
                }
                toggleItem.state = playerState.showingPluginOverlay ? .on : .off
                menu.addItem(toggleItem)
            }

            let enabledPlugins = pluginStore.plugins.filter { $0.isEnabled }
            if !enabledPlugins.isEmpty {
                menu.addItem(.separator())
                menu.addItem(.sectionHeader(title: "プラグインウィンドウ"))
                for plugin in enabledPlugins {
                    let pluginID = plugin.id
                    menu.addItem(
                        ClosureMenuItem(title: plugin.name) { [openWindow] in
                            openWindow(id: AppWindowID.plugin.rawValue, value: pluginID)
                        }
                    )
                }
            }

            guard let event = NSApp.currentEvent,
                let contentView = event.window?.contentView
            else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
        }

        private func submenuItem(title: String, submenu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            return item
        }
    }

    /// クロージャを実行できる NSMenuItem。SwiftUI から NSMenu を組み立てるための補助。
    private final class ClosureMenuItem: NSMenuItem {
        private let handler: () -> Void

        init(title: String, handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(invoke), keyEquivalent: "")
            target = self
        }

        required init(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func invoke() {
            handler()
        }
    }

    private struct PlayerSlider: View {
        @Binding var value: Double
        var range: ClosedRange<Double> = 0...1
        let scale: CGFloat
        var onEditingChanged: (Bool) -> Void = { _ in }

        var body: some View {
            GeometryReader { geometry in
                let width = max(geometry.size.width, 0)
                let rawProgress = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let progress = CGFloat(rawProgress.isFinite ? min(max(rawProgress, 0), 1) : 0)
                let thumbWidth: CGFloat = 4 * scale
                let thumbHeight: CGFloat = 16 * scale
                let trackHeight: CGFloat = 4 * scale

                ZStack(alignment: .leading) {
                    // Track Background
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .frame(height: trackHeight)

                    // Fill Track
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: progress * width, height: trackHeight)

                    // Thumb
                    Capsule()
                        .fill(Color.white)
                        .frame(width: thumbWidth, height: thumbHeight)
                        .offset(x: progress * (width - thumbWidth))
                        .shadow(color: .black.opacity(0.2), radius: 2 * scale)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            guard width > 0 else { return }
                            onEditingChanged(true)
                            let rawProgress = gesture.location.x / width
                            let clampedProgress = min(max(rawProgress, 0), 1)
                            value =
                                range.lowerBound + Double(clampedProgress)
                                * (range.upperBound - range.lowerBound)
                        }
                        .onEnded { _ in
                            onEditingChanged(false)
                        }
                )
            }
        }
    }

    #Preview("Detached Player Controls") {
        DetachedPlayerOverlayPreview()
            .frame(width: 1280, height: 720)
            .preferredColorScheme(.dark)
    }

    private struct DetachedPlayerOverlayPreview: View {
        @State private var playerState = Self.makePlayerState()
        @State private var isAlwaysOnTop = false
        private let appModel = AppModel.shared

        var body: some View {
            DetachedPlayerOverlayView_macOS(
                playerState: playerState,
                appModel: appModel,
                pluginStore: appModel.pluginStore,
                isAlwaysOnTop: $isAlwaysOnTop,
                playerWindow: nil,
                onToggleFullscreen: {},
                onControlsVisibilityChanged: { _ in }
            )
        }

        private static func makePlayerState() -> PlayerState {
            let state = PlayerState()
            state.isPlaying = true
            state.isSubtitleEnabled = true
            state.isPipAvailable = true
            state.volume = 80

            guard let streamURL = URL(string: "https://example.com/preview") else {
                return state
            }

            var playable = Playable(
                streamURL: streamURL,
                source: .liveService(serviceUniqueId: "preview"),
                program: mockProgram(),
                service: mockService()
            )
            playable.isSeekable = true
            playable.length = previewProgramDuration

            state.currentPlayable = playable
            state.nextProgram = mockNextProgram()
            state.playbackStatus = PlayerPlaybackStatus(
                playableID: playable.id,
                isPlaying: true,
                time: previewProgramDuration * 0.8,
                position: 0.8
            )
            state.player = DetachedPlayerOverlayPreviewVLCMediaPlayer(isSeekable: true)
            return state
        }

        private static let previewProgramDuration: TimeInterval = 30 * 60
        private static let previewProgramStartAt = previewDate(
            year: 2010,
            month: 10,
            day: 3,
            hour: 23,
            minute: 30
        )
        private static let previewProgramEndAt = previewProgramStartAt.addingTimeInterval(
            previewProgramDuration
        )

        private static var previewCalendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            if let timeZone = TimeZone(identifier: "Asia/Tokyo") {
                calendar.timeZone = timeZone
            }
            return calendar
        }

        private static func previewDate(
            year: Int,
            month: Int,
            day: Int,
            hour: Int,
            minute: Int
        ) -> Date {
            var components = DateComponents()
            components.calendar = previewCalendar
            components.timeZone = previewCalendar.timeZone
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            guard let date = previewCalendar.date(from: components) else {
                return Date(timeIntervalSince1970: 0)
            }
            return date
        }

        private static func mockProgram() -> Program {
            return Program(
                id: "preview-program",
                serverId: "preview",
                eventId: 1,
                serviceId: 23609,
                networkId: 32391,
                startAt: previewProgramStartAt,
                endAt: previewProgramEndAt,
                duration: previewProgramDuration,
                name: "俺の妹がこんなに可愛いわけがない🈟",
                desc: "#1「俺が妹と恋をするわけがない」",
                extended: nil,
                genres: [],
                updatedAt: nil
            )
        }

        private static func mockNextProgram() -> Program {
            return Program(
                id: "preview-next-program",
                serverId: "preview",
                eventId: 2,
                serviceId: 23609,
                networkId: 32391,
                startAt: previewProgramEndAt,
                endAt: previewProgramEndAt.addingTimeInterval(previewProgramDuration),
                duration: previewProgramDuration,
                name: "閃光のナイトレイド🈟",
                desc: nil,
                extended: nil,
                genres: [],
                updatedAt: nil
            )
        }

        private static func mockService() -> TVService {
            TVService(
                id: "preview-service",
                providerIdentifier: nil,
                serviceId: 23609,
                networkId: 32391,
                transportStreamId: nil,
                name: "ＴＯＫＹＯ　ＭＸ１",
                type: .digitalTelevision,
                remoteControlKeyId: nil,
                hasLogoData: false,
                channel: nil,
                serverId: "preview"
            )
        }
    }

    private final class DetachedPlayerOverlayPreviewVLCMediaPlayer: VLCMediaPlayer {
        private let previewIsSeekable: Bool

        init(isSeekable: Bool) {
            previewIsSeekable = isSeekable
            super.init()
        }

        override var isSeekable: Bool { previewIsSeekable }
    }
#endif
