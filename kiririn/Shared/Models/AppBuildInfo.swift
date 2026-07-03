import Foundation

struct AppBuildInfo {
    let appName: String
    let version: String
    let buildNumber: String
    let gitCommitHash: String

    var versionDescription: String {
        "\(version) (\(buildNumber), \(gitCommitHash))"
    }

    var appVersionDescription: String {
        "\(appName) \(versionDescription)"
    }

    static var current: AppBuildInfo {
        AppBuildInfo(bundle: .main)
    }

    init(bundle: Bundle) {
        appName = Self.infoValue("CFBundleDisplayName", from: bundle, fallback: "kiririn")
        version = Self.infoValue("CFBundleShortVersionString", from: bundle)
        buildNumber = Self.infoValue("CFBundleVersion", from: bundle)
        gitCommitHash = Self.infoValue("KiririnGitCommitHash", from: bundle)
    }

    private static func infoValue(_ key: String, from bundle: Bundle, fallback: String = "-")
        -> String
    {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            return fallback
        }

        return value
    }
}
