import Foundation
import WebKit

private final class BMLProxySessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler:
            @escaping @Sendable (
                URLSession.AuthChallengeDisposition, URLCredential?
            ) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 放送局の通信コンテンツには古い証明書設備が残っているため、
        // web-bmlのHTTPプロキシと同様に専用セッション内では接続を許可する。
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

final class BMLURLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "kiririn-bml"
    static let host = "app"
    static let contentURL = URL(string: "\(scheme)://\(host)/bml.html")

    /// 通信コンテンツ(データ放送のインターネット接続機能)を許可するか。
    /// JS側は同じ値をWKUserScript経由で受け取り、無効ならそもそも /ip/*
    /// を呼ばないが、こちらでも拒否して二重に守る。
    private let allowsInternetAccess: Bool

    /// /ip/* プロキシで進行中のリクエスト。stop()で該当Taskをキャンセルし、
    /// キャンセル後はWKURLSchemeTaskに一切触らない(触るとWebKitが例外を
    /// 投げる)。WKURLSchemeHandlerのコールバックはメインスレッドで呼ばれる
    /// ので、この辞書はメインアクター上からのみ触る。
    private var proxyTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    private static let proxySession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(
            configuration: configuration, delegate: BMLProxySessionDelegate(), delegateQueue: nil)
    }()

    init(allowsInternetAccess: Bool = false) {
        self.allowsInternetAccess = allowsInternetAccess
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
            requestURL.scheme == Self.scheme,
            requestURL.host == Self.host
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        if requestURL.path.hasPrefix("/ip/") {
            startProxy(urlSchemeTask, requestURL: requestURL)
            return
        }

        guard let resourceURL = Self.resourceURL(for: requestURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        do {
            let data = try Data(contentsOf: resourceURL)
            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType(for: resourceURL.pathExtension),
                expectedContentLength: data.count,
                textEncodingName: resourceURL.pathExtension == "html" ? "utf-8" : nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        proxyTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    static func resourceURL(for requestURL: URL) -> URL? {
        let resourceName = requestURL.lastPathComponent
        guard !resourceName.isEmpty, resourceName == requestURL.path.dropFirst(),
            resourceName != ".", resourceName != ".."
        else { return nil }

        let name = (resourceName as NSString).deletingPathExtension
        let extensionName = (resourceName as NSString).pathExtension
        guard !name.isEmpty, !extensionName.isEmpty else { return nil }

        return Bundle.main.url(
            forResource: name,
            withExtension: extensionName,
            subdirectory: "Features/Player/DataBroadcast/Web/dist"
        ) ?? Bundle.main.url(forResource: name, withExtension: extensionName)
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": "text/html"
        case "js": "text/javascript"
        case "json", "map": "application/json"
        case "css": "text/css"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }

    // MARK: - 通信コンテンツ用HTTPプロキシ (/ip/get, /ip/post, /ip/confirm)
    //
    // web-bml純正サーバーの /api/get・/api/post・/api/confirm 相当
    // (web/web-bml/server/index.ts)。ヘッダーの許可リストやPOSTボディの
    // 上限(電文4096バイト)もそちらに合わせている。JS側の対向実装は
    // web/bml/src/ip.ts。

    private func startProxy(_ urlSchemeTask: WKURLSchemeTask, requestURL: URL) {
        guard allowsInternetAccess else {
            urlSchemeTask.didFailWithError(URLError(.notConnectedToInternet))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        let request = urlSchemeTask.request
        proxyTasks[id] = Task { @MainActor [weak self] in
            defer { self?.proxyTasks[id] = nil }
            do {
                let (response, data) = try await Self.performProxy(
                    path: requestURL.path, requestURL: requestURL, originalRequest: request)
                guard !Task.isCancelled else { return }
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    // internal (not private) - kiririnTestsから直接叩いて検証するため
    static func performProxy(
        path: String, requestURL: URL, originalRequest: URLRequest
    ) async throws -> (HTTPURLResponse, Data) {
        let queryItems =
            URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func queryValue(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        switch path {
        case "/ip/get", "/ip/post":
            guard let target = queryValue("url").flatMap(URL.init(string:)),
                target.scheme == "http" || target.scheme == "https"
            else { throw URLError(.badURL) }
            var upstream = URLRequest(url: target)
            upstream.setValue("*/*", forHTTPHeaderField: "Accept")
            upstream.setValue("ja", forHTTPHeaderField: "Accept-Language")
            upstream.setValue("no-cache", forHTTPHeaderField: "Pragma")
            if path == "/ip/post" {
                // 電文(Denbun=<binary>)は最大4096バイト - web-bmlサーバーと同じ上限
                let body =
                    originalRequest.httpBody ?? readBodyStream(originalRequest.httpBodyStream)
                guard body.count <= 4096 + "Denbun=".count else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                upstream.httpMethod = "POST"
                upstream.httpBody = body
                upstream.setValue(
                    "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            } else {
                for field in ["If-Modified-Since", "Cache-Control"] {
                    if let value = originalRequest.value(forHTTPHeaderField: field) {
                        upstream.setValue(value, forHTTPHeaderField: field)
                    }
                }
            }
            let (data, response) = try await proxySession.data(for: upstream)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            let allowedResponseHeaders: Set<String> = [
                "accept-ranges", "authentication-info", "last-modified", "pragma", "date",
                "cache-control", "age", "expire", "content-language", "content-location",
                "content-type",
            ]
            // WebKitがカスタムスキームのオリジンをopaque扱いした場合でも
            // fetchが応答とヘッダーを読めるようCORSヘッダーを付けておく
            // (同一オリジン扱いなら単に無視される)。
            var headers: [String: String] = [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Expose-Headers": "*",
            ]
            for case (let key as String, let value as String) in http.allHeaderFields
            where allowedResponseHeaders.contains(key.lowercased()) {
                headers[key] = value
            }
            guard
                let proxyResponse = HTTPURLResponse(
                    url: requestURL, statusCode: http.statusCode, httpVersion: "HTTP/1.1",
                    headerFields: headers)
            else { throw URLError(.badServerResponse) }
            return (proxyResponse, data)

        case "/ip/confirm":
            // web-bmlサーバー同様、ICMP pingの代わりにDNS解決の成否と所要時間を
            // 返す(isICMPは無視)。BMLコンテンツは疎通確認に使うだけなので十分。
            guard let destination = queryValue("destination"), !destination.isEmpty,
                let timeoutMillis = queryValue("timeoutMillis").flatMap(Int.init)
            else { throw URLError(.badURL) }
            let begin = ContinuousClock.now
            let ipAddress = await resolveIPv4(destination, timeoutMillis: timeoutMillis)
            let elapsedMillis = Int((ContinuousClock.now - begin) / .milliseconds(1))
            // OptionalをそのままJSONSerializationに渡すと実行時エラーに
            // なるので、失敗時は明示的にNSNull(JSONのnull)へ落とす。
            let result: [String: Any] = [
                "success": ipAddress != nil,
                "ipAddress": ipAddress.map { $0 as Any } ?? NSNull(),
                "responseTimeMillis": ipAddress != nil ? elapsedMillis as Any : NSNull(),
            ]
            let data = try JSONSerialization.data(withJSONObject: result)
            guard
                let proxyResponse = HTTPURLResponse(
                    url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "Access-Control-Allow-Origin": "*",
                        "Access-Control-Expose-Headers": "*",
                    ])
            else { throw URLError(.badServerResponse) }
            return (proxyResponse, data)

        default:
            throw URLError(.fileDoesNotExist)
        }
    }

    /// WebKitはfetchのリクエストボディをhttpBodyではなくhttpBodyStreamで
    /// 渡してくることがあるので、その場合はここで読み出す。電文の上限を
    /// 少し超えたところで打ち切る(超過はperformProxy側の上限チェックで弾く)。
    private static func readBodyStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= 4096 + "Denbun=".count {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    /// getaddrinfoでのIPv4名前解決をタイムアウト付きで行う。getaddrinfo自体は
    /// キャンセルできないので、タイムアウト時はブロック中のスレッドを見捨てて
    /// 先に帰る(解決が終われば勝手に片付く)。
    static func resolveIPv4(_ host: String, timeoutMillis: Int) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else {
                    return nil
                }
                defer { freeaddrinfo(info) }
                var pointer: UnsafeMutablePointer<addrinfo>? = info
                while let current = pointer {
                    if current.pointee.ai_family == AF_INET, let addr = current.pointee.ai_addr {
                        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                            $0.pointee.sin_addr
                        }
                        if inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                            return String(cString: buffer)
                        }
                    }
                    pointer = current.pointee.ai_next
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(max(0, timeoutMillis)))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
