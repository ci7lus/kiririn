import Foundation

nonisolated enum ServerType: String, Codable, Sendable, CaseIterable {
    case mirakurun
    case epgstation
    case googledrive
    case konomitv

    var displayName: String {
        switch self {
        case .mirakurun: return "Mirakurun"
        case .epgstation: return "EPGStation"
        case .googledrive: return "Google Drive"
        case .konomitv: return "KonomiTV"
        }
    }

    var requiresBaseURL: Bool {
        switch self {
        case .googledrive: return false
        default: return true
        }
    }

    var supportedFeatures: [ServerFeature] {
        switch self {
        case .mirakurun:
            return [.live]
        case .epgstation:
            return [.live, .recording]
        case .googledrive:
            return [.recording]
        case .konomitv:
            return [.recording]
        }
    }

    var supportsLive: Bool {
        supportedFeatures.contains(.live)
    }

    var supportsRecording: Bool {
        supportedFeatures.contains(.recording)
    }
}

nonisolated enum ServerFeature: String, Codable, Sendable {
    case live
    case recording
}

nonisolated enum ServerAuth: Codable, Equatable, Sendable {
    case none
    case basic(username: String, password: String)
    case bearer(token: String)
    case cookie(cookie: String)
    case oauth2(accessToken: String?, refreshToken: String?, expiryDate: Date?)
}

nonisolated struct ServerConfiguration: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var type: ServerType
    var baseURL: String?
    var auth: ServerAuth
    var customHeaders: [String: String]
    var liveEnabled: Bool
    var recordingEnabled: Bool

    var features: [ServerFeature] {
        var result: [ServerFeature] = []
        if supports(.live) && liveEnabled {
            result.append(.live)
        }
        if supports(.recording) && recordingEnabled {
            result.append(.recording)
        }
        return result
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        type: ServerType,
        baseURL: String?,
        auth: ServerAuth = .none,
        customHeaders: [String: String] = [:],
        liveEnabled: Bool? = nil,
        recordingEnabled: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.baseURL = baseURL
        self.auth = auth
        self.customHeaders = customHeaders
        self.liveEnabled = liveEnabled ?? type.supportsLive
        self.recordingEnabled = recordingEnabled ?? type.supportsRecording
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case baseURL
        case auth
        case customHeaders
        case liveEnabled
        case recordingEnabled
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ServerType.self, forKey: .type)

        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.type = type
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        self.auth = try container.decodeIfPresent(ServerAuth.self, forKey: .auth) ?? .none
        self.customHeaders =
            try container.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
        self.liveEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .liveEnabled) ?? type.supportsLive
        self.recordingEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .recordingEnabled)
            ?? type.supportsRecording
    }

    func supports(_ feature: ServerFeature) -> Bool {
        type.supportedFeatures.contains(feature)
    }

    var effectiveBaseURL: URL? {
        guard var urlString = baseURL else { return nil }
        if !urlString.hasSuffix("/") {
            urlString += "/"
        }
        return URL(string: urlString)
    }
}
