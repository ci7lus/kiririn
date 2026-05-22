#if !os(macOS)
    import SwiftUI
    import Combine
    import UIKit
    import VLCKit
    import OrderedCollections

    @MainActor
    struct PlayerOverlayView: View {
        private enum MiniPlayerCorner {
            case topLeading
            case topTrailing
            case bottomLeading
            case bottomTrailing
        }

        @State var playerState: PlayerState
        @Environment(\.verticalSizeClass) private var verticalSizeClass
        #if os(macOS)
            @Environment(\.openWindow) private var openWindow
        #endif
        let manager: BackendManager
        let pluginStore: PluginStore
        let appModel: AppModel
        let showsLowerContext: Bool
        @State private var dragOffset: CGFloat = 0
        @State private var infoDragOffset: CGFloat = 0
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

        init(
            playerState: PlayerState,
            manager: BackendManager,
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
                        if verticalSizeClass == .compact {
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
                infoDragOffset = 0
                withAnimation(.easeOut(duration: 0.22)) {
                    isInfoSheetVisible = true
                }

            }
            .onChange(of: playerState.availablePanelPlugins.map(\.id)) {
                ensureLowerTabSelection()
            }
            .onChange(of: playerState.mode) { oldMode, newMode in
                infoDragOffset = 0
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
                let frame = playerSurfaceFrame(in: geo)
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
        }

        private func playerSurfaceFrame(in geo: GeometryProxy) -> CGRect {
            switch playerState.mode {
            case .expanded:
                if verticalSizeClass == .compact {
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
                if verticalSizeClass == .compact {
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
                                infoSheet
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                                    .ignoresSafeArea()
                            } else {
                                infoSheetCollapsedBar
                            }
                        }
                    }

                    VStack(spacing: 0) {
                        ZStack(alignment: .top) {
                            videoArea(width: geo.size.width, height: videoHeight)

                            videoControlsOverlay(width: geo.size.width, height: videoHeight)
                                .opacity(playerState.showControls && dragOffset == 0 ? 1 : 0)
                                .allowsHitTesting(playerState.showControls && dragOffset == 0)
                        }

                        if isSeekActionAvailable && !(playerState.showControls && dragOffset == 0) {
                            GeometryReader { pGeo in
                                ZStack(alignment: .leading) {
                                    Color.gray.opacity(0.3)
                                    Color.blue
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
                }
            }
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
        private func videoArea(width: CGFloat, height: CGFloat) -> some View {
            ZStack {
                Group {
                    if playerState.player == nil {
                        Color.black
                    } else {
                        Color.clear
                    }
                }
                .frame(width: width, height: height)

                if playerState.player == nil {
                    ProgressView()
                        .tint(.white)
                }

                videoTapZonesOverlay(width: width, height: height)
                    .allowsHitTesting(!playerState.showControls)

                seekFeedbackOverlay(height: height)
                volumeFeedbackOverlay(height: height)
                captureFeedbackOverlay(height: height)
                playbackErrorOverlay(height: height)

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

                videoControlsOverlay(width: width, height: height)
                    .opacity(playerState.showControls && dragOffset == 0 ? 1 : 0)
                    .allowsHitTesting(playerState.showControls && dragOffset == 0)

            }
            .frame(width: width, height: height)
            .clipped()
            .animation(.easeInOut(duration: 0.2), value: playerState.showControls)
        }

        @ViewBuilder
        private func floatingOrientationLockButton(geo: GeometryProxy) -> some View {
            if showsOrientationLockButton {
                let frame = playerSurfaceFrame(in: geo)
                let bottomInset =
                    usesFullscreenPlayerLayout
                    ? max(geo.safeAreaInsets.bottom + 2, 2)
                    : 2
                orientationLockButton
                    .position(
                        x: frame.maxX - 30,
                        y: frame.maxY - bottomInset - 22
                    )
                    .transition(.opacity)
                    .zIndex(10)
                    .animation(.easeInOut(duration: 0.28), value: geo.size)
                    .animation(.easeInOut(duration: 0.28), value: verticalSizeClass)
                    .animation(.easeInOut(duration: 0.2), value: playerState.showControls)
            }
        }

        @ViewBuilder
        private func videoControlsOverlay(width: CGFloat, height: CGFloat) -> some View {
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { playerState.tapControls() }

                Color.black.opacity(0.2)
                    .allowsHitTesting(false)

                if isSeekActionAvailable && displayDuration > 0 {
                    HStack(spacing: 48) {
                        Button {
                            seekBackward()
                        } label: {
                            Image(systemName: "gobackward.10")
                                .font(.system(size: 32, weight: .medium))
                                .foregroundStyle(.white)
                        }.keyboardShortcut(.leftArrow, modifiers: [])

                        Button {
                            playerState.togglePlayPause()
                        } label: {
                            Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 48, weight: .bold))
                                .foregroundStyle(.white)
                        }.keyboardShortcut(.space, modifiers: [])

                        Button {
                            seekForward()
                        } label: {
                            Image(systemName: "goforward.10")
                                .font(.system(size: 32, weight: .medium))
                                .foregroundStyle(.white)
                        }.keyboardShortcut(.rightArrow, modifiers: [])
                    }
                } else {
                    Button {
                        playerState.togglePlayPause()
                    } label: {
                        Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 48, weight: .bold))
                            .foregroundStyle(.white)
                    }.keyboardShortcut(.space, modifiers: [])
                }

                VStack {
                    HStack(spacing: 8) {
                        if showsLowerContext {
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    playerState.collapse()
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                            }
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
        private func videoTapZonesOverlay(width: CGFloat, height: CGFloat) -> some View {
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { handleSingleTapInVideoArea() }
                    .onTapGesture(count: 2) {
                        handleDoubleTapInVideoArea {
                            seekBackward()
                        }
                    }

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { handleSingleTapInVideoArea() }

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { handleSingleTapInVideoArea() }
                    .onTapGesture(count: 2) {
                        handleDoubleTapInVideoArea {
                            seekForward()
                        }
                    }
            }
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
        private func seekFeedbackOverlay(height: CGFloat) -> some View {
            if isSeekFeedbackVisible {
                VStack {
                    Text(seekFeedbackText)
                        .font(feedbackOverlayFont)
                        .foregroundStyle(.white)
                        .padding(.horizontal, feedbackOverlayHorizontalPadding)
                        .padding(.vertical, feedbackOverlayVerticalPadding)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(.top, max(24, height * 0.22))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: isSeekFeedbackVisible)
                .allowsHitTesting(false)
            }
        }

        @ViewBuilder
        private var infoSheet: some View {
            VStack(spacing: 0) {
                ZStack {
                    Capsule()
                        .fill(Color.kiririnTertiaryLabel)
                        .frame(width: 36, height: 5)

                    HStack {
                        Spacer()
                        Button {
                            dismissInfoSheet()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                                .background(Color.kiririnTertiarySystemFill, in: Circle())
                        }
                        .padding(.trailing, 16)
                    }
                }
                .frame(height: 44)
                .contentShape(Rectangle())
                .gesture(infoSheetDismissDragGesture)

                ScrollView {
                    programInfoContent
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                }
            }
            .background(Color.kiririnSystemBackground)
            .clipShape(.rect(topLeadingRadius: 16, topTrailingRadius: 16))
            .offset(y: max(0, infoDragOffset))
        }

        private func dismissInfoSheet() {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isInfoSheetVisible = false
                infoDragOffset = 0
            }
        }

        private var infoSheetDismissDragGesture: some Gesture {
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    if value.translation.height > 0 {
                        infoDragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    let velocity = value.predictedEndLocation.y - value.location.y
                    if value.translation.height > 80 || velocity > 200 {
                        dismissInfoSheet()
                    } else {
                        withAnimation(.interpolatingSpring(stiffness: 300, damping: 28)) {
                            infoDragOffset = 0
                        }
                    }
                }
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

                NavigationStack {
                    CaptureListView(
                        showsNavigationTitle: false,
                        showsSearch: false,
                        playerState: playerState
                    )
                }
                .tag("capture")
                .tabItem {
                    Label("キャプチャ", systemImage: "photo.on.rectangle.angled")
                }

                NavigationStack {
                    LowerContextPluginsView(
                        pluginStore: pluginStore,
                        playerState: playerState,
                        appModel: appModel,
                        selectedPluginID: $selectedPluginID
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
            let validTags = ["caption", "capture", "plugin"]
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
            VStack(spacing: 8) {
                Spacer()

                Button {
                    withAnimation(.easeOut(duration: 0.22)) {
                        isInfoSheetVisible = true
                    }
                } label: {
                    Label("情報を開く", systemImage: "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.bottom, 64)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

        private var programInfoContent: some View {
            Group {
                if let program = playerState.displayProgram {
                    ProgramInfoContentView(
                        program: program,
                        serviceName: playerState.currentPlayable?.serviceName,
                        showsCopyContextMenu: true
                    )
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        BroadcastText(playerState.currentPlayable?.title ?? "")
                            .font(.title3)
                            .fontWeight(.bold)

                        if let sub = playerState.currentPlayable?.subtitle,
                            !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            BroadcastText(sub)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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
                        ProgressView()
                            .tint(.white)
                    } else {
                        Color.black.opacity(0.001)
                    }

                    Color.black.opacity(0.001)

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
                                        Image(systemName: "xmark")
                                            .font(.title2)
                                            .fontWeight(.bold)
                                            .foregroundStyle(.white)
                                            .frame(width: 44, height: 44)
                                            .background(.black.opacity(0.35), in: Circle())
                                    }
                                    .buttonStyle(.plain)

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
                                Image(
                                    systemName: playerState.isPlaying ? "pause.fill" : "play.fill"
                                )
                                .font(.system(size: 40, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 82, height: 82)
                                .background(.black.opacity(0.35), in: Circle())
                            }
                            .buttonStyle(.plain)

                            VStack {
                                Spacer()
                                VStack(alignment: .leading, spacing: 2) {
                                    BroadcastText(playerState.currentPlayable?.title ?? "")
                                        .font(.caption)
                                        .fontWeight(.semibold)
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

                seekFeedbackOverlay(height: geo.size.height)
                    .ignoresSafeArea()
                volumeFeedbackOverlay(height: geo.size.height)
                    .ignoresSafeArea()
                captureFeedbackOverlay(height: geo.size.height)
                    .ignoresSafeArea()
                playbackErrorOverlay(height: geo.size.height)
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
        private func fullscreenControlsOverlay(geo: GeometryProxy) -> some View {
            let isPortraitFullscreen = geo.size.height > geo.size.width
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { playerState.tapControls() }

                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                if isSeekActionAvailable && displayDuration > 0 {
                    HStack(spacing: 32) {
                        Button {
                            seekBackward()
                        } label: {
                            Image(systemName: "gobackward.10")
                                .font(.system(size: 40, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 62, height: 62)
                        }

                        Button {
                            playerState.togglePlayPause()
                        } label: {
                            Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 56, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 84, height: 84)
                        }

                        Button {
                            seekForward()
                        } label: {
                            Image(systemName: "goforward.10")
                                .font(.system(size: 40, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 62, height: 62)
                        }
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
                }

                VStack {
                    if isPortraitFullscreen {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                BroadcastText(playerState.currentPlayable?.title ?? "")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                if let sub = playerState.currentPlayable?.subtitle,
                                    !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                {
                                    BroadcastText(sub)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.7))
                                        .lineLimit(1)
                                }
                            }

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
                            VStack(alignment: .leading, spacing: 2) {
                                BroadcastText(playerState.currentPlayable?.title ?? "")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                if let sub = playerState.currentPlayable?.subtitle,
                                    !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                {
                                    BroadcastText(sub)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.7))
                                        .lineLimit(1)
                                }
                            }
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

                    Spacer()

                    fullscreenSeekbar(
                        horizontalPadding: 16,
                        bottomPadding: 16
                    )
                }

            }
        }

        private var orientationLockButton: some View {
            Button {
                toggleLandscapeOrientationLock()
            } label: {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .padding(6)
                    .rotationEffect(.degrees(orientationButtonRotation))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel(
                isLandscapeOrientationLocked
                    ? "横画面固定を解除して縦画面に戻す" : "横画面に固定"
            )
        }

        @ViewBuilder
        private func topRightControlButtons(isFullscreen: Bool, showsFullscreenToggle: Bool = true)
            -> some View
        {
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
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                }
            }

            Button {
                playerState.setSubtitleEnabled(!playerState.isSubtitleEnabled)
            } label: {
                Image(
                    systemName: playerState.isSubtitleEnabled
                        ? "captions.bubble.fill" : "captions.bubble"
                )
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
            }

            if playerState.isPipAvailable {
                Button {
                    playerState.togglePip()
                } label: {
                    Image(systemName: playerState.isPipEnabled ? "pip.exit" : "pip.enter")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
            }

            Button {
                playerState.takeCapture()
            } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .keyboardShortcut("s", modifiers: .command)

            Button {
                playerState.toggleRecording()
            } label: {
                Image(systemName: playerState.isRecording ? "record.circle.fill" : "record.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(playerState.isRecording ? .red : .white)
                    .frame(width: 44, height: 44)
            }
            .keyboardShortcut("r", modifiers: .command)

            Menu {
                playerPlaybackOptionMenuEntries(
                    playerState: playerState,
                    isSeekActionAvailable: isSeekActionAvailable
                )
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }

        private func seekForward() {
            guard isSeekActionAvailable else { return }
            jump(seconds: 10)
        }

        private func seekBackward() {
            guard isSeekActionAvailable else { return }
            jump(seconds: -10)
        }

        @ViewBuilder
        private func seekBarOverlay(horizontalPadding: CGFloat, bottomPadding: CGFloat) -> some View
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
                        let progress = CGFloat(displayProgress)
                        let availableWidth = geo.size.width - horizontalPadding * 2

                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.clear)
                                .frame(width: availableWidth, height: interactionHeight)
                                .position(
                                    x: horizontalPadding + availableWidth / 2,
                                    y: geo.size.height / 2 + 8
                                )
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 8)
                                        .onChanged { value in
                                            if !playerState.isSeeking {
                                                initialScrubPosition =
                                                    playerState.playbackStatus.position
                                                initialScrubTime = playerState.playbackStatus.time
                                            }
                                            playerState.isSeeking = true
                                            let relativeX = value.location.x
                                            let newProgress = min(
                                                max(0, relativeX / availableWidth), 1)
                                            scrubPosition = Float(newProgress)
                                            seekToPosition(Float(newProgress))
                                        }
                                        .onEnded { _ in
                                            if playerState.isSeeking, let scrub = scrubPosition {
                                                seekToPosition(scrub)
                                            }
                                            playerState.isSeeking = false
                                            scrubPosition = nil
                                            initialScrubPosition = nil
                                            initialScrubTime = nil
                                        }
                                )

                            Capsule()
                                .fill(Color.blue)
                                .frame(
                                    width: max(0, availableWidth * progress), height: trackHeight
                                )
                                .padding(.leading, horizontalPadding)
                                .offset(y: 8)
                                .allowsHitTesting(false)

                            Circle()
                                .fill(Color.blue)
                                .frame(width: thumbSize, height: thumbSize)
                                .shadow(radius: 2)
                                .position(
                                    x: horizontalPadding + availableWidth * progress,
                                    y: geo.size.height / 2 + 8
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
        private func fullscreenSeekbar(horizontalPadding: CGFloat, bottomPadding: CGFloat)
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
                                            if !playerState.isSeeking {
                                                initialScrubPosition =
                                                    playerState.playbackStatus.position
                                                initialScrubTime = playerState.playbackStatus.time
                                            }
                                            playerState.isSeeking = true
                                            let relativeX = value.location.x
                                            let newProgress = min(
                                                max(0, relativeX / availableWidth), 1)
                                            scrubPosition = Float(newProgress)
                                            seekToPosition(Float(newProgress))
                                        }
                                        .onEnded { _ in
                                            if playerState.isSeeking, let scrub = scrubPosition {
                                                seekToPosition(scrub)
                                            }
                                            playerState.isSeeking = false
                                            scrubPosition = nil
                                            initialScrubPosition = nil
                                            initialScrubTime = nil
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
                            .padding(.trailing, showsOrientationLockButton ? 60 : 0)
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

        private var feedbackOverlayFont: Font {
            verticalSizeClass == .compact
                ? .title2.weight(.bold)
                : .title3.weight(.semibold)
        }

        private var feedbackOverlayHorizontalPadding: CGFloat {
            verticalSizeClass == .compact ? 20 : 16
        }

        private var feedbackOverlayVerticalPadding: CGFloat {
            verticalSizeClass == .compact ? 10 : 8
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
            guard let player = playerState.player else { return }
            player.position = Double(position)
        }

        private func showVolumeFeedback() {
            if playerState.isMuted {
                volumeFeedbackText = "ミュート"
            } else {
                volumeFeedbackText = "音量: \(Int(playerState.volume.rounded()))%"
            }
            volumeFeedbackHideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.18)) {
                isVolumeFeedbackVisible = true
            }
            let task = DispatchWorkItem {
                withAnimation(.easeInOut(duration: 0.24)) {
                    isVolumeFeedbackVisible = false
                }
            }
            volumeFeedbackHideTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: task)
        }

        @ViewBuilder
        private func captureFeedbackOverlay(height: CGFloat) -> some View {
            if isCaptureFeedbackVisible {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: captureFeedbackSystemImage)
                            .foregroundStyle(captureFeedbackText == "録画開始" ? .red : .white)
                        Text(captureFeedbackText)
                    }
                    .font(feedbackOverlayFont)
                    .foregroundStyle(.white)
                    .padding(.horizontal, feedbackOverlayHorizontalPadding)
                    .padding(.vertical, feedbackOverlayVerticalPadding)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(.top, max(24, height * 0.22))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: isCaptureFeedbackVisible)
                .allowsHitTesting(false)
            }
        }

        @ViewBuilder
        private func volumeFeedbackOverlay(height: CGFloat) -> some View {
            if isVolumeFeedbackVisible {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: volumeIconName)
                        Text(volumeFeedbackText)
                    }
                    .font(feedbackOverlayFont)
                    .foregroundStyle(.white)
                    .padding(.horizontal, feedbackOverlayHorizontalPadding)
                    .padding(.vertical, feedbackOverlayVerticalPadding)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(.top, max(24, height * 0.22))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: isVolumeFeedbackVisible)
                .allowsHitTesting(false)
            }
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
            withAnimation(.easeInOut(duration: 0.18)) {
                isCaptureFeedbackVisible = true
            }
            let task = DispatchWorkItem {
                withAnimation(.easeInOut(duration: 0.24)) {
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
            withAnimation(.easeInOut(duration: 0.18)) {
                isSeekFeedbackVisible = true
            }
            let task = DispatchWorkItem {
                withAnimation(.easeInOut(duration: 0.24)) {
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

    private struct LowerContextPluginsView: View {
        let pluginStore: PluginStore
        @State var playerState: PlayerState
        let appModel: AppModel
        @Binding var selectedPluginID: UUID?

        private var enabledPlugins: [PluginDefinition] {
            pluginStore.plugins.filter { $0.isEnabled && $0.supports(area: .panel) }
        }

        private var selectedPlugin: PluginDefinition? {
            enabledPlugins.first { $0.id == selectedPluginID }
        }

        var body: some View {
            ZStack {
                if let plugin = selectedPlugin {
                    LowerContextPluginPanel(
                        plugin: plugin, playerState: playerState, appModel: appModel
                    )
                    .id(plugin.id)
                } else {
                    ContentUnavailableView(
                        "有効なプラグインなし",
                        systemImage: "puzzlepiece.extension",
                        description: Text("設定からプラグインを追加または有効にしてください")
                    )
                }

                if enabledPlugins.count > 1 {
                    VStack {
                        Spacer()
                        pluginSwitcher
                            .padding(.horizontal)
                            .padding(.bottom, 20)
                    }
                }
            }
            .navigationTitle("")
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
            .frame(height: 52)
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

        var body: some View {
            PluginOverlayView(
                pluginDefinition: plugin,
                appModel: appModel,
                reloadToken: playerState.pluginReloadToken
                    + playerState.perPluginReloadTokens[plugin.id.uuidString, default: 0],
                displayArea: .panel,
                playerID: playerState.id
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.kiririnSecondarySystemBackground)
        }
    }
#endif
