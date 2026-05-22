import AuthenticationServices
import CryptoKit
import Foundation
import Logging
import SwiftUI

// MARK: - Credentials Loader

private struct GoogleDriveCredentials {
    static let shared: GoogleDriveCredentials? = {
        guard
            let url = Bundle.main.url(
                forResource:
                    "client_37428464726-9t8mg48lvga6oo3lojk37jqggchabm7e.apps.googleusercontent.com",
                withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else {
            return nil
        }

        guard let clientID = plist["CLIENT_ID"] as? String,
            let reversedClientID = plist["REVERSED_CLIENT_ID"] as? String
        else {
            return nil
        }

        return GoogleDriveCredentials(clientID: clientID, reversedClientID: reversedClientID)
    }()

    let clientID: String
    let reversedClientID: String

    var callbackScheme: String { reversedClientID }
    var redirectURI: String { "\(reversedClientID):/oauth2callback" }
}

final class GoogleDriveProvider: RecordingBackendProvider {
    private let lock = NSLock()
    private var _configuration: BackendConfiguration
    var configuration: BackendConfiguration {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _configuration
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _configuration = newValue
        }
    }

    var onConfigurationUpdated: (@Sendable (BackendConfiguration) -> Void)?

    private let logger = Logging.Logger(label: "GoogleDriveProvider")
    private var _cachedFiles: [String: GoogleDriveFile] = [:]
    private var cachedFiles: [String: GoogleDriveFile] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _cachedFiles
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _cachedFiles = newValue
        }
    }

    init(configuration: BackendConfiguration) {
        self._configuration = configuration
    }

    func checkConnection() async throws {
        let _: GoogleDriveAbout = try await request(
            path: "drive/v3/about", queryItems: [URLQueryItem(name: "fields", value: "user")])
    }

    func fetchHeaders() async throws -> [String: String] {
        var headers = configuration.customHeaders
        if let token = try await getValidAccessToken() {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    private func getValidAccessToken() async throws -> String? {
        let currentConfig = self.configuration
        guard case .oauth2(let accessToken, let refreshToken, let expiryDate) = currentConfig.auth
        else {
            return nil
        }

        // 期限切れ（または5分前）ならリフレッシュ
        if let expiry = expiryDate, expiry.addingTimeInterval(-300) < Date(),
            let refreshToken = refreshToken
        {
            logger.info("Access token is expired (expired at \(expiry)), refreshing...")
            if let tokenResponse = try await refreshAccessToken(refreshToken: refreshToken) {
                let newExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
                var newConfig = currentConfig
                newConfig.auth = .oauth2(
                    accessToken: tokenResponse.accessToken,
                    refreshToken: tokenResponse.refreshToken ?? refreshToken,
                    expiryDate: newExpiry
                )
                self.configuration = newConfig
                self.onConfigurationUpdated?(newConfig)
                return tokenResponse.accessToken
            }
            return nil
        }

        return accessToken
    }

    private func refreshAccessToken(refreshToken: String) async throws -> GoogleOAuthTokenResponse?
    {
        guard let credentials = GoogleDriveCredentials.shared else {
            throw URLError(.fileDoesNotExist)
        }

        let components = URLComponents(string: "https://oauth2.googleapis.com/token")!
        let bodyItems = [
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = bodyItems
        request.httpBody = bodyComponents.query?.data(using: .utf8)

        let (data, response) = try await URLSession.kiririnShared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            logger.error(
                "Token refresh failed with status code \( (response as? HTTPURLResponse)?.statusCode ?? 0): \(String(data: data, encoding: .utf8) ?? "no data")"
            )
            return nil
        }

        return try JSONDecoder().decode(GoogleOAuthTokenResponse.self, from: data)
    }

    func fetchRecords(pageToken: String?, limit: Int, keyword: String?) async throws
        -> RecordsResult
    {
        var query = "mimeType contains 'video/' and trashed = false"
        if let keyword, !keyword.isEmpty {
            let escapedKeyword = keyword.replacingOccurrences(of: "'", with: "\\'")
            query += " and fullText contains '\(escapedKeyword)'"
        }

        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "pageSize", value: "\(limit)"),
            URLQueryItem(name: "orderBy", value: "modifiedTime desc"),
            URLQueryItem(name: "corpora", value: "allDrives"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeTeamDriveItems", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            URLQueryItem(
                name: "fields",
                value:
                    "nextPageToken, files(id, name, mimeType, size, modifiedTime, description, thumbnailLink, videoMediaMetadata(durationMillis))"
            ),
        ]

        if let pageToken = pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        let response: GoogleDriveFileList = try await request(
            path: "drive/v3/files",
            queryItems: queryItems
        )

        for file in response.files {
            cachedFiles[file.id] = file
        }

        let records = response.files.map { $0.toRecord(backendId: configuration.id) }
        return RecordsResult(records: records, nextPageToken: response.nextPageToken)
    }

    func fetchRecord(id: String) async throws -> Recorded {
        let file: GoogleDriveFile = try await request(
            path: "drive/v3/files/\(id)",
            queryItems: [
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                URLQueryItem(
                    name: "fields",
                    value: "id, name, mimeType, size, modifiedTime, description, thumbnailLink"),
            ]
        )
        cachedFiles[file.id] = file
        return file.toRecord(backendId: configuration.id)
    }

    func fetchRecordThumbnail(id: String) async throws -> Data? {
        let file: GoogleDriveFile
        if let cached = cachedFiles[id] {
            file = cached
        } else {
            file = try await request(
                path: "drive/v3/files/\(id)",
                queryItems: [
                    URLQueryItem(name: "supportsAllDrives", value: "true"),
                    URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                    URLQueryItem(name: "fields", value: "thumbnailLink"),
                ]
            )
            cachedFiles[id] = file
        }
        guard let link = file.thumbnailLink, let url = URL(string: link) else { return nil }
        return try await requestData(url: url)
    }

    func buildRecordedPlayable(record: Recorded, variant: RecordedVariant) -> Playable {
        let streamURL = URL(
            string: "https://www.googleapis.com/drive/v3/files/\(record.id)?alt=media")!
        var playable = Playable(
            streamURL: streamURL,
            headers: [:],
            backendId: configuration.id,
            source: .recordedFile(
                recordId: record.id, variantId: variant.id, backendId: record.backendId),
            program: nil,
            service: nil
        )
        playable.overriddenProgram = PlayableProgramOverride(
            duration: record.duration,
            name: record.name,
            desc: record.desc,
            extended: record.extended,
            genres: record.genres.isEmpty ? nil : record.genres
        )
        return playable
    }

    private func request<T: Decodable & Sendable>(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        let data = try await requestData(path: path, queryItems: queryItems)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription:
                    "Expected date string to be ISO8601-formatted (including fractional seconds), but got: \(dateString)"
            )
        }
        do {
            let decodedData = try decoder.decode(T.self, from: data)
            return decodedData
        } catch let DecodingError.dataCorrupted(context) {
            logger.error("データが破損しています: \(context)")
        } catch let DecodingError.keyNotFound(key, context) {
            logger.error("キーが見つかりません: '\(key.stringValue)' - \(context.debugDescription)")
        } catch let DecodingError.typeMismatch(type, context) {
            logger.error("型の不一致: \(type) を期待していましたが、違います - \(context.debugDescription)")
        } catch let DecodingError.valueNotFound(value, context) {
            logger.error("値が見つかりません: \(value) - \(context.debugDescription)")
        } catch {
            logger.error("\(String(describing: String(data: data, encoding: .utf8)))")
        }
        throw APIError.invalidResponse
    }

    private func requestData(
        path: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> Data {
        let url = URL(string: "https://www.googleapis.com/")!.appendingPathComponent(path)
        return try await requestData(url: url, queryItems: queryItems)
    }

    private func requestData(
        url: URL,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> Data {
        let token = try await getValidAccessToken()
        var headers = configuration.customHeaders
        if let token {
            headers["Authorization"] = "Bearer \(token)"
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        if let queryItems = queryItems {
            components.queryItems = (components.queryItems ?? []) + queryItems
        }

        var request = URLRequest(url: components.url!)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.kiririnShared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return data
    }
}

// MARK: - DTOs

private nonisolated struct GoogleDriveAbout: Codable, Sendable {
    struct User: Codable, Sendable {
        let displayName: String
        let emailAddress: String
    }
    let user: User
}

private nonisolated struct GoogleDriveFileList: Codable, Sendable {
    let files: [GoogleDriveFile]
    let nextPageToken: String?
}

private nonisolated struct GoogleDriveFileVideoMetadata: Codable, Sendable {
    let durationMillis: String?
}

private nonisolated struct GoogleDriveFile: Codable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let modifiedTime: Date
    let description: String?
    let thumbnailLink: String?
    let videoMediaMetadata: GoogleDriveFileVideoMetadata?

    func toRecord(backendId: String) -> Recorded {
        let duration: Double? = videoMediaMetadata?.durationMillis.flatMap { Double($0) }.map {
            $0 / 1000
        }
        return Recorded(
            id: id,
            name: name,
            desc: description,
            extended: nil,
            serviceName: nil,
            serviceId: nil,
            networkId: nil,
            startAt: nil,
            duration: duration,
            referenceDate: modifiedTime,
            genres: [],
            variants: [RecordedVariant(id: id, name: "Original")],
            isRecording: false,
            hasThumbnail: thumbnailLink != nil,
            backendId: backendId
        )
    }
}

private struct GoogleOAuthTokenResponse: Codable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String
    let tokenType: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
    }
}

// MARK: - UI Components

/// ASWebAuthenticationSession の表示コンテキストを提供するコーディネーター
private final class AuthenticationCoordinator: NSObject,
    ASWebAuthenticationPresentationContextProviding
{
    static let shared = AuthenticationCoordinator()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
            return NSApplication.shared.keyWindow ?? NSWindow()
        #else
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }?
                .windows
                .first { $0.isKeyWindow }
            return window ?? UIWindow()
        #endif
    }
}

struct GoogleDriveAuthEditor: View {
    @Binding var auth: BackendAuth
    @Binding var name: String

    @State private var isAuthenticating = false

    var body: some View {
        Section("Google Drive連携") {
            if case .oauth2(let token, _, _) = auth, let token = token, !token.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("ログイン済み")
                    Spacer()
                    Button("再ログイン") {
                        Task { await signInWithGoogle() }
                    }
                    .font(.caption)
                    .disabled(isAuthenticating)
                }
            } else {
                Button {
                    Task { await signInWithGoogle() }
                } label: {
                    HStack {
                        if isAuthenticating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "link")
                        }
                        Text("Google アカウントでログイン")
                    }
                }
                .disabled(isAuthenticating)
                .buttonStyle(.plain)
            }
        }
    }

    @MainActor
    private func signInWithGoogle() async {
        guard let credentials = GoogleDriveCredentials.shared else {
            print("Credentials not found")
            return
        }

        isAuthenticating = true
        defer { isAuthenticating = false }

        // PKCE: Code Verifier & Challenge
        let codeVerifier = generateRandomString(length: 64)
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "redirect_uri", value: credentials.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.readonly"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        guard let authURL = components.url else { return }

        let session = ASWebAuthenticationSession(
            url: authURL, callbackURLScheme: credentials.callbackScheme
        ) { callbackURL, error in
            if let error = error {
                print("Auth error: \(error)")
                return
            }
            guard let callbackURL = callbackURL,
                let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: true),
                let code = components.queryItems?.first(where: { $0.name == "code" })?.value
            else {
                return
            }

            Task {
                await exchangeCodeForToken(code: code, codeVerifier: codeVerifier)
            }
        }

        session.presentationContextProvider = AuthenticationCoordinator.shared
        session.start()
    }

    private func exchangeCodeForToken(code: String, codeVerifier: String) async {
        guard let credentials = GoogleDriveCredentials.shared else { return }

        let components = URLComponents(string: "https://oauth2.googleapis.com/token")!
        let bodyItems = [
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "redirect_uri", value: credentials.redirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = bodyItems
        request.httpBody = bodyComponents.query?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.kiririnShared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                (200...299).contains(httpResponse.statusCode)
            else {
                print("Token exchange failed: \(String(data: data, encoding: .utf8) ?? "no data")")
                return
            }

            let tokenResponse = try JSONDecoder().decode(GoogleOAuthTokenResponse.self, from: data)

            await MainActor.run {
                print("Token exchange succeeded: \(tokenResponse.expiresIn)")
                self.auth = .oauth2(
                    accessToken: tokenResponse.accessToken,
                    refreshToken: tokenResponse.refreshToken,
                    expiryDate: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
                )
                if self.name.isEmpty {
                    self.name = "Google Drive"
                }
            }
        } catch {
            print("Token exchange error: \(error)")
        }
    }

    // MARK: - PKCE Helpers

    private func generateRandomString(length: Int) -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        return String((0..<length).map { _ in characters.randomElement()! })
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let inputData = Data(verifier.utf8)
        let hashed = SHA256.hash(data: inputData)
        return Data(hashed).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}
