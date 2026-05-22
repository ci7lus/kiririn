import Combine
import Logging
import SwiftUI
import WebKit

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

enum PluginDisplayArea: String, Codable, CaseIterable, Sendable {
    case playerOverlay
    case pluginSettings
    case pluginScreen

    var localizedName: String {
        switch self {
        case .playerOverlay: return "プレイヤーオーバーレイ"
        case .pluginSettings: return "プラグイン設定"
        case .pluginScreen: return "プラグインスクリーン"
        }
    }
}

enum PluginWebOrigin {
    static func host(pluginID: String, manifestContextId: String?) -> String {
        if let manifestContextId, !manifestContextId.isEmpty {
            return "\(manifestContextId).ctx.plugin.kiririn.internal"
        }
        return "\(pluginID.lowercased()).plugin.kiririn.internal"
    }

    static func url(pluginID: String, manifestContextId: String?) -> URL? {
        URL(string: "https://\(host(pluginID: pluginID, manifestContextId: manifestContextId))/")
    }

    static func host(for plugin: PluginDefinition) -> String {
        host(pluginID: plugin.id.uuidString, manifestContextId: plugin.manifestContextId)
    }
}

@MainActor
enum PluginWebsiteDataStore {
    private static let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
    private static let cleanupHTML = """
        <!doctype html>
        <html>
        <head><meta charset=\"utf-8\"></head>
        <body></body>
        </html>
        """
    private static let cleanupScript = """
            try { localStorage.clear(); } catch {}
            try { sessionStorage.clear(); } catch {}
            try {
                if ('caches' in self) {
                    const cacheKeys = await caches.keys();
                    await Promise.all(cacheKeys.map(key => caches.delete(key)));
                }
            } catch {}
            try {
                if ('indexedDB' in self && typeof indexedDB.databases === 'function') {
                    const databases = await indexedDB.databases();
                    await Promise.all((databases || []).map(database => {
                        if (!database || !database.name) {
                            return Promise.resolve();
                        }
                        return new Promise(resolve => {
                            const request = indexedDB.deleteDatabase(database.name);
                            request.onsuccess = () => resolve();
                            request.onerror = () => resolve();
                            request.onblocked = () => resolve();
                        });
                    }));
                }
            } catch {}
            try {
                if ('serviceWorker' in navigator) {
                    const registrations = await navigator.serviceWorker.getRegistrations();
                    await Promise.all(registrations.map(registration => registration.unregister()));
                }
            } catch {}
            try {
                const expires = 'expires=Thu, 01 Jan 1970 00:00:00 GMT';
                const cookieNames = document.cookie
                    .split(';')
                    .map(entry => entry.split('=')[0]?.trim())
                    .filter(Boolean);
                for (const name of cookieNames) {
                    document.cookie = `${name}=; ${expires}; path=/`;
                    document.cookie = `${name}=; ${expires}; path=/; domain=${location.hostname}`;
                }
            } catch {}
            return true;
        """

    @MainActor
    static func removeAllData(forHost host: String) async throws {
        let dataStore = WKWebsiteDataStore.default()
        try await clearCookies(forHost: host, dataStore: dataStore)
        try await clearOriginStorage(forHost: host, dataStore: dataStore)

        let records = await exactRecords(forHost: host, dataStore: dataStore)
        guard !records.isEmpty else { return }

        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: dataTypes, for: records) {
                continuation.resume(returning: ())
            }
        }
    }

    private static func exactRecords(forHost host: String, dataStore: WKWebsiteDataStore) async
        -> [WKWebsiteDataRecord]
    {
        await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
                continuation.resume(
                    returning: records.filter {
                        $0.displayName.caseInsensitiveCompare(host) == .orderedSame
                    })
            }
        }
    }

    private static func clearCookies(forHost host: String, dataStore: WKWebsiteDataStore)
        async throws
    {
        let cookieStore = dataStore.httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }

        let matchingCookies = cookies.filter { cookie in
            cookie.domain.caseInsensitiveCompare(host) == .orderedSame
                || cookie.domain.caseInsensitiveCompare(".\(host)") == .orderedSame
        }

        for cookie in matchingCookies {
            await withCheckedContinuation { continuation in
                cookieStore.delete(cookie) {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func clearOriginStorage(forHost host: String, dataStore: WKWebsiteDataStore)
        async throws
    {
        try await OriginCleaner(host: host, dataStore: dataStore).run()
    }

    @MainActor
    private final class OriginCleaner: NSObject, WKNavigationDelegate {
        private let webView: WKWebView
        private let baseURL: URL
        private var continuation: CheckedContinuation<Void, Error>?

        init(host: String, dataStore: WKWebsiteDataStore) throws {
            guard let baseURL = URL(string: "https://\(host)/") else {
                throw NSError(
                    domain: "PluginWebsiteDataStore", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "プラグインのデータ削除に必要な WebView を初期化できませんでした"])
            }

            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = dataStore

            self.baseURL = baseURL
            self.webView = WKWebView(frame: .zero, configuration: configuration)
            super.init()
            webView.navigationDelegate = self
        }

        func run() async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                webView.loadHTMLString(cleanupHTML, baseURL: baseURL)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                do {
                    _ = try await webView.callAsyncJavaScript(
                        cleanupScript,
                        arguments: [:],
                        in: nil,
                        contentWorld: .page
                    )
                    finish(.success(()))
                } catch {
                    finish(.failure(error))
                }
            }
        }

        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
            finish(.failure(error))
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            finish(.failure(error))
        }

        private func finish(_ result: Result<Void, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            webView.navigationDelegate = nil

            switch result {
            case .success:
                continuation.resume(returning: ())
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }
}

struct PluginOverlayView: View {
    let pluginID: String
    let manifestPluginID: String?
    let htmlContent: String
    let appModel: AppModel
    let reloadToken: Int
    let displayArea: PluginDisplayArea
    let playerID: String?
    let manifestContextId: String?
    let allowedURLPatterns: [String]?
    let viewSize: CGSize
    let onReloadRequested: (() -> Void)?

    init(
        pluginID: String,
        manifestPluginID: String? = nil,
        htmlContent: String,
        appModel: AppModel,
        reloadToken: Int,
        displayArea: PluginDisplayArea,
        playerID: String? = nil,
        manifestContextId: String? = nil,
        allowedURLPatterns: [String]? = nil,
        viewSize: CGSize,
        onReloadRequested: (() -> Void)? = nil
    ) {
        self.pluginID = pluginID
        self.manifestPluginID = manifestPluginID
        self.htmlContent = htmlContent
        self.appModel = appModel
        self.reloadToken = reloadToken
        self.displayArea = displayArea
        self.playerID = playerID
        self.manifestContextId = manifestContextId
        self.allowedURLPatterns = allowedURLPatterns
        self.viewSize = viewSize
        self.onReloadRequested = onReloadRequested
    }

    @State private var isCrashed = false
    @State private var lastError: String?
    @State private var isDetailsExpanded = false
    @State private var pendingOpenURL: URL?
    @State private var openURLToken = 0

    var body: some View {
        // アクティブな全プレイヤーの状態を追跡するハッシュを生成し、これを元に再描画と同期をトリガーさせる。
        // 再生位置(time)は頻繁すぎるため除外するが、番組変更や再生/停止、シーク可否の変化は網羅する。
        let stateHash =
            appModel.activePlayerStates.map {
                "\($0.id):\($0.currentPlayable?.id ?? "none"):\($0.playbackStatus.isPlaying):\($0.currentPlayable?.isSeekable ?? false)"
            }.joined(separator: "|") + (appModel.focusedPlayerID ?? "")

        ZStack {
            PluginWebView(
                pluginID: pluginID,
                htmlContent: htmlContent,
                appModel: appModel,
                reloadToken: reloadToken,
                displayArea: displayArea,
                playerID: playerID,
                manifestContextId: manifestContextId,
                allowedURLPatterns: allowedURLPatterns,
                deepLinkURL: pendingOpenURL,
                deepLinkToken: openURLToken,
                viewSize: viewSize,
                stateHash: stateHash,
                onCrash: {
                    isDetailsExpanded = false
                    isCrashed = true
                },
                onError: { error, isFatal in
                    lastError = error
                    if isFatal {
                        isDetailsExpanded = false
                        isCrashed = true
                    }
                },
                onReloadRequested: onReloadRequested
            )
            .allowsHitTesting(!isCrashed)

            if isCrashed {
                crashView
            }
        }
        .onChange(of: reloadToken) {
            isCrashed = false
            lastError = nil
        }
        .onAppear {
            consumeQueuedOpenURLIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pluginOpenURLRequested)) {
            notification in
            guard let manifestPluginID,
                let userInfo = notification.userInfo,
                let targetManifestID = userInfo["manifestID"] as? String,
                targetManifestID == manifestPluginID,
                let urlString = userInfo["url"] as? String,
                let url = URL(string: urlString)
            else {
                return
            }
            queueOpenURLEvent(url)
        }
    }

    private func consumeQueuedOpenURLIfNeeded() {
        guard let manifestPluginID else {
            return
        }
        let queuedURLs = appModel.consumePendingPluginOpenURLs(manifestID: manifestPluginID)
        guard !queuedURLs.isEmpty else { return }
        for queuedURL in queuedURLs {
            queueOpenURLEvent(queuedURL)
        }
    }

    private func queueOpenURLEvent(_ url: URL) {
        pendingOpenURL = url
        openURLToken += 1
    }

    @ViewBuilder
    private var crashView: some View {
        if displayArea == .playerOverlay {
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
                        onReloadRequested?()
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
    let pluginID: String
    let htmlContent: String
    let appModel: AppModel
    let reloadToken: Int
    let displayArea: PluginDisplayArea
    let playerID: String?
    let manifestContextId: String?
    let allowedURLPatterns: [String]?
    let deepLinkURL: URL?
    let deepLinkToken: Int
    let viewSize: CGSize
    let stateHash: String
    let onCrash: @MainActor () -> Void
    let onError: @MainActor (String, Bool) -> Void
    let onReloadRequested: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            parent: self, onCrash: onCrash, onError: onError, onReloadRequested: onReloadRequested)
    }

    private func makePlatformWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
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
            webView.scrollView.isScrollEnabled = displayArea != .playerOverlay
            webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.lastLoadedHTML = htmlContent
        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.isPageReady = false

        if displayArea == .playerOverlay, let pid = playerID {
            let wv = webView
            let pid = pid
            let plugID = pluginID
            Task { @MainActor in
                PluginOverlaySnapshotRegistry.shared.register(wv, playerID: pid, pluginID: plugID)
            }
        }

        Task { @MainActor in
            await self.applyContentBlockersAndLoad(to: webView)
        }
        return webView
    }

    @MainActor
    private func applyContentBlockersAndLoad(to webView: WKWebView) async {
        let pluginHost = PluginWebOrigin.host(
            pluginID: pluginID, manifestContextId: manifestContextId)
        let rulesJSON = Self.contentBlockerRulesJSON(
            for: allowedURLPatterns, pluginHost: pluginHost)
        let logger = Logger(label: "PluginBridge")
        do {
            let store = Self.makeContentRuleListStore()
            let ruleList: WKContentRuleList = try await withCheckedThrowingContinuation {
                continuation in
                store.compileContentRuleList(
                    forIdentifier: pluginID,
                    encodedContentRuleList: rulesJSON
                ) { ruleList, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let ruleList {
                        continuation.resume(returning: ruleList)
                    } else {
                        continuation.resume(
                            throwing: NSError(domain: "kiririn.plugin", code: -1, userInfo: nil))
                    }
                }
            }
            webView.configuration.userContentController.add(ruleList)
        } catch {
            logger.warning(
                "Content blocker compilation failed for plugin \(pluginID): \(error.localizedDescription). JSON: \(rulesJSON)"
            )
        }
        loadHTML(into: webView)
    }

    private static func makeContentRuleListStore() -> WKContentRuleListStore {
        let fm = FileManager.default
        if let cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let storeURL = cacheDir.appendingPathComponent(
                "kiririn_content_rule_lists", isDirectory: true)
            try? fm.createDirectory(at: storeURL, withIntermediateDirectories: true)
            if let store = WKContentRuleListStore(url: storeURL) {
                return store
            }
        }
        return WKContentRuleListStore.default()
    }

    private static func contentBlockerRulesJSON(for patterns: [String]?, pluginHost: String)
        -> String
    {
        let escapedHost = NSRegularExpression.escapedPattern(for: pluginHost)
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            [
                "trigger": ["url-filter": "^https?://[^/]*\\.kiririn\\.internal/"],
                "action": ["type": "ignore-previous-rules"],
            ],
            [
                "trigger": ["url-filter": "^blob:https?://\(escapedHost)/"],
                "action": ["type": "ignore-previous-rules"],
            ],
        ]
        if let patterns {
            for pattern in patterns {
                rules.append([
                    "trigger": ["url-filter": pattern], "action": ["type": "ignore-previous-rules"],
                ])
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
            let json = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
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
        let htmlChanged = context.coordinator.lastLoadedHTML != htmlContent
        let tokenChanged = context.coordinator.lastReloadToken != reloadToken

        if htmlChanged || tokenChanged {
            context.coordinator.lastLoadedHTML = htmlContent
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.lastInjectedPlayablesJson = nil
            context.coordinator.lastInjectedStatusesJson = nil
            context.coordinator.lastInjectedFocusedPlayerID = nil
            context.coordinator.lastInjectedDisplayArea = nil
            context.coordinator.lastInjectedPlayerIDs = nil
            context.coordinator.wantsCaptureEvents = false
            context.coordinator.cancelAllExternalRequests()
            context.coordinator.isPageReady = false
            webView.configuration.userContentController.removeAllContentRuleLists()
            Task { @MainActor in
                await self.applyContentBlockersAndLoad(to: webView)
            }
        }
        if context.coordinator.lastInjectedOpenURLToken != deepLinkToken {
            context.coordinator.lastInjectedOpenURLToken = deepLinkToken
            if let deepLinkURL {
                context.coordinator.queueOpenURLEvent(deepLinkURL)
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
        injectDisplayArea(into: webView, coordinator: coordinator, force: force)
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
        coordinator.cancelAllExternalRequests()
        coordinator.captureEventCancellable?.cancel()
        coordinator.captureEventCancellable = nil
        uiView.configuration.userContentController.removeAllContentRuleLists()
        uiView.configuration.userContentController.removeAllUserScripts()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "kiririn")
        uiView.uiDelegate = nil
        uiView.navigationDelegate = nil

        if let parent = coordinator.parent,
            parent.displayArea == .playerOverlay,
            let playerID = parent.playerID
        {
            let pluginID = parent.pluginID
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

    private func loadHTML(into webView: WKWebView) {
        if htmlContent.hasPrefix("http://") || htmlContent.hasPrefix("https://") {
            if let url = URL(string: htmlContent) {
                webView.load(URLRequest(url: url))
            }
        } else {
            webView.loadHTMLString(htmlContent, baseURL: pluginBaseURL())
        }
    }

    private func pluginBaseURL() -> URL? {
        PluginWebOrigin.url(pluginID: pluginID, manifestContextId: manifestContextId)
    }

    private func makeApplicationNameForUserAgent() -> String {
        let appVersion =
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
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

    private func injectDisplayArea(
        into webView: WKWebView, coordinator: Coordinator, force: Bool = false
    ) {
        var area: [String: Any] = [
            "type": displayArea.rawValue,
            "width": viewSize.width,
            "height": viewSize.height,
        ]
        if let pid = playerID {
            area["playerID"] = pid
        }

        if !force, let lastArea = coordinator.lastInjectedDisplayArea,
            NSDictionary(dictionary: lastArea).isEqual(to: area)
        {
            return
        }
        coordinator.lastInjectedDisplayArea = area

        guard
            let jsonData = try? JSONSerialization.data(
                withJSONObject: area, options: [.sortedKeys]),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else { return }

        let js =
            "if(window.kiririn && window.kiririn._onDisplayAreaChange){window.kiririn._onDisplayAreaChange(\(jsonString));}"
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

        var displayContext: [String: Any] = [
            "type": displayArea.rawValue,
            "width": viewSize.width,
            "height": viewSize.height,
        ]
        if let pid = playerID {
            displayContext["playerID"] = pid
        }

        guard
            let displayData = try? JSONSerialization.data(
                withJSONObject: displayContext, options: [.sortedKeys]),
            let displayString = String(data: displayData, encoding: .utf8)
        else {
            return "window.kiririn = {};"
        }

        return """
            window.kiririn = {
                _playables: \(playablesJson),
                _playablesListeners: [],
                _statuses: \(statusJson),
                _statusesListeners: [],
                _focusedPlayerID: \(focusedID.isEmpty ? "null" : "\"\(focusedID)\""),
                _focusedPlayerIDListeners: [],
                _playerClosedListeners: [],
                _displayArea: \(displayString),
                _displayAreaListeners: [],
                _openURLListeners: [],
                _captureTakenListeners: [],
                _captureBlobResolvers: Object.create(null),
                _captureEventsSubscribed: false,
                _externalRequestResolvers: Object.create(null),

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

                getDisplayArea: function() { return this._displayArea; },
                onDisplayAreaChange: function(callback) { this._displayAreaListeners.push(callback); },
                _onDisplayAreaChange: function(area) {
                    this._displayArea = area;
                    this._displayAreaListeners.forEach(function(cb) { try { cb(area); } catch(e) {} });
                },

                onOpenURL: function(callback) { this._openURLListeners.push(callback); },
                _emitOpenURL: function(payload) {
                    this._openURLListeners.forEach(function(cb) { try { cb(payload); } catch(e) {} });
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
                        capturedAt: payload.capturedAt == null ? null : new Date(payload.capturedAt * 1000),
                        references: Array.isArray(payload.references) ? payload.references : []
                    }) : payload;
                    this._captureTakenListeners.forEach(function(cb) { try { cb(normalizedPayload); } catch(e) {} });
                },

                reload: function() {
                    window.webkit.messageHandlers.kiririn.postMessage({type: 'reload'});
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

                getCaptureBlob: function(ref) {
                    return this._performCaptureBlobRequest(ref);
                },

                fetch: function(input, init) {
                    return this._performBridgeFetch(input, init);
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
                },

                _resolveExternalRequest: function(requestID, payload) {
                    const pending = this._externalRequestResolvers[requestID];
                    if (!pending) { return; }
                    delete this._externalRequestResolvers[requestID];
                    if (pending.abortHandler && pending.signal) {
                        pending.signal.removeEventListener('abort', pending.abortHandler);
                    }

                    try {
                        const bytes = payload && payload.bodyBase64 ? (function(base64) {
                            const binary = atob(base64);
                            const buffer = new Uint8Array(binary.length);
                            for (let index = 0; index < binary.length; index += 1) {
                                buffer[index] = binary.charCodeAt(index);
                            }
                            return buffer;
                        })(payload.bodyBase64) : new Uint8Array();

                        pending.resolve(new Response(bytes, {
                            status: payload.status || 200,
                            statusText: payload.statusText || '',
                            headers: payload.headers || {}
                        }));
                    } catch (error) {
                        pending.reject(error);
                    }
                },

                _rejectExternalRequest: function(requestID, message) {
                    const pending = this._externalRequestResolvers[requestID];
                    if (!pending) { return; }
                    delete this._externalRequestResolvers[requestID];
                    if (pending.abortHandler && pending.signal) {
                        pending.signal.removeEventListener('abort', pending.abortHandler);
                    }
                    pending.reject(new TypeError(message || 'External request failed'));
                }
            };

            (function() {
                const originalFetch = window.fetch ? window.fetch.bind(window) : null;
                let nextExternalRequestID = 0;
                let nextCaptureBlobRequestID = 0;

                function headersToObject(headers) {
                    const result = {};
                    headers.forEach(function(value, key) {
                        if (Object.prototype.hasOwnProperty.call(result, key)) {
                            result[key] = result[key] + ', ' + value;
                        } else {
                            result[key] = value;
                        }
                    });
                    return result;
                }

                function arrayBufferToBase64(buffer) {
                    const bytes = new Uint8Array(buffer);
                    const chunkSize = 0x8000;
                    let binary = '';

                    for (let index = 0; index < bytes.length; index += chunkSize) {
                        const chunk = bytes.subarray(index, Math.min(index + chunkSize, bytes.length));
                        binary += String.fromCharCode.apply(null, Array.from(chunk));
                    }

                    return btoa(binary);
                }

                async function buildExternalRequestPayload(input, init) {
                    const request = input instanceof Request ? input : new Request(input, init);
                    const url = new URL(request.url, window.location.href);
                    const headers = headersToObject(request.headers);
                    let bodyBase64 = null;

                    if (request.method !== 'GET' && request.method !== 'HEAD') {
                        const bodyBuffer = await request.clone().arrayBuffer();
                        if (bodyBuffer.byteLength > 0) {
                            bodyBase64 = arrayBufferToBase64(bodyBuffer);
                        }
                    }

                    return {
                        request: request,
                        payload: {
                            requestID: 'external-request-' + (++nextExternalRequestID),
                            url: url.toString(),
                            method: request.method,
                            headers: headers,
                            bodyBase64: bodyBase64,
                            credentials: request.credentials
                        }
                    };
                }

                window.kiririn._performBridgeFetch = function(input, init) {
                    let resolvedURL;
                    try {
                        const rawURL = input instanceof Request ? input.url : input;
                        resolvedURL = new URL(rawURL, window.location.href);
                    } catch (error) {
                        if (originalFetch) {
                            return originalFetch(input, init);
                        }
                        return Promise.reject(error);
                    }

                    if (resolvedURL.protocol !== 'http:' && resolvedURL.protocol !== 'https:') {
                        if (originalFetch) {
                            return originalFetch(input, init);
                        }
                        return Promise.reject(new TypeError('Only HTTP(S) requests are supported by kiririn.fetch'));
                    }

                    if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.kiririn) {
                        if (originalFetch) {
                            return originalFetch(input, init);
                        }
                        return Promise.reject(new TypeError('Kiririn bridge is unavailable'));
                    }

                    return (async function() {
                        const prepared = await buildExternalRequestPayload(input, init);
                        const request = prepared.request;
                        const payload = prepared.payload;
                        const signal = request.signal;

                        return await new Promise(function(resolve, reject) {
                            if (signal && signal.aborted) {
                                reject(new DOMException('The operation was aborted.', 'AbortError'));
                                return;
                            }

                            const pending = {
                                resolve: resolve,
                                reject: reject,
                                signal: signal || null,
                                abortHandler: null
                            };

                            if (signal) {
                                pending.abortHandler = function() {
                                    delete window.kiririn._externalRequestResolvers[payload.requestID];
                                    window.webkit.messageHandlers.kiririn.postMessage({
                                        type: '_externalRequestCancel',
                                        data: { requestID: payload.requestID }
                                    });
                                    reject(new DOMException('The operation was aborted.', 'AbortError'));
                                };
                                signal.addEventListener('abort', pending.abortHandler, { once: true });
                            }

                            window.kiririn._externalRequestResolvers[payload.requestID] = pending;
                            window.webkit.messageHandlers.kiririn.postMessage({
                                type: '_externalRequest',
                                data: payload
                            });
                        });
                    })();
                };

                window.kiririn._performCaptureBlobRequest = function(ref) {
                    if (!ref || typeof ref.playerID !== 'string' || typeof ref.captureID !== 'string' || (ref.variant !== 'original' && ref.variant !== 'composite')) {
                        return Promise.reject(new TypeError('Invalid capture reference'));
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
                                ref: {
                                    playerID: ref.playerID,
                                    captureID: ref.captureID,
                                    variant: ref.variant
                                }
                            }
                        });
                    });
                };
            })();

            // Logging interception
            (function() {
                window.onerror = function(message, source, lineno, colno, error) {
                    const stack = error && error.stack ? error.stack : '';
                    const msg = `${message} at ${source}:${lineno}:${colno}\\n${stack}`;
                    window.webkit.messageHandlers.kiririn.postMessage({
                        type: '_error',
                        data: { message: msg }
                    });
                };

                window.onunhandledrejection = function(event) {
                    const error = event.reason;
                    const stack = (error && error.stack) ? error.stack : '';
                    const msg = `Unhandled Rejection: ${error}\\n${stack}`;
                    window.webkit.messageHandlers.kiririn.postMessage({
                        type: '_error',
                        data: { message: msg }
                    });
                };
            })();
            """
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
        var parent: PluginWebView?
        weak var webView: WKWebView?
        var lastLoadedHTML: String?
        var lastReloadToken: Int = 0
        var lastInjectedDisplayArea: [String: Any]?
        var lastInjectedPlayablesJson: String?
        var lastInjectedStatusesJson: String?
        var lastInjectedFocusedPlayerID: String?
        var lastInjectedPlayerIDs: Set<String>?
        var lastInjectedOpenURLToken: Int = 0
        var isPageReady = false
        var wantsCaptureEvents = false
        var pendingOpenURLEvents: [URL] = []
        var pendingExternalRequests: [String: URLSessionDataTask] = [:]
        var captureEventCancellable: AnyCancellable?
        let onCrash: @MainActor () -> Void
        let onError: @MainActor (String, Bool) -> Void
        let onReloadRequested: (() -> Void)?
        private let logger = Logger(label: "PluginBridge")

        init(
            parent: PluginWebView, onCrash: @escaping @MainActor () -> Void,
            onError: @escaping @MainActor (String, Bool) -> Void, onReloadRequested: (() -> Void)?
        ) {
            self.parent = parent
            self.onCrash = onCrash
            self.onError = onError
            self.onReloadRequested = onReloadRequested
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            Task { @MainActor in
                guard let body = message.body as? [String: Any],
                    let type = body["type"] as? String
                else { return }

                if type == "_log" {
                    guard let data = body["data"] as? [String: Any],
                        let level = data["level"] as? String,
                        let msg = data["message"] as? String
                    else { return }

                    switch level {
                    case "warning":
                        logger.warning("[\(message.name)] \(msg)")
                    case "error":
                        logger.error("[\(message.name)] \(msg)")
                        onError(msg, false)
                    default:
                        logger.info("[\(message.name)] \(msg)")
                    }
                } else if type == "_error" {
                    guard let data = body["data"] as? [String: Any],
                        let msg = data["message"] as? String
                    else { return }
                    logger.error("[\(message.name)] \(msg)")
                    onError(msg, true)
                } else if type == "_captureTakenSubscribe" {
                    wantsCaptureEvents = true
                    subscribeToCaptureEventsIfNeeded()
                } else if type == "_captureBlobRequest" {
                    guard let data = body["data"] as? [String: Any] else { return }
                    await handleCaptureBlobRequest(data)
                } else if type == "reload" {
                    onReloadRequested?()
                } else if type == "_externalRequest" {
                    guard let data = body["data"] as? [String: Any] else { return }
                    handleExternalRequest(data)
                } else if type == "_externalRequestCancel" {
                    guard let data = body["data"] as? [String: Any] else { return }
                    cancelExternalRequest(data)
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
            let payload: [String: Any] = [
                "playerID": event.playerID,
                "captureID": event.captureID,
                "capturedAt": event.capturedAt.timeIntervalSince1970,
                "references": event.references.map { Self.captureReferenceObject(from: $0) },
            ]

            guard let payloadLiteral = Self.javaScriptObjectLiteral(payload) else { return }
            evaluateJavaScript(
                "if (window.kiririn && window.kiririn._emitCaptureTaken) { window.kiririn._emitCaptureTaken(\(payloadLiteral)); }"
            )
        }

        @MainActor
        private func handleCaptureBlobRequest(_ data: [String: Any]) async {
            guard let requestID = data["requestID"] as? String else { return }
            guard let ref = data["ref"] as? [String: Any],
                let requestedPlayerID = ref["playerID"] as? String,
                let captureID = ref["captureID"] as? String,
                let variantRawValue = ref["variant"] as? String,
                let variant = PluginCaptureVariant(rawValue: variantRawValue)
            else {
                rejectCaptureBlob(requestID: requestID, message: "キャプチャ参照が不正です")
                return
            }

            guard canReceiveCaptureEvent(for: requestedPlayerID) else {
                rejectCaptureBlob(requestID: requestID, message: "このコンテキストでは対象のキャプチャを取得できません")
                return
            }

            let reference = PluginCaptureBlobReference(
                playerID: requestedPlayerID,
                captureID: captureID,
                variant: variant,
                overlayPluginManifestIDs: []
            )

            guard let blob = await CaptureService.shared.captureBlob(for: reference) else {
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

        private func handleExternalRequest(_ data: [String: Any]) {
            guard let requestID = data["requestID"] as? String else { return }
            guard let urlString = data["url"] as? String,
                let url = URL(string: urlString),
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else {
                rejectExternalRequest(requestID: requestID, message: "外部リクエストURLが無効です")
                return
            }

            let allowedPatterns = parent?.allowedURLPatterns
            if let allowedPatterns {
                let absoluteURL = url.absoluteString
                let isAllowed = allowedPatterns.contains { pattern in
                    guard let regex = try? NSRegularExpression(pattern: pattern) else {
                        return false
                    }
                    return regex.firstMatch(
                        in: absoluteURL, range: NSRange(absoluteURL.startIndex..., in: absoluteURL))
                        != nil
                }
                if !isAllowed {
                    rejectExternalRequest(
                        requestID: requestID, message: "アクセスが許可されていない URL です: \(url.absoluteString)"
                    )
                    return
                }
            } else {
                rejectExternalRequest(requestID: requestID, message: "このプラグインは外部リクエストを宣言していません")
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = (data["method"] as? String)?.uppercased() ?? "GET"

            if let headers = data["headers"] as? [String: Any] {
                for (name, value) in headers {
                    request.setValue(String(describing: value), forHTTPHeaderField: name)
                }
            }

            if let bodyBase64 = data["bodyBase64"] as? String {
                guard let body = Data(base64Encoded: bodyBase64) else {
                    rejectExternalRequest(requestID: requestID, message: "外部リクエスト本文のデコードに失敗しました")
                    return
                }
                request.httpBody = body
            }

            let credentials = (data["credentials"] as? String) ?? "same-origin"
            request.httpShouldHandleCookies = credentials == "include"
            let method = request.httpMethod ?? "GET"
            let requestURL = url.absoluteString

            let task = URLSession.kiririnShared.dataTask(with: request) {
                [weak self] data, response, error in
                guard let self else { return }

                Task { @MainActor in
                    self.pendingExternalRequests[requestID] = nil
                }

                if let error {
                    self.rejectExternalRequest(
                        requestID: requestID, message: error.localizedDescription)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.rejectExternalRequest(
                        requestID: requestID, message: "外部リクエストから有効なレスポンスを受け取れませんでした")
                    return
                }

                self.logger.info(
                    "bridge fetch: \(method) \(requestURL) -> \(httpResponse.statusCode)")

                let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) {
                    partialResult, element in
                    guard let name = element.key as? String else { return }
                    partialResult[name] = String(describing: element.value)
                }

                self.resolveExternalRequest(
                    requestID: requestID,
                    payload: [
                        "status": httpResponse.statusCode,
                        "statusText": HTTPURLResponse.localizedString(
                            forStatusCode: httpResponse.statusCode),
                        "headers": headers,
                        "bodyBase64": (data ?? Data()).base64EncodedString(),
                    ]
                )
            }

            pendingExternalRequests[requestID] = task
            task.resume()
        }

        private func cancelExternalRequest(_ data: [String: Any]) {
            guard let requestID = data["requestID"] as? String else { return }
            pendingExternalRequests[requestID]?.cancel()
            pendingExternalRequests[requestID] = nil
        }

        func cancelAllExternalRequests() {
            for task in pendingExternalRequests.values {
                task.cancel()
            }
            pendingExternalRequests.removeAll()
        }

        func queueOpenURLEvent(_ url: URL) {
            pendingOpenURLEvents.append(url)
            flushOpenURLEventsIfPossible()
        }

        private func flushOpenURLEventsIfPossible() {
            guard isPageReady else { return }
            while !pendingOpenURLEvents.isEmpty {
                let url = pendingOpenURLEvents.removeFirst()
                guard let payloadLiteral = Self.javaScriptObjectLiteral(["url": url.absoluteString])
                else { continue }
                evaluateJavaScript(
                    "if (window.kiririn && window.kiririn._emitOpenURL) { window.kiririn._emitOpenURL(\(payloadLiteral)); }"
                )
            }
        }

        private func resolveExternalRequest(requestID: String, payload: [String: Any]) {
            guard let requestIDLiteral = Self.javaScriptStringLiteral(requestID),
                let payloadLiteral = Self.javaScriptObjectLiteral(payload)
            else { return }

            evaluateJavaScript(
                "if (window.kiririn && window.kiririn._resolveExternalRequest) { window.kiririn._resolveExternalRequest(\(requestIDLiteral), \(payloadLiteral)); }"
            )
        }

        private func rejectExternalRequest(requestID: String, message: String) {
            guard let requestIDLiteral = Self.javaScriptStringLiteral(requestID),
                let messageLiteral = Self.javaScriptStringLiteral(message)
            else { return }

            evaluateJavaScript(
                "if (window.kiririn && window.kiririn._rejectExternalRequest) { window.kiririn._rejectExternalRequest(\(requestIDLiteral), \(messageLiteral)); }"
            )
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

        nonisolated private static func captureReferenceObject(
            from reference: PluginCaptureBlobReference
        ) -> [String: Any] {
            [
                "playerID": reference.playerID,
                "captureID": reference.captureID,
                "variant": reference.variant.rawValue,
                "overlayPluginManifestIDs": reference.overlayPluginManifestIDs,
            ]
        }

        // MARK: - WKNavigationDelegate

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Task { @MainActor in
                onCrash()
            }
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
                url.host?.hasSuffix(".kiririn.internal") == true
            {
                // 自前ドメインへのナビゲーション（リロード等）をインターセプト
                if navigationAction.navigationType == .reload
                    || navigationAction.navigationType == .linkActivated
                {
                    Task { @MainActor in
                        onReloadRequested?()
                    }
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
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
            flushOpenURLEventsIfPossible()
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
