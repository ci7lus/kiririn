import Foundation
import Logging

nonisolated final class APIClient: Sendable {
    let baseURL: URL?
    let defaultHeaders: [String: String]
    private let session: URLSession
    private let backendName: String
    private let backendType: BackendType
    private let logger = Logging.Logger(label: "APIClient")

    init(configuration: BackendConfiguration) {
        self.baseURL = configuration.effectiveBaseURL
        self.backendName = configuration.name
        self.backendType = configuration.type

        var headers = configuration.customHeaders
        switch configuration.auth {
        case .basic(let username, let password):
            if !username.isEmpty {
                let credentials = "\(username):\(password)"
                if let data = credentials.data(using: .utf8) {
                    headers["Authorization"] = "Basic \(data.base64EncodedString())"
                }
            }
        case .bearer(let token):
            if !token.isEmpty {
                headers["Authorization"] = "Bearer \(token)"
            }
        case .none, .oauth2:
            break
        }
        self.defaultHeaders = headers

        let config = URLSessionConfiguration.kiririnDefault
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func request<T: Decodable & Sendable>(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        guard let url = buildURL(path: path, queryItems: queryItems) else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        for (key, value) in defaultHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            var diagnosticData = data
            var diagnosticError: Error = error

            if Self.jsonErrorIndex(from: error) != nil,
                let sanitizedJSON = Self.sanitizedJSONByRemovingInvalidControlCharacters(from: data)
            {
                do {
                    let decoded = try decoder.decode(T.self, from: sanitizedJSON.data)
                    logger.warning(
                        "Recovered malformed JSON by removing \(sanitizedJSON.removedControlCharacterCount) invalid control character(s); backend=\(backendName); type=\(backendType.displayName); url=\(url.absoluteString)"
                    )
                    return decoded
                } catch {
                    diagnosticData = sanitizedJSON.data
                    diagnosticError = error
                    logger.error(
                        "Malformed JSON recovery failed after removing \(sanitizedJSON.removedControlCharacterCount) invalid control character(s); backend=\(backendName); type=\(backendType.displayName); url=\(url.absoluteString); reason=\(error.localizedDescription)"
                    )
                }
            }

            let diagnostic = Self.makeDecodingDiagnostic(
                data: diagnosticData,
                error: diagnosticError,
                url: url,
                backendName: backendName,
                backendType: backendType,
                contentType: httpResponse.value(forHTTPHeaderField: "Content-Type")
            )
            logger.error("\(diagnostic.detail)")
            throw APIError.decodingError(diagnostic.summary)
        }
    }

    func requestData(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> Data {
        guard let url = buildURL(path: path, queryItems: queryItems) else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        for (key, value) in defaultHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return data
    }

    func buildStreamURL(path: String, queryItems: [URLQueryItem]? = nil) -> URL? {
        buildURL(path: path, queryItems: queryItems)
    }

    private func buildURL(path: String, queryItems: [URLQueryItem]?) -> URL? {
        guard let baseURL = baseURL else { return nil }
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)!
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url
    }
}

nonisolated struct APIDecodingDiagnostic: Sendable {
    let summary: String
    let detail: String
    let errorIndex: Int?
    let snippet: String?
}

nonisolated struct APIJSONSanitizationResult: Sendable {
    let data: Data
    let removedControlCharacterCount: Int
}

extension APIClient {
    nonisolated static func makeDecodingDiagnostic(
        data: Data,
        error: Error,
        url: URL,
        backendName: String,
        backendType: BackendType,
        contentType: String?
    ) -> APIDecodingDiagnostic {
        let endpoint = endpointDescription(for: url)
        let reason = decodingReason(for: error)
        let errorIndex = jsonErrorIndex(from: error)
        let diagnosticSnippet =
            errorIndex.map { snippet(around: $0, in: data) } ?? previewSnippet(from: data)

        var summary = "\(backendName) (\(backendType.displayName)) の \(endpoint) が不正な JSON を返しました"
        if let errorIndex {
            summary += " [byte \(errorIndex)]"
        }

        var detailParts = [
            "JSON decoding failed",
            "backend=\(backendName)",
            "type=\(backendType.displayName)",
            "url=\(url.absoluteString)",
            "bytes=\(data.count)",
        ]
        if let contentType, !contentType.isEmpty {
            detailParts.append("contentType=\(contentType)")
        }
        detailParts.append("reason=\(reason)")
        if let errorIndex {
            detailParts.append("errorIndex=\(errorIndex)")
        }
        if let diagnosticSnippet {
            detailParts.append("snippet=\(diagnosticSnippet)")
        }

        return APIDecodingDiagnostic(
            summary: summary,
            detail: detailParts.joined(separator: "; "),
            errorIndex: errorIndex,
            snippet: diagnosticSnippet
        )
    }

    private nonisolated static func endpointDescription(for url: URL) -> String {
        let querySuffix = url.query.map { "?\($0)" } ?? ""
        let endpoint = "\(url.path)\(querySuffix)"
        return endpoint.isEmpty ? url.absoluteString : endpoint
    }

    private nonisolated static func decodingReason(for error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context):
            return
                "dataCorrupted at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        case DecodingError.keyNotFound(let key, let context):
            return
                "keyNotFound '\(key.stringValue)' at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        case DecodingError.typeMismatch(let type, let context):
            return
                "typeMismatch \(type) at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        case DecodingError.valueNotFound(let type, let context):
            return
                "valueNotFound \(type) at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }

    private nonisolated static func codingPathDescription(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "<root>" }

        var result = ""
        for key in codingPath {
            let component: String
            if let intValue = key.intValue {
                component = "[\(intValue)]"
            } else {
                component = key.stringValue
            }

            if component.hasPrefix("[") {
                result += component
            } else if result.isEmpty {
                result = component
            } else {
                result += ".\(component)"
            }
        }

        return result
    }

    private nonisolated static func jsonErrorIndex(from error: Error) -> Int? {
        extractJSONSerializationErrorIndex(from: error as NSError)
    }

    private nonisolated static func extractJSONSerializationErrorIndex(from error: NSError) -> Int?
    {
        if let index = (error.userInfo["NSJSONSerializationErrorIndex"] as? NSNumber)?.intValue {
            return index
        }
        if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return extractJSONSerializationErrorIndex(from: underlyingError)
        }
        return nil
    }

    private nonisolated static func previewSnippet(from data: Data, limit: Int = 96) -> String? {
        guard !data.isEmpty else { return nil }

        let upperBound = min(data.count, limit)
        let prefix = Data(data.prefix(upperBound))
        let suffix = data.count > limit ? "..." : ""
        return "text=\(sanitizedText(from: prefix))\(suffix)"
    }

    private nonisolated static func snippet(around index: Int, in data: Data, radius: Int = 48)
        -> String
    {
        guard !data.isEmpty else { return "data is empty" }

        let clampedIndex = max(0, min(index, data.count - 1))
        let lowerBound = max(0, clampedIndex - radius)
        let upperBound = min(data.count, clampedIndex + radius + 1)
        let slice = Data(data[lowerBound..<upperBound])
        let bytes = Array(slice)
        let highlightedOffset = clampedIndex - lowerBound
        let hex = bytes.enumerated().map { offset, byte in
            let byteText = String(format: "%02X", byte)
            return offset == highlightedOffset ? "[\(byteText)]" : byteText
        }.joined(separator: " ")

        return
            "offset=\(index) range=\(lowerBound)..<\(upperBound) text=\(sanitizedText(from: slice)) hex=\(hex)"
    }

    private nonisolated static func sanitizedText(from data: Data) -> String {
        sanitizeForLog(String(decoding: data, as: UTF8.self))
    }

    private nonisolated static func sanitizeForLog(_ string: String) -> String {
        string.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x0A:
                return "\\n"
            case 0x0D:
                return "\\r"
            case 0x09:
                return "\\t"
            case 0x20...0x7E:
                return String(scalar)
            default:
                if CharacterSet.controlCharacters.contains(scalar) {
                    return String(format: "\\u{%04X}", scalar.value)
                }
                return String(scalar)
            }
        }.joined()
    }

    nonisolated static func sanitizedJSONByRemovingInvalidControlCharacters(from data: Data)
        -> APIJSONSanitizationResult?
    {
        guard !data.isEmpty else { return nil }

        var sanitized = Data()
        sanitized.reserveCapacity(data.count)

        var removedControlCharacterCount = 0
        var isInsideString = false
        var isEscaping = false

        for byte in data {
            if isInsideString {
                if isEscaping {
                    sanitized.append(byte)
                    isEscaping = false
                    continue
                }

                if byte == 0x5C {
                    sanitized.append(byte)
                    isEscaping = true
                    continue
                }

                if byte == 0x22 {
                    sanitized.append(byte)
                    isInsideString = false
                    continue
                }

                if byte < 0x20 {
                    removedControlCharacterCount += 1
                    continue
                }

                sanitized.append(byte)
                continue
            }

            if byte == 0x22 {
                isInsideString = true
            }

            if byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D {
                removedControlCharacterCount += 1
                continue
            }

            sanitized.append(byte)
        }

        guard removedControlCharacterCount > 0 else { return nil }
        return APIJSONSanitizationResult(
            data: sanitized,
            removedControlCharacterCount: removedControlCharacterCount
        )
    }
}

nonisolated enum APIError: Error, Sendable, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    //...
    case decodingError(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "無効なURLです"
        case .invalidResponse:
            return "サーバーから不正なレスポンスが返されました"
        case .httpError(let code):
            return "HTTPエラー: \(code)"
        case .decodingError(let msg):
            return "データの解析に失敗しました: \(msg)"
        case .notFound:
            return "リソースが見つかりません"
        }
    }
}
