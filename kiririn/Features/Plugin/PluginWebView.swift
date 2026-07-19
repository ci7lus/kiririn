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

#if os(macOS)
    typealias PluginWebViewRepresentable = NSViewRepresentable
#else
    typealias PluginWebViewRepresentable = UIViewRepresentable
#endif

@MainActor
struct PluginWebView: PluginWebViewRepresentable {
    let pluginDefinition: PluginDefinition
    let extensionRuntime: ExtensionPluginRuntime
    let appModel: AppModel
    let reloadKey: PluginReloadKey
    let displayArea: PluginDisplayArea
    let playerID: String?
    let safeAreaInsets: PluginSafeAreaInsets
    let deeplinkURL: URL?
    let deeplinkToken: Int
    let stateHash: String
    let onCrash: @MainActor () -> Void
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, onCrash: onCrash)
    }

    private func makePlatformWebView(context: Context) -> WKWebView {
        let config = extensionRuntime.webViewConfiguration
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
        context.coordinator.prepareForPageLoad(
            pageURL: currentPageURLString(),
            reloadKey: reloadKey
        )

        if displayArea == .overlay, let pid = playerID {
            PluginOverlaySnapshotRegistry.shared.register(
                webView,
                playerID: pid,
                pluginID: pluginDefinition.id.uuidString
            )
        }

        loadPluginPage(into: webView)
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
        context.coordinator.parent = self
        context.coordinator.onCrash = onCrash

        let tokenChanged = context.coordinator.lastReloadKey != reloadKey

        if pageChanged || tokenChanged {
            context.coordinator.prepareForPageLoad(
                pageURL: currentPageURLString(),
                reloadKey: reloadKey
            )
            loadPluginPage(into: webView)
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
        uiView.configuration.userContentController.removeAllUserScripts()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "kiririn")
        uiView.uiDelegate = nil
        uiView.navigationDelegate = nil

        if let parent = coordinator.parent,
            parent.displayArea == .overlay,
            let playerID = parent.playerID
        {
            let pluginID = parent.pluginDefinition.id.uuidString
            PluginOverlaySnapshotRegistry.shared.unregister(
                uiView, playerID: playerID, pluginID: pluginID)
        }

        coordinator.tearDown()
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
            "bridgeVersion": 3,
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
        if let extensionPageURL = extensionRuntime.pageURL(for: displayArea) {
            webView.load(URLRequest(url: extensionPageURL))
        }
    }

    private func currentPageURLString() -> String? {
        extensionRuntime.pageURL(for: displayArea)?.absoluteString
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

                seekToTime: function(time, playerID) {
                    window.webkit.messageHandlers.kiririn.postMessage({type: 'player:seekToTime', data: {time: time, playerID: playerID || null}});
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
        var lastReloadKey: PluginReloadKey?
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
        var onCrash: (@MainActor () -> Void)?
        private let logger = Logger(label: "PluginBridge")

        init(parent: PluginWebView, onCrash: @escaping @MainActor () -> Void) {
            self.parent = parent
            self.onCrash = onCrash
        }

        func prepareForPageLoad(pageURL: String?, reloadKey: PluginReloadKey) {
            lastLoadedPageURL = pageURL
            lastReloadKey = reloadKey
            lastInjectedPlayablesJson = nil
            lastInjectedStatusesJson = nil
            lastInjectedFocusedPlayerID = nil
            lastInjectedPlayerIDs = nil
            wantsCaptureEvents = false
            isPageReady = false
        }

        func tearDown() {
            captureEventCancellable?.cancel()
            captureEventCancellable = nil
            parent = nil
            onCrash = nil
            pendingDeeplinkEvents.removeAll()
            announcedCaptureEvents.removeAll()
            lastInjectedPlayablesJson = nil
            lastInjectedStatusesJson = nil
            lastInjectedFocusedPlayerID = nil
            lastInjectedPlayerIDs = nil
            wantsCaptureEvents = false
            isPageReady = false
            webView = nil
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
                    || type == "player:seekToTime"
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
                    case "player:seekToTime":
                        if let time = data?["time"] as? Double {
                            target.seek(toTime: time)
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
                onCrash?()
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
