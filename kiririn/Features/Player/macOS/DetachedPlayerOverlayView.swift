import AppKit
import Combine
import KppxKit
import SwiftUI
import VLCKit

struct DetachedPlayerOverlayView_macOS: View {
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
                                .opacity(playerState.showingPluginOverlay ? 1 : 0)
                                .allowsHitTesting(false)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }

                if playerState.showsPlaybackLoadingIndicator {
                    playbackLoadingIndicator
                }

                WindowDragSurface(
                    onClick: {},
                    onMouseMoved: {
                        if !isControllerVisible {
                            setControllerVisible(true, animated: true)
                        }
                        scheduleControllerHide()
                    },
                    onMouseExited: {
                        hideControllerTask?.cancel()
                        hideControllerTask = nil
                        setControllerVisible(false, animated: true, manageCursor: false)
                        setCursorHidden(false)
                    },
                    onDoubleClick: {
                        onToggleFullscreen()
                    },
                    isAlwaysOnTop: { isAlwaysOnTop },
                    onToggleAlwaysOnTop: {
                        isAlwaysOnTop.toggle()
                    }
                )

                controllerOverlay(scale: overlayScale)
                    .opacity(isControllerVisible ? 1 : 0)
                    .allowsHitTesting(isControllerVisible)
                    .animation(.easeInOut(duration: 0.22), value: isControllerVisible)

                seekFeedbackOverlay(scale: overlayScale)
                volumeFeedbackOverlay(scale: overlayScale)
                captureFeedbackOverlay(scale: overlayScale)
                playbackErrorOverlay(scale: overlayScale)

                keyboardShortcuts
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .animation(
                .easeInOut(duration: 0.18),
                value: playerState.showsPlaybackLoadingIndicator
            )
            .onTapGesture(count: 2) {
                onToggleFullscreen()
            }
            .onAppear {
                onControlsVisibilityChanged(isControllerVisible)
                scheduleControllerHide()
            }
            .onDisappear {
                hideControllerTask?.cancel()
                hideControllerTask = nil
                onControlsVisibilityChanged(true)
                setCursorHidden(false)
                seekFeedbackHideTask?.cancel()
                seekFeedbackHideTask = nil
                volumeFeedbackHideTask?.cancel()
                volumeFeedbackHideTask = nil
                captureFeedbackHideTask?.cancel()
                captureFeedbackHideTask = nil
            }
            .onReceive(CaptureService.shared.didAddCapture) { (playerID, item) in
                guard playerID == playerState.id else { return }
                if item.type == .image {
                    showCaptureFeedback(text: "キャプチャを撮影しました", systemImage: "camera.fill")
                }
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
                    BroadcastText(playerState.currentPlayable?.title ?? "")
                        .font(.system(size: 14 * scale, weight: .semibold))
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
                        BroadcastText(subtitle)
                            .font(.system(size: 12 * scale, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let nextProgramText {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                            BroadcastText(nextProgramText)
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

            Spacer()

            HStack(spacing: 12 * scale) {
                if playerState.player?.isSeekable ?? false {
                    Button {
                        jump(seconds: -10)
                    } label: {
                        Image(systemName: "gobackward.10")
                            .frame(width: 20 * scale, height: 20 * scale)
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                }

                Button {
                    playerState.togglePlayPause()
                } label: {
                    Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18 * scale, weight: .bold))
                        .frame(width: 24 * scale, height: 24 * scale)
                }
                .keyboardShortcut(.space, modifiers: [])

                if playerState.player?.isSeekable ?? false {
                    Button {
                        jump(seconds: 10)
                    } label: {
                        Image(systemName: "goforward.10")
                            .frame(width: 20 * scale, height: 20 * scale)
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [])
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
                .keyboardShortcut("m", modifiers: [])

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

                Button {
                    playerState.setSubtitleEnabled(!playerState.isSubtitleEnabled)
                } label: {
                    Image(
                        systemName: playerState.isSubtitleEnabled
                            ? "captions.bubble.fill" : "captions.bubble"
                    )
                    .frame(width: 20 * scale, height: 20 * scale)
                }
                .keyboardShortcut("t", modifiers: [])

                Button {
                    playerState.takeCapture()
                } label: {
                    Image(systemName: "camera.fill")
                        .frame(width: 20 * scale, height: 20 * scale)
                }
                .keyboardShortcut("s", modifiers: .command)

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
                .keyboardShortcut("r", modifiers: .command)

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

    private func controlScale(for containerSize: CGSize) -> CGFloat {
        let baseScale = min(containerSize.width / 1920, containerSize.height / 1080)
        let clampedScale = min(max(baseScale, 1.0), 1.7)
        let isFullscreen = playerWindow?.styleMask.contains(.fullScreen) ?? false
        if isFullscreen {
            return clampedScale
        }
        return min(clampedScale, 1.15)
    }

    private var keyboardShortcuts: some View {
        Group {
            Button("") { playerState.togglePlayPause() }
                .buttonStyle(.plain)
                .keyboardShortcut("p", modifiers: [])

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
        let task = DispatchWorkItem {
            setControllerVisible(false, animated: true)
        }
        hideControllerTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: task)
    }

    private func setControllerVisible(
        _ visible: Bool, animated: Bool, manageCursor: Bool = true
    ) {
        let didChange = isControllerVisible != visible
        if animated {
            isControllerVisible = visible
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
            playerState.seek(to: Float(seekValue))
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
            let item = ClosureMenuItem(
                title: PlayerPlaybackOptionCatalog.audioTrackLabel(index: index, track: track)
            ) { [playerState] in
                playerState.selectAudioTrack(track)
            }
            item.state = playerState.selectedAudioTrack == track ? .on : .off
            audioMenu.addItem(item)
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
            ClosureMenuItem(title: "再読み込み", systemImage: "arrow.clockwise") { [playerState] in
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

    init(title: String, systemImage: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        if let systemImage {
            image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
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
            let width = geometry.size.width
            let progress = CGFloat(
                (value - range.lowerBound) / (range.upperBound - range.lowerBound))
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

private struct WindowDragSurface: NSViewRepresentable {
    let onClick: () -> Void
    let onMouseMoved: () -> Void
    let onMouseExited: () -> Void
    let onDoubleClick: () -> Void
    let isAlwaysOnTop: () -> Bool
    let onToggleAlwaysOnTop: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        view.onClick = onClick
        view.onMouseMoved = onMouseMoved
        view.onMouseExited = onMouseExited
        view.onDoubleClick = onDoubleClick
        view.isAlwaysOnTop = isAlwaysOnTop
        view.onToggleAlwaysOnTop = onToggleAlwaysOnTop
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let dragView = nsView as? DragView else { return }
        dragView.onClick = onClick
        dragView.onMouseMoved = onMouseMoved
        dragView.onMouseExited = onMouseExited
        dragView.onDoubleClick = onDoubleClick
        dragView.isAlwaysOnTop = isAlwaysOnTop
        dragView.onToggleAlwaysOnTop = onToggleAlwaysOnTop
    }

    private final class DragView: NSView {
        var onClick: (() -> Void)?
        var onMouseMoved: (() -> Void)?
        var onMouseExited: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        var isAlwaysOnTop: (() -> Bool)?
        var onToggleAlwaysOnTop: (() -> Void)?
        private var globalMouseMonitor: Any?
        private var wasPointerInsideWindow = true

        override func mouseDragged(with event: NSEvent) {
            super.mouseDragged(with: event)
            window?.performDrag(with: event)
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            onMouseMoved?()
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            onMouseExited?()
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 1 {
                onClick?()
            } else if event.clickCount == 2 {
                onDoubleClick?()
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            let isPinned = isAlwaysOnTop?() ?? false
            let menu = NSMenu(title: "")
            let item = NSMenuItem(
                title: "最前面に固定",
                action: #selector(toggleAlwaysOnTop),
                keyEquivalent: ""
            )
            item.state = isPinned ? .on : .off
            item.target = self
            menu.addItem(item)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        @objc private func toggleAlwaysOnTop() {
            onToggleAlwaysOnTop?()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopGlobalMouseMonitor()
            guard window != nil else { return }
            wasPointerInsideWindow = true
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
            ) { [weak self] _ in
                self?.handleGlobalPointerLocationChange()
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for trackingArea in trackingAreas {
                removeTrackingArea(trackingArea)
            }
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [
                        .mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect,
                    ],
                    owner: self
                )
            )
        }

        deinit {
            stopGlobalMouseMonitor()
        }

        private func stopGlobalMouseMonitor() {
            guard let monitor = globalMouseMonitor else { return }
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }

        private func handleGlobalPointerLocationChange() {
            guard let window else { return }
            let isInsideWindow = window.frame.contains(NSEvent.mouseLocation)
            if wasPointerInsideWindow && !isInsideWindow {
                onMouseExited?()
            }
            wasPointerInsideWindow = isInsideWindow
        }
    }
}

#Preview("Detached Player Controls") {
    DetachedPlayerOverlayChromePreview()
        .frame(width: 1280, height: 720)
        .preferredColorScheme(.dark)
}

private struct DetachedPlayerOverlayChromePreview: View {
    @State private var isPlaying = true
    @State private var isMuted = false
    @State private var volume: Double = 80
    @State private var isRecording = false
    @State private var isPipAvailable = true
    @State private var isPipEnabled = false
    @State private var isSubtitleEnabled = true
    @State private var progress: Double = 0.32
    @State private var isSeekable = true
    @State private var isAlwaysOnTop = false

    private let totalTime: Double = 5400
    private var currentTime: Double { totalTime * progress }
    private let scale: CGFloat = 1.0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.0, blue: 0.1),
                    Color(red: 0.18, green: 0.06, blue: 0.28),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 0) {
                titleBar
                Spacer()
                controlsBar
            }
        }
        .buttonStyle(.plain)
    }

    private var titleBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("NHK総合 ニュースウォッチ9")
                    .font(.system(size: 14 * scale, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("NHK")
                        .font(.system(size: 12 * scale, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("2024年1月15日 21:00 - 22:00")
                        .font(.system(size: 12 * scale, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                Text("字幕付き")
                    .font(.system(size: 12 * scale, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                    Text("22:00 ドラマ10「何かしてる」")
                }
                .font(.system(size: 12 * scale, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 8 * scale)
        .padding(.leading, 76 * scale)
        .background(.ultraThinMaterial)
        .allowsHitTesting(false)
    }

    private var controlsBar: some View {
        HStack(spacing: 12 * scale) {
            if isSeekable {
                Button {
                    progress = max(0, progress - 10.0 / totalTime)
                } label: {
                    Image(systemName: "gobackward.10")
                        .frame(width: 20 * scale, height: 20 * scale)
                }
            }

            Button {
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18 * scale, weight: .bold))
                    .frame(width: 24 * scale, height: 24 * scale)
            }

            if isSeekable {
                Button {
                    progress = min(1, progress + 10.0 / totalTime)
                } label: {
                    Image(systemName: "goforward.10")
                        .frame(width: 20 * scale, height: 20 * scale)
                }
            }

            if isSeekable {
                Text(currentTime.playerTimeString)
                    .font(.system(size: 12 * scale, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 56 * scale, alignment: .leading)
                    .lineLimit(1)

                PlayerSlider(
                    value: $progress,
                    range: 0...1,
                    scale: scale
                )
                .frame(height: 24 * scale)
                .disabled(!isSeekable)

                Text(totalTime.playerTimeString)
                    .font(.system(size: 12 * scale, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 56 * scale, alignment: .trailing)
                    .lineLimit(1)
            } else {
                Spacer(minLength: 0)
            }

            Button {
                isMuted.toggle()
            } label: {
                Image(
                    systemName: isMuted
                        ? "speaker.slash.fill" : "speaker.wave.2.fill"
                )
                .frame(width: 20 * scale, height: 20 * scale)
            }

            PlayerSlider(
                value: $volume,
                range: 0...200,
                scale: scale
            )
            .frame(width: 120 * scale, height: 24 * scale)
            .opacity(isMuted ? 0.45 : 1)

            if isPipAvailable {
                Button {
                    isPipEnabled.toggle()
                } label: {
                    Image(systemName: isPipEnabled ? "pip.exit" : "pip.enter")
                        .frame(width: 20 * scale, height: 20 * scale)
                }
            }

            Button {
                isSubtitleEnabled.toggle()
            } label: {
                Image(
                    systemName: isSubtitleEnabled
                        ? "captions.bubble.fill" : "captions.bubble"
                )
                .frame(width: 20 * scale, height: 20 * scale)
            }

            Button {
            } label: {
                Image(systemName: "camera.fill")
                    .frame(width: 20 * scale, height: 20 * scale)
            }

            Button {
                isRecording.toggle()
            } label: {
                Image(
                    systemName: isRecording
                        ? "record.circle.fill" : "record.circle"
                )
                .foregroundStyle(isRecording ? .red : .primary)
                .frame(width: 20 * scale, height: 20 * scale)
            }

            Menu {
                Button("再生速度") {}
                Button("映像トラック") {}
                Button("音声トラック") {}
                Divider()
                Button("プラグインを表示") {}
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20 * scale, height: 20 * scale)
                    .contentShape(.rect)
            }
        }
        .font(.system(size: 15 * scale, weight: .semibold))
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 8 * scale)
        .background(playerControlBackground)
        .padding(8 * scale)
    }

    private var playerControlBackground: some View {
        RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
            .fill(.ultraThinMaterial)
    }
}
