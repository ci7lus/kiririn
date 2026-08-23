import Foundation

nonisolated enum KiririnOpenError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case invalidService
    case serviceNotFound
    case serviceUnavailable

    var operation: String {
        switch self {
        case .invalidURL:
            return "openURL"
        case .invalidService, .serviceNotFound, .serviceUnavailable:
            return "openService"
        }
    }

    var code: String {
        switch self {
        case .invalidURL:
            return "invalidURL"
        case .invalidService:
            return "invalidService"
        case .serviceNotFound:
            return "serviceNotFound"
        case .serviceUnavailable:
            return "serviceUnavailable"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "再生するURLが不正です"
        case .invalidService:
            return "サービス指定が不正です"
        case .serviceNotFound:
            return "指定されたサービスが見つかりません"
        case .serviceUnavailable:
            return "指定されたサービスを再生できるサーバーがありません"
        }
    }
}

nonisolated struct ServiceOpenRequest: Equatable, Sendable {
    let networkId: Int
    let serviceId: Int
    let preferredServerId: String?

    init(networkId: Int, serviceId: Int, preferredServerId: String? = nil) {
        self.networkId = networkId
        self.serviceId = serviceId
        self.preferredServerId = preferredServerId
    }

    var deepLinkURL: URL? {
        guard Self.isValidIdentifier(networkId), Self.isValidIdentifier(serviceId) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "kiririn"
        components.host = "open"
        components.path = "/service"
        components.queryItems = [
            URLQueryItem(name: "networkId", value: String(networkId)),
            URLQueryItem(name: "serviceId", value: String(serviceId)),
        ]

        if let preferredServerId, !preferredServerId.isEmpty {
            components.queryItems?.append(
                URLQueryItem(name: "serverId", value: preferredServerId)
            )
        }

        return components.url
    }

    init?(components: URLComponents) {
        guard
            let networkId = Self.integerQueryValue(
                named: "networkId", in: components.queryItems),
            let serviceId = Self.integerQueryValue(
                named: "serviceId", in: components.queryItems),
            Self.isValidIdentifier(networkId),
            Self.isValidIdentifier(serviceId)
        else {
            return nil
        }

        let preferredServerId = components.queryItems?
            .first(where: { $0.name == "serverId" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        self.init(
            networkId: networkId,
            serviceId: serviceId,
            preferredServerId: preferredServerId?.isEmpty == false ? preferredServerId : nil
        )
    }

    static func isValidIdentifier(_ value: Int) -> Bool {
        (0...Int(UInt16.max)).contains(value)
    }

    private static func integerQueryValue(
        named name: String,
        in queryItems: [URLQueryItem]?
    ) -> Int? {
        guard let value = queryItems?.first(where: { $0.name == name })?.value,
            let integer = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        return integer
    }
}
