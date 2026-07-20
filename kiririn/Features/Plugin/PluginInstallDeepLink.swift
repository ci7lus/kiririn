import Foundation

struct PluginInstallDeepLink: Equatable {
    static let updateManifestURLQueryName = "updateManifestUrl"

    let updateManifestURL: URL
    let manifestID: String

    static func isInstallRequest(_ components: URLComponents) -> Bool {
        components.queryItems?.contains(where: {
            $0.name == updateManifestURLQueryName
        }) == true
    }

    init?(components: URLComponents) {
        let queryItems = components.queryItems ?? []
        guard
            let rawUpdateManifestURL = queryItems.first(where: {
                $0.name == Self.updateManifestURLQueryName
            })?.value,
            let updateManifestURL = URL(string: rawUpdateManifestURL),
            let scheme = updateManifestURL.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let manifestID = queryItems.first(where: { $0.name == "manifestID" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !manifestID.isEmpty
        else {
            return nil
        }

        self.updateManifestURL = updateManifestURL
        self.manifestID = manifestID
    }
}
