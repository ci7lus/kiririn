import WebKit

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
