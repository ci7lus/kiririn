import Foundation
import KppxKit
import Logging

@MainActor
@Observable
final class AppModel {
    static let shared: AppModel = {
        configureLoggingIfNeeded()
        return AppModel()
    }()
    private let logger = Logger(label: "AppModel")

    private static let loggingBootstrapToken: Void = {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            #if DEBUG
                handler.logLevel = .debug
            #else
                handler.logLevel = .info
            #endif
            return handler
        }
    }()

    let configStore: ServerConfigStore
    let manager: ServerManager
    let playerState: PlayerState
    let pluginStore: PluginStore
    let remoteControlService: RemoteControlService
    @ObservationIgnored
    private let mediaPlaybackCoordinator: MediaPlaybackCoordinator
    @ObservationIgnored
    let openRequestCoordinator: PlaybackOpenCoordinator
    private(set) var cacheStore: CacheStore?

    var activePlayerStates: [PlayerState] = []
    var focusedPlayerID: String?
    var recordingsSearchText = ""

    var pendingPluginInstallPreviews: [PluginInstallPreview] = []
    var pendingPluginInstallErrorMessage: String?

    @ObservationIgnored
    private var recordingsViewModelStore: [String: RecordsViewModel] = [:]

    func recordingsViewModel(for serverId: String) -> RecordsViewModel {
        if let existing = recordingsViewModelStore[serverId] {
            return existing
        }
        let vm = RecordsViewModel()
        recordingsViewModelStore[serverId] = vm
        return vm
    }

    var focusedPlayerState: PlayerState? {
        guard let focusedPlayerID else { return nil }
        return activePlayerStates.first { $0.id == focusedPlayerID }
    }

    private var didSetupManager = false
    @ObservationIgnored
    private var setupTask: Task<Void, Never>?
    #if os(macOS)
        @ObservationIgnored
        private var globalCaptureHotKeyManager: GlobalCaptureHotKeyManager?
    #endif
    @ObservationIgnored
    private var pendingPluginDeeplinks: [String: [URL]] = [:]

    private static func configureLoggingIfNeeded() {
        _ = loggingBootstrapToken
    }

    private init() {
        let store = ServerConfigStore()
        configStore = store
        let manager = ServerManager(configStore: store)
        self.manager = manager
        playerState = PlayerState()
        playerState.manager = manager
        activePlayerStates = [playerState]
        focusedPlayerID = playerState.id
        pluginStore = PluginStore()
        remoteControlService = RemoteControlService()
        mediaPlaybackCoordinator = MediaPlaybackCoordinator()
        let openRequestCoordinator = PlaybackOpenCoordinator(
            manager: manager,
            playerState: playerState
        )
        self.openRequestCoordinator = openRequestCoordinator
        pluginStore.onLocalFolderManifestChanged = { [weak self] pluginID in
            guard let self else { return }
            self.syncPluginsToPlayer(forceReloadPluginIDs: [pluginID])
        }
        playerState.plugins = pluginStore.plugins
        openRequestCoordinator.register(playerState)
        openRequestCoordinator.configureManagerSetupWaiter { [weak self] in
            guard let self else { return }
            await self.waitForManagerSetup()
        }
        remoteControlService.configure(appModel: self)
        mediaPlaybackCoordinator.configure(appModel: self)
    }

    func setupIfNeeded() {
        guard !didSetupManager else { return }
        didSetupManager = true
        #if os(macOS)
            ensureGlobalCaptureHotKeyManager()
        #endif
        logger.debug("setupIfNeeded start: providers=\(manager.providers.count)")
        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let cacheStore = CacheStore()
            await installCacheStore(cacheStore)
            await manager.connectAll()
            let states = manager.connectionStates
                .map { "\($0.key):\($0.value.status.rawValue)" }
                .sorted()
                .joined(separator: ",")
            logger.debug("setupIfNeeded finished: connectionStates=\(states)")
        }
    }

    @discardableResult
    func deleteCacheDatabase() async throws -> Bool {
        if let cacheStore {
            try cacheStore.close()
        }

        do {
            let didDeleteFile = try CacheStore.deletePersistentDatabaseFiles()
            await installCacheStore(CacheStore())
            return didDeleteFile
        } catch {
            await installCacheStore(CacheStore())
            throw error
        }
    }

    private func installCacheStore(_ cacheStore: CacheStore) async {
        self.cacheStore = cacheStore
        playerState.cacheStore = cacheStore
        for state in activePlayerStates {
            state.cacheStore = cacheStore
        }
        await manager.setCacheStore(cacheStore)
    }

    #if os(macOS)
        func refreshGlobalCaptureHotKey() {
            ensureGlobalCaptureHotKeyManager()
            globalCaptureHotKeyManager?.reloadFromDefaults()
        }

        func takeCaptureForFocusedPlayer() {
            guard let focusedPlayerID,
                let state = activePlayerStates.first(where: { $0.id == focusedPlayerID })
            else {
                let focusedIDDescription = focusedPlayerID ?? "nil"
                logger.debug(
                    "global capture ignored: no focused player (focusedPlayerID: \(focusedIDDescription), active: \(activePlayerStates.count))"
                )
                return
            }
            logger.info("taking global capture for player: \(focusedPlayerID)")
            state.takeCapture()
        }

        private func ensureGlobalCaptureHotKeyManager() {
            guard globalCaptureHotKeyManager == nil else { return }
            globalCaptureHotKeyManager = GlobalCaptureHotKeyManager { [weak self] in
                Task { @MainActor in
                    self?.takeCaptureForFocusedPlayer()
                }
            }
        }
    #endif

    func syncPluginsToPlayer(forceReloadPluginIDs: Set<UUID> = []) {
        let previousPluginsByID = Dictionary(
            uniqueKeysWithValues: playerState.plugins.map { ($0.id, $0) }
        )
        let previouslyEnabledPluginIDs = Set(
            playerState.plugins.lazy
                .filter { $0.isEnabled && !$0.isBlocked }
                .map(\.id)
        )
        pluginStore.refreshPluginsFromFiles()
        let currentPlugins = pluginStore.plugins
        let enabledPluginIDs = Set(
            currentPlugins.lazy
                .filter { $0.isEnabled && !$0.isBlocked }
                .map(\.id)
        )
        let currentPluginsByID = Dictionary(
            uniqueKeysWithValues: currentPlugins.map { ($0.id, $0) }
        )
        let changedEnabledPluginIDs = Set(
            enabledPluginIDs.filter { pluginID in
                guard let previous = previousPluginsByID[pluginID],
                    let current = currentPluginsByID[pluginID]
                else { return false }
                return previous != current
            })
        let invalidatedPluginIDs =
            previouslyEnabledPluginIDs.subtracting(enabledPluginIDs)
            .union(changedEnabledPluginIDs)
            .union(forceReloadPluginIDs)
        for pluginID in invalidatedPluginIDs {
            ExtensionPluginRuntimeRegistry.shared.invalidate(pluginID: pluginID)
        }
        playerState.plugins = currentPlugins

        for state in activePlayerStates where state !== playerState {
            state.plugins = currentPlugins
        }

        let reloadedPluginIDs =
            changedEnabledPluginIDs
            .union(forceReloadPluginIDs)
            .intersection(enabledPluginIDs)
        for pluginID in reloadedPluginIDs {
            reloadPluginTokenInAllPlayerStates(id: pluginID.uuidString)
        }
    }

    func reloadPluginsInAllPlayerStates() {
        ExtensionPluginRuntimeRegistry.shared.invalidateAll()
        playerState.reloadPlugins()
        for state in activePlayerStates where state !== playerState {
            state.reloadPlugins()
        }
    }

    func reloadPluginInAllPlayerStates(id: String) {
        if let pluginID = UUID(uuidString: id) {
            ExtensionPluginRuntimeRegistry.shared.invalidate(pluginID: pluginID)
        }
        reloadPluginTokenInAllPlayerStates(id: id)
    }

    private func reloadPluginTokenInAllPlayerStates(id: String) {
        playerState.reloadPlugin(id: id)
        for state in activePlayerStates where state !== playerState {
            state.reloadPlugin(id: id)
        }
    }

    func makeDetachedPlayerState() -> PlayerState {
        let state = PlayerState()
        state.manager = manager
        state.plugins = pluginStore.plugins
        state.cacheStore = cacheStore
        return state
    }

    func configureDetachedPlayerState(_ state: PlayerState) {
        state.manager = manager
        state.plugins = pluginStore.plugins
        if let cacheStore {
            state.cacheStore = cacheStore
        }
    }

    func playImportedFile(_ url: URL, securityScoped: Bool = true) {
        logger.info("playImportedFile url=\(url.absoluteString), securityScoped=\(securityScoped)")
        let didStartSecurityScope: Bool
        if securityScoped {
            didStartSecurityScope = url.startAccessingSecurityScopedResource()
            if didStartSecurityScope {
                logger.debug("security scope granted for \(url.absoluteString)")
            } else {
                logger.warning("security scope denied for \(url.absoluteString)")
            }
        } else {
            didStartSecurityScope = false
        }
        defer {
            if didStartSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let bookmarkData =
            securityScoped
            ? try? url.bookmarkData(
                options: .securityScoped, includingResourceValuesForKeys: nil, relativeTo: nil)
            : nil
        let playable = Playable(
            streamURL: url,
            source: .fileURL(url, bookmarkData: bookmarkData)
        )
        playerState.play(playable: playable)
    }

    func registerActivePlayerState(_ state: PlayerState) {
        guard !activePlayerStates.contains(where: { $0 === state }) else { return }
        activePlayerStates.append(state)
        openRequestCoordinator.register(state)
    }

    func unregisterActivePlayerState(_ state: PlayerState) {
        activePlayerStates.removeAll { $0 === state }
        openRequestCoordinator.unregister(state)
    }

    private func waitForManagerSetup() async {
        setupIfNeeded()
        await setupTask?.value
    }

    func handleDeepLink(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "kiririn",
            let host = components.host?.lowercased()
        else {
            return
        }

        switch host {
        case "open":
            openRequestCoordinator.handleOpenDeepLink(components: components)
        case "plugins":
            handlePluginDeepLink(components: components)
        default:
            logger.debug("ignored unsupported deep link host: \(host)")
        }
    }

    func queuePluginInstall(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let preview = try pluginStore.previewPlugin(packageURL: url, sourceType: .kppx)
            pendingPluginInstallPreviews.append(preview)
        } catch {
            logger.warning("queuePluginInstall failed: \(error.localizedDescription)")
            pendingPluginInstallErrorMessage = error.localizedDescription
        }
    }

    func consumeNextPendingPluginInstallPreview() -> PluginInstallConfirmationRequest? {
        guard !pendingPluginInstallPreviews.isEmpty else { return nil }
        let preview = pendingPluginInstallPreviews.removeFirst()
        do {
            return try PluginInstallConfirmationRequest(
                preview: preview,
                routing: pluginStore.installRouting(for: preview)
            )
        } catch {
            pendingPluginInstallErrorMessage = error.localizedDescription
            return nil
        }
    }

    func consumePendingPluginDeeplinks(manifestID: String) -> [URL] {
        defer { pendingPluginDeeplinks.removeValue(forKey: manifestID) }
        return pendingPluginDeeplinks[manifestID] ?? []
    }

    private func handlePluginDeepLink(components: URLComponents) {
        if PluginInstallDeepLink.isInstallRequest(components) {
            handlePluginInstallDeepLink(components: components)
            return
        }

        let pathComponents = components.path.split(separator: "/").map(String.init)
        guard let manifestID = pathComponents.first, !manifestID.isEmpty else {
            logger.warning("deep link plugins rejected: missing manifest id")
            return
        }
        guard let plugin = pluginStore.plugin(manifestID: manifestID) else {
            logger.warning("deep link plugins rejected: plugin not found manifestID=\(manifestID)")
            return
        }

        guard let callbackURL = components.url else {
            logger.warning("deep link plugins rejected: could not determine callback url")
            return
        }

        pendingPluginDeeplinks[manifestID, default: []].append(callbackURL)
        #if os(macOS)
            NotificationCenter.default.post(name: .requestOpenPluginWindow, object: plugin.id)
        #endif
        NotificationCenter.default.post(
            name: .pluginDeeplinkOpened,
            object: nil,
            userInfo: [
                "manifestID": manifestID,
                "deeplinkURL": callbackURL.absoluteString,
            ]
        )
        logger.info("deep link plugin callback queued: manifestID=\(manifestID)")
    }

    private func handlePluginInstallDeepLink(components: URLComponents) {
        guard let request = PluginInstallDeepLink(components: components) else {
            logger.warning("deep link plugin install rejected: invalid parameters")
            pendingPluginInstallErrorMessage =
                "プラグインの追加URLにupdateManifestUrlまたはmanifestIDが正しく設定されていません"
            return
        }

        Task { @MainActor in
            do {
                let preview = try await pluginStore.previewPlugin(
                    fromUpdateManifestURL: request.updateManifestURL,
                    manifestID: request.manifestID
                )
                pendingPluginInstallPreviews.append(preview)
                logger.info("deep link plugin install resolved: manifestID=\(request.manifestID)")
            } catch {
                logger.warning(
                    "deep link plugin install failed: manifestID=\(request.manifestID), error=\(error.localizedDescription)"
                )
                pendingPluginInstallErrorMessage = error.localizedDescription
            }
        }
    }

}
