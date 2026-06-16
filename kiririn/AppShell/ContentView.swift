import KppxKit
import SwiftUI

#if !os(macOS)
    import UIKit
#endif

private struct IsTabActiveKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var isTabActive: Bool {
        get { self[IsTabActiveKey.self] }
        set { self[IsTabActiveKey.self] = newValue }
    }
}

struct ContentView: View {
    let appModel: AppModel

    @State private var isLoadingIndicatorVisible = false
    @State private var loadingIndicatorHideTask: Task<Void, Never>?
    @State private var droppedPluginAlertMessage: String?
    @State private var externalInstallConfirmation: PluginInstallConfirmationRequest?
    @State private var externalInstallErrorMessage: String?
    #if os(macOS)
        private enum AppTab: String, CaseIterable, Hashable {
            case nowPlaying, guide, recordings, capture, settings

            var title: String {
                switch self {
                case .nowPlaying: return "放送中"
                case .guide: return "番組表"
                case .recordings: return "録画"
                case .capture: return "キャプチャ"
                case .settings: return "設定"
                }
            }

            var icon: String {
                switch self {
                case .nowPlaying: return "tv"
                case .guide: return "calendar"
                case .recordings: return "film.stack"
                case .capture: return "photo.on.rectangle.angled"
                case .settings: return "gear"
                }
            }
        }

        @State private var selectedMacTab: AppTab? = .nowPlaying
        @State private var visitedMacTabs: Set<AppTab> = [.nowPlaying]
    #endif
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
        mainStack
            .onAppear {
                isLoadingIndicatorVisible = manager.isDataLoading
                droppedPluginAlertMessage = pluginStore.droppedPluginAlertMessage
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
            .onChange(of: pluginStore.droppedPluginAlertMessage) { _, newValue in
                droppedPluginAlertMessage = newValue
            }
            .onChange(of: appModel.pendingPluginInstallPreviews.count) { _, _ in
                presentNextExternalInstallIfPossible()
            }
            .onChange(of: appModel.pendingPluginInstallErrorMessage) { _, newValue in
                guard let message = newValue else { return }
                externalInstallErrorMessage = message
                appModel.pendingPluginInstallErrorMessage = nil
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
                if url.isFileURL && url.pathExtension.lowercased() == "kppx" {
                    appModel.queuePluginInstall(from: url)
                } else {
                    appModel.handleDeepLink(url: url)
                }
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
                    allowedContentTypes: PlayableMediaUTTypes.allowedContentTypes,
                    allowsMultipleSelection: false
                ) { result in
                    handleFileImport(result)
                }
            #endif
    }

    @ViewBuilder
    private var mainStack: some View {
        ZStack {
            #if os(macOS)
                NavigationSplitView {
                    List(AppTab.allCases, id: \.self, selection: $selectedMacTab) { tab in
                        Label(tab.title, systemImage: tab.icon)
                    }
                    .listStyle(.sidebar)
                    .navigationSplitViewColumnWidth(min: 160, ideal: 200)
                } detail: {
                    ZStack {
                        ForEach(macTabDisplayOrder, id: \.self) { tab in
                            macTabContent(for: tab)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .opacity(selectedMacTab == tab ? 1 : 0)
                                .allowsHitTesting(selectedMacTab == tab)
                                .accessibilityHidden(selectedMacTab != tab)
                                .environment(\.isTabActive, selectedMacTab == tab)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onChange(of: selectedMacTab) { old, new in
                    if let tab = new {
                        visitedMacTabs.insert(tab)
                    } else if let old {
                        selectedMacTab = old
                    }
                }
            #else
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
                .opacity(playerState.isActive && playerState.mode == .fullscreen ? 0 : 1)
                .tabViewStyle(.sidebarAdaptable)
            #endif

            #if !os(macOS)
                if playerState.player != nil {
                    PlayerOverlayView_iOS(
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
        .alert(
            "プラグインの通知",
            isPresented: Binding(
                get: { droppedPluginAlertMessage != nil },
                set: { newValue in
                    if !newValue {
                        droppedPluginAlertMessage = nil
                        pluginStore.clearDroppedPluginAlertMessage()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                droppedPluginAlertMessage = nil
                pluginStore.clearDroppedPluginAlertMessage()
            }
        } message: {
            Text(droppedPluginAlertMessage ?? "")
        }
        .modifier(
            ExternalPluginInstallModifier(
                confirmation: $externalInstallConfirmation,
                errorMessage: $externalInstallErrorMessage,
                onCancel: {
                    externalInstallConfirmation = nil
                    presentNextExternalInstallIfPossible()
                },
                onConfirm: { confirmExternalInstall($0) },
                onErrorDismiss: {
                    externalInstallErrorMessage = nil
                    presentNextExternalInstallIfPossible()
                }
            ))
    }

    #if os(macOS)
        private var macTabDisplayOrder: [AppTab] {
            var result: [AppTab] = []
            if let sel = selectedMacTab, visitedMacTabs.contains(sel) {
                result.append(sel)
            }
            for tab in AppTab.allCases where visitedMacTabs.contains(tab) && tab != selectedMacTab {
                result.append(tab)
            }
            return result
        }

        @ViewBuilder
        private func macTabContent(for tab: AppTab) -> some View {
            switch tab {
            case .nowPlaying:
                NavigationStack {
                    ServiceListView(manager: manager, playerState: playerState)
                }
            case .guide:
                NavigationStack {
                    ProgramGuideView(manager: manager, playerState: playerState)
                }
            case .recordings:
                NavigationStack {
                    RecordsListView(
                        manager: manager,
                        searchText: Bindable(appModel).recordingsSearchText,
                        showsNavigationTitle: true,
                        showsSearch: true,
                        playerState: playerState
                    )
                }
            case .capture:
                NavigationStack {
                    CaptureListView(
                        showsNavigationTitle: true,
                        showsSearch: true,
                        playerState: playerState
                    )
                }
            case .settings:
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
    #endif

    #if !os(macOS)
        private func handleFileImport(_ result: Result<[URL], Error>) {
            guard case .success(let urls) = result,
                let fileURL = urls.first
            else { return }
            appModel.playImportedFile(fileURL)
        }
    #endif

    private func presentNextExternalInstallIfPossible() {
        guard externalInstallConfirmation == nil, externalInstallErrorMessage == nil else {
            return
        }
        externalInstallConfirmation = appModel.consumeNextPendingPluginInstallPreview()
    }

    private func confirmExternalInstall(_ request: PluginInstallConfirmationRequest) {
        do {
            var replacedPlugin: PluginDefinition?
            switch request.kind {
            case .install:
                _ = try pluginStore.installPlugin(from: request.preview)
            case .update(let pluginID, _):
                guard let previous = pluginStore.plugin(id: pluginID) else {
                    throw PluginManifestValidationError(messages: ["プラグインが見つかりません"])
                }
                replacedPlugin = previous
                _ = try pluginStore.overwritePlugin(previous, with: request.preview)
            case .reenable(let pluginID):
                _ = try pluginStore.reenableBlockedPlugin(id: pluginID, with: request.preview)
            }
            externalInstallConfirmation = nil
            if let replacedPlugin {
                Task { @MainActor in
                    await PluginWebsiteDataStore.unregisterServiceWorkers(for: replacedPlugin)
                    appModel.reloadPluginsInAllPlayerStates()
                }
            } else {
                appModel.reloadPluginsInAllPlayerStates()
            }
            #if os(macOS)
                selectedMacTab = .settings
            #endif
            presentNextExternalInstallIfPossible()
        } catch {
            externalInstallConfirmation = nil
            externalInstallErrorMessage = error.localizedDescription
        }
    }
}

private struct ExternalPluginInstallModifier: ViewModifier {
    @Binding var confirmation: PluginInstallConfirmationRequest?
    @Binding var errorMessage: String?
    let onCancel: () -> Void
    let onConfirm: (PluginInstallConfirmationRequest) -> Void
    let onErrorDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $confirmation) { request in
                PluginInstallConfirmationSheet(
                    request: request,
                    onCancel: onCancel,
                    onConfirm: { onConfirm(request) }
                )
            }
            .alert(
                "プラグインの追加エラー",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { newValue in if !newValue { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { onErrorDismiss() }
            } message: {
                Text(errorMessage ?? "")
            }
    }
}
