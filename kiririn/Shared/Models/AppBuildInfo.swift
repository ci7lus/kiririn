import Foundation

struct AppBuildInfo {
    let appName: String
    let version: String
    let temporaryMarketingVersion: String?
    let buildNumber: String
    let gitCommitHash: String

    private var displayedVersion: String {
        temporaryMarketingVersion ?? version
    }

    var versionDescription: String {
        "\(displayedVersion) (\(buildNumber), \(gitCommitHash))"
    }

    var versionWithGitCommitHashDescription: String {
        "\(displayedVersion) (\(gitCommitHash))"
    }

    var appVersionDescription: String {
        "\(appName) \(versionDescription)"
    }

    var appVersionWithGitCommitHashDescription: String {
        "\(appName) \(versionWithGitCommitHashDescription)"
    }

    static var current: AppBuildInfo {
        AppBuildInfo(bundle: .main)
    }

    init(bundle: Bundle) {
        appName = Self.infoValue("CFBundleDisplayName", from: bundle, fallback: "kiririn")
        version = Self.infoValue("CFBundleShortVersionString", from: bundle)
        temporaryMarketingVersion = Self.optionalInfoValue(
            "KiririnTemporaryMarketingVersion",
            from: bundle
        )
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

    private static func optionalInfoValue(_ key: String, from bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            return nil
        }

        return value
    }
}
