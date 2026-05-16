import SwiftUI
import UniformTypeIdentifiers

#if !os(macOS)
    import UIKit
#endif

struct ContentView: View {
    let appModel: AppModel

    @State private var isLoadingIndicatorVisible = false
    @State private var loadingIndicatorHideTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    #if !os(macOS)
        @Environment(\.verticalSizeClass) private var verticalSizeClass
        @State private var showingFilePicker = false
    #endif

    private var configStore: BackendConfigStore { appModel.configStore }
    private var manager: BackendManager { appModel.manager }
    private var playerState: PlayerState { appModel.playerState }
    private var pluginStore: PluginStore { appModel.pluginStore }

    var body: some View {
        ZStack {
            TabView {
                Tab("放送中", systemImage: "tv") {
                    NavigationStack {
                        ServiceListView(manager: manager, playerState: playerState)
                    }
                }

                Tab("番組表", systemImage: "calendar") {
                    NavigationStack {
                        ProgramGuideView(manager: manager, playerState: playerState)
                    }
                }

                Tab("録画", systemImage: "film.stack") {
                    NavigationStack {
                        RecordsListView(
                            manager: manager,
                            searchText: Bindable(appModel).recordingsSearchText,
                            showsNavigationTitle: true,
                            showsSearch: true,
                            playerState: playerState
                        )
                    }
                }

                Tab("キャプチャ", systemImage: "photo.on.rectangle.angled") {
                    NavigationStack {
                        CaptureListView(
                            showsNavigationTitle: true,
                            showsSearch: true,
                            playerState: playerState
                        )
                    }
                }

                Tab("設定", systemImage: "gear") {
                    NavigationStack {
                        SettingsView(
                            configStore: configStore,
                            manager: manager,
                            appModel: appModel,
                            pluginStore: pluginStore,
                            playerState: playerState
                        )
                    }
                }
            }
            #if !os(macOS)
                .opacity(playerState.isActive && playerState.mode == .fullscreen ? 0 : 1)
            #endif
            .tabViewStyle(.sidebarAdaptable)

            #if !os(macOS)
                if playerState.player != nil {
                    PlayerOverlayView(
                        playerState: playerState, manager: manager, pluginStore: pluginStore,
                        appModel: appModel
                    )
                    .ignoresSafeArea(edges: verticalSizeClass == .compact ? [.top, .bottom] : [])
                    .opacity(playerState.isActive ? 1 : 0)
                    .allowsHitTesting(playerState.isActive)
                    .accessibilityHidden(!playerState.isActive)
                    .zIndex(1)
                }
            #endif

            if isLoadingIndicatorVisible && !playerState.isActive {
                VStack {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("データ取得中…")
                            .font(.footnote)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.kiririnSeparator.opacity(0.35), lineWidth: 0.8)
                    }
                    .padding(.top, 8)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .transition(.opacity)
                .zIndex(2)
                .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: playerState.isActive)
        .onAppear {
            isLoadingIndicatorVisible = manager.isDataLoading
        }
        .onChange(of: manager.isDataLoading) { _, isLoading in
            loadingIndicatorHideTask?.cancel()
            loadingIndicatorHideTask = nil

            if isLoading {
                isLoadingIndicatorVisible = true
            } else {
                loadingIndicatorHideTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    if !manager.isDataLoading {
                        isLoadingIndicatorVisible = false
                    }
                    loadingIndicatorHideTask = nil
                }
            }
        }
        .onDisappear {
            loadingIndicatorHideTask?.cancel()
            loadingIndicatorHideTask = nil
        }
        .task {
            appModel.setupIfNeeded()
            appModel.syncPluginsToPlayer()
        }
        .onChange(of: pluginStore.plugins) { _, _ in
            appModel.syncPluginsToPlayer()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            if playerState.isPipEnabled {
                playerState.isPipEnabled = false
            }
            Task {
                await manager.handleAppDidBecomeActive()
            }
        }
        .onOpenURL { url in
            appModel.handleDeepLink(url: url)
        }
        #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: .requestOpenPlayable)) {
                notification in
                guard let playable = notification.object as? Playable else { return }
                openWindow(id: AppWindowID.player.rawValue, value: playable)
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestOpenPluginWindow)) {
                notification in
                guard let pluginID = notification.object as? UUID else { return }
                openWindow(id: AppWindowID.plugin.rawValue, value: pluginID)
            }
        #endif
        #if !os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: .requestOpenFile)) { _ in
                showingFilePicker = true
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.userDidTakeScreenshotNotification)
            ) { _ in
                guard playerState.player != nil else { return }
                playerState.takeCapture()
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [
                    .movie, .video, .mpeg2TransportStream, .mpeg4Movie, .quickTimeMovie,
                    .audiovisualContent,
                ],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
        #endif
    }

    #if !os(macOS)
        private func handleFileImport(_ result: Result<[URL], Error>) {
            guard case .success(let urls) = result,
                let fileURL = urls.first
            else { return }
            appModel.playImportedFile(fileURL)
        }
    #endif
}
