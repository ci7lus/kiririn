import Combine
import KppxKit
import Logging
import SwiftUI
import WebKit

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

extension PluginDisplayArea {
    var localizedName: String {
        switch self {
        case .overlay: return "プレイヤーオーバーレイ"
        case .options: return "プラグイン設定"
        case .panel: return "パネル"
        }
    }
}

struct PluginSafeAreaInsets: Sendable, Equatable {
    let top: CGFloat
    let right: CGFloat
    let bottom: CGFloat
    let left: CGFloat

    static let zero = PluginSafeAreaInsets(top: 0, right: 0, bottom: 0, left: 0)

    var asDictionary: [String: Double] {
        [
            "top": Double(top),
            "right": Double(right),
            "bottom": Double(bottom),
            "left": Double(left),
        ]
    }
}

enum ExtensionPluginContextConfiguration {
    private static let errorDomain = "PluginRuntime"
    private static let baseURLScheme = "webkit-extension"

    static func uniqueIdentifier(for manifestID: String) -> String {
        manifestID
    }

    private static func baseURL(forHost host: String, identity: String) throws -> URL {
        var components = URLComponents()
        components.scheme = baseURLScheme
        components.host = host
        components.path = "/"

        guard let baseURL = components.url else {
            throw NSError(
                domain: errorDomain,
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "プラグインの base URL が不正です: \(identity)"
                ]
            )
        }

        return baseURL
    }

    private static func host(from baseURL: URL, identity: String) throws -> String {
        guard let host = baseURL.host, !host.isEmpty else {
            throw NSError(
                domain: errorDomain,
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "プラグインの host を解決できませんでした: \(identity)"
                ]
            )
        }

        return host
    }

    static func baseURL(for pluginID: UUID) throws -> URL {
        try baseURL(forHost: pluginID.uuidString.lowercased(), identity: pluginID.uuidString)
    }

    static func host(for pluginID: UUID) throws -> String {
        try host(from: baseURL(for: pluginID), identity: pluginID.uuidString)
    }

    static func websiteDataHost(for pluginID: UUID) throws -> String {
        try host(for: pluginID)
    }

    @MainActor
    static func makeContext(
        for webExtension: WKWebExtension,
        pluginID: UUID,
        manifestID: String,
        requestedPermissions: [String],
        requestedHostPermissions: [String]
    ) throws -> WKWebExtensionContext {
        let context = WKWebExtensionContext(for: webExtension)
        try applyStableIdentity(to: context, pluginID: pluginID, manifestID: manifestID)
        applyRequestedPermissions(requestedPermissions, to: context)
        applyRequestedHostPermissions(requestedHostPermissions, to: context)
        return context
    }

    @MainActor
    static func applyStableIdentity(
        to context: WKWebExtensionContext,
        pluginID: UUID,
        manifestID: String
    ) throws {
        context.uniqueIdentifier = uniqueIdentifier(for: manifestID)
        context.baseURL = try baseURL(for: pluginID)
    }

    @MainActor
    private static func applyRequestedPermissions(
        _ requestedPermissions: [String],
        to context: WKWebExtensionContext
    ) {
        for permission in requestedPermissions {
            context.setPermissionStatus(
                .grantedExplicitly,
                for: WKWebExtension.Permission(permission)
            )
        }
    }

    @MainActor
    private static func applyRequestedHostPermissions(
        _ hostPermissions: [String],
        to context: WKWebExtensionContext
    ) {
        for pattern in hostPermissions {
            guard let matchPattern = try? WKWebExtension.MatchPattern(string: pattern) else {
                continue
            }
            context.setPermissionStatus(.grantedExplicitly, for: matchPattern)
        }
    }
}

@MainActor
enum PluginWebsiteDataStore {
    private static let extensionDataTypes = WKWebExtensionController.allExtensionDataTypes
    private static let websiteDataTypes = WKWebsiteDataStore.allWebsiteDataTypes()

    static func unregisterServiceWorkers(for plugin: PluginDefinition) async {
        guard let host = try? ExtensionPluginContextConfiguration.websiteDataHost(for: plugin.id)
        else { return }
        let swTypes: Set<String> = [WKWebsiteDataTypeServiceWorkerRegistrations]
        let dataStore = WKWebsiteDataStore.default()
        let records = await matchingRecords(forHost: host, dataStore: dataStore)
        guard !records.isEmpty else { return }
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: swTypes, for: records) {
                continuation.resume(returning: ())
            }
        }
    }

    @MainActor
    static func removeAllData(for plugin: PluginDefinition, store: PluginStore) async throws
        -> Bool
    {
        let removedWebsiteData = try await removeWebsiteData(for: plugin)

        do {
            let runtime = try await ExtensionPluginRuntimeRegistry.shared.makeRuntime(
                for: plugin,
                store: store
            )
            let removedExtensionData = await removeExtensionData(for: runtime)
            return removedExtensionData || removedWebsiteData
        } catch {
            if removedWebsiteData {
                return true
            }
            throw error
        }
    }

    private static func removeExtensionData(for runtime: ExtensionPluginRuntime) async -> Bool {
        guard
            let record = await runtime.controller.dataRecord(
                ofTypes: extensionDataTypes,
                for: runtime.context
            )
        else {
            return false
        }

        let removableTypes = record.containedDataTypes.intersection(extensionDataTypes)
        guard !removableTypes.isEmpty else { return false }

        await runtime.controller.removeData(ofTypes: removableTypes, from: [record])
        return true
    }

    private static func removeWebsiteData(for plugin: PluginDefinition) async throws -> Bool {
        let host = try ExtensionPluginContextConfiguration.websiteDataHost(for: plugin.id)
        return await removeWebsiteData(forHost: host)
    }

    private static func removeWebsiteData(forHost host: String) async -> Bool {
        let dataStore = WKWebsiteDataStore.default()
        let records = await matchingRecords(forHost: host, dataStore: dataStore)
        guard !records.isEmpty else { return false }

        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: websiteDataTypes, for: records) {
                continuation.resume(returning: ())
            }
        }

        return true
    }

    private static func matchingRecords(forHost host: String, dataStore: WKWebsiteDataStore) async
        -> [WKWebsiteDataRecord]
    {
        let normalizedHost = host.lowercased()

        return await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: websiteDataTypes) { records in
                continuation.resume(
                    returning: records.filter {
                        let displayName = $0.displayName.lowercased()
                        return displayName == normalizedHost
                            || displayName.hasSuffix(".\(normalizedHost)")
                    })
            }
        }
    }
}

@MainActor
private final class PluginExtensionControllerDelegate: NSObject, WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        completionHandler(matchPatterns, nil)
    }
}

@MainActor
final class ExtensionPluginRuntime {
    let pluginID: UUID
    let manifest: ExtensionPluginManifest
    let resourceBaseURL: URL
    let webExtension: WKWebExtension
    let context: WKWebExtensionContext
    let controller: WKWebExtensionController
    private let controllerDelegate: PluginExtensionControllerDelegate
    private var isInvalidated = false

    init(
        plugin: PluginDefinition,
        manifest: ExtensionPluginManifest,
        resourceBaseURL: URL
    ) async throws {
        let normalizedResourceBaseURL = resourceBaseURL.standardizedFileURL
        guard normalizedResourceBaseURL.isFileURL else {
            throw NSError(
                domain: "PluginRuntime",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "プラグインのリソース URL が不正です: \(resourceBaseURL.absoluteString)"
                ]
            )
        }
        self.pluginID = plugin.id
        self.manifest = manifest
        self.resourceBaseURL = normalizedResourceBaseURL
        self.webExtension = try await WKWebExtension(
            resourceBaseURL: normalizedResourceBaseURL)
        self.context = try ExtensionPluginContextConfiguration.makeContext(
            for: webExtension,
            pluginID: plugin.id,
            manifestID: plugin.manifestID,
            requestedPermissions: manifest.requestedPermissions,
            requestedHostPermissions: manifest.requestedHostPermissions
        )
        self.context.isInspectable = true
        let delegate = PluginExtensionControllerDelegate()
        self.controllerDelegate = delegate
        self.controller = WKWebExtensionController()
        self.controller.delegate = delegate
        try controller.load(context)
    }

    func pageURL(for area: PluginDisplayArea) -> URL? {
        guard let pagePath = manifest.pagePath(for: area) else {
            return nil
        }
        return context.baseURL.appending(path: pagePath)
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        try? controller.unload(context)
    }
}

@MainActor
final class ExtensionPluginRuntimeRegistry {
    static let shared = ExtensionPluginRuntimeRegistry()

    private struct PendingRuntimeLoad {
        let token: UUID
        let task: Task<ExtensionPluginRuntime, Error>
    }

    private var runtimes: [UUID: ExtensionPluginRuntime] = [:]
    private var pendingLoads: [UUID: PendingRuntimeLoad] = [:]

    func makeRuntime(for plugin: PluginDefinition, store: PluginStore) async throws
        -> ExtensionPluginRuntime
    {
        if let runtime = runtimes[plugin.id] {
            return runtime
        }

        if let pendingLoad = pendingLoads[plugin.id] {
            return try await resolvePendingLoad(pendingLoad, for: plugin, store: store)
        }

        let manifest = try store.resolvedManifest(for: plugin)

        let resourceBaseURL = try store.resourceBaseURL(for: plugin)
        let pendingLoad = PendingRuntimeLoad(
            token: UUID(),
            task: Task { @MainActor in
                try await ExtensionPluginRuntime(
                    plugin: plugin,
                    manifest: manifest,
                    resourceBaseURL: resourceBaseURL
                )
            }
        )
        pendingLoads[plugin.id] = pendingLoad
        return try await resolvePendingLoad(pendingLoad, for: plugin, store: store)
    }

    func invalidate(pluginID: UUID) {
        pendingLoads.removeValue(forKey: pluginID)?.task.cancel()
        runtimes.removeValue(forKey: pluginID)?.invalidate()
    }

    func invalidateAll() {
        let activeRuntimes = Array(runtimes.values)
        let activeLoads = Array(pendingLoads.values)
        runtimes = [:]
        pendingLoads = [:]
        for pendingLoad in activeLoads {
            pendingLoad.task.cancel()
        }
        for runtime in activeRuntimes {
            runtime.invalidate()
        }
    }

    private func resolvePendingLoad(
        _ pendingLoad: PendingRuntimeLoad,
        for plugin: PluginDefinition,
        store: PluginStore
    ) async throws -> ExtensionPluginRuntime {
        do {
            let runtime = try await pendingLoad.task.value

            if let existingRuntime = runtimes[plugin.id], existingRuntime === runtime {
                return existingRuntime
            }

            guard pendingLoads[plugin.id]?.token == pendingLoad.token else {
                runtime.invalidate()
                try Task.checkCancellation()
                return try await makeRuntime(for: plugin, store: store)
            }

            pendingLoads[plugin.id] = nil

            if let existingRuntime = runtimes[plugin.id] {
                if existingRuntime !== runtime {
                    runtime.invalidate()
                }
                return existingRuntime
            }

            runtimes[plugin.id] = runtime
            return runtime
        } catch {
            if pendingLoads[plugin.id]?.token == pendingLoad.token {
                pendingLoads[plugin.id] = nil
            }
            throw error
        }
    }
}

struct PluginOverlayView: View {
    let pluginDefinition: PluginDefinition
    let appModel: AppModel
    let reloadToken: Int
    let displayArea: PluginDisplayArea
    let playerID: String?
    let safeAreaInsets: PluginSafeAreaInsets

    init(
        pluginDefinition: PluginDefinition,
        appModel: AppModel,
        reloadToken: Int,
        displayArea: PluginDisplayArea,
        playerID: String? = nil,
        safeAreaInsets: PluginSafeAreaInsets = .zero
    ) {
        self.pluginDefinition = pluginDefinition
        self.appModel = appModel
        self.reloadToken = reloadToken
        self.displayArea = displayArea
        self.playerID = playerID
        self.safeAreaInsets = safeAreaInsets
    }

    @State private var isCrashed = false
    @State private var lastError: String?
    @State private var isDetailsExpanded = false
    @State private var pendingDeeplinkURL: URL?
    @State private var deeplinkToken = 0
    @State private var extensionRuntime: ExtensionPluginRuntime?

    var body: some View {
        // アクティブな全プレイヤーの状態を追跡するハッシュを生成し、これを元に再描画と同期をトリガーさせる。
        // 再生位置(time)は頻繁すぎるため除外するが、番組変更や再生/停止、シーク可否の変化は網羅する。
        let stateHash =
            appModel.activePlayerStates.map {
                "\($0.id):\($0.currentPlayable?.id ?? "none"):\($0.playbackStatus.isPlaying):\($0.currentPlayable?.isSeekable ?? false)"
            }.joined(separator: "|") + (appModel.focusedPlayerID ?? "")
        ZStack {
            if extensionRuntime != nil {
                PluginWebView(
                    pluginDefinition: pluginDefinition,
                    extensionRuntime: extensionRuntime,
                    appModel: appModel,
                    reloadToken: reloadToken,
                    displayArea: displayArea,
                    playerID: playerID,
                    safeAreaInsets: safeAreaInsets,
                    deeplinkURL: pendingDeeplinkURL,
                    deeplinkToken: deeplinkToken,
                    stateHash: stateHash,
                    onCrash: {
                        isDetailsExpanded = false
                        isCrashed = true
                    }
                )
                .allowsHitTesting(!isCrashed)
            } else if displayArea != .overlay {
                ProgressView()
            }

            if isCrashed {
                crashView
            }
        }
        .onChange(of: reloadToken) {
            isCrashed = false
            lastError = nil
            ExtensionPluginRuntimeRegistry.shared.invalidate(pluginID: pluginDefinition.id)
            extensionRuntime = nil
        }
        .onDisappear {
            releaseExtensionRuntime()
        }
        .onAppear {
            consumeQueuedDeeplinkIfNeeded()
        }
        .task(id: runtimeLoadKey) {
            await loadExtensionRuntime()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pluginDeeplinkOpened)) {
            notification in
            let manifestPluginID = pluginDefinition.manifestID
            guard let userInfo = notification.userInfo,
                let targetManifestID = userInfo["manifestID"] as? String,
                targetManifestID == manifestPluginID,
                let urlString = userInfo["deeplinkURL"] as? String,
                let url = URL(string: urlString)
            else {
                return
            }
            queueDeeplinkEvent(url)
        }
    }

    private func consumeQueuedDeeplinkIfNeeded() {
        let manifestPluginID = pluginDefinition.manifestID
        let queuedURLs = appModel.consumePendingPluginDeeplinks(manifestID: manifestPluginID)
        guard !queuedURLs.isEmpty else { return }
        for queuedURL in queuedURLs {
            queueDeeplinkEvent(queuedURL)
        }
    }

    private func queueDeeplinkEvent(_ url: URL) {
        pendingDeeplinkURL = url
        deeplinkToken += 1
    }

    private var runtimeLoadKey: String {
        return
            "\(pluginDefinition.id.uuidString)-\(reloadToken)-\(pluginDefinition.resourceBasePath)"
    }

    @MainActor
    private func loadExtensionRuntime() async {
        let expectedLoadKey = runtimeLoadKey

        do {
            let runtime = try await ExtensionPluginRuntimeRegistry.shared.makeRuntime(
                for: pluginDefinition,
                store: appModel.pluginStore
            )
            guard !Task.isCancelled, runtimeLoadKey == expectedLoadKey else { return }
            extensionRuntime = runtime
        } catch {
            guard !Task.isCancelled, runtimeLoadKey == expectedLoadKey else {
                return
            }
            extensionRuntime = nil
            lastError = error.localizedDescription
            if displayArea != .overlay {
                isCrashed = true
            }
        }
    }

    @MainActor
    private func releaseExtensionRuntime() {
        extensionRuntime = nil
    }

    @ViewBuilder
    private var crashView: some View {
        if displayArea == .overlay {
            // オーバーレイの場合はエラーを表示しない
            Color.clear
        } else {
            ZStack {
                Color.black.opacity(0.24)

                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    VStack(spacing: 4) {
                        Text("プラグインがクラッシュしました")
                            .font(.headline)
                        Text("レンダープロセスが停止したか、予期しないエラーが発生しました")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let lastError {
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                withAnimation {
                                    isDetailsExpanded.toggle()
                                }
                            } label: {
                                HStack {
                                    Text("スタックトレースを表示")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .rotationEffect(.degrees(isDetailsExpanded ? 90 : 0))
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)

                            if isDetailsExpanded {
                                ScrollView {
                                    Text(lastError)
                                        .font(.system(.caption, design: .monospaced))
                                        .multilineTextAlignment(.leading)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.black.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .frame(maxHeight: 200)
                            }
                        }
                        .padding(.horizontal)
                        .frame(maxWidth: 400)
                    }

                    Button("再読み込み") {
                        isCrashed = false
                        lastError = nil
                        isDetailsExpanded = false
                        ExtensionPluginRuntimeRegistry.shared.invalidate(
                            pluginID: pluginDefinition.id)
                        extensionRuntime = nil
                        Task {
                            await loadExtensionRuntime()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: 440)
                .background(
                    .regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                }
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#if os(macOS)
    private typealias PluginWebViewRepresentable = NSViewRepresentable
#else
    private typealias PluginWebViewRepresentable = UIViewRepresentable
#endif

private struct PluginWebView: PluginWebViewRepresentable {
    let pluginDefinition: PluginDefinition
    let extensionRuntime: ExtensionPluginRuntime?
    let appModel: AppModel
    let reloadToken: Int
    let displayArea: PluginDisplayArea
    let playerID: String?
    let safeAreaInsets: PluginSafeAreaInsets
    let deeplinkURL: URL?
    let deeplinkToken: Int
    let stateHash: String
    let onCrash: @MainActor () -> Void
    private let logger = Logging.Logger(label: "PluginWebView")

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, onCrash: onCrash)
    }

    private func makePlatformWebView(context: Context) -> WKWebView {
        let config: WKWebViewConfiguration = {
            if let existingConfig = extensionRuntime?.context.webViewConfiguration {
                return existingConfig
            } else {
                logger.error("Failed to get web view configuration. Using default.")
                return WKWebViewConfiguration()
            }
        }()
        config.applicationNameForUserAgent = makeApplicationNameForUserAgent()
        let contentController = WKUserContentController()

        let bridgeScript = WKUserScript(
            source: makeBridgeJS(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(bridgeScript)

        // WKUserContentController holds a strong reference to the handler.
        // Use a weak proxy to avoid a retain cycle between the Coordinator and the WebView.
        let weakHandler = LeakAversionScriptMessageHandler(handler: context.coordinator)
        contentController.add(weakHandler, name: "kiririn")

        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        #if os(macOS)
            webView.setValue(false, forKey: "drawsBackground")
            webView.allowsMagnification = false
        #else
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.isScrollEnabled = displayArea != .overlay
            webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.lastLoadedPageURL = currentPageURLString()
        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.isPageReady = false

        if displayArea == .overlay, let pid = playerID {
            let wv = webView
            let pid = pid
            let plugID = pluginDefinition.id.uuidString
            Task { @MainActor in
                PluginOverlaySnapshotRegistry.shared.register(wv, playerID: pid, pluginID: plugID)
            }
        }

        Task { @MainActor in
            self.loadPluginPage(into: webView)
        }
        return webView
    }

    #if os(macOS)
        func makeNSView(context: Context) -> WKWebView {
            makePlatformWebView(context: context)
        }
    #else
        func makeUIView(context: Context) -> WKWebView {
            makePlatformWebView(context: context)
        }
    #endif

    private func updatePlatformWebView(_ webView: WKWebView, context: Context) {
        let pageChanged = context.coordinator.lastLoadedPageURL != currentPageURLString()
        let tokenChanged = context.coordinator.lastReloadToken != reloadToken

        if pageChanged || tokenChanged {
            context.coordinator.lastLoadedPageURL = currentPageURLString()
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.lastInjectedPlayablesJson = nil
            context.coordinator.lastInjectedStatusesJson = nil
            context.coordinator.lastInjectedFocusedPlayerID = nil
            context.coordinator.lastInjectedPlayerIDs = nil
            context.coordinator.wantsCaptureEvents = false
            context.coordinator.isPageReady = false
            Task { @MainActor in
                self.loadPluginPage(into: webView)
            }
        }
        if context.coordinator.lastInjectedDeeplinkToken != deeplinkToken {
            context.coordinator.lastInjectedDeeplinkToken = deeplinkToken
            if let deeplinkURL {
                context.coordinator.queueDeeplinkEvent(deeplinkURL)
            }
        }
        injectAllStates(into: webView, coordinator: context.coordinator)
    }

    private func injectAllStates(
        into webView: WKWebView, coordinator: Coordinator, force: Bool = false
    ) {
        injectPlayables(into: webView, coordinator: coordinator, force: force)
        injectStatuses(into: webView, coordinator: coordinator, force: force)
        injectFocus(into: webView, coordinator: coordinator, force: force)
    }

    #if os(macOS)
        func updateNSView(_ webView: WKWebView, context: Context) {
            updatePlatformWebView(webView, context: context)
        }
    #else
        func updateUIView(_ webView: WKWebView, context: Context) {
            updatePlatformWebView(webView, context: context)
        }
    #endif

    private static func dismantlePlatformWebView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.loadHTMLString("", baseURL: nil)
        coordinator.captureEventCancellable?.cancel()
        coordinator.captureEventCancellable = nil
        uiView.configuration.userContentController.removeAllUserScripts()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "kiririn")
        uiView.uiDelegate = nil
        uiView.navigationDelegate = nil

        if let parent = coordinator.parent,
            parent.displayArea == .overlay,
            let playerID = parent.playerID
        {
            let pluginID = parent.pluginDefinition.id.uuidString
            Task { @MainActor in
                PluginOverlaySnapshotRegistry.shared.unregister(
                    playerID: playerID, pluginID: pluginID)
            }
        }

        coordinator.webView = nil
    }

    #if os(macOS)
        static func dismantleNSView(_ uiView: WKWebView, coordinator: Coordinator) {
            dismantlePlatformWebView(uiView, coordinator: coordinator)
        }
    #else
        static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
            dismantlePlatformWebView(uiView, coordinator: coordinator)
        }
    #endif

    private func makeRuntimeInfoContext() -> [String: Any] {
        let bundle = Bundle.main
        let appVersion =
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion =
            (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
        let runtimePlayerID: Any = {
            if displayArea == .overlay {
                return playerID ?? NSNull()
            }
            return NSNull()
        }()

        return [
            "platform": {
                #if os(macOS)
                    "macOS"
                #else
                    "iOS"
                #endif
            }(),
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "appVersion": appVersion ?? NSNull(),
            "buildVersion": buildVersion,
            "bundleIdentifier": bundle.bundleIdentifier ?? NSNull(),
            "bridgeVersion": 2,
            "displayAreaType": displayArea.rawValue,
            "playerID": runtimePlayerID,
        ]
    }

    private func makeApplicationNameForUserAgent() -> String {
        let appVersion =
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "1"
        return "kiririn/\(appVersion)"
    }

    private func injectPlayables(
        into webView: WKWebView, coordinator: Coordinator, force: Bool = false
    ) {
        let currentIDs = Set(appModel.activePlayerStates.map { $0.id })
        if let lastIDs = coordinator.lastInjectedPlayerIDs {
            let removedIDs = lastIDs.subtracting(currentIDs)
            for removedID in removedIDs {
                let js =
                    "if(window.kiririn && window.kiririn._onPlayerClosed) window.kiririn._onPlayerClosed(\"\(removedID)\");"
                webView.evaluateJavaScript(js)
            }
        }
        coordinator.lastInjectedPlayerIDs = currentIDs

        let playables = appModel.activePlayerStates.compactMap { state -> [String: Any]? in
            guard var schema = state.currentPlayable?.toPluginSchema() else { return nil }
            schema["playerID"] = state.id
            return schema
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: playables, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return }

        if !force, let last = coordinator.lastInjectedPlayablesJson, last == json {
            return
        }
        coordinator.lastInjectedPlayablesJson = json

        let js =
            "if(window.kiririn && window.kiririn._onPlayablesChange) window.kiririn._onPlayablesChange(\(json));"
        webView.evaluateJavaScript(js)
    }

    private func loadPluginPage(into webView: WKWebView) {
        if let extensionRuntime,
            let extensionPageURL = extensionRuntime.pageURL(for: displayArea)
        {
            webView.load(URLRequest(url: extensionPageURL))
        }
    }

    private func currentPageURLString() -> String? {
        extensionRuntime?.pageURL(for: displayArea)?.absoluteString
    }

    private func injectStatuses(
        into webView: WKWebView, coordinator: Coordinator, force: Bool = false
    ) {
        let statuses = appModel.activePlayerStates.compactMap { state -> [String: Any]? in
            guard let s = state.playbackStatus as PlayerPlaybackStatus?,
                state.currentPlayable != nil
            else { return nil }
            return [
                "playerID": state.id,
                "playableID": s.playableID ?? "",
                "isPlaying": s.isPlaying,
                "time": s.time,
                "position": s.position,
                "rate": s.rate,
            ]
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: statuses, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return }

        if !force, let last = coordinator.lastInjectedStatusesJson, last == json {
            return
        }
        coordinator.lastInjectedStatusesJson = json

        let js =
            "if(window.kiririn && window.kiririn._onPlayerStatusesChange) window.kiririn._onPlayerStatusesChange(\(json));"
        webView.evaluateJavaScript(js)
    }

    private func injectFocus(into webView: WKWebView, coordinator: Coordinator, force: Bool = false)
    {
        let activeIDs = Set(appModel.activePlayerStates.map(\.id))
        let normalizedFocusedID = appModel.focusedPlayerID.flatMap {
            activeIDs.contains($0) ? $0 : nil
        }
        let focusedID = normalizedFocusedID ?? ""

        if !force, let last = coordinator.lastInjectedFocusedPlayerID, last == focusedID {
            return
        }
        coordinator.lastInjectedFocusedPlayerID = focusedID

        let js =
            "if(window.kiririn && window.kiririn._onFocusedPlayerIDChange) window.kiririn._onFocusedPlayerIDChange(\(focusedID.isEmpty ? "null" : "\"\(focusedID)\""));"
        webView.evaluateJavaScript(js)
    }

    private func makeBridgeJS() -> String {
        let playables = appModel.activePlayerStates.compactMap { state -> [String: Any]? in
            guard var schema = state.currentPlayable?.toPluginSchema() else { return nil }
            schema["playerID"] = state.id
            return schema
        }
        let statuses = appModel.activePlayerStates.compactMap { state -> [String: Any]? in
            guard let s = state.playbackStatus as PlayerPlaybackStatus?,
                state.currentPlayable != nil
            else { return nil }
            return [
                "playerID": state.id,
                "playableID": s.playableID ?? "",
                "isPlaying": s.isPlaying,
                "time": s.time,
                "position": s.position,
                "rate": s.rate,
            ]
        }
        let activeIDs = Set(appModel.activePlayerStates.map(\.id))
        let focusedID = appModel.focusedPlayerID.flatMap { activeIDs.contains($0) ? $0 : nil } ?? ""

        let playablesJson =
            (try? JSONSerialization.data(withJSONObject: playables, options: [.sortedKeys])).flatMap
        { String(data: $0, encoding: .utf8) } ?? "[]"
        let statusJson =
            (try? JSONSerialization.data(withJSONObject: statuses, options: [.sortedKeys])).flatMap
        { String(data: $0, encoding: .utf8) } ?? "[]"

        guard
            let runtimeInfoData = try? JSONSerialization.data(
                withJSONObject: makeRuntimeInfoContext(), options: [.sortedKeys]),
            let runtimeInfoString = String(data: runtimeInfoData, encoding: .utf8)
        else {
            return "window.kiririn = {};"
        }

        let safeAreaInsetsString =
            (try? JSONSerialization.data(
                withJSONObject: safeAreaInsets.asDictionary,
                options: [.sortedKeys]
            )).flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"bottom":0,"left":0,"right":0,"top":0}"#

        return """
            window.kiririn = {
                _playables: \(playablesJson),
                _playablesListeners: [],
                _statuses: \(statusJson),
                _statusesListeners: [],
                _focusedPlayerID: \(focusedID.isEmpty ? "null" : "\"\(focusedID)\""),
                _focusedPlayerIDListeners: [],
                _playerClosedListeners: [],
                _runtimeInfo: \(runtimeInfoString),
                _safeAreaInsets: \(safeAreaInsetsString),
                _deeplinkOpenedListeners: [],
                _captureTakenListeners: [],
                _captureBlobResolvers: Object.create(null),
                _captureEventsSubscribed: false,

                getPlayables: function() { return this._playables; },
                onPlayablesChange: function(callback) { this._playablesListeners.push(callback); },
                _onPlayablesChange: function(playables) {
                    this._playables = playables;
                    this._playablesListeners.forEach(function(cb) { try { cb(playables); } catch(e) {} });
                },

                getPlayerStatuses: function() { return this._statuses; },
                onPlayerStatusesChange: function(callback) { this._statusesListeners.push(callback); },
                _onPlayerStatusesChange: function(statuses) {
                    this._statuses = statuses;
                    this._statusesListeners.forEach(function(cb) { try { cb(statuses); } catch(e) {} });
                },

                getFocusedPlayerID: function() { return this._focusedPlayerID; },
                onFocusedPlayerIDChange: function(callback) { this._focusedPlayerIDListeners.push(callback); },
                _onFocusedPlayerIDChange: function(id) {
                    this._focusedPlayerID = id;
                    this._focusedPlayerIDListeners.forEach(function(cb) { try { cb(id); } catch(e) {} });
                },

                onPlayerClosed: function(callback) { this._playerClosedListeners.push(callback); },
                _onPlayerClosed: function(playerID) {
                    if (this._focusedPlayerID === playerID) {
                        this._focusedPlayerID = null;
                        this._focusedPlayerIDListeners.forEach(function(cb) { try { cb(null); } catch(e) {} });
                    }
                    this._playerClosedListeners.forEach(function(cb) { try { cb(playerID); } catch(e) {} });
                },

                getPlayable: function(playerID) {
                    return this.getPlayables().find(p => p.playerID === playerID) || null;
                },

                getPlayerStatus: function(playerID) {
                    return this.getPlayerStatuses().find(s => s.playerID === playerID) || null;
                },

                getRuntimeInfo: function() { return this._runtimeInfo; },

                _applySafeAreaInsetsToCSS: function() {
                    if (!this._safeAreaInsets) { return; }
                    const insets = this._safeAreaInsets;
                    const root = document.documentElement;
                    if (!root || !root.style) { return; }
                    root.style.setProperty('--kiririn-safe-area-inset-top', String(insets.top) + 'px');
                    root.style.setProperty('--kiririn-safe-area-inset-right', String(insets.right) + 'px');
                    root.style.setProperty('--kiririn-safe-area-inset-bottom', String(insets.bottom) + 'px');
                    root.style.setProperty('--kiririn-safe-area-inset-left', String(insets.left) + 'px');
                },

                onDeeplinkOpened: function(callback) { this._deeplinkOpenedListeners.push(callback); },
                _emitDeeplinkOpened: function(payload) {
                    this._deeplinkOpenedListeners.forEach(function(cb) { try { cb(payload); } catch(e) {} });
                },

                onCaptureTaken: function(callback) {
                    this._captureTakenListeners.push(callback);
                    if (!this._captureEventsSubscribed && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kiririn) {
                        this._captureEventsSubscribed = true;
                        window.webkit.messageHandlers.kiririn.postMessage({type: '_captureTakenSubscribe'});
                    }
                },
                _emitCaptureTaken: function(payload) {
                    const normalizedPayload = payload ? Object.assign({}, payload, {
                        capturedAt: new Date(payload.capturedAt * 1000),
                        variants: Array.isArray(payload.variants) ? payload.variants : []
                    }) : payload;
                    this._captureTakenListeners.forEach(function(cb) { try { cb(normalizedPayload); } catch(e) {} });
                },

                sendMessage: function(type, data) {
                    window.webkit.messageHandlers.kiririn.postMessage({type: type, data: data});
                },

                play: function(playerID) {
                    window.webkit.messageHandlers.kiririn.postMessage({type: 'player:play', data: {playerID: playerID || null}});
                },

                pause: function(playerID) {
                    window.webkit.messageHandlers.kiririn.postMessage({type: 'player:pause', data: {playerID: playerID || null}});
                },

                togglePlayPause: function(playerID) {
                    window.webkit.messageHandlers.kiririn.postMessage({type: 'player:togglePlayPause', data: {playerID: playerID || null}});
                },

                seek: function(position, playerID) {
                    window.webkit.messageHandlers.kiririn.postMessage({type: 'player:seek', data: {position: position, playerID: playerID || null}});
                },

                getCaptureBlob: function(captureID, variant) {
                    return this._performCaptureBlobRequest(captureID, variant);
                },

                _resolveCaptureBlob: function(requestID, payload) {
                    const pending = this._captureBlobResolvers[requestID];
                    if (!pending) { return; }
                    delete this._captureBlobResolvers[requestID];

                    if (!payload || typeof payload.bodyBase64 !== 'string') {
                        pending.resolve(null);
                        return;
                    }

                    try {
                        const binary = atob(payload.bodyBase64);
                        const buffer = new Uint8Array(binary.length);
                        for (let index = 0; index < binary.length; index += 1) {
                            buffer[index] = binary.charCodeAt(index);
                        }
                        pending.resolve(new Blob([buffer], {
                            type: payload.mimeType || 'application/octet-stream'
                        }));
                    } catch (error) {
                        pending.reject(error);
                    }
                },

                _rejectCaptureBlob: function(requestID, message) {
                    const pending = this._captureBlobResolvers[requestID];
                    if (!pending) { return; }
                    delete this._captureBlobResolvers[requestID];
                    pending.reject(new TypeError(message || 'Capture blob request failed'));
                }
            };

            (function() {
                let nextCaptureBlobRequestID = 0;
                window.kiririn._performCaptureBlobRequest = function(captureID, variant) {
                    if (typeof captureID !== 'string' || captureID.length === 0 || (variant !== 'original' && variant !== 'composite')) {
                        return Promise.reject(new TypeError('Invalid capture request'));
                    }

                    if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.kiririn) {
                        return Promise.reject(new TypeError('Kiririn bridge is unavailable'));
                    }

                    return new Promise(function(resolve, reject) {
                        const requestID = 'capture-blob-' + (++nextCaptureBlobRequestID);
                        window.kiririn._captureBlobResolvers[requestID] = {
                            resolve: resolve,
                            reject: reject
                        };
                        window.webkit.messageHandlers.kiririn.postMessage({
                            type: '_captureBlobRequest',
                            data: {
                                requestID: requestID,
                                captureID: captureID,
                                variant: variant
                            }
                        });
                    });
                };
            })();

            window.kiririn._applySafeAreaInsetsToCSS();

            // Logging interception
            (function() {
                function presentUnhandledPluginError(message) {
                    window.alert(message);
                }

                window.onerror = function(message) {
                    presentUnhandledPluginError(String(message));
                };

                window.onunhandledrejection = function(event) {
                    presentUnhandledPluginError(String(event.reason));
                };
            })();
            """
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
        var parent: PluginWebView?
        weak var webView: WKWebView?
        var lastLoadedPageURL: String?
        var lastReloadToken: Int = 0
        var lastInjectedPlayablesJson: String?
        var lastInjectedStatusesJson: String?
        var lastInjectedFocusedPlayerID: String?
        var lastInjectedPlayerIDs: Set<String>?
        var lastInjectedDeeplinkToken: Int = 0
        var isPageReady = false
        var wantsCaptureEvents = false
        var pendingDeeplinkEvents: [URL] = []
        var announcedCaptureEvents: [String: PluginCaptureEvent] = [:]
        var captureEventCancellable: AnyCancellable?
        let onCrash: @MainActor () -> Void
        private let logger = Logger(label: "PluginBridge")

        init(parent: PluginWebView, onCrash: @escaping @MainActor () -> Void) {
            self.parent = parent
            self.onCrash = onCrash
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            Task { @MainActor in
                guard let body = message.body as? [String: Any],
                    let type = body["type"] as? String
                else { return }

                if type == "_captureTakenSubscribe" {
                    wantsCaptureEvents = true
                    subscribeToCaptureEventsIfNeeded()
                } else if type == "_captureBlobRequest" {
                    guard let data = body["data"] as? [String: Any] else { return }
                    await handleCaptureBlobRequest(data)
                } else if type == "player:play" || type == "player:pause"
                    || type == "player:togglePlayPause" || type == "player:seek"
                {
                    let data = body["data"] as? [String: Any]
                    let requestedPlayerID = data?["playerID"] as? String
                    let propPlayerID = self.parent?.playerID
                    let focusedPlayerID = self.parent?.appModel.focusedPlayerID
                    let firstPlayerID = self.parent?.appModel.activePlayerStates.first?.id
                    let resolvedID =
                        requestedPlayerID ?? propPlayerID ?? focusedPlayerID ?? firstPlayerID
                    guard let resolvedID,
                        let target = self.parent?.appModel.activePlayerStates.first(where: {
                            $0.id == resolvedID
                        })
                    else { return }
                    switch type {
                    case "player:play":
                        if !target.isPlaying { target.togglePlayPause() }
                    case "player:pause":
                        if target.isPlaying { target.togglePlayPause() }
                    case "player:togglePlayPause":
                        target.togglePlayPause()
                    case "player:seek":
                        if let rawPosition = data?["position"] as? Double {
                            target.seek(to: Float(max(0.0, min(1.0, rawPosition))))
                        }
                    default:
                        break
                    }
                }
            }
        }

        @MainActor
        private func subscribeToCaptureEventsIfNeeded() {
            guard captureEventCancellable == nil else { return }

            captureEventCancellable = CaptureService.shared.didCaptureForPlugin.sink {
                [weak self] event in
                guard let self else { return }
                guard self.wantsCaptureEvents,
                    self.isPageReady,
                    self.canReceiveCaptureEvent(for: event.playerID)
                else {
                    return
                }

                self.dispatchPluginCaptureEvent(event)
            }
        }

        @MainActor
        private func canReceiveCaptureEvent(for playerID: String) -> Bool {
            guard let contextPlayerID = parent?.playerID else {
                // Standalone plugin screens do not carry a bound playerID.
                // Treat them as global capture observers once they opt in.
                return true
            }
            return contextPlayerID == playerID
        }

        @MainActor
        private func dispatchPluginCaptureEvent(_ event: PluginCaptureEvent) {
            announcedCaptureEvents[event.captureID] = event
            let payload: [String: Any] = [
                "playerID": event.playerID,
                "captureID": event.captureID,
                "capturedAt": event.capturedAt.timeIntervalSince1970,
                "variants": event.variants.map { Self.captureVariantObject(from: $0) },
            ]

            guard let payloadLiteral = Self.javaScriptObjectLiteral(payload) else { return }
            evaluateJavaScript(
                "if (window.kiririn && window.kiririn._emitCaptureTaken) { window.kiririn._emitCaptureTaken(\(payloadLiteral)); }"
            )
        }

        @MainActor
        private func handleCaptureBlobRequest(_ data: [String: Any]) async {
            guard let requestID = data["requestID"] as? String else { return }
            guard let captureID = data["captureID"] as? String,
                let variantRawValue = data["variant"] as? String,
                let variant = PluginCaptureVariant(rawValue: variantRawValue)
            else {
                rejectCaptureBlob(requestID: requestID, message: "キャプチャ要求が不正です")
                return
            }

            guard let announcedEvent = announcedCaptureEvents[captureID] else {
                rejectCaptureBlob(requestID: requestID, message: "このコンテキストでは対象のキャプチャを取得できません")
                return
            }

            guard canReceiveCaptureEvent(for: announcedEvent.playerID) else {
                rejectCaptureBlob(requestID: requestID, message: "このコンテキストでは対象のキャプチャを取得できません")
                return
            }

            guard announcedEvent.variants.contains(where: { $0.type == variant }) else {
                rejectCaptureBlob(requestID: requestID, message: "このコンテキストでは対象のキャプチャを取得できません")
                return
            }

            guard
                let blob = await CaptureService.shared.captureBlob(
                    captureID: captureID,
                    variant: variant
                )
            else {
                resolveCaptureBlob(requestID: requestID, payload: nil)
                return
            }

            resolveCaptureBlob(
                requestID: requestID,
                payload: [
                    "bodyBase64": blob.data.base64EncodedString(),
                    "mimeType": blob.mimeType,
                ]
            )
        }

        func queueDeeplinkEvent(_ url: URL) {
            pendingDeeplinkEvents.append(url)
            flushDeeplinkEventsIfPossible()
        }

        private func flushDeeplinkEventsIfPossible() {
            guard isPageReady else { return }
            while !pendingDeeplinkEvents.isEmpty {
                let url = pendingDeeplinkEvents.removeFirst()
                guard let payloadLiteral = Self.javaScriptObjectLiteral(["url": url.absoluteString])
                else { continue }
                evaluateJavaScript(
                    "if (window.kiririn && window.kiririn._emitDeeplinkOpened) { window.kiririn._emitDeeplinkOpened(\(payloadLiteral)); }"
                )
            }
        }

        private func resolveCaptureBlob(requestID: String, payload: [String: Any]?) {
            guard let requestIDLiteral = Self.javaScriptStringLiteral(requestID) else { return }
            let payloadLiteral = payload.flatMap(Self.javaScriptObjectLiteral) ?? "null"

            evaluateJavaScript(
                "if (window.kiririn && window.kiririn._resolveCaptureBlob) { window.kiririn._resolveCaptureBlob(\(requestIDLiteral), \(payloadLiteral)); }"
            )
        }

        private func rejectCaptureBlob(requestID: String, message: String) {
            guard let requestIDLiteral = Self.javaScriptStringLiteral(requestID),
                let messageLiteral = Self.javaScriptStringLiteral(message)
            else { return }

            evaluateJavaScript(
                "if (window.kiririn && window.kiririn._rejectCaptureBlob) { window.kiririn._rejectCaptureBlob(\(requestIDLiteral), \(messageLiteral)); }"
            )
        }

        private func evaluateJavaScript(_ script: String) {
            let webView = self.webView
            Task { @MainActor in
                try? await webView?.evaluateJavaScript(script)
            }
        }

        nonisolated private static func javaScriptStringLiteral(_ value: String) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
                let json = String(data: data, encoding: .utf8)
            else {
                return nil
            }

            return String(json.dropFirst().dropLast())
        }

        nonisolated private static func javaScriptObjectLiteral(_ value: [String: Any]) -> String? {
            guard JSONSerialization.isValidJSONObject(value),
                let data = try? JSONSerialization.data(
                    withJSONObject: value, options: [.sortedKeys]),
                let json = String(data: data, encoding: .utf8)
            else {
                return nil
            }

            return json
        }

        nonisolated private static func captureVariantObject(
            from variant: PluginCaptureVariantMetadata
        ) -> [String: Any] {
            [
                "type": variant.type.rawValue,
                "overlayPluginManifestIDs": variant.overlayPluginManifestIDs,
            ]
        }

        // MARK: - WKNavigationDelegate

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Task { @MainActor in
                onCrash()
            }
        }

        // MARK: - WKUIDelegate

        @MainActor
        func webView(
            _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
        ) {
            #if os(macOS)
                let alert = NSAlert()
                alert.messageText = message
                alert.addButton(withTitle: "OK")
                if let window = webView.window ?? NSApp.mainWindow {
                    alert.beginSheetModal(for: window) { _ in completionHandler() }
                } else {
                    _ = alert.runModal()
                    completionHandler()
                }
            #else
                let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                alert.addAction(
                    UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
                findParentViewController(of: webView)?.present(alert, animated: true)
            #endif
        }

        @MainActor
        func webView(
            _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
        ) {
            #if os(macOS)
                let alert = NSAlert()
                alert.messageText = message
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "キャンセル")
                if let window = webView.window ?? NSApp.mainWindow {
                    alert.beginSheetModal(for: window) { response in
                        completionHandler(response == .alertFirstButtonReturn)
                    }
                } else {
                    completionHandler(alert.runModal() == .alertFirstButtonReturn)
                }
            #else
                let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                alert.addAction(
                    UIAlertAction(title: "キャンセル", style: .cancel) { _ in completionHandler(false) })
                alert.addAction(
                    UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
                findParentViewController(of: webView)?.present(alert, animated: true)
            #endif
        }

        @MainActor
        func webView(
            _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?, initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            #if os(macOS)
                let alert = NSAlert()
                alert.messageText = prompt
                let input = NSTextField(string: defaultText ?? "")
                input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
                alert.accessoryView = input
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "キャンセル")
                if let window = webView.window ?? NSApp.mainWindow {
                    alert.beginSheetModal(for: window) { response in
                        completionHandler(
                            response == .alertFirstButtonReturn ? input.stringValue : nil)
                    }
                } else {
                    let response = alert.runModal()
                    completionHandler(response == .alertFirstButtonReturn ? input.stringValue : nil)
                }
            #else
                let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
                alert.addTextField { textField in
                    textField.text = defaultText
                }
                alert.addAction(
                    UIAlertAction(title: "キャンセル", style: .cancel) { _ in completionHandler(nil) })
                alert.addAction(
                    UIAlertAction(title: "OK", style: .default) { _ in
                        completionHandler(alert.textFields?.first?.text)
                    })
                findParentViewController(of: webView)?.present(alert, animated: true)
            #endif
        }

        #if !os(macOS)
            private func findParentViewController(of view: UIView) -> UIViewController? {
                var parentResponder: UIResponder? = view
                while parentResponder != nil {
                    parentResponder = parentResponder?.next
                    if let viewController = parentResponder as? UIViewController {
                        return viewController
                    }
                }
                return nil
            }
        #endif

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageReady = true
            flushDeeplinkEventsIfPossible()
            // キャッシュをリセットした直後の reload 完了後に、改めて全状態を注入する
            parent?.injectAllStates(into: webView, coordinator: self, force: true)
        }
    }
}

private class LeakAversionScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var handler: WKScriptMessageHandler?

    init(handler: WKScriptMessageHandler) {
        self.handler = handler
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        handler?.userContentController(userContentController, didReceive: message)
    }
}
