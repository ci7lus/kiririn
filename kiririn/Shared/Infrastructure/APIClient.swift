import Foundation

nonisolated final class APIClient: Sendable {
    let baseURL: URL?
    let defaultHeaders: [String: String]
    private let session: URLSession

    init(configuration: BackendConfiguration) {
        self.baseURL = configuration.effectiveBaseURL

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
        return try decoder.decode(T.self, from: data)
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
