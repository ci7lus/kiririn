import ARIBStandardKit
import Combine
import KppxKit
import OrderedCollections
import SwiftUI
import UIKit
import VLCKit

@MainActor
struct PlayerOverlayView_iOS: View {
    private enum MiniPlayerCorner {
        case topLeading
        case topTrailing
        case bottomLeading
        case bottomTrailing
    }

    private struct TransportControlMetrics {
        let sideButtonSize: CGFloat
        let centerButtonSize: CGFloat
        let sideIconSize: CGFloat
        let centerIconSize: CGFloat
        let spacing: CGFloat
    }

    @State var playerState: PlayerState
    @AppStorage(DataBroadcastSettings.enabledKey) private var isDataBroadcastEnabled = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    let manager: ServerManager
    let pluginStore: PluginStore
    let appModel: AppModel
    let showsLowerContext: Bool
    @State private var dragOffset: CGFloat = 0
    @State private var miniPlayerCenter: CGPoint = .zero
    @State private var miniPlayerDragOffset: CGSize = .zero
    @State private var miniPlayerBaseWidth: CGFloat = 280
    @State private var hasCustomMiniPlayerSize = false
    @State private var miniPlayerPinchStartWidth: CGFloat?
    @State private var miniPlayerPinchStartCenter: CGPoint?
    @State private var miniPlayerPinchStartHeight: CGFloat?
    @State private var miniPlayerCorner: MiniPlayerCorner = .bottomTrailing
    @State private var hasInitializedMiniPlayerPosition = false
    @State private var miniEntrySourceMode: PlayerMode = .expanded
    @State private var miniOverlayVisible = true
    @State private var miniOverlayHideTask: DispatchWorkItem?
    @State private var isInfoSheetVisible = true
    @State private var lowerTabSelection = "caption"
    @State private var selectedPluginID: UUID?
    @State private var scrubPosition: Float?
    @State private var initialScrubTime: Double?
    @State private var initialScrubPosition: Float?
    @State private var seekFeedbackText = ""
    @State private var isSeekFeedbackVisible = false
    @State private var seekFeedbackHideTask: DispatchWorkItem?
    @State private var volumeFeedbackText = ""
    @State private var isVolumeFeedbackVisible = false
    @State private var volumeFeedbackHideTask: DispatchWorkItem?
    @State private var tapWindowInitialControlsState: Bool?
    @State private var tapWindowCount = 0
    @State private var tapWindowResetTask: DispatchWorkItem?
    @State private var captureFeedbackText = ""
    @State private var captureFeedbackSystemImage = ""
    @State private var isCaptureFeedbackVisible = false
    @State private var captureFeedbackHideTask: DispatchWorkItem?
    @State private var isLandscapeOrientationLocked = false
    @State private var orientationButtonRotation: Double = 0
    @State private var orientationToggleTask: Task<Void, Never>?
    @State private var collapsedBarReservedBottomHeight: CGFloat = 96
    @State private var isLandscapeBMLRemoteVisible = false
    @State private var landscapeBMLRemoteOffset: CGSize = .zero
    @State private var landscapeBMLRemoteDragOffset: CGSize = .zero

    init(
        playerState: PlayerState,
        manager: ServerManager,
        pluginStore: PluginStore,
        appModel: AppModel? = nil,
        showsLowerContext: Bool = true
    ) {
        _playerState = State(initialValue: playerState)
        self.manager = manager
        self.pluginStore = pluginStore
        self.appModel = appModel ?? .shared
        self.showsLowerContext = showsLowerContext
    }

    private var displayTime: Double {
        if playerState.isSeeking,
            let pos = scrubPosition,
            let initPos = initialScrubPosition,
            let initTime = initialScrubTime,
            displayDuration > 0
        {
            let delta = Double(pos - initPos)
            return initTime + delta * displayDuration
        }
        return playerState.playbackStatus.time
    }

    private var displayDuration: Double {
        playerState.currentPlayable?.length ?? 0
    }

    private var isSeekActionAvailable: Bool {
        return playerState.player?.isSeekable ?? false
    }

    private var displayProgress: Double {
        if playerState.isSeeking, let scrub = scrubPosition {
            return Double(scrub)
        }
        return Double(playerState.playbackStatus.position)
    }

    private var showsOrientationLockButton: Bool {
        guard playerState.mode != .mini else { return false }
        guard UIDevice.current.userInterfaceIdiom != .pad else { return false }
        if usesFullscreenPlayerLayout {
            return playerState.showControls
        }
        return playerState.showControls && dragOffset == 0
    }

    private var usesFullscreenPlayerLayout: Bool {
        switch playerState.mode {
        case .fullscreen:
            return true
        case .expanded:
            return verticalSizeClass == .compact
        case .mini:
            return false
        }
    }

    private func expandedModeUsesFullscreenLayout(in size: CGSize) -> Bool {
        if verticalSizeClass == .compact { return true }
        if UIDevice.current.userInterfaceIdiom == .pad && size.width > size.height {
            return true
        }
        return false
    }

    private func usesGlassFullscreenControls(in size: CGSize) -> Bool {
        switch playerState.mode {
        case .fullscreen:
            return true
        case .expanded:
            return expandedModeUsesFullscreenLayout(in: size)
        case .mini:
            return false
        }
    }

    private var showsFullscreenToggleButton: Bool {
        guard showsLowerContext else { return false }
        return !(UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass == .compact)
    }

    private func miniPlayerWidthBounds(in geo: GeometryProxy) -> (
        margin: CGFloat,
        minWidth: CGFloat,
        maxWidth: CGFloat
    ) {
        let margin: CGFloat = 12
        let availableWidth = max(120, geo.size.width - margin * 2)
        let minWidth = min(180, availableWidth)
        let maxWidth = min(availableWidth, max(380, geo.size.width / 2))
        return (margin, minWidth, maxWidth)
    }

    private func effectiveMiniPlayerWidth(in geo: GeometryProxy) -> CGFloat {
        let bounds = miniPlayerWidthBounds(in: geo)
        let preferredWidth = max(geo.size.width, geo.size.height) / 3
        let baseWidth = hasCustomMiniPlayerSize ? miniPlayerBaseWidth : preferredWidth
        return min(max(baseWidth, bounds.minWidth), bounds.maxWidth)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if usesFullscreenPlayerLayout || playerState.mode == .expanded {
                    Color.black
                        .ignoresSafeArea()
                }

                persistentPlayerView(geo: geo)
                switch playerState.mode {
                case .expanded:
                    if expandedModeUsesFullscreenLayout(in: geo.size) {
                        fullscreenView(geo: geo)
                    } else {
                        expandedView(geo: geo)
                    }
                case .mini:
                    miniPlayerView(geo: geo)
                case .fullscreen:
                    fullscreenView(geo: geo)
                }

                floatingOrientationLockButton(geo: geo)

                if isLandscapeBMLRemoteVisible
                    && expandedModeUsesFullscreenLayout(in: geo.size)
                {
                    landscapeBMLRemoteOverlay(geo: geo)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(20)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: playerState.mode)
        .onAppear {
            isLandscapeOrientationLocked = PlayerOrientationController.shared.isLandscapeLocked
            orientationButtonRotation = isLandscapeOrientationLocked ? 180 : 0
        }
        #if os(macOS)
            .buttonStyle(.plain)
        #endif
        .onChange(of: playerState.currentPlayable?.id) {
            withAnimation(.easeOut(duration: 0.22)) {
                isInfoSheetVisible = true
            }

        }
        .onChange(of: playerState.availablePanelPlugins.map(\.id)) {
            ensureLowerTabSelection()
        }
        .onChange(of: isDataBroadcastEnabled) {
            ensureLowerTabSelection()
        }
        .onChange(of: verticalSizeClass) { _, newValue in
            if newValue != .compact {
                isLandscapeBMLRemoteVisible = false
                landscapeBMLRemoteOffset = .zero
                landscapeBMLRemoteDragOffset = .zero
            }
        }
        .onChange(of: playerState.mode) { oldMode, newMode in
            isInfoSheetVisible = true
            if newMode == .mini {
                miniEntrySourceMode = oldMode
                if isLandscapeOrientationLocked {
                    unlockLandscapeOrientation()
                }
            }
        }
        .onDisappear {
            orientationToggleTask?.cancel()
            orientationToggleTask = nil
            if isLandscapeOrientationLocked {
                unlockLandscapeOrientation()
            }
            tapWindowResetTask?.cancel()
            tapWindowResetTask = nil
            tapWindowInitialControlsState = nil
            tapWindowCount = 0
        }
        .onReceive(CaptureService.shared.didAddCapture) { (playerID, item) in
            guard playerID == playerState.id else { return }
            if item.type == .image {
                showCaptureFeedback(text: "キャプチャを撮影しました", systemImage: "camera.fill")
            }
        }
        .sheet(
            item: Binding(
                get: { playerState.dataBroadcastSession?.inputRequest },
                set: { _ in }
            )
        ) { request in
            BMLTextInputView(
                request: request,
                onSubmit: {
                    playerState.dataBroadcastSession?.submitInput($0, requestId: request.id)
                },
                onCancel: {
                    playerState.dataBroadcastSession?.cancelInput(requestId: request.id)
                }
            )
            .presentationDetents([request.isMultiline ? .medium : .height(260)])
        }
        .onChange(of: playerState.isRecording) { oldValue, newValue in
            if newValue {
                showCaptureFeedback(text: "録画開始", systemImage: "record.circle.fill")
            } else if oldValue {
                showCaptureFeedback(text: "録画終了", systemImage: "stop.circle.fill")
            }
        }
    }

    @ViewBuilder
    private func persistentPlayerView(geo: GeometryProxy) -> some View {
        if let player = playerState.player {
            let surfaceFrame = playerSurfaceFrame(in: geo)
            let frame = bmlVideoFrame(in: surfaceFrame)
            ZStack {
                Color.black

                PlayerLayerView(
                    player: player,
                    isPipEnabled: playerState.isPipEnabled,
                    isPlaying: playerState.isPlaying,
                    onPipAvailableChanged: { isAvailable in
                        if playerState.isPipAvailable != isAvailable {
                            playerState.isPipAvailable = isAvailable
                        }
                    },
                    onPipEnabledChanged: { isEnabled in
                        if playerState.isPipEnabled != isEnabled {
                            playerState.isPipEnabled = isEnabled
                        }
                    }
                )

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
            .frame(width: frame.width, height: frame.height)
            .clipShape(.rect(cornerRadius: playerState.mode == .mini ? 14 : 0))
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
        }

        if let session = playerState.dataBroadcastSession {
            let frame = playerSurfaceFrame(in: geo)
            BMLOverlayView_iOS(session: session)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .opacity(playerState.bmlContentVisible ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    private func bmlVideoFrame(in surfaceFrame: CGRect) -> CGRect {
        guard playerState.bmlContentVisible,
            let session = playerState.dataBroadcastSession,
            let videoRect = session.videoRect,
            session.webView.bounds.width > 0,
            session.webView.bounds.height > 0
        else { return surfaceFrame }

        let scaleX = surfaceFrame.width / session.webView.bounds.width
        let scaleY = surfaceFrame.height / session.webView.bounds.height
        return CGRect(
            x: surfaceFrame.minX + videoRect.minX * scaleX,
            y: surfaceFrame.minY + videoRect.minY * scaleY,
            width: videoRect.width * scaleX,
            height: videoRect.height * scaleY
        )
    }

    private func playerSurfaceFrame(in geo: GeometryProxy) -> CGRect {
        switch playerState.mode {
        case .expanded:
            if expandedModeUsesFullscreenLayout(in: geo.size) {
                return CGRect(origin: .zero, size: geo.size)
            }
            let height = geo.size.width * 9 / 16
            return CGRect(x: 0, y: 0, width: geo.size.width, height: height)
        case .mini:
            let miniWidth = effectiveMiniPlayerWidth(in: geo)
            let miniHeight = miniWidth * 9 / 16
            let center: CGPoint
            if hasInitializedMiniPlayerPosition {
                center = CGPoint(
                    x: miniPlayerCenter.x + miniPlayerDragOffset.width,
                    y: miniPlayerCenter.y + miniPlayerDragOffset.height
                )
            } else {
                center = sourcePlayerCenterForMiniTransition(in: geo)
            }
            return CGRect(
                x: center.x - miniWidth / 2,
                y: center.y - miniHeight / 2,
                width: miniWidth,
                height: miniHeight
            )
        case .fullscreen:
            return CGRect(origin: .zero, size: geo.size)
        }
    }

    private func sourcePlayerCenterForMiniTransition(in geo: GeometryProxy) -> CGPoint {
        switch miniEntrySourceMode {
        case .expanded:
            if expandedModeUsesFullscreenLayout(in: geo.size) {
                return CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            let height = geo.size.width * 9 / 16
            return CGPoint(x: geo.size.width / 2, y: height / 2)
        case .fullscreen:
            return CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
        case .mini:
            return CGPoint(
                x: miniPlayerCenter.x + miniPlayerDragOffset.width,
                y: miniPlayerCenter.y + miniPlayerDragOffset.height
            )
        }
    }

    @ViewBuilder
    private func expandedView(geo: GeometryProxy) -> some View {
        if !showsLowerContext {
            macVideoOnlyExpandedView(geo: geo)
        } else {
            let videoHeight = geo.size.width * 9 / 16

            ZStack(alignment: .top) {
                if playerState.player == nil {
                    Color.black
                } else {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: videoHeight)
                        Color.kiririnSystemBackground
                    }
                }

                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: videoHeight)

                    ZStack(alignment: .bottom) {
                        lowerContextView

                        if isInfoSheetVisible {
                            PlayerInfoSheet(
                                playable: playerState.currentPlayable,
                                isVisible: $isInfoSheetVisible
                            )
                            .padding(.top, 4)
                            .id(playerState.currentPlayable?.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .ignoresSafeArea()
                        } else {
                            infoSheetCollapsedBar
                        }
                    }
                    .mask(alignment: .top) {
                        Rectangle()
                            .padding(.bottom, -(geo.safeAreaInsets.bottom + 80))
                    }
                }
                .zIndex(0)

                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        videoArea(
                            width: geo.size.width,
                            height: videoHeight,
                            showsControlsOverlay: false
                        )

                        videoControlsOverlay(width: geo.size.width, height: videoHeight)
                            .opacity(playerState.showControls && dragOffset == 0 ? 1 : 0)
                            .allowsHitTesting(playerState.showControls && dragOffset == 0)
                    }

                    if isSeekActionAvailable && !(playerState.showControls && dragOffset == 0) {
                        GeometryReader { pGeo in
                            ZStack(alignment: .leading) {
                                Color.gray.opacity(0.3)
                                Color.accentColor
                                    .frame(width: pGeo.size.width * CGFloat(displayProgress))
                            }
                        }
                        .frame(height: 2)
                    }
                }
                .zIndex(2)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if value.translation.height > 0 {
                                dragOffset = value.translation.height
                                if playerState.showControls {
                                    withAnimation(.easeInOut(duration: 0.1)) {
                                        playerState.setControlsVisible(false)
                                    }
                                }
                            }
                        }
                        .onEnded { value in
                            if value.translation.height > 100 {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    playerState.collapse()
                                }
                            }
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                dragOffset = 0
                            }
                        }
                )

                if isSeekActionAvailable && playerState.showControls && dragOffset == 0 {
                    expandedSeekThumbHitArea(width: geo.size.width)
                        .position(x: geo.size.width / 2, y: videoHeight)
                        .zIndex(3)
                }
            }
        }
    }

    private func expandedSeekThumbHitArea(width: CGFloat) -> some View {
        GeometryReader { geo in
            let hitWidth: CGFloat = 96
            let hitHeight: CGFloat = 64
            let availableWidth = max(geo.size.width, 1)
            let progress = min(max(CGFloat(displayProgress), 0), 1)
            let thumbCenterX = min(
                max(hitWidth / 2, availableWidth * progress),
                max(hitWidth / 2, availableWidth - hitWidth / 2)
            )

            Rectangle()
                .fill(Color.clear)
                .frame(width: hitWidth, height: hitHeight)
                .position(x: thumbCenterX, y: hitHeight / 2)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            updateScrubFromThumbDrag(
                                translationX: value.translation.width,
                                availableWidth: availableWidth
                            )
                        }
                        .onEnded { _ in
                            finishScrub()
                        }
                )
        }
        .frame(width: width, height: 64)
    }

    @ViewBuilder
    private func macVideoOnlyExpandedView(geo: GeometryProxy) -> some View {
        let videoHeight = geo.size.width * 9 / 16
        VStack(spacing: 0) {
            videoArea(width: geo.size.width, height: min(videoHeight, geo.size.height))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
    }

    @ViewBuilder
    private func videoArea(
        width: CGFloat,
        height: CGFloat,
        showsControlsOverlay: Bool = true
    ) -> some View {
        ZStack {
            Group {
                if playerState.player == nil {
                    Color.black
                } else {
                    Color.clear
                }
            }
            .frame(width: width, height: height)

            if playerState.showsPlaybackLoadingIndicator {
                playbackLoadingIndicator
            }

            videoTapZonesOverlay(width: width, height: height)
                .allowsHitTesting(!playerState.showControls)

            feedbackOverlays(height: height)

            Group {
                Button {
                    playerState.setVolume(playerState.volume + 10)
                    showVolumeFeedback()
                } label: {
                    Color.white.frame(width: 1, height: 1)
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                .opacity(0.01)

                Button {
                    playerState.setVolume(playerState.volume - 10)
                    showVolumeFeedback()
                } label: {
                    Color.white.frame(width: 1, height: 1)
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                .opacity(0.01)
            }
            .allowsHitTesting(true)

            if showsControlsOverlay {
                videoControlsOverlay(width: width, height: height)
                    .opacity(playerState.showControls && dragOffset == 0 ? 1 : 0)
                    .allowsHitTesting(playerState.showControls && dragOffset == 0)
            }

        }
        .frame(width: width, height: height)
        .clipped()
        .animation(.easeInOut(duration: 0.18), value: playerState.showsPlaybackLoadingIndicator)
        .animation(.easeInOut(duration: 0.2), value: playerState.showControls)
    }

    @ViewBuilder
    private func floatingOrientationLockButton(geo: GeometryProxy) -> some View {
        if showsOrientationLockButton {
            if #available(iOS 26, *), usesGlassFullscreenControls(in: geo.size) {
                EmptyView()
            } else {
                let frame = playerSurfaceFrame(in: geo)
                let centerBottomInset =
                    usesFullscreenPlayerLayout
                    ? max(geo.safeAreaInsets.bottom + 104, 104)
                    : 28
                orientationLockButton(usesGlass: false)
                    .position(
                        x: frame.maxX - 28,
                        y: frame.maxY - centerBottomInset
                    )
                    .transition(.opacity)
                    .zIndex(10)
                    .animation(.easeInOut(duration: 0.28), value: geo.size)
                    .animation(.easeInOut(duration: 0.28), value: verticalSizeClass)
                    .animation(.easeInOut(duration: 0.2), value: playerState.showControls)
            }
        }
    }

    private func landscapeBMLRemoteOverlay(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("データ放送")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isLandscapeBMLRemoteVisible = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("データ放送コントローラを閉じる")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        landscapeBMLRemoteDragOffset = value.translation
                    }
                    .onEnded { value in
                        let proposed = CGSize(
                            width: landscapeBMLRemoteOffset.width + value.translation.width,
                            height: landscapeBMLRemoteOffset.height + value.translation.height
                        )
                        landscapeBMLRemoteOffset = clampedLandscapeBMLRemoteOffset(
                            proposed, in: geo)
                        landscapeBMLRemoteDragOffset = .zero
                    }
            )

            BMLRemoteControlView(playerState: playerState)
        }
        .frame(width: 220)
        .foregroundStyle(.primary)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .position(landscapeBMLRemotePosition(in: geo))
    }

    private func landscapeBMLRemotePosition(in geo: GeometryProxy) -> CGPoint {
        let proposed = CGSize(
            width: landscapeBMLRemoteOffset.width + landscapeBMLRemoteDragOffset.width,
            height: landscapeBMLRemoteOffset.height + landscapeBMLRemoteDragOffset.height
        )
        let offset = clampedLandscapeBMLRemoteOffset(proposed, in: geo)
        return CGPoint(
            x: geo.size.width - max(geo.safeAreaInsets.trailing, 12) - 110 + offset.width,
            y: geo.size.height / 2 + offset.height
        )
    }

    private func clampedLandscapeBMLRemoteOffset(
        _ offset: CGSize, in geo: GeometryProxy
    ) -> CGSize {
        let margin: CGFloat = 8
        let halfWidth: CGFloat = 110
        let halfHeight = min(180, max(0, geo.size.height / 2 - margin))
        let defaultX = geo.size.width - max(geo.safeAreaInsets.trailing, 12) - halfWidth
        let defaultY = geo.size.height / 2
        let minX = geo.safeAreaInsets.leading + margin + halfWidth
        let maxX = geo.size.width - geo.safeAreaInsets.trailing - margin - halfWidth
        let minY = geo.safeAreaInsets.top + margin + halfHeight
        let maxY = geo.size.height - geo.safeAreaInsets.bottom - margin - halfHeight
        return CGSize(
            width: min(max(defaultX + offset.width, minX), maxX) - defaultX,
            height: min(max(defaultY + offset.height, minY), maxY) - defaultY
        )
    }

    @ViewBuilder
    private func videoControlsOverlay(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { playerState.tapControls() }

            Color.black.opacity(0.2)
                .allowsHitTesting(false)

            videoTapZonesOverlay(width: width, height: height)

            transportControls(width: width, height: height, isFullscreen: false, usesGlass: false)

            VStack {
                HStack(spacing: 8) {
                    if showsLowerContext {
                        collapsePlayerButton
                            .padding(.leading, 8)
                    }

                    Spacer()

                    topRightControlButtons(
                        isFullscreen: false,
                        showsFullscreenToggle: showsFullscreenToggleButton
                    )
                }
                .padding(.top, 4)
                .padding(.trailing, 8)

                Spacer()

                seekBarOverlay(horizontalPadding: 0, bottomPadding: 0)
            }

        }
        .frame(width: width, height: height)
    }

    @ViewBuilder
    private func transportControls(
        width: CGFloat,
        height: CGFloat,
        isFullscreen: Bool,
        usesGlass: Bool
    )
        -> some View
    {
        if #available(iOS 26, *), isFullscreen, usesGlass {
            glassTransportControls(width: width, height: height, isFullscreen: isFullscreen)
        } else if isFullscreen {
            legacyFullscreenTransportControls()
        } else {
            videoTransportControls()
        }
    }

    @available(iOS 26.0, *)
    private func glassTransportControls(width: CGFloat, height: CGFloat, isFullscreen: Bool)
        -> some View
    {
        let metrics = transportMetrics(
            width: width, height: height, isFullscreen: isFullscreen)
        return GlassEffectContainer(spacing: metrics.spacing) {
            if isSeekActionAvailable && displayDuration > 0 {
                HStack(spacing: metrics.spacing) {
                    Button {
                        seekToBeginning()
                    } label: {
                        glassTransportIcon(
                            systemName: "backward.end.fill",
                            fontSize: metrics.sideIconSize,
                            weight: .semibold,
                            buttonSize: metrics.sideButtonSize
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("先頭に戻る")

                    Button {
                        seekBackward()
                    } label: {
                        glassTransportIcon(
                            systemName: "gobackward.10",
                            fontSize: metrics.sideIconSize,
                            weight: .semibold,
                            buttonSize: metrics.sideButtonSize
                        )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .accessibilityLabel("10秒戻る")

                    Button {
                        playerState.togglePlayPause()
                    } label: {
                        glassTransportIcon(
                            systemName: playerState.isPlaying ? "pause.fill" : "play.fill",
                            fontSize: metrics.centerIconSize,
                            weight: .bold,
                            buttonSize: metrics.centerButtonSize
                        )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .accessibilityLabel(playerState.isPlaying ? "一時停止" : "再生")

                    Button {
                        seekForward()
                    } label: {
                        glassTransportIcon(
                            systemName: "goforward.10",
                            fontSize: metrics.sideIconSize,
                            weight: .semibold,
                            buttonSize: metrics.sideButtonSize
                        )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .accessibilityLabel("10秒進む")

                    Color.clear
                        .frame(width: metrics.sideButtonSize, height: metrics.sideButtonSize)
                        .accessibilityHidden(true)
                }
            } else {
                Button {
                    playerState.togglePlayPause()
                } label: {
                    glassTransportIcon(
                        systemName: playerState.isPlaying ? "pause.fill" : "play.fill",
                        fontSize: metrics.centerIconSize,
                        weight: .bold,
                        buttonSize: metrics.centerButtonSize
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(playerState.isPlaying ? "一時停止" : "再生")
            }
        }
        .frame(maxWidth: .infinity)
    }

    @available(iOS 26.0, *)
    private func glassTransportIcon(
        systemName: String,
        fontSize: CGFloat,
        weight: Font.Weight,
        buttonSize: CGFloat
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: fontSize, weight: weight))
            .foregroundStyle(.white)
            .frame(width: buttonSize, height: buttonSize)
            .glassEffect(.regular.interactive(), in: .circle)
            .contentShape(.circle)
    }

    private func transportMetrics(width: CGFloat, height: CGFloat, isFullscreen: Bool)
        -> TransportControlMetrics
    {
        let baseSideButtonSize: CGFloat = 64
        let baseCenterButtonSize: CGFloat = 94
        let baseSideIconSize: CGFloat = 34
        let baseCenterIconSize: CGFloat = 46
        let baseSpacing: CGFloat = isFullscreen ? 26 : 22
        let requiredWidth =
            baseSideButtonSize * 4 + baseCenterButtonSize + baseSpacing * 4
        let fittingScale = max(width - 24, 1) / requiredWidth
        if isFullscreen {
            let heightScale = min(max(min(width, height) / 390, 0.92), 1.08)
            let scale = min(heightScale, fittingScale)
            return TransportControlMetrics(
                sideButtonSize: baseSideButtonSize * scale,
                centerButtonSize: baseCenterButtonSize * scale,
                sideIconSize: baseSideIconSize * scale,
                centerIconSize: baseCenterIconSize * scale,
                spacing: baseSpacing * scale
            )
        }

        let heightScale = min(max(height / 260, 0.72), 0.92)
        let scale = min(heightScale, fittingScale)
        return TransportControlMetrics(
            sideButtonSize: baseSideButtonSize * scale,
            centerButtonSize: baseCenterButtonSize * scale,
            sideIconSize: baseSideIconSize * scale,
            centerIconSize: baseCenterIconSize * scale,
            spacing: baseSpacing * scale
        )
    }

    @ViewBuilder
    private func videoTransportControls() -> some View {
        if isSeekActionAvailable && displayDuration > 0 {
            HStack(spacing: 32) {
                Button {
                    seekToBeginning()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("先頭に戻る")

                Button {
                    seekBackward()
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .accessibilityLabel("10秒戻る")

                Button {
                    playerState.togglePlayPause()
                } label: {
                    Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(playerState.isPlaying ? "一時停止" : "再生")

                Button {
                    seekForward()
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .accessibilityLabel("10秒進む")

                Color.clear.frame(width: 32)
            }
            .frame(maxWidth: .infinity)
        } else {
            Button {
                playerState.togglePlayPause()
            } label: {
                Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(playerState.isPlaying ? "一時停止" : "再生")
        }
    }

    @ViewBuilder
    private func legacyFullscreenTransportControls() -> some View {
        if isSeekActionAvailable && displayDuration > 0 {
            HStack(spacing: 24) {
                Button {
                    seekToBeginning()
                } label: {
                    Image(systemName: "backward.end")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 62, height: 62)
                }
                .accessibilityLabel("先頭に戻る")

                Button {
                    seekBackward()
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 62, height: 62)
                }
                .accessibilityLabel("10秒戻る")

                Button {
                    playerState.togglePlayPause()
                } label: {
                    Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 84, height: 84)
                }
                .accessibilityLabel(playerState.isPlaying ? "一時停止" : "再生")

                Button {
                    seekForward()
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 62, height: 62)
                }
                .accessibilityLabel("10秒進む")

                Color.clear.frame(width: 62)
            }
        } else {
            Button {
                playerState.togglePlayPause()
            } label: {
                Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 84)
            }
            .accessibilityLabel(playerState.isPlaying ? "一時停止" : "再生")
        }
    }

    private var collapsePlayerButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                playerState.collapse()
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("プレイヤーをたたむ")
    }

    private func videoTapZonesOverlay(width: CGFloat, height: CGFloat) -> some View {
        VideoTapZonesOverlay(
            onSingleTap: handleSingleTapInVideoArea,
            onBackwardDoubleTap: {
                handleDoubleTapInVideoArea {
                    seekBackward()
                }
            },
            onForwardDoubleTap: {
                handleDoubleTapInVideoArea {
                    seekForward()
                }
            }
        )
        .frame(width: width, height: height)
    }

    private func handleSingleTapInVideoArea() {
        if tapWindowInitialControlsState == nil {
            tapWindowInitialControlsState = playerState.showControls
        }
        tapWindowCount += 1
        playerState.tapControls()

        tapWindowResetTask?.cancel()
        let task = DispatchWorkItem {
            tapWindowInitialControlsState = nil
            tapWindowCount = 0
            tapWindowResetTask = nil
        }
        tapWindowResetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }

    private func handleDoubleTapInVideoArea(_ action: () -> Void) {
        guard isSeekActionAvailable && displayDuration > 0 else { return }
        tapWindowResetTask?.cancel()
        tapWindowResetTask = nil
        if let initialState = tapWindowInitialControlsState, tapWindowCount > 0 {
            playerState.setControlsVisible(initialState)
        }
        tapWindowInitialControlsState = nil
        tapWindowCount = 0
        action()
    }

    @ViewBuilder
    private var lowerContextView: some View {
        TabView(selection: $lowerTabSelection) {
            NavigationStack {
                CaptionHistoryView(playerState: playerState)
            }
            .tag("caption")
            .tabItem {
                Label("字幕", systemImage: "captions.bubble")
            }

            if isDataBroadcastEnabled {
                NavigationStack {
                    if playerState.dataBroadcastSession != nil {
                        BMLRemoteControlView(
                            playerState: playerState,
                            layout: .tab
                        )
                        .padding(.top, 24)
                        .padding(.bottom, collapsedBarReservedBottomHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .navigationTitle("データ放送")
                        .navigationBarTitleDisplayMode(.inline)
                    } else {
                        unavailableLowerContextView(
                            title: "データ放送を利用できません",
                            systemImage: "d.circle",
                            message: "データ放送に対応したライブ放送を再生してください"
                        )
                    }
                }
                .tag("dataBroadcast")
                .tabItem {
                    Label("データ放送", systemImage: "d.circle")
                }
            }

            NavigationStack {
                LowerContextPluginsView(
                    pluginStore: pluginStore,
                    playerState: playerState,
                    appModel: appModel,
                    selectedPluginID: $selectedPluginID,
                    collapsedBarReservedHeight: collapsedBarReservedBottomHeight
                )
            }
            .tag("plugin")
            .tabItem {
                Label("プラグイン", systemImage: "puzzlepiece.extension")
            }
        }
        .onAppear {
            ensureLowerTabSelection()
        }
        .background(Color.kiririnSystemBackground)
    }

    private func ensureLowerTabSelection() {
        let validTags =
            isDataBroadcastEnabled
            ? ["caption", "dataBroadcast", "plugin"]
            : ["caption", "plugin"]
        if !validTags.contains(lowerTabSelection) {
            lowerTabSelection = "caption"
        }

        let enabledPlugins = pluginStore.plugins.filter { $0.isEnabled }
        if let currentID = selectedPluginID {
            if !enabledPlugins.contains(where: { $0.id == currentID }) {
                selectedPluginID = enabledPlugins.first?.id
            }
        } else {
            selectedPluginID = enabledPlugins.first?.id
        }
    }

    private var programInfoTransitionKey: String {
        if let program = playerState.displayProgram {
            let extendedSignature = (program.extended ?? [:])
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "|")
            return [
                "program",
                program.id,
                program.name,
                program.desc ?? "",
                "\(program.startAt.timeIntervalSince1970)",
                "\(program.endAt.timeIntervalSince1970)",
                "\(program.duration)",
                extendedSignature,
            ].joined(separator: "§")
        }
        return
            "playable:\(playerState.currentPlayable?.id ?? "none"):\(playerState.currentPlayable?.title ?? "")"
    }

    private var infoSheetCollapsedBar: some View {
        PlayerInfoSheetCollapsedBar(
            onTap: {
                withAnimation(.easeOut(duration: 0.22)) {
                    isInfoSheetVisible = true
                }
            },
            onReservedHeightChange: { collapsedBarReservedBottomHeight = $0 }
        )
    }

    @ViewBuilder
    private func unavailableLowerContextView(
        title: String, systemImage: String, message: String
    ) -> some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(message)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.kiririnSystemBackground)
    }

    @ViewBuilder
    private func miniPlayerView(geo: GeometryProxy) -> some View {
        let bounds = miniPlayerWidthBounds(in: geo)
        let miniMargin = bounds.margin
        let minMiniWidth = bounds.minWidth
        let maxMiniWidth = bounds.maxWidth
        let miniWidth = effectiveMiniPlayerWidth(in: geo)
        let miniHeight = miniWidth * 9 / 16
        let miniSize = CGSize(width: miniWidth, height: miniHeight)

        ZStack {
            Color.clear

            ZStack(alignment: .bottom) {
                if playerState.player == nil {
                    Color.black
                } else {
                    Color.black.opacity(0.001)
                }

                Color.black.opacity(0.001)

                if playerState.showsPlaybackLoadingIndicator {
                    playbackLoadingIndicator
                }

                if miniOverlayVisible {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    ZStack {
                        VStack {
                            HStack {
                                Button {
                                    playerState.close()
                                } label: {
                                    if #available(iOS 26, *) {
                                        Image(systemName: "xmark")
                                            .font(.title2)
                                            .fontWeight(.bold)
                                            .foregroundStyle(.white)
                                            .frame(width: 44, height: 44)
                                            .glassEffect(
                                                .regular.interactive(),
                                                in: .circle
                                            )
                                            .contentShape(.circle)
                                    } else {
                                        Image(systemName: "xmark")
                                            .font(.title2)
                                            .fontWeight(.bold)
                                            .foregroundStyle(.white)
                                            .frame(width: 44, height: 44)
                                            .background(.black.opacity(0.35), in: Circle())
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("プレイヤーを閉じる")

                                Spacer()
                            }
                            Spacer()
                        }
                        .padding(.top, 8)
                        .padding(.leading, 8)
                        .padding(.trailing, 8)

                        Button {
                            markMiniPlayerInteraction()
                            playerState.togglePlayPause()
                        } label: {
                            if #available(iOS 26, *) {
                                let buttonSize = min(max(miniWidth * 0.44, 56), 68)
                                Image(
                                    systemName: playerState.isPlaying ? "pause.fill" : "play.fill"
                                )
                                .font(.system(size: buttonSize * 0.48, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: buttonSize, height: buttonSize)
                                .glassEffect(
                                    .regular.interactive(), in: .circle
                                )
                                .contentShape(.circle)
                            } else {
                                Image(
                                    systemName: playerState.isPlaying ? "pause.fill" : "play.fill"
                                )
                                .font(.system(size: 40, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 82, height: 82)
                                .background(.black.opacity(0.35), in: Circle())
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(playerState.isPlaying ? "一時停止" : "再生")

                        VStack {
                            Spacer()
                            VStack(alignment: .leading, spacing: 2) {
                                BroadcastText(
                                    playerState.currentPlayable?.title ?? "",
                                    style: .caption,
                                    weight: .semibold
                                )
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                if let sub = playerState.currentPlayable?.serviceName {
                                    Text(sub)
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.85))
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                        }
                    }
                }

                playbackErrorOverlay(height: miniSize.height)
            }
            .frame(width: miniSize.width, height: miniSize.height)
            .animation(.easeInOut(duration: 0.18), value: playerState.showsPlaybackLoadingIndicator)
            .clipShape(.rect(cornerRadius: 14))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .position(
                x: miniPlayerCenter.x + miniPlayerDragOffset.width,
                y: miniPlayerCenter.y + miniPlayerDragOffset.height
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        markMiniPlayerInteraction()
                        miniPlayerDragOffset = value.translation
                    }
                    .onEnded { value in
                        markMiniPlayerInteraction()
                        let releasedCenter = CGPoint(
                            x: miniPlayerCenter.x + value.translation.width,
                            y: miniPlayerCenter.y + value.translation.height
                        )
                        miniPlayerCenter = releasedCenter
                        miniPlayerDragOffset = .zero
                        miniPlayerCorner = nearestMiniPlayerCorner(
                            to: releasedCenter, in: geo, miniSize: miniSize, margin: miniMargin)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            miniPlayerCenter = centerForMiniPlayerCorner(
                                miniPlayerCorner, in: geo, miniSize: miniSize,
                                margin: miniMargin)
                        }
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        markMiniPlayerInteraction()
                        if miniPlayerPinchStartWidth == nil {
                            let startWidth = effectiveMiniPlayerWidth(in: geo)
                            hasCustomMiniPlayerSize = true
                            miniPlayerPinchStartWidth = startWidth
                            miniPlayerPinchStartHeight = startWidth * 9 / 16
                            miniPlayerPinchStartCenter = CGPoint(
                                x: miniPlayerCenter.x + miniPlayerDragOffset.width,
                                y: miniPlayerCenter.y + miniPlayerDragOffset.height
                            )
                        }
                        if let pinchStartWidth = miniPlayerPinchStartWidth,
                            let pinchStartHeight = miniPlayerPinchStartHeight,
                            let pinchStartCenter = miniPlayerPinchStartCenter
                        {
                            let resizedWidth = pinchStartWidth * value.magnification
                            let clampedWidth = min(
                                max(resizedWidth, minMiniWidth), maxMiniWidth)
                            let clampedHeight = clampedWidth * 9 / 16
                            let anchor = value.startAnchor
                            let anchorX = CGFloat(anchor.x)
                            let anchorY = CGFloat(anchor.y)
                            let startTopLeft = CGPoint(
                                x: pinchStartCenter.x - pinchStartWidth / 2,
                                y: pinchStartCenter.y - pinchStartHeight / 2
                            )
                            let anchorPosition = CGPoint(
                                x: startTopLeft.x + pinchStartWidth * anchorX,
                                y: startTopLeft.y + pinchStartHeight * anchorY
                            )
                            let resizedCenter = CGPoint(
                                x: anchorPosition.x + clampedWidth * (0.5 - anchorX),
                                y: anchorPosition.y + clampedHeight * (0.5 - anchorY)
                            )
                            miniPlayerBaseWidth = clampedWidth
                            miniPlayerCenter = clampedMiniPlayerCenter(
                                resizedCenter,
                                in: geo,
                                miniSize: CGSize(width: clampedWidth, height: clampedHeight),
                                margin: miniMargin
                            )
                        }
                    }
                    .onEnded { _ in
                        markMiniPlayerInteraction()
                        miniPlayerPinchStartWidth = nil
                        miniPlayerPinchStartCenter = nil
                        miniPlayerPinchStartHeight = nil
                        miniPlayerBaseWidth = min(
                            max(miniPlayerBaseWidth, minMiniWidth), maxMiniWidth)
                        miniPlayerCenter = clampedMiniPlayerCenter(
                            miniPlayerCenter,
                            in: geo,
                            miniSize: CGSize(
                                width: miniPlayerBaseWidth, height: miniPlayerBaseWidth * 9 / 16
                            ),
                            margin: miniMargin
                        )
                        miniPlayerCorner = nearestMiniPlayerCorner(
                            to: miniPlayerCenter,
                            in: geo,
                            miniSize: CGSize(
                                width: miniPlayerBaseWidth, height: miniPlayerBaseWidth * 9 / 16
                            ),
                            margin: miniMargin
                        )
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            miniPlayerCenter = centerForMiniPlayerCorner(
                                miniPlayerCorner,
                                in: geo,
                                miniSize: CGSize(
                                    width: miniPlayerBaseWidth,
                                    height: miniPlayerBaseWidth * 9 / 16),
                                margin: miniMargin
                            )
                        }
                    }
            )
            .onTapGesture {
                let wasOverlayVisible = miniOverlayVisible
                markMiniPlayerInteraction()
                if wasOverlayVisible {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        playerState.expand()
                    }
                }
            }
            .onAppear {
                miniPlayerBaseWidth = effectiveMiniPlayerWidth(in: geo)
                if !hasInitializedMiniPlayerPosition {
                    let targetCenter = centerForMiniPlayerCorner(
                        miniPlayerCorner, in: geo, miniSize: miniSize, margin: miniMargin)
                    miniPlayerCenter = sourcePlayerCenterForMiniTransition(in: geo)
                    hasInitializedMiniPlayerPosition = true
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        miniPlayerCenter = targetCenter
                    }
                } else {
                    miniPlayerCenter = centerForMiniPlayerCorner(
                        miniPlayerCorner, in: geo, miniSize: miniSize, margin: miniMargin)
                }
                markMiniPlayerInteraction()
            }
            .onDisappear {
                miniOverlayHideTask?.cancel()
                miniOverlayHideTask = nil
            }
            .onChange(of: geo.size) {
                miniPlayerBaseWidth = effectiveMiniPlayerWidth(in: geo)
                miniPlayerCenter = centerForMiniPlayerCorner(
                    miniPlayerCorner, in: geo, miniSize: miniSize, margin: miniMargin)
            }
            .onChange(of: geo.safeAreaInsets.top) {
                miniPlayerCenter = centerForMiniPlayerCorner(
                    miniPlayerCorner, in: geo, miniSize: miniSize, margin: miniMargin)
            }
            .onChange(of: geo.safeAreaInsets.bottom) {
                miniPlayerCenter = centerForMiniPlayerCorner(
                    miniPlayerCorner, in: geo, miniSize: miniSize, margin: miniMargin)
            }
            .onChange(of: playerState.mode) { oldMode, mode in
                if mode == .mini {
                    markMiniPlayerInteraction()
                } else {
                    miniOverlayHideTask?.cancel()
                    miniOverlayHideTask = nil
                    miniOverlayVisible = true
                }
            }
        }
    }

    private func centerForMiniPlayerCorner(
        _ corner: MiniPlayerCorner,
        in geo: GeometryProxy,
        miniSize: CGSize,
        margin: CGFloat
    ) -> CGPoint {
        let minX = miniSize.width / 2 + margin
        let maxX = geo.size.width - miniSize.width / 2 - margin
        let minY = geo.safeAreaInsets.top + miniSize.height / 2 + margin
        let maxY =
            geo.size.height - miniBottomInset(in: geo) - miniBottomReservedSpace(in: geo)
            - miniSize.height / 2 - margin

        if maxX < minX || maxY < minY {
            return CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
        }

        switch corner {
        case .topLeading:
            return CGPoint(x: minX, y: minY)
        case .topTrailing:
            return CGPoint(x: maxX, y: minY)
        case .bottomLeading:
            return CGPoint(x: minX, y: maxY)
        case .bottomTrailing:
            return CGPoint(x: maxX, y: maxY)
        }
    }

    private func clampedMiniPlayerCenter(
        _ center: CGPoint,
        in geo: GeometryProxy,
        miniSize: CGSize,
        margin: CGFloat
    ) -> CGPoint {
        let minX = miniSize.width / 2 + margin
        let maxX = geo.size.width - miniSize.width / 2 - margin
        let minY = geo.safeAreaInsets.top + miniSize.height / 2 + margin
        let maxY =
            geo.size.height - miniBottomInset(in: geo) - miniBottomReservedSpace(in: geo)
            - miniSize.height / 2 - margin

        if maxX < minX || maxY < minY {
            return CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
        }

        let clampedX = min(max(center.x, minX), maxX)
        let clampedY = min(max(center.y, minY), maxY)
        return CGPoint(x: clampedX, y: clampedY)
    }

    private func nearestMiniPlayerCorner(
        to point: CGPoint,
        in geo: GeometryProxy,
        miniSize: CGSize,
        margin: CGFloat
    ) -> MiniPlayerCorner {
        let corners: [MiniPlayerCorner] = [
            .topLeading, .topTrailing, .bottomLeading, .bottomTrailing,
        ]

        return corners.min(by: { lhs, rhs in
            let lhsPoint = centerForMiniPlayerCorner(
                lhs, in: geo, miniSize: miniSize, margin: margin)
            let rhsPoint = centerForMiniPlayerCorner(
                rhs, in: geo, miniSize: miniSize, margin: margin)
            let lhsDistance = hypot(point.x - lhsPoint.x, point.y - lhsPoint.y)
            let rhsDistance = hypot(point.x - rhsPoint.x, point.y - rhsPoint.y)
            return lhsDistance < rhsDistance
        }) ?? .bottomTrailing
    }

    private func markMiniPlayerInteraction() {
        withAnimation(.easeInOut(duration: 0.2)) {
            miniOverlayVisible = true
        }
        miniOverlayHideTask?.cancel()
        let task = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.2)) {
                miniOverlayVisible = false
            }
        }
        miniOverlayHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }

    private func miniBottomInset(in geo: GeometryProxy) -> CGFloat {
        #if os(iOS)
            min(geo.safeAreaInsets.bottom, 32)
        #else
            geo.safeAreaInsets.bottom
        #endif
    }

    private func miniBottomReservedSpace(in geo: GeometryProxy) -> CGFloat {
        #if os(iOS)
            geo.size.width > geo.size.height ? 64 : 16
        #else
            0
        #endif
    }

    @ViewBuilder
    private func fullscreenView(geo: GeometryProxy) -> some View {
        ZStack {
            if playerState.player == nil {
                Color.black.ignoresSafeArea()
            } else {
                Color.clear.ignoresSafeArea()
            }

            videoTapZonesOverlay(width: geo.size.width, height: geo.size.height)
                .ignoresSafeArea()
                .allowsHitTesting(!playerState.showControls)

            if playerState.showsPlaybackLoadingIndicator {
                playbackLoadingIndicator
                    .ignoresSafeArea()
            }

            feedbackOverlays(height: geo.size.height)
                .ignoresSafeArea()

            Group {
                Button {
                    playerState.setVolume(playerState.volume + 10)
                    showVolumeFeedback()
                } label: {
                    Color.white.frame(width: 1, height: 1)
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                .opacity(0.01)

                Button {
                    playerState.setVolume(playerState.volume - 10)
                    showVolumeFeedback()
                } label: {
                    Color.white.frame(width: 1, height: 1)
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                .opacity(0.01)
            }
            .allowsHitTesting(true)

            fullscreenControlsOverlay(geo: geo)
                .opacity(playerState.showControls ? 1 : 0)
                .allowsHitTesting(playerState.showControls)

        }
        .animation(.easeInOut(duration: 0.18), value: playerState.showsPlaybackLoadingIndicator)
        #if os(macOS)
            .animation(.easeInOut(duration: 0.2), value: playerState.showControls)
        #else
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .animation(.easeInOut(duration: 0.2), value: playerState.showControls)
        #endif
        .gesture(
            DragGesture()
                .onChanged { value in
                    if value.translation.height > 0 {
                        dragOffset = value.translation.height
                        if playerState.showControls {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                playerState.setControlsVisible(false)
                            }
                        }
                    }
                }
                .onEnded { value in
                    if value.translation.height > 100 {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            playerState.collapse()
                        }
                    }
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                }
        )
    }

    @ViewBuilder
    private var playbackLoadingIndicator: some View {
        ProgressView()
            .tint(.white)
            .controlSize(.regular)
            .allowsHitTesting(false)
            .accessibilityLabel("動画を読み込み中")
            .transition(.opacity)
    }

    @ViewBuilder
    private func fullscreenControlsOverlay(geo: GeometryProxy) -> some View {
        let isPortraitFullscreen = geo.size.height > geo.size.width
        let usesGlassControls = usesGlassFullscreenControls(in: geo.size)
        let metadataBottomPadding: CGFloat =
            isPortraitFullscreen || isSeekActionAvailable ? 4 : 24
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { playerState.tapControls() }

            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            videoTapZonesOverlay(width: geo.size.width, height: geo.size.height)
                .ignoresSafeArea()

            transportControls(
                width: geo.size.width,
                height: geo.size.height,
                isFullscreen: true,
                usesGlass: usesGlassControls
            )

            VStack {
                if #available(iOS 26, *), usesGlassControls {
                    fullscreenGlassTopControls(geo: geo)
                } else {
                    legacyFullscreenTopControls(isPortraitFullscreen: isPortraitFullscreen)
                }

                Spacer()

                if #available(iOS 26, *), usesGlassControls {
                    fullscreenGlassBottomMetadata(
                        horizontalPadding: 16,
                        bottomPadding: metadataBottomPadding
                    )
                }

                fullscreenSeekbar(
                    horizontalPadding: 16,
                    bottomPadding: 16,
                    usesGlass: usesGlassControls
                )
            }

        }
    }

    @available(iOS 26.0, *)
    private func fullscreenGlassTopControls(geo: GeometryProxy) -> some View {
        HStack(spacing: 12) {
            if showsFullscreenToggleButton {
                Button {
                    playerState.exitFullscreen()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .glassEffect(
                            .regular.interactive(), in: .circle
                        )
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("フルスクリーンを終了")
            }

            Spacer(minLength: 12)

            topRightControlButtons(
                isFullscreen: true,
                showsFullscreenToggle: false,
                showsOptionsMenu: false
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func legacyFullscreenTopControls(isPortraitFullscreen: Bool) -> some View {
        if isPortraitFullscreen {
            VStack(alignment: .leading, spacing: 8) {
                fullscreenTitleBlock(
                    titleStyle: .subheadline,
                    titleWeight: .semibold,
                    subtitleStyle: .caption
                )

                HStack {
                    Spacer()
                    topRightControlButtons(
                        isFullscreen: true,
                        showsFullscreenToggle: showsFullscreenToggleButton
                    )
                }
            }
            .padding(.leading)
            .padding(.trailing, 8)
            .padding(.top, 8)
        } else {
            HStack {
                fullscreenTitleBlock(
                    titleStyle: .subheadline,
                    titleWeight: .semibold,
                    subtitleStyle: .caption
                )
                .padding(.leading)

                Spacer()

                topRightControlButtons(
                    isFullscreen: true,
                    showsFullscreenToggle: showsFullscreenToggleButton
                )
                .padding(.trailing, 8)
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func fullscreenTitleBlock(
        titleStyle: Font.TextStyle,
        titleWeight: Font.Weight,
        subtitleStyle: Font.TextStyle
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            BroadcastText(
                playerState.currentPlayable?.title ?? "",
                style: titleStyle,
                weight: titleWeight
            )
            .foregroundStyle(.white)
            .lineLimit(1)
            if let sub = playerState.currentPlayable?.subtitle,
                !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                BroadcastText(sub, style: subtitleStyle)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
    }

    @available(iOS 26.0, *)
    private func fullscreenGlassBottomMetadata(
        horizontalPadding: CGFloat,
        bottomPadding: CGFloat
    ) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            fullscreenTitleBlock(
                titleStyle: .title2,
                titleWeight: .bold,
                subtitleStyle: .caption
            )
            .layoutPriority(1)

            Spacer(minLength: 4)

            VStack(spacing: 10) {
                if showsOrientationLockButton {
                    orientationLockButton(usesGlass: true)
                }

                topRightOptionsMenuButton(itemSize: 52, iconSize: 22, usesGlass: true)
            }
        }
        .padding(.horizontal, horizontalPadding + 4)
        .padding(.bottom, bottomPadding)
    }

    private func orientationLockButton(usesGlass: Bool) -> some View {
        Button {
            toggleLandscapeOrientationLock()
        } label: {
            if #available(iOS 26, *), usesGlass {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .rotationEffect(.degrees(orientationButtonRotation))
                    .glassEffect(
                        .regular.interactive(), in: .circle
                    )
                    .contentShape(.circle)
            } else {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .padding(6)
                    .rotationEffect(.degrees(orientationButtonRotation))
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(
            isLandscapeOrientationLocked
                ? "横画面固定を解除して縦画面に戻す" : "横画面に固定"
        )
    }

    @ViewBuilder
    private func topRightControlButtons(
        isFullscreen: Bool,
        showsFullscreenToggle: Bool = true,
        showsOptionsMenu: Bool = true,
        separatesOptionsMenu: Bool = false
    )
        -> some View
    {
        if #available(iOS 26, *), isFullscreen {
            HStack(spacing: separatesOptionsMenu && showsOptionsMenu ? 10 : 0) {
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 0) {
                        topRightControlButtonItems(
                            isFullscreen: isFullscreen,
                            showsFullscreenToggle: showsFullscreenToggle,
                            showsOptionsMenu: showsOptionsMenu && !separatesOptionsMenu,
                            itemSize: 44,
                            iconSize: 20
                        )
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 52)
                    .contentShape(.capsule)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)

                if separatesOptionsMenu && showsOptionsMenu {
                    topRightOptionsMenuButton(itemSize: 52, iconSize: 20, usesGlass: true)
                }
            }
        } else {
            plainTopRightControlButtons(
                isFullscreen: isFullscreen,
                showsFullscreenToggle: showsFullscreenToggle,
                showsOptionsMenu: showsOptionsMenu,
                separatesOptionsMenu: separatesOptionsMenu
            )
        }
    }

    @ViewBuilder
    private func plainTopRightControlButtons(
        isFullscreen: Bool,
        showsFullscreenToggle: Bool,
        showsOptionsMenu: Bool,
        separatesOptionsMenu: Bool
    ) -> some View {
        if separatesOptionsMenu && showsOptionsMenu {
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    topRightControlButtonItems(
                        isFullscreen: isFullscreen,
                        showsFullscreenToggle: showsFullscreenToggle,
                        showsOptionsMenu: false,
                        itemSize: 44,
                        iconSize: 20
                    )
                }
                .padding(.horizontal, 8)
                .frame(height: 52)

                topRightOptionsMenuButton(itemSize: 52, iconSize: 20, usesGlass: false)
            }
        } else {
            topRightControlButtonItems(
                isFullscreen: isFullscreen,
                showsFullscreenToggle: showsFullscreenToggle,
                showsOptionsMenu: showsOptionsMenu,
                itemSize: 44,
                iconSize: 20
            )
        }
    }

    @ViewBuilder
    private func topRightControlButtonItems(
        isFullscreen: Bool,
        showsFullscreenToggle: Bool,
        showsOptionsMenu: Bool,
        itemSize: CGFloat,
        iconSize: CGFloat
    ) -> some View {
        if showsFullscreenToggle {
            Button {
                if isFullscreen {
                    playerState.exitFullscreen()
                } else {
                    playerState.enterFullscreen()
                }
            } label: {
                Image(
                    systemName: isFullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                )
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: itemSize, height: itemSize)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(
                isFullscreen ? "フルスクリーンを終了" : "フルスクリーンにする"
            )
        }

        if playerState.dataBroadcastSession != nil {
            Button {
                if showsLowerContext && verticalSizeClass != .compact && !isFullscreen {
                    lowerTabSelection = "dataBroadcast"
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isLandscapeBMLRemoteVisible.toggle()
                    }
                }
            } label: {
                Image(systemName: "d.circle\(playerState.bmlContentVisible ? ".fill" : "")")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: itemSize, height: itemSize)
                    .contentShape(Rectangle())
            }
            .disabled(!playerState.bmlAvailable)
            .accessibilityLabel(
                showsLowerContext && verticalSizeClass != .compact && !isFullscreen
                    ? "データ放送タブを表示" : "データ放送コントローラを表示"
            )
        }

        Button {
            playerState.setSubtitleEnabled(!playerState.isSubtitleEnabled)
        } label: {
            Image(
                systemName: playerState.isSubtitleEnabled
                    ? "captions.bubble.fill" : "captions.bubble"
            )
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: itemSize, height: itemSize)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(playerState.isSubtitleEnabled ? "字幕を非表示" : "字幕を表示")

        if playerState.isPipAvailable {
            Button {
                playerState.togglePip()
            } label: {
                Image(systemName: playerState.isPipEnabled ? "pip.exit" : "pip.enter")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: itemSize, height: itemSize)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(
                playerState.isPipEnabled ? "ピクチャインピクチャを終了" : "ピクチャインピクチャを開始"
            )
        }

        Button {
            playerState.takeCapture()
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: itemSize, height: itemSize)
                .contentShape(Rectangle())
        }
        .keyboardShortcut("s", modifiers: .command)
        .accessibilityLabel("キャプチャを撮影")

        Button {
            playerState.toggleRecording()
        } label: {
            Image(systemName: playerState.isRecording ? "record.circle.fill" : "record.circle")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(playerState.isRecording ? .red : .white)
                .frame(width: itemSize, height: itemSize)
                .contentShape(Rectangle())
        }
        .keyboardShortcut("r", modifiers: .command)
        .accessibilityLabel(playerState.isRecording ? "録画を停止" : "録画を開始")

        if showsOptionsMenu {
            Menu {
                PlayerPlaybackOptionMenuEntries(
                    playerState: playerState,
                    isSeekActionAvailable: isSeekActionAvailable
                )
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: itemSize, height: itemSize)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("再生オプション")
        }
    }

    private func topRightOptionsMenuButton(
        itemSize: CGFloat,
        iconSize: CGFloat,
        usesGlass: Bool
    ) -> some View {
        Menu {
            PlayerPlaybackOptionMenuEntries(
                playerState: playerState,
                isSeekActionAvailable: isSeekActionAvailable
            )
        } label: {
            let icon = Image(systemName: "ellipsis")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: itemSize, height: itemSize)
                .contentShape(Rectangle())

            if #available(iOS 26, *), usesGlass {
                icon
                    .glassEffect(
                        .regular.interactive(), in: .circle
                    )
                    .contentShape(.circle)
            } else {
                icon
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("再生オプション")
    }

    private func seekForward() {
        guard isSeekActionAvailable else { return }
        jump(seconds: 10)
    }

    private func seekBackward() {
        guard isSeekActionAvailable else { return }
        jump(seconds: -10)
    }

    private func seekToBeginning() {
        guard isSeekActionAvailable else { return }
        playerState.seek(to: 0)
    }

    private func updateScrub(relativeX: CGFloat, availableWidth: CGFloat) {
        guard availableWidth > 0 else { return }
        if !playerState.isSeeking {
            initialScrubPosition = playerState.playbackStatus.position
            initialScrubTime = playerState.playbackStatus.time
        }
        playerState.isSeeking = true
        let newProgress = min(max(0, relativeX / availableWidth), 1)
        scrubPosition = Float(newProgress)
    }

    private func updateScrubFromThumbDrag(translationX: CGFloat, availableWidth: CGFloat) {
        guard availableWidth > 0 else { return }
        let baseProgress: Float
        if !playerState.isSeeking {
            baseProgress = playerState.playbackStatus.position
            initialScrubPosition = baseProgress
            initialScrubTime = playerState.playbackStatus.time
        } else {
            baseProgress =
                initialScrubPosition
                ?? scrubPosition
                ?? playerState.playbackStatus.position
        }
        playerState.isSeeking = true
        let newProgress = min(max(0, CGFloat(baseProgress) + translationX / availableWidth), 1)
        scrubPosition = Float(newProgress)
    }

    private func finishScrub() {
        if playerState.isSeeking, let scrub = scrubPosition {
            seekToPosition(scrub)
        }
        playerState.isSeeking = false
        scrubPosition = nil
        initialScrubPosition = nil
        initialScrubTime = nil
    }

    private func seekBarOverlay(horizontalPadding: CGFloat, bottomPadding: CGFloat) -> some View {
        legacySeekBarOverlay(horizontalPadding: horizontalPadding, bottomPadding: bottomPadding)
    }

    private func legacySeekBarOverlay(horizontalPadding: CGFloat, bottomPadding: CGFloat)
        -> some View
    {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if isSeekActionAvailable && displayDuration > 0 {
                    Text(
                        "\(displayTime.playerTimeString) / \(displayDuration.playerTimeString)"
                    )
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                } else if isSeekActionAvailable && displayDuration <= 0 && displayTime > 0 {
                    Text(displayTime.playerTimeString)
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                Spacer()
                #if os(macOS)
                    GeometryReader { geo in
                        let controlWidth = min(240, max(120, geo.size.width * 0.25))
                        HStack(spacing: 10) {
                            Button {
                                playerState.toggleMute()
                                showVolumeFeedback()
                            } label: {
                                Image(systemName: volumeIconName)
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut("m", modifiers: [])

                            Slider(
                                value: Binding(
                                    get: { Double(playerState.volume) },
                                    set: {
                                        playerState.setVolume(Float($0))
                                        showVolumeFeedback()
                                    }
                                ),
                                in: 0...200
                            )
                            .tint(.white)
                        }
                        .frame(width: controlWidth)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .frame(height: 36)
                #endif
            }
            .padding(.horizontal, 16)

            if isSeekActionAvailable {
                GeometryReader { geo in
                    let trackHeight: CGFloat = 4
                    let thumbSize: CGFloat = 16
                    let interactionHeight: CGFloat = 24
                    let trackCenterY = geo.size.height / 2 + 8
                    let progress = CGFloat(displayProgress)
                    let availableWidth = geo.size.width - horizontalPadding * 2

                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: availableWidth, height: interactionHeight)
                            .position(
                                x: horizontalPadding + availableWidth / 2,
                                y: trackCenterY
                            )
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 8)
                                    .onChanged { value in
                                        updateScrub(
                                            relativeX: value.location.x,
                                            availableWidth: availableWidth
                                        )
                                    }
                                    .onEnded { _ in
                                        finishScrub()
                                    }
                            )

                        Capsule()
                            .fill(Color.accentColor)
                            .frame(
                                width: max(0, availableWidth * progress), height: trackHeight
                            )
                            .padding(.leading, horizontalPadding)
                            .offset(y: 8)
                            .allowsHitTesting(false)

                        Circle()
                            .fill(Color.white)
                            .frame(width: thumbSize, height: thumbSize)
                            .shadow(radius: 2)
                            .position(
                                x: horizontalPadding + availableWidth * progress,
                                y: trackCenterY
                            )
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 16)
            }
        }
        .padding(.bottom, bottomPadding)
        .contentShape(Rectangle())
        .onTapGesture {
        }
    }

    @ViewBuilder
    private func fullscreenSeekbar(
        horizontalPadding: CGFloat,
        bottomPadding: CGFloat,
        usesGlass: Bool
    )
        -> some View
    {
        if #available(iOS 26, *), usesGlass {
            fullscreenGlassSeekbar(
                horizontalPadding: horizontalPadding,
                bottomPadding: bottomPadding
            )
        } else {
            legacyFullscreenSeekbar(
                horizontalPadding: horizontalPadding,
                bottomPadding: bottomPadding
            )
        }
    }

    private func legacyFullscreenSeekbar(horizontalPadding: CGFloat, bottomPadding: CGFloat)
        -> some View
    {
        VStack(spacing: 10) {
            if isSeekActionAvailable {
                GeometryReader { geo in
                    let trackHeight: CGFloat = playerState.isSeeking ? 10 : 5
                    let interactionHeight: CGFloat = 24
                    let progress = CGFloat(displayProgress)
                    let availableWidth = geo.size.width - horizontalPadding * 2

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.25))
                            .frame(height: trackHeight)
                            .padding(.horizontal, horizontalPadding)

                        Capsule()
                            .fill(.white)
                            .frame(
                                width: max(trackHeight, availableWidth * progress),
                                height: trackHeight
                            )
                            .padding(.leading, horizontalPadding)

                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: availableWidth, height: interactionHeight)
                            .position(
                                x: horizontalPadding + availableWidth / 2,
                                y: geo.size.height / 2
                            )
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 8)
                                    .onChanged { value in
                                        updateScrub(
                                            relativeX: value.location.x,
                                            availableWidth: availableWidth
                                        )
                                    }
                                    .onEnded { _ in
                                        finishScrub()
                                    }
                            )
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .animation(
                        .spring(response: 0.2, dampingFraction: 0.75),
                        value: playerState.isSeeking)
                }
                .frame(height: 44)
            }

            HStack {
                if isSeekActionAvailable && displayDuration > 0 {
                    Text(displayTime.playerTimeString)
                        .font(.caption)
                        .bold()
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text("-\(max(0, displayDuration - displayTime).playerTimeString)")
                        .font(.caption)
                        .bold()
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                } else if isSeekActionAvailable && displayTime > 0 {
                    Text(displayTime.playerTimeString)
                        .font(.caption)
                        .bold()
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, horizontalPadding)
        }
        .padding(.bottom, bottomPadding)
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    @available(iOS 26.0, *)
    @ViewBuilder
    private func fullscreenGlassSeekbar(horizontalPadding: CGFloat, bottomPadding: CGFloat)
        -> some View
    {
        if isSeekActionAvailable {
            HStack(spacing: 14) {
                if displayDuration > 0 {
                    Text(displayTime.playerTimeString)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(width: 52, alignment: .leading)
                } else if displayTime > 0 {
                    Text(displayTime.playerTimeString)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(width: 52, alignment: .leading)
                }

                glassSeekTrack(trackHeight: playerState.isSeeking ? 8 : 6, showsThumb: false)

                if displayDuration > 0 {
                    Text("-\(max(0, displayDuration - displayTime).playerTimeString)")
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(width: 56, alignment: .trailing)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, bottomPadding)
            .contentShape(Rectangle())
            .onTapGesture {}
        }
    }

    @available(iOS 26.0, *)
    private func glassSeekTrack(trackHeight: CGFloat, showsThumb: Bool) -> some View {
        GeometryReader { geo in
            let progress = min(max(CGFloat(displayProgress), 0), 1)
            let availableWidth = max(geo.size.width, 1)
            let thumbSize = max(14, trackHeight + 8)
            let interactionHeight: CGFloat = 30

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.36))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(.white)
                    .frame(width: max(trackHeight, availableWidth * progress), height: trackHeight)

                if showsThumb {
                    Circle()
                        .fill(.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .position(x: availableWidth * progress, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                }

                Rectangle()
                    .fill(Color.clear)
                    .frame(width: availableWidth, height: interactionHeight)
                    .position(x: availableWidth / 2, y: geo.size.height / 2)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                updateScrub(
                                    relativeX: value.location.x,
                                    availableWidth: availableWidth
                                )
                            }
                            .onEnded { _ in
                                finishScrub()
                            }
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(
                .spring(response: 0.2, dampingFraction: 0.75),
                value: playerState.isSeeking)
        }
        .frame(height: 30)
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

    private func feedbackOverlays(height: CGFloat) -> some View {
        PlayerFeedbackOverlays(
            height: height,
            verticalSizeClass: verticalSizeClass,
            usesFullscreenPlayerLayout: usesFullscreenPlayerLayout,
            showControls: playerState.showControls,
            isSeekFeedbackVisible: isSeekFeedbackVisible,
            seekFeedbackText: seekFeedbackText,
            isVolumeFeedbackVisible: isVolumeFeedbackVisible,
            volumeFeedbackText: volumeFeedbackText,
            volumeIconName: volumeIconName,
            isCaptureFeedbackVisible: isCaptureFeedbackVisible,
            captureFeedbackText: captureFeedbackText,
            captureFeedbackSystemImage: captureFeedbackSystemImage,
            playbackErrorText: playbackErrorBannerText
        )
    }

    private var feedbackOverlayFont: Font {
        verticalSizeClass == .compact
            ? .headline.weight(.semibold)
            : .subheadline.weight(.semibold)
    }

    private var feedbackOverlayHorizontalPadding: CGFloat {
        verticalSizeClass == .compact ? 18 : 16
    }

    private var feedbackOverlayVerticalPadding: CGFloat {
        verticalSizeClass == .compact ? 9 : 8
    }

    private func seek(to seconds: Double) {
        guard isSeekActionAvailable, let player = playerState.player else { return }
        let current = playerState.playbackStatus.time
        let delta = seconds - current
        let clamped = min(max(0, seconds), max(displayDuration, 0))
        player.time = VLCTime(int: Int32((clamped * 1000).rounded()))
        showSeekFeedback(for: delta)
    }

    private func jump(seconds: Double) {
        guard isSeekActionAvailable, let player = playerState.player else { return }
        player.jump(withOffset: Int32(seconds) * 1000)
        showSeekFeedback(for: seconds)
    }

    private func seekToPosition(_ position: Float) {
        playerState.seek(to: position)
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

    @ViewBuilder
    private func playbackErrorOverlay(height: CGFloat) -> some View {
        if let message = playbackErrorBannerText {
            VStack {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(message)
                        .lineLimit(2)
                }
                .font(feedbackOverlayFont)
                .foregroundStyle(.white)
                .padding(.horizontal, feedbackOverlayHorizontalPadding)
                .padding(.vertical, feedbackOverlayVerticalPadding)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(.top, max(24, height * 0.12))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
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

    private func toggleLandscapeOrientationLock() {
        orientationToggleTask?.cancel()
        let shouldUnlock = isLandscapeOrientationLocked
        if !shouldUnlock && !PlayerOrientationController.shared.canRotateCurrentWindow {
            return
        }
        withAnimation(.easeInOut(duration: 0.28)) {
            orientationButtonRotation += 180
        }
        let task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            withAnimation {
                if shouldUnlock {
                    unlockLandscapeOrientation()
                } else {
                    if PlayerOrientationController.shared.lockLandscape() {
                        isLandscapeOrientationLocked = true
                    }
                }
            }
            orientationToggleTask = nil
        }
        orientationToggleTask = task
    }

    private func unlockLandscapeOrientation() {
        PlayerOrientationController.shared.unlockAndReturnToPortrait()
        isLandscapeOrientationLocked = false
    }
}

@MainActor
private struct VideoTapZonesOverlay: UIViewRepresentable {
    let onSingleTap: () -> Void
    let onBackwardDoubleTap: () -> Void
    let onForwardDoubleTap: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap)
        )
        singleTap.numberOfTapsRequired = 1

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)

        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onBackwardDoubleTap = onBackwardDoubleTap
        context.coordinator.onForwardDoubleTap = onForwardDoubleTap
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSingleTap: onSingleTap,
            onBackwardDoubleTap: onBackwardDoubleTap,
            onForwardDoubleTap: onForwardDoubleTap
        )
    }

    final class Coordinator: NSObject {
        var onSingleTap: () -> Void
        var onBackwardDoubleTap: () -> Void
        var onForwardDoubleTap: () -> Void

        init(
            onSingleTap: @escaping () -> Void,
            onBackwardDoubleTap: @escaping () -> Void,
            onForwardDoubleTap: @escaping () -> Void
        ) {
            self.onSingleTap = onSingleTap
            self.onBackwardDoubleTap = onBackwardDoubleTap
            self.onForwardDoubleTap = onForwardDoubleTap
        }

        @objc func handleSingleTap() {
            onSingleTap()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let x = recognizer.location(in: view).x
            let zoneWidth = view.bounds.width / 3
            if x < zoneWidth {
                onBackwardDoubleTap()
            } else if x > zoneWidth * 2 {
                onForwardDoubleTap()
            }
        }
    }
}

@MainActor
private struct PlayerFeedbackOverlays: View {
    let height: CGFloat
    let verticalSizeClass: UserInterfaceSizeClass?
    let usesFullscreenPlayerLayout: Bool
    let showControls: Bool
    let isSeekFeedbackVisible: Bool
    let seekFeedbackText: String
    let isVolumeFeedbackVisible: Bool
    let volumeFeedbackText: String
    let volumeIconName: String
    let isCaptureFeedbackVisible: Bool
    let captureFeedbackText: String
    let captureFeedbackSystemImage: String
    let playbackErrorText: String?

    var body: some View {
        ZStack {
            feedbackOverlay(isVisible: isSeekFeedbackVisible) {
                feedbackLabel(text: seekFeedbackText)
            }
            feedbackOverlay(isVisible: isVolumeFeedbackVisible) {
                feedbackLabel(text: volumeFeedbackText, systemImage: volumeIconName)
            }
            feedbackOverlay(isVisible: isCaptureFeedbackVisible) {
                feedbackLabel(
                    text: captureFeedbackText,
                    systemImage: captureFeedbackSystemImage,
                    iconTint: captureFeedbackText == "録画開始" ? .red : .white.opacity(0.94)
                )
            }
            playbackErrorOverlay
        }
        .allowsHitTesting(false)
    }

    private var feedbackOverlayFont: Font {
        verticalSizeClass == .compact
            ? .headline.weight(.semibold)
            : .subheadline.weight(.semibold)
    }

    private var feedbackOverlayHorizontalPadding: CGFloat {
        verticalSizeClass == .compact ? 18 : 16
    }

    private var feedbackOverlayVerticalPadding: CGFloat {
        verticalSizeClass == .compact ? 9 : 8
    }

    private var feedbackOverlayTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }

    private func feedbackOverlayTopPadding() -> CGFloat {
        if showControls {
            if usesFullscreenPlayerLayout {
                return min(max(80, height * 0.14), 120)
            }
            return min(max(56, height * 0.22), 72)
        }

        if usesFullscreenPlayerLayout {
            return min(max(42, height * 0.08), 72)
        }
        return min(max(20, height * 0.10), 34)
    }

    @ViewBuilder
    private func feedbackOverlay<Content: View>(
        isVisible: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if isVisible {
            VStack {
                content()
                    .padding(.top, feedbackOverlayTopPadding())
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(feedbackOverlayTransition)
        }
    }

    @ViewBuilder
    private func feedbackLabel(
        text: String,
        systemImage: String? = nil,
        iconTint: Color = .white.opacity(0.94)
    ) -> some View {
        let label = HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconTint)
            }

            Text(text)
                .lineLimit(1)
        }
        .font(feedbackOverlayFont)
        .foregroundStyle(.white)
        .padding(.horizontal, feedbackOverlayHorizontalPadding)
        .padding(.vertical, feedbackOverlayVerticalPadding)
        .frame(minHeight: verticalSizeClass == .compact ? 38 : 34)
        .shadow(color: .black.opacity(0.28), radius: 4, y: 1)

        if #available(iOS 26, *) {
            label
                .glassEffect(.regular, in: .capsule)
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
    private var playbackErrorOverlay: some View {
        if let playbackErrorText {
            VStack {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(playbackErrorText)
                        .lineLimit(2)
                }
                .font(feedbackOverlayFont)
                .foregroundStyle(.white)
                .padding(.horizontal, feedbackOverlayHorizontalPadding)
                .padding(.vertical, feedbackOverlayVerticalPadding)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(.top, feedbackOverlayTopPadding())
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(feedbackOverlayTransition)
        }
    }
}

struct PlayerInfoSheet: View {
    let playable: Playable?
    @Binding var isVisible: Bool
    @State private var dragOffset: CGFloat = 0
    @State private var didTriggerScrollDismiss = false
    private let headerHeight: CGFloat = 78
    private let contentTopPadding: CGFloat = 78
    private let scrollDismissThreshold: CGFloat = 100
    private let sheetCornerRadius: CGFloat = 50

    var body: some View {
        if #available(iOS 26, *) {
            infoSheetContent
                .clipShape(RoundedRectangle(cornerRadius: sheetCornerRadius, style: .continuous))
                .glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: sheetCornerRadius, style: .continuous)
                )
                .offset(y: max(0, dragOffset))
        } else {
            infoSheetContent
                .background(Color.kiririnSystemBackground)
                .clipShape(.rect(topLeadingRadius: 16, topTrailingRadius: 16))
                .offset(y: max(0, dragOffset))
        }
    }

    private var infoSheetContent: some View {
        ZStack(alignment: .top) {
            ScrollView {
                PlayerInfoSheetPullDismissObserver { pullDistance in
                    handleScrollPullDistance(pullDistance)
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

                content
                    .padding(.horizontal, 16)
                    .padding(.top, contentTopPadding)
                    .padding(.bottom, 32)
            }

            infoSheetHeader
        }
    }

    private var infoSheetHeader: some View {
        ZStack(alignment: .top) {
            infoSheetHeaderBackdrop

            Capsule()
                .fill(Color.kiririnTertiaryLabel)
                .frame(width: 36, height: 5)
                .padding(.top, 6)

            HStack {
                dismissButton
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            Text("番組詳細")
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
                .padding(.top, 36)
        }
        .frame(height: headerHeight)
        .contentShape(Rectangle())
        .gesture(dismissDragGesture)
    }

    private var infoSheetHeaderBackdrop: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                Color.kiririnSystemBackground.opacity(0.22)
            }
            .frame(height: headerHeight)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.74),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var dismissButton: some View {
        Button {
            dismiss()
        } label: {
            if #available(iOS 26, *) {
                Image(systemName: "xmark")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.accent)
                    .frame(width: 48, height: 48)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .contentShape(.circle)
            } else {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Color.kiririnTertiarySystemFill, in: Circle())
                    .contentShape(.circle)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("閉じる")
    }

    @ViewBuilder
    private var content: some View {
        if let program = playable?.displayProgram {
            ProgramInfoContentView(
                program: program,
                serviceName: playable?.serviceName,
                showsCopyContextMenu: true
            )
        } else {
            VStack(alignment: .leading, spacing: 12) {
                BroadcastText(playable?.title ?? "", style: .title3, weight: .bold)

                if let sub = playable?.subtitle,
                    !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    BroadcastText(sub, style: .subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if value.translation.height > 0 {
                    dragOffset = value.translation.height
                }
            }
            .onEnded { value in
                let velocity = value.predictedEndLocation.y - value.location.y
                if value.translation.height > 80 || velocity > 200 {
                    dismiss()
                } else {
                    withAnimation(.interpolatingSpring(stiffness: 300, damping: 28)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func handleScrollPullDistance(_ distance: CGFloat) {
        guard !didTriggerScrollDismiss, distance > scrollDismissThreshold else { return }
        didTriggerScrollDismiss = true
        dismiss()
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isVisible = false
            dragOffset = 0
        }
    }
}

private struct PlayerInfoSheetPullDismissObserver: UIViewRepresentable {
    var onPullDistanceChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            context.coordinator.attach(to: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPullDistanceChange = onPullDistanceChange
        DispatchQueue.main.async {
            context.coordinator.attach(to: uiView)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPullDistanceChange: onPullDistanceChange)
    }

    final class Coordinator {
        var onPullDistanceChange: (CGFloat) -> Void
        private weak var scrollView: UIScrollView?
        private var contentOffsetObservation: NSKeyValueObservation?

        init(onPullDistanceChange: @escaping (CGFloat) -> Void) {
            self.onPullDistanceChange = onPullDistanceChange
        }

        func attach(to view: UIView) {
            guard let scrollView = view.enclosingScrollView() else { return }
            guard self.scrollView !== scrollView else { return }
            detach()
            self.scrollView = scrollView
            contentOffsetObservation = scrollView.observe(
                \.contentOffset,
                options: [.new]
            ) { [weak self, weak scrollView] _, _ in
                guard let self, let scrollView else { return }
                self.reportPullDistance(in: scrollView)
            }
            reportPullDistance(in: scrollView)
        }

        func detach() {
            contentOffsetObservation?.invalidate()
            contentOffsetObservation = nil
            scrollView = nil
        }

        private func reportPullDistance(in scrollView: UIScrollView) {
            let topOffset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            onPullDistanceChange(max(0, -topOffset))
        }
    }
}

extension UIView {
    fileprivate func enclosingScrollView() -> UIScrollView? {
        var current: UIView? = self
        while let view = current {
            if let scrollView = view as? UIScrollView {
                return scrollView
            }
            current = view.superview
        }
        return nil
    }
}

private struct CollapsedBarReservedHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 96
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct PlayerInfoSheetCollapsedBar: View {
    let onTap: () -> Void
    var onReservedHeightChange: ((CGFloat) -> Void)? = nil

    private static let capsuleBottomPadding: CGFloat = 64
    private static let coordinateSpaceName = "PlayerInfoSheetCollapsedBar"

    var body: some View {
        GeometryReader { outerGeo in
            VStack(spacing: 8) {
                Spacer()

                Button(action: onTap) {
                    Label("番組情報を開く", systemImage: "chevron.up")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .background(
                    GeometryReader { buttonGeo in
                        Color.clear.preference(
                            key: CollapsedBarReservedHeightPreferenceKey.self,
                            value: outerGeo.size.height
                                - buttonGeo.frame(in: .named(Self.coordinateSpaceName)).minY
                        )
                    }
                )
                .padding(.bottom, Self.capsuleBottomPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onPreferenceChange(CollapsedBarReservedHeightPreferenceKey.self) { height in
            onReservedHeightChange?(height)
        }
    }
}

private struct LowerContextPluginsView: View {
    let pluginStore: PluginStore
    @State var playerState: PlayerState
    let appModel: AppModel
    @Binding var selectedPluginID: UUID?
    let collapsedBarReservedHeight: CGFloat
    private let pluginSwitcherHeight: CGFloat = 52
    private let pluginSwitcherBottomPadding: CGFloat = 52
    private let singlePluginTooltipGap: CGFloat = 32

    private var enabledPlugins: [PluginDefinition] {
        pluginStore.plugins.filter { $0.isEnabled && $0.supports(area: .panel) }
    }

    private var selectedPlugin: PluginDefinition? {
        enabledPlugins.first { $0.id == selectedPluginID }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let plugin = selectedPlugin {
                    LowerContextPluginPanel(
                        plugin: plugin,
                        playerState: playerState,
                        appModel: appModel,
                        safeAreaInsets: panelSafeAreaInsets(
                            containerSafeAreaInsets: geo.safeAreaInsets)
                    )
                    .id(plugin.id)
                } else {
                    ContentUnavailableView(
                        "有効なプラグインがありません",
                        systemImage: "puzzlepiece.extension",
                        description: Text("設定からプラグインを追加または有効にしてください")
                    )
                }

                if enabledPlugins.count > 1 {
                    VStack {
                        Spacer()
                        pluginSwitcher
                            .padding(.horizontal)
                            .padding(.bottom, pluginSwitcherBottomPadding)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("")
    }

    private func panelSafeAreaInsets(containerSafeAreaInsets: EdgeInsets)
        -> PluginSafeAreaInsets
    {
        let additionalBottomInset =
            enabledPlugins.count > 1
            ? containerSafeAreaInsets.bottom
            : singlePluginTooltipGap
        let bottomInset = collapsedBarReservedHeight + additionalBottomInset
        return PluginSafeAreaInsets(
            top: containerSafeAreaInsets.top,
            right: containerSafeAreaInsets.trailing,
            bottom: bottomInset,
            left: containerSafeAreaInsets.leading
        )
    }

    private var pluginSwitcher: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .font(.headline)
                .foregroundStyle(.secondary)

            Picker("プラグイン切り替え", selection: $selectedPluginID) {
                ForEach(enabledPlugins) { plugin in
                    Text(plugin.name).tag(Optional(plugin.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tint(.primary)
        }
        .padding(.horizontal, 18)
        .frame(height: pluginSwitcherHeight)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.kiririnSeparator.opacity(0.35), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
    }
}

private struct LowerContextPluginPanel: View {
    let plugin: PluginDefinition
    @State var playerState: PlayerState
    let appModel: AppModel
    let safeAreaInsets: PluginSafeAreaInsets

    var body: some View {
        PluginOverlayView(
            pluginDefinition: plugin,
            appModel: appModel,
            reloadToken: playerState.pluginReloadToken
                + playerState.perPluginReloadTokens[plugin.id.uuidString, default: 0],
            displayArea: .panel,
            playerID: playerState.id,
            safeAreaInsets: safeAreaInsets
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.kiririnSecondarySystemBackground)
        .ignoresSafeArea(edges: .bottom)
    }
}

private struct PlayerOverlayPreview: View {
    @State private var playerState: PlayerState
    private let appModel = AppModel.shared

    init(isSeekable: Bool) {
        _playerState = State(initialValue: Self.makePlayerState(isSeekable: isSeekable))
    }

    private static func makePlayerState(isSeekable: Bool) -> PlayerState {
        let state = PlayerState()
        state.mode = .fullscreen
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
        playable.isSeekable = isSeekable
        playable.length = previewProgramDuration
        state.currentPlayable = playable
        state.nextProgram = mockNextProgram()
        state.playbackStatus = PlayerPlaybackStatus(
            playableID: playable.id,
            isPlaying: true,
            time: previewProgramDuration * 0.8,
            position: 0.8
        )
        state.player = PreviewVLCMediaPlayer(isSeekable: isSeekable)
        return state
    }

    var body: some View {
        PlayerOverlayView_iOS(
            playerState: playerState,
            manager: appModel.manager,
            pluginStore: appModel.pluginStore,
            appModel: appModel
        )
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
        Program(
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
        Program(
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

private final class PreviewVLCMediaPlayer: VLCMediaPlayer {
    private let previewIsSeekable: Bool

    init(isSeekable: Bool) {
        previewIsSeekable = isSeekable
        super.init()
    }

    override var isSeekable: Bool { previewIsSeekable }
}

#Preview("Seekable") {
    PlayerOverlayPreview(isSeekable: true)
}

#Preview("Not Seekable") {
    PlayerOverlayPreview(isSeekable: false)
}
