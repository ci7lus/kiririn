import Foundation
import Logging
import WebKit

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

struct DataBroadcastCaptureLayout {
    let canvasSize: CGSize
    let videoFrame: CGRect
}

struct DataBroadcastCaptureSnapshot {
    let image: CGImage
    let layout: DataBroadcastCaptureLayout
}

/// Owns everything needed to run データ放送 for one live playback session:
/// the Mahiron SSE subscription, module fetch scheduling, and the WKWebView
/// hosting the vendored web-bml bundle. Lifecycle is tied to `PlayerState`
/// (created in `play()`, torn down in `cleanup()`/on channel change - see
/// the plan at ~/.claude/plans/mahiron-api-buzzing-pascal.md).
///
/// Design: thin-Swift / fat-JS. This class only does transport (SSE bytes,
/// module GETs) and lifecycle; all ARIB byte-level parsing (PMT sections,
/// DII descriptors, zlib, multipart entities) happens in the JS adapter
/// (web/bml/src/mahiron.ts, pmt.ts, module_decoder.ts), which reuses
/// web-bml/aribts code directly. The minimal Mahiron JSON structs here exist
/// only to decide *which* modules to fetch, not to interpret their content.
@MainActor
@Observable
final class DataBroadcastSession {
    struct InputRequest: Identifiable, Equatable {
        let id: Int
        let characterType: String
        let allowedCharacters: String?
        let maxLength: Int
        let value: String
        let isSecure: Bool
        let isMultiline: Bool
    }

    enum Status: Equatable {
        case idle
        case connecting
        case active
        case unsupported
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var videoRect: CGRect?
    private(set) var isInvisible = false
    /// 実機の「データ取得中...」に相当。コンテンツが待っているモジュール取得が
    /// 保留中のあいだtrue (web-bmlのIndicator.setReceivingStatus由来)。
    private(set) var isReceiving = false
    /// 実機の「通信中...」に相当。通信コンテンツのHTTP GET/POSTが進行中の
    /// あいだtrue (web-bmlのIndicator.setNetworkingGet/PostStatus由来)。
    private(set) var isNetworking = false
    private(set) var usedKeyGroups: Set<String> = []
    private(set) var inputRequest: InputRequest?
    private var receivingClearTask: Task<Void, Never>?
    private var networkingClearTask: Task<Void, Never>?
    private var invisibleUpdateTask: Task<Void, Never>?

    let webView: WKWebView

    func captureLayout(outputHeight: CGFloat) -> DataBroadcastCaptureLayout? {
        let sourceSize = webView.bounds.size
        guard sourceSize.width > 0, sourceSize.height > 0, outputHeight > 0,
            let videoRect, videoRect.width > 0, videoRect.height > 0
        else { return nil }

        let scale = outputHeight / sourceSize.height
        return DataBroadcastCaptureLayout(
            canvasSize: CGSize(width: sourceSize.width * scale, height: outputHeight),
            videoFrame: CGRect(
                x: videoRect.minX * scale,
                y: videoRect.minY * scale,
                width: videoRect.width * scale,
                height: videoRect.height * scale
            )
        )
    }

    func takeCaptureSnapshot(layout: DataBroadcastCaptureLayout) async
        -> DataBroadcastCaptureSnapshot?
    {
        await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in
                #if os(macOS)
                    let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                #else
                    let cgImage = image?.cgImage
                #endif
                continuation.resume(
                    returning: cgImage.map {
                        DataBroadcastCaptureSnapshot(image: $0, layout: layout)
                    })
            }
        }
    }

    private let endpoint: DataBroadcastEndpoint
    private let postalCode: String?
    private let programInfoProvider: () -> BMLProgramInfoPayload?
    private let tuneHandler: (BMLTuneRequest) -> Void
    private let audioStreamHandler: (BMLAudioStreamRequest) -> Void
    private let sseClient = SSEClient()
    private let logger = Logger(label: "DataBroadcastSession")

    private var sseTask: Task<Void, Never>?
    private var started = false
    private var isReady = false
    private var pendingMessages: [String] = []
    private var consecutiveFailures = 0

    // Module fetch scheduling.
    private struct FetchRequest {
        let componentTag: Int
        let moduleId: Int
        let downloadId: UInt32
        let version: Int
        let info: Data
        let priority: Int
    }
    private var fetchQueue: [FetchRequest] = []
    private var delivered: Set<String> = []
    private var inflight: Set<String> = []
    private var activeFetchCount = 0
    private let maxConcurrentFetches = 4
    /// Latest module metadata seen per "componentTag/moduleId". Drives the
    /// periodic reconciliation pass: a module whose fetch failed (or whose
    /// completion event we somehow missed) has no other retry trigger on a
    /// static carousel, and web-bml would wait on it forever showing
    /// データ取得中. Reconciliation re-schedules anything complete-but-
    /// undelivered until it succeeds or is abandoned.
    private var knownModules: [String: MahironModule] = [:]
    private var fetchFailureCounts: [String: Int] = [:]
    private var abandonedFetches: Set<String> = []
    private var reconcileTask: Task<Void, Never>?
    private let maxFetchFailures = 5

    private let scriptMessageProxy: LeakAversionBMLMessageHandler

    init(
        endpoint: DataBroadcastEndpoint, postalCode: String?,
        programInfoProvider: @escaping () -> BMLProgramInfoPayload?,
        tuneHandler: @escaping (BMLTuneRequest) -> Void,
        audioStreamHandler: @escaping (BMLAudioStreamRequest) -> Void
    ) {
        self.endpoint = endpoint
        self.postalCode = DataBroadcastSettings.validatedPostalCode(postalCode)
        self.programInfoProvider = programInfoProvider
        self.tuneHandler = tuneHandler
        self.audioStreamHandler = audioStreamHandler
        let proxy = LeakAversionBMLMessageHandler()
        self.scriptMessageProxy = proxy
        self.webView = Self.makeWebView(
            messageHandler: proxy,
            allowsInternetAccess: DataBroadcastSettings.internetAccessEnabled())
        proxy.session = self
        loadContent()
    }

    // MARK: - Lifecycle

    /// Starts the SSE subscription if not already started. Idempotent -
    /// callers don't need to track whether they've already called this.
    func startIfIdle() {
        guard !started else { return }
        started = true
        status = .connecting
        sendProgramInfo(asInit: true)
        connectSSE()
        startReconciliation()
    }

    func stop() {
        started = false
        sseTask?.cancel()
        sseTask = nil
        reconcileTask?.cancel()
        reconcileTask = nil
        receivingClearTask?.cancel()
        receivingClearTask = nil
        isReceiving = false
        networkingClearTask?.cancel()
        networkingClearTask = nil
        isNetworking = false
        invisibleUpdateTask?.cancel()
        invisibleUpdateTask = nil
        inputRequest = nil
        consecutiveFailures = 0
        sseClient.cancelAll()
        // In-flight fetch Tasks capture `self` weakly and are cheap
        // no-ops if this session is deallocated before they complete.
        fetchQueue.removeAll()
        inflight.removeAll()
        delivered.removeAll()
        knownModules.removeAll()
        fetchFailureCounts.removeAll()
        abandonedFetches.removeAll()
        status = .idle
    }

    /// Call when the app's own program/EPG state changes for the currently
    /// tuned service (see PlayerState.refreshProgramInfo). web-bml has no
    /// internal recovery if a ProgramInfoMessage never arrives at all, but
    /// re-sending on every program change is what drives its
    /// DataEventChanged-adjacent relaunch behavior for program boundaries.
    func refreshProgramInfo() {
        guard started else { return }
        sendProgramInfo(asInit: false)
    }

    func setAudioOutput(volume: Float, isMuted: Bool) {
        post(
            #"{"type":"audioOutput","volume":\#(volume),"muted":\#(isMuted)}"#
        )
    }

    // MARK: - SSE

    private func connectSSE() {
        sseTask?.cancel()
        sseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var receivedAnyEvent = false
                for try await event in self.sseClient.events(
                    url: self.endpoint.eventsURL, headers: self.endpoint.headers)
                {
                    guard !Task.isCancelled else { return }
                    receivedAnyEvent = true
                    // Connection is alive; reset backoff so the next drop
                    // starts with a short delay again.
                    self.consecutiveFailures = 0
                    self.handle(event)
                }
                // Stream ended cleanly (server closed it).
                // If we never received any event, the server likely doesn't
                // support this endpoint or has no data - don't reconnect.
                if !receivedAnyEvent {
                    self.logger.info(
                        "data-broadcast stream ended without any events (server may not support it)"
                    )
                    self.status = .unsupported
                } else {
                    self.maybeReconnect(reason: "stream ended")
                }
            } catch is CancellationError {
                // Expected on stop()/teardown.
            } catch let SSEClientError.httpError(statusCode) where statusCode == 404 {
                self.logger.info("data-broadcast events not supported (404)")
                self.status = .unsupported
            } catch {
                self.logger.warning("data-broadcast SSE error: \(error)")
                self.maybeReconnect(reason: "\(error)")
            }
        }
    }

    /// Reconnect with exponential backoff (2s → 4s → 8s → … → 60s cap).
    /// Gives up after too many consecutive failures without a successful
    /// event in between. Servers that returned 404 are already marked
    /// `.unsupported` and never reach here.
    private func maybeReconnect(reason: String) {
        guard started, status != .unsupported else { return }
        consecutiveFailures += 1
        let maxAttempts = 10
        guard consecutiveFailures <= maxAttempts else {
            status = .failed(reason)
            return
        }
        let delay = min(pow(2.0, Double(consecutiveFailures)), 60.0)
        logger.info(
            "data-broadcast reconnecting in \(Int(delay))s (attempt \(consecutiveFailures)/\(maxAttempts)): \(reason)"
        )
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.started else { return }
            self.connectSSE()
        }
    }

    private func handle(_ event: SSEEvent) {
        if status == .connecting {
            logger.info("data-broadcast SSE connected (first event: \(event.event))")
            status = .active
        }
        postSSE(event: event.event, jsonData: event.data)

        guard let bytes = event.data.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        switch event.event {
        case "snapshot":
            guard
                let snapshot = (try? decoder.decode(MahironSnapshotEnvelope.self, from: bytes))?
                    .snapshot
            else {
                logger.warning("failed to decode snapshot event")
                return
            }
            knownModules.removeAll()
            scheduleAll(components: snapshot.components ?? snapshot.pmt?.components ?? [])
        case "pmt":
            guard let pmt = (try? decoder.decode(MahironPMTEnvelope.self, from: bytes))?.pmt else {
                logger.warning("failed to decode pmt event")
                return
            }
            scheduleAll(components: pmt.components ?? [])
        case "moduleListUpdated":
            guard
                let list = (try? decoder.decode(MahironModuleListEnvelope.self, from: bytes))?
                    .moduleList
            else {
                logger.warning("failed to decode moduleListUpdated event")
                return
            }
            // The DII list is authoritative: drop tracked modules no longer
            // in the carousel so reconciliation doesn't hammer 404s for them.
            let prefix = "\(list.componentTag)/"
            knownModules = knownModules.filter { !$0.key.hasPrefix(prefix) }
            for module in list.modules {
                schedule(componentTag: list.componentTag, module: module)
            }
        case "moduleUpdated":
            guard
                let module = (try? decoder.decode(MahironModuleEnvelope.self, from: bytes))?.module
            else {
                logger.warning("failed to decode moduleUpdated event")
                return
            }
            schedule(componentTag: module.componentTag, module: module)
        default:
            break
        }
    }

    // MARK: - Module fetch scheduling

    private func scheduleAll(components: [MahironComponent]) {
        for component in components {
            for module in component.modules {
                schedule(componentTag: component.componentTag, module: module)
            }
        }
    }

    private func schedule(componentTag: Int, module: MahironModule) {
        knownModules["\(componentTag)/\(module.moduleId)"] = module
        guard module.complete else { return }
        let key = "\(componentTag)/\(module.moduleId)/\(module.downloadId)/\(module.version)"
        guard !delivered.contains(key), !inflight.contains(key), !abandonedFetches.contains(key)
        else { return }

        // Startup component/module (0x40/0x0000, profile A/C) goes first so
        // the d-button feels instant; everything else follows in arrival order.
        let isStartup = componentTag == 0x40 && module.moduleId == 0x0000
        let priority = isStartup ? 0 : 1

        inflight.insert(key)
        fetchQueue.append(
            FetchRequest(
                componentTag: componentTag,
                moduleId: module.moduleId,
                downloadId: module.downloadId,
                version: module.version,
                info: module.info ?? Data(),
                priority: priority
            ))
        fetchQueue.sort { $0.priority < $1.priority }
        drainFetchQueue()
    }

    private func drainFetchQueue() {
        while activeFetchCount < maxConcurrentFetches, !fetchQueue.isEmpty {
            let request = fetchQueue.removeFirst()
            activeFetchCount += 1
            Task { @MainActor [weak self] in
                await self?.performFetch(request, attempt: 1)
            }
        }
    }

    private func performFetch(_ request: FetchRequest, attempt: Int) async {
        let key =
            "\(request.componentTag)/\(request.moduleId)/\(request.downloadId)/\(request.version)"
        let url = endpoint.moduleURL(componentTag: request.componentTag, moduleId: request.moduleId)
        do {
            var urlRequest = URLRequest(url: url)
            for (field, value) in endpoint.headers {
                urlRequest.setValue(value, forHTTPHeaderField: field)
            }
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else {
                throw APIError.httpError(statusCode: http.statusCode, diagnostic: nil)
            }
            inflight.remove(key)
            delivered.insert(key)
            logger.debug(
                "module fetched component=\(request.componentTag) module=\(request.moduleId) bytes=\(data.count)"
            )
            postModuleData(request, data: data)
        } catch {
            if attempt < 2 {
                try? await Task.sleep(for: .seconds(1))
                await performFetch(request, attempt: attempt + 1)
                return
            }
            let failureCount = (fetchFailureCounts[key] ?? 0) + 1
            fetchFailureCounts[key] = failureCount
            if failureCount >= maxFetchFailures {
                abandonedFetches.insert(key)
                logger.warning(
                    "giving up on module after \(failureCount) failures component=\(request.componentTag) module=\(request.moduleId): \(error)"
                )
            } else {
                // Reconciliation re-schedules this on its next pass.
                logger.warning(
                    "module fetch failed (\(failureCount)/\(maxFetchFailures)) component=\(request.componentTag) module=\(request.moduleId): \(error)"
                )
            }
            inflight.remove(key)
        }
        activeFetchCount -= 1
        drainFetchQueue()
    }

    /// Safety net for delivery gaps: on a static carousel there is no further
    /// SSE event to re-trigger a module whose fetch failed, so a page waiting
    /// on it would show データ取得中 indefinitely. Periodically re-schedule
    /// every known complete module that hasn't been delivered yet (schedule()
    /// dedupes against delivered/inflight/abandoned, so passes are cheap
    /// no-ops in the steady state).
    private func startReconciliation() {
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.started else { return }
                self.reconcile()
            }
        }
    }

    private func reconcile() {
        for (key, module) in knownModules {
            guard module.complete else { continue }
            let fullKey = "\(key)/\(module.downloadId)/\(module.version)"
            guard !delivered.contains(fullKey), !inflight.contains(fullKey),
                !abandonedFetches.contains(fullKey)
            else { continue }
            guard let componentTag = key.split(separator: "/").first.flatMap({ Int($0) }) else {
                continue
            }
            logger.info(
                "reconcile: re-scheduling undelivered module component=\(componentTag) module=\(module.moduleId)"
            )
            schedule(componentTag: componentTag, module: module)
        }
    }

    // MARK: - Native -> Web

    private func sendProgramInfo(asInit: Bool) {
        let payload = programInfoProvider()
        let programInfoJSON = payload.flatMap { try? Self.jsonText(for: $0) } ?? "null"
        if asInit {
            let postalCodeJSON = postalCode.map(Self.jsonEscapedString) ?? "null"
            post(
                #"{"type":"init","programInfo":\#(programInfoJSON),"postalCode":\#(postalCodeJSON)}"#
            )
        } else {
            post(#"{"type":"programInfo","programInfo":\#(programInfoJSON)}"#)
        }
    }

    private func postSSE(event: String, jsonData: String) {
        let escapedEvent = Self.jsonEscapedString(event)
        post(#"{"type":"sse","event":\#(escapedEvent),"data":\#(jsonData)}"#)
    }

    private func postModuleData(_ request: FetchRequest, data: Data) {
        let moduleInfoB64 = request.info.base64EncodedString()
        let dataB64 = data.base64EncodedString()
        let json =
            "{\"type\":\"moduleData\",\"componentTag\":\(request.componentTag),"
            + "\"moduleId\":\(request.moduleId),\"downloadId\":\(request.downloadId),"
            + "\"version\":\(request.version),\"moduleInfoB64\":\"\(moduleInfoB64)\","
            + "\"dataBase64\":\"\(dataB64)\"}"
        post(json)
    }

    /// Sends an ARIB key event (see AribKeyCode in
    /// web-bml/client/content.ts) to the BML browser.
    func sendKey(down: Bool, aribKeyCode: Int) {
        post(#"{"type":"key","action":"\#(down ? "down" : "up")","aribKeyCode":\#(aribKeyCode)}"#)
    }

    func submitInput(_ value: String, requestId: Int) {
        guard inputRequest?.id == requestId else { return }
        inputRequest = nil
        post(
            #"{"type":"inputResult","requestId":\#(requestId),"value":\#(Self.jsonEscapedString(value))}"#
        )
    }

    func cancelInput(requestId: Int) {
        guard inputRequest?.id == requestId else { return }
        inputRequest = nil
        post(#"{"type":"inputCancel","requestId":\#(requestId)}"#)
    }

    private func post(_ json: String) {
        guard isReady else {
            pendingMessages.append(json)
            return
        }
        evaluate(json)
    }

    private func flushPendingMessages() {
        let messages = pendingMessages
        pendingMessages.removeAll()
        for json in messages {
            evaluate(json)
        }
    }

    private func evaluate(_ json: String) {
        webView.evaluateJavaScript("window.kiririnBML.onNativeMessage(\(json))") {
            [weak self] _, error in
            if let error {
                self?.logger.warning(
                    "evaluateJavaScript failed: \(error) (payload prefix: \(json.prefix(120)))")
            }
        }
    }

    private static func jsonText<T: Encodable>(for value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonEscapedString(_ string: String) -> String {
        let data = (try? JSONEncoder().encode(string)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Web -> Native

    fileprivate func handleBridgeMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            logger.info("BML web bundle ready (flushing \(pendingMessages.count) pending messages)")
            isReady = true
            flushPendingMessages()
        case "tune":
            guard let request = BMLTuneRequest(bridgeMessage: body) else {
                logger.warning("invalid BML tune request")
                return
            }
            tuneHandler(request)
        case "setMainAudioStream":
            guard let request = BMLAudioStreamRequest(bridgeMessage: body) else {
                logger.warning("invalid BML setMainAudioStream request")
                return
            }
            logger.info(
                "BML setMainAudioStream: componentId=\(request.componentId) channelId=\(String(describing: request.channelId)) pid=\(String(describing: request.pid)) index=\(String(describing: request.audioIndex))"
            )
            audioStreamHandler(request)
        case "videoRect":
            if let x = body["x"] as? Double, let y = body["y"] as? Double,
                let width = body["width"] as? Double, let height = body["height"] as? Double
            {
                // Zero size = the active document has no video object; show
                // the video full-bleed rather than keeping a stale rect.
                if width > 0, height > 0 {
                    videoRect = CGRect(x: x, y: y, width: width, height: height)
                    logger.info("BML videoRect: \(x),\(y) \(width)x\(height)")
                } else {
                    videoRect = nil
                    logger.info("BML videoRect cleared")
                }
            }
        case "invisible":
            let nextValue = (body["value"] as? Bool) ?? false
            invisibleUpdateTask?.cancel()
            invisibleUpdateTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self else { return }
                if self.isInvisible != nextValue {
                    self.isInvisible = nextValue
                    self.logger.info("BML invisible: \(nextValue)")
                }
            }
        case "receiving":
            receivingClearTask?.cancel()
            receivingClearTask = nil
            if (body["value"] as? Bool) ?? false {
                isReceiving = true
            } else {
                // Hold briefly before clearing so back-to-back fetches don't
                // flicker the データ取得中 badge.
                receivingClearTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    self?.isReceiving = false
                }
            }
        case "networking":
            networkingClearTask?.cancel()
            networkingClearTask = nil
            if (body["value"] as? Bool) ?? false {
                isNetworking = true
            } else {
                // receivingと同様、連続するリクエストでバッジがちらつかない
                // よう少し保持してから消す。
                networkingClearTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    self?.isNetworking = false
                }
            }
        case "usedKeyList":
            usedKeyGroups = Set((body["groups"] as? [String]) ?? [])
            logger.info("BML usedKeyList: \(usedKeyGroups.sorted())")
        case "storageChanged":
            guard let key = body["key"] as? String else {
                logger.warning("invalid BML storageChanged message")
                return
            }
            DataBroadcastSettings.setWebStorageItem(key: key, value: body["value"] as? String)
        case "inputRequest":
            guard let requestId = body["requestId"] as? Int,
                let characterType = body["characterType"] as? String,
                let maxLength = body["maxLength"] as? Int,
                let value = body["value"] as? String,
                let inputMode = body["inputMode"] as? String,
                let multiline = body["multiline"] as? Bool
            else {
                logger.warning("invalid BML input request")
                return
            }
            inputRequest = InputRequest(
                id: requestId,
                characterType: characterType,
                allowedCharacters: body["allowedCharacters"] as? String,
                maxLength: maxLength,
                value: value,
                isSecure: inputMode == "password",
                isMultiline: multiline
            )
        case "inputCancelled":
            guard let requestId = body["requestId"] as? Int,
                inputRequest?.id == requestId
            else { return }
            inputRequest = nil
        case "error":
            logger.warning("BML error: \(body["message"] as? String ?? "unknown")")
        case "log":
            logger.debug("[bml] \(body["message"] as? String ?? "")")
        case "loaded":
            logger.info(
                "BML loaded: \(body["width"] as? Double ?? 0)x\(body["height"] as? Double ?? 0) profile=\(body["profile"] as? String ?? "?")"
            )
        default:
            break
        }
    }

    // MARK: - WebView construction

    // WKWebView copies its configuration at init time; registering the
    // message handler on `webView.configuration` afterwards can silently do
    // nothing. Build the content controller into the configuration BEFORE
    // creating the web view (same order as PluginOverlayView).
    private static func makeWebView(
        messageHandler: WKScriptMessageHandler, allowsInternetAccess: Bool
    ) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(
            BMLURLSchemeHandler(allowsInternetAccess: allowsInternetAccess),
            forURLScheme: BMLURLSchemeHandler.scheme)
        let contentController = WKUserContentController()
        contentController.add(messageHandler, name: "bml")
        // BMLBrowserはバンドルスクリプト評価時(initメッセージより前)に生成
        // されるので、生成時点で確定していなければならない設定はここで
        // atDocumentStartに注入する - web/bml/src/index.tsが参照。
        contentController.addUserScript(
            WKUserScript(
                source: "window.kiririnBMLConfig = { internetAccess: \(allowsInternetAccess) };",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        // kiririn-bml://オリジンのlocalStorageはWebKitがディスク永続化しない
        // ため、ネイティブ側ミラー(dataBroadcast.webStorage)が正。バンドル
        // スクリプトより先(atDocumentStart)にミラー内容でシードし直す。
        contentController.addUserScript(
            WKUserScript(
                source: Self.storageSeedScript(
                    snapshot: DataBroadcastSettings.webStorage()),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        config.userContentController = contentController
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        #if os(macOS)
            webView.setValue(false, forKey: "drawsBackground")
        #else
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.isScrollEnabled = false
        #endif
        return webView
    }

    /// ミラーの内容でlocalStorageを丸ごと置き換えるスクリプト。clear()して
    /// から書き戻すことで、WebKit側にセッション内で残った値とミラーの不整合
    /// (削除済みキーの復活など)を防ぎ、ミラーを単一の正とする。
    /// JSONはES2019以降JavaScriptの完全なサブセットなのでリテラル埋め込みで安全。
    static func storageSeedScript(snapshot: [String: String]) -> String {
        let entriesJSON: String =
            (try? JSONSerialization.data(withJSONObject: snapshot))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
            try {
                localStorage.clear();
                const entries = \(entriesJSON);
                for (const key of Object.keys(entries)) {
                    localStorage.setItem(key, entries[key]);
                }
            } catch (e) {}
            """
    }

    private func loadContent() {
        guard let url = BMLURLSchemeHandler.contentURL,
            BMLURLSchemeHandler.resourceURL(for: url) != nil
        else {
            logger.error("BML web bundle not found in app bundle (run setup.sh)")
            status = .failed("Webバンドルが見つかりません")
            return
        }
        webView.load(URLRequest(url: url))
    }
}

/// `WKUserContentController` retains its message handlers strongly; this
/// proxy breaks the cycle back to `DataBroadcastSession`, which itself owns
/// the `WKWebView` (and therefore the content controller). Mirrors
/// PluginOverlayView's `LeakAversionScriptMessageHandler`.
private final class LeakAversionBMLMessageHandler: NSObject, WKScriptMessageHandler {
    weak var session: DataBroadcastSession?

    nonisolated func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            guard let body = message.body as? [String: Any] else { return }
            self.session?.handleBridgeMessage(body)
        }
    }
}
