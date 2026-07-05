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
    @Environment(AppModel.self) private var appModel

    @State private var isLoadingIndicatorVisible = false
    @State private var loadingIndicatorHideTask: Task<Void, Never>?
    @State private var communicationFailureToastVisible = false
    @State private var communicationFailureToastHideTask: Task<Void, Never>?
    @State private var cacheDatabaseFailureToastVisible = false
    @State private var cacheDatabaseFailureToastHideTask: Task<Void, Never>?
    @State private var didShowCacheDatabaseFailureToast = false
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

        private enum SettingsNavigationDestination: Hashable {
            case about
        }

        private struct MacCommandNotificationModifier: ViewModifier {
            @Binding var selectedTab: AppTab?
            @Binding var settingsNavigationPath: NavigationPath
            @Environment(\.openWindow) private var openWindow

            func body(content: Content) -> some View {
                content
                    .onReceive(
                        NotificationCenter.default.publisher(for: .requestOpenPlayable)
                    ) { notification in
                        guard let playable = notification.object as? Playable else { return }
                        openWindow(id: AppWindowID.player.rawValue, value: playable)
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(for: .requestOpenPluginWindow)
                    ) { notification in
                        guard let pluginID = notification.object as? UUID else { return }
                        openWindow(id: AppWindowID.plugin.rawValue, value: pluginID)
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(for: .requestOpenSettings)
                    ) { _ in
                        selectedTab = .settings
                        settingsNavigationPath = NavigationPath()
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(for: .requestOpenAboutApp)
                    ) { _ in
                        selectedTab = .settings
                        settingsNavigationPath = NavigationPath()
                        settingsNavigationPath.append(SettingsNavigationDestination.about)
                    }
            }
        }

        @State private var selectedMacTab: AppTab? = .nowPlaying
        @State private var visitedMacTabs: Set<AppTab> = [.nowPlaying]
        @State private var settingsNavigationPath = NavigationPath()
    #endif
    @Environment(\.scenePhase) private var scenePhase
    #if !os(macOS)
        @Environment(\.verticalSizeClass) private var verticalSizeClass
        @State private var showingFilePicker = false
    #endif

    private var configStore: ServerConfigStore { appModel.configStore }
    private var manager: ServerManager { appModel.manager }
    private var playerState: PlayerState { appModel.playerState }
    private var pluginStore: PluginStore { appModel.pluginStore }

    var body: some View {
        mainStack
            .tint(.accentColor)
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
                communicationFailureToastHideTask?.cancel()
                communicationFailureToastHideTask = nil
                cacheDatabaseFailureToastHideTask?.cancel()
                cacheDatabaseFailureToastHideTask = nil
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
            .onChange(of: manager.communicationFailureCount) { _, newValue in
                guard newValue > 0 else { return }
                showCommunicationFailureToast()
            }
            .onChange(of: appModel.cacheStore?.databaseFailureFeedback?.id) { _, newValue in
                guard newValue != nil else {
                    didShowCacheDatabaseFailureToast = false
                    return
                }
                showCacheDatabaseFailureToast()
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
                .modifier(
                    MacCommandNotificationModifier(
                        selectedTab: $selectedMacTab,
                        settingsNavigationPath: $settingsNavigationPath
                    ))
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
                appFeedbackOverlay(topPadding: feedbackTopPadding) {
                    AppFeedbackLabel(text: "データ取得中…", showsProgress: true)
                }
                .zIndex(2)
            }

            if communicationFailureToastVisible && !playerState.isActive {
                appFeedbackOverlay(topPadding: feedbackTopPadding) {
                    AppFeedbackLabel(
                        text: "通信に失敗しました",
                        systemImage: "exclamationmark.triangle.fill",
                        iconTint: .yellow
                    )
                }
                .zIndex(3)
            }

            if cacheDatabaseFailureToastVisible && !playerState.isActive {
                appFeedbackOverlay(topPadding: feedbackTopPadding) {
                    AppFeedbackLabel(
                        text: appModel.cacheStore?.databaseFailureFeedback?.message
                            ?? "キャッシュが破損している可能性があります",
                        systemImage: "exclamationmark.triangle.fill",
                        iconTint: .yellow
                    )
                }
                .zIndex(4)
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

    private var feedbackTopPadding: CGFloat {
        #if os(iOS)
            46
        #else
            8
        #endif
    }

    @ViewBuilder
    private func appFeedbackOverlay<Content: View>(
        topPadding: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack {
            content()
                .padding(.top, topPadding)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    private func showCommunicationFailureToast() {
        communicationFailureToastHideTask?.cancel()
        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
            communicationFailureToastVisible = true
        }
        communicationFailureToastHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.22)) {
                communicationFailureToastVisible = false
            }
            communicationFailureToastHideTask = nil
        }
    }

    private func showCacheDatabaseFailureToast() {
        guard !didShowCacheDatabaseFailureToast else { return }
        didShowCacheDatabaseFailureToast = true
        cacheDatabaseFailureToastHideTask?.cancel()
        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
            cacheDatabaseFailureToastVisible = true
        }
        cacheDatabaseFailureToastHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.22)) {
                cacheDatabaseFailureToastVisible = false
            }
            cacheDatabaseFailureToastHideTask = nil
        }
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
                NavigationStack(path: $settingsNavigationPath) {
                    SettingsView(
                        configStore: configStore,
                        manager: manager,
                        appModel: appModel,
                        pluginStore: pluginStore,
                        playerState: playerState
                    )
                    .navigationDestination(for: SettingsNavigationDestination.self) {
                        destination in
                        switch destination {
                        case .about:
                            AboutAppView()
                        }
                    }
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
