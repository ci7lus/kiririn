import Foundation
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

    let configStore: BackendConfigStore
    let manager: BackendManager
    let playerState: PlayerState
    let pluginStore: PluginStore
    private(set) var cacheStore: CacheStore?

    var activePlayerStates: [PlayerState] = []
    var focusedPlayerID: String?
    var recordingsSearchText = ""

    @ObservationIgnored
    private var recordingsViewModelStore: [String: RecordsViewModel] = [:]

    func recordingsViewModel(for backendId: String) -> RecordsViewModel {
        if let existing = recordingsViewModelStore[backendId] {
            return existing
        }
        let vm = RecordsViewModel()
        recordingsViewModelStore[backendId] = vm
        return vm
    }

    var focusedPlayerState: PlayerState? {
        guard let focusedPlayerID else { return nil }
        return activePlayerStates.first { $0.id == focusedPlayerID }
    }

    private var didSetupManager = false
    #if os(macOS)
        @ObservationIgnored
        private var globalCaptureHotKeyManager: GlobalCaptureHotKeyManager?
    #endif
    @ObservationIgnored
    private var pendingPluginOpenURLs: [String: [URL]] = [:]

    private static func configureLoggingIfNeeded() {
        _ = loggingBootstrapToken
    }

    private init() {
        let store = BackendConfigStore()
        configStore = store
        let manager = BackendManager(configStore: store)
        self.manager = manager
        playerState = PlayerState()
        playerState.manager = manager
        activePlayerStates = [playerState]
        focusedPlayerID = playerState.id
        pluginStore = PluginStore()
        playerState.plugins = pluginStore.plugins
    }

    func setupIfNeeded() {
        guard !didSetupManager else { return }
        didSetupManager = true
        #if os(macOS)
            ensureGlobalCaptureHotKeyManager()
        #endif
        logger.debug("setupIfNeeded start: providers=\(manager.providers.count)")
        Task {
            let cacheStore = CacheStore()
            self.cacheStore = cacheStore
            playerState.cacheStore = cacheStore
            await manager.setCacheStore(cacheStore)
            await manager.connectAll()
            let states = manager.connectionStates
                .map { "\($0.key):\($0.value.status.rawValue)" }
                .sorted()
                .joined(separator: ",")
            logger.debug("setupIfNeeded finished: connectionStates=\(states)")
        }
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

    func syncPluginsToPlayer() {
        pluginStore.refreshPluginsFromFiles()
        let currentPlugins = pluginStore.plugins
        playerState.plugins = currentPlugins

        for state in activePlayerStates {
            state.plugins = currentPlugins
        }
    }

    func reloadPluginsInAllPlayerStates() {
        playerState.reloadPlugins()
        for state in activePlayerStates where state !== playerState {
            state.reloadPlugins()
        }
    }

    func reloadPluginInAllPlayerStates(id: String) {
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
        if securityScoped {
            if url.startAccessingSecurityScopedResource() {
                playerState.adoptSecurityScopedPlaybackURL(url)
                logger.debug("security scope granted for \(url.absoluteString)")
            } else {
                playerState.adoptSecurityScopedPlaybackURL(nil)
                logger.warning("security scope denied for \(url.absoluteString)")
            }
        } else {
            playerState.adoptSecurityScopedPlaybackURL(nil)
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

    func handleDeepLink(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "kiririn",
            let host = components.host?.lowercased()
        else {
            return
        }

        switch host {
        case "open":
            handleOpenDeepLink(components: components)
        case "plugins":
            handlePluginDeepLink(components: components)
        default:
            logger.debug("ignored unsupported deep link host: \(host)")
        }
    }

    func consumePendingPluginOpenURLs(manifestID: String) -> [URL] {
        defer { pendingPluginOpenURLs.removeValue(forKey: manifestID) }
        return pendingPluginOpenURLs[manifestID] ?? []
    }

    private func handleOpenDeepLink(components: URLComponents) {
        guard let mediaURL = parseMediaURL(from: components) else {
            logger.warning("deep link open rejected: invalid media url")
            return
        }
        playDirectURL(mediaURL)
        logger.info("deep link open accepted: \(mediaURL.absoluteString)")
    }

    private func handlePluginDeepLink(components: URLComponents) {
        let pathComponents = components.path.split(separator: "/").map(String.init)
        guard let manifestID = pathComponents.first, !manifestID.isEmpty else {
            logger.warning("deep link plugins rejected: missing manifest id")
            return
        }
        guard let mediaURL = parseMediaURL(from: components) else {
            logger.warning("deep link plugins rejected: invalid media url")
            return
        }
        guard let plugin = pluginStore.plugin(manifestID: manifestID) else {
            logger.warning("deep link plugins rejected: plugin not found manifestID=\(manifestID)")
            return
        }

        pendingPluginOpenURLs[manifestID, default: []].append(mediaURL)
        #if os(macOS)
            NotificationCenter.default.post(name: .requestOpenPluginWindow, object: plugin.id)
        #endif
        NotificationCenter.default.post(
            name: .pluginOpenURLRequested,
            object: nil,
            userInfo: [
                "manifestID": manifestID,
                "url": mediaURL.absoluteString,
            ]
        )
        logger.info("deep link plugin callback queued: manifestID=\(manifestID)")
    }

    private func parseMediaURL(from components: URLComponents) -> URL? {
        guard let rawValue = components.queryItems?.first(where: { $0.name == "url" })?.value else {
            return nil
        }

        let candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        if let parsedURL = validatedMediaURL(from: candidate) {
            return parsedURL
        }

        if let decodedCandidate = candidate.removingPercentEncoding,
            decodedCandidate != candidate,
            let parsedURL = validatedMediaURL(from: decodedCandidate)
        {
            return parsedURL
        }

        return nil
    }

    private func validatedMediaURL(from candidate: String) -> URL? {
        guard let parsedURL = URL(string: candidate),
            let scheme = parsedURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            return nil
        }
        return parsedURL
    }

    private func playDirectURL(_ url: URL) {
        let playable = Playable(
            streamURL: url,
            source: .directURL(url)
        )
        #if os(macOS)
            NotificationCenter.default.post(name: .requestOpenPlayable, object: playable)
        #else
            playerState.play(playable: playable)
        #endif
    }
}
