import CryptoKit
import Foundation

public struct GeckoUpdateManifest: Decodable, Sendable {
    public let addons: [String: GeckoUpdateManifestAddon]
}

public struct GeckoUpdateManifestAddon: Decodable, Sendable {
    public let updates: [GeckoUpdateManifestEntry]
}

public struct GeckoUpdateManifestEntry: Decodable, Sendable {
    public let version: String?
    public let updateLink: String
    public let updateHash: String?
    public let updateInfoURL: String?
    public let applications: GeckoUpdateManifestApplications?

    private enum CodingKeys: String, CodingKey {
        case version
        case updateLink = "update_link"
        case updateHash = "update_hash"
        case updateInfoURL = "update_info_url"
        case applications
    }
}

public struct GeckoUpdateManifestApplications: Decodable, Sendable {
    public let kiririn: GeckoUpdateManifestKiririnApplication?
}

public struct GeckoUpdateManifestKiririnApplication: Decodable, Sendable {
    public let strictMinVersion: String?
    public let strictMaxVersion: String?
    public let advisoryMaxVersion: String?

    private enum CodingKeys: String, CodingKey {
        case strictMinVersion = "strict_min_version"
        case strictMaxVersion = "strict_max_version"
        case advisoryMaxVersion = "advisory_max_version"
    }
}

public struct GeckoUpdateHash: Sendable {
    public enum Algorithm: Sendable {
        case sha256
        case sha512
    }

    public let algorithm: Algorithm
    public let expectedHex: String

    public init?(_ rawValue: String?) {
        guard
            let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty
        else {
            return nil
        }

        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }

        let normalizedHex = parts[1].lowercased()
        guard
            !normalizedHex.isEmpty,
            normalizedHex.unicodeScalars.allSatisfy(Self.hexadecimalCharacters.contains)
        else {
            return nil
        }

        switch parts[0].lowercased() {
        case "sha256":
            guard normalizedHex.count == 64 else { return nil }
            algorithm = .sha256
        case "sha512":
            guard normalizedHex.count == 128 else { return nil }
            algorithm = .sha512
        default:
            return nil
        }

        expectedHex = normalizedHex
    }

    public func matches(data: Data) -> Bool {
        let actualHex: String
        switch algorithm {
        case .sha256:
            actualHex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .sha512:
            actualHex = SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return actualHex == expectedHex
    }

    private static let hexadecimalCharacters = CharacterSet(
        charactersIn: "0123456789abcdefABCDEF"
    )
}

public struct PluginUpdateResolver: Sendable {
    public let currentAppVersion: String
    public let session: URLSession

    public init(currentAppVersion: String, session: URLSession = .shared) {
        self.currentAppVersion = currentAppVersion
        self.session = session
    }

    public func resolveUpdateEntry(
        fromUpdateManifestURL url: URL,
        manifestID: String,
        currentVersion: String?
    ) async throws -> GeckoUpdateManifestEntry {
        guard !manifestID.isEmpty else {
            throw PluginManifestValidationError(messages: [
                "IDが設定されていないため更新先を解決できません"
            ])
        }

        let data = try await fetchDataIgnoringCache(from: url)

        let updateManifest: GeckoUpdateManifest
        do {
            updateManifest = try JSONDecoder().decode(GeckoUpdateManifest.self, from: data)
        } catch {
            throw PluginManifestValidationError(messages: [
                "アップデートマニフェストのJSONを読み取れません: \(error.localizedDescription)"
            ])
        }

        guard let addon = updateManifest.addons[manifestID] else {
            throw PluginManifestValidationError(messages: [
                "アップデートマニフェストにID \"\(manifestID)\" の定義がありません"
            ])
        }

        let compatibleEntries = addon.updates.filter(isCompatible)
        guard !compatibleEntries.isEmpty else {
            throw PluginManifestValidationError(messages: [
                "このバージョンのKiririnに対応した更新候補がありません"
            ])
        }

        let sortedEntries = compatibleEntries.sorted { lhs, rhs in
            (lhs.version ?? "").compare(rhs.version ?? "", options: .numeric) == .orderedDescending
        }
        guard let entry = sortedEntries.first(where: supportsUpdateDownload) else {
            throw PluginManifestValidationError(messages: [
                "アップデートマニフェストに利用できるダウンロードURLがありません"
            ])
        }

        try validateUpdateVersion(
            currentVersion: currentVersion,
            candidateVersion: entry.version
        )

        return entry
    }

    public func isCompatible(_ entry: GeckoUpdateManifestEntry) -> Bool {
        guard let applications = entry.applications else {
            return true
        }
        guard let kiririn = applications.kiririn else {
            return false
        }

        if let minVersion = Self.trimmedNonEmpty(kiririn.strictMinVersion),
            currentAppVersion.compare(minVersion, options: .numeric) == .orderedAscending
        {
            return false
        }
        if let maxVersion = Self.trimmedNonEmpty(kiririn.strictMaxVersion),
            maxVersion != "*",
            currentAppVersion.compare(maxVersion, options: .numeric) == .orderedDescending
        {
            return false
        }

        return true
    }

    public func supportsUpdateDownload(_ entry: GeckoUpdateManifestEntry) -> Bool {
        guard
            let url = URL(string: entry.updateLink),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme)
        else {
            return false
        }

        return scheme == "https" || Self.trimmedNonEmpty(entry.updateHash) != nil
    }

    public func parseUpdateHash(_ rawValue: String?) throws -> GeckoUpdateHash? {
        guard let rawValue = Self.trimmedNonEmpty(rawValue) else {
            return nil
        }
        guard let updateHash = GeckoUpdateHash(rawValue) else {
            throw PluginManifestValidationError(messages: [
                "アップデート検証用ハッシュの形式が不正です。sha256:またはsha512:で始まる16進ハッシュを指定してください"
            ])
        }
        return updateHash
    }

    public func validateUpdateVersion(currentVersion: String?, candidateVersion: String?) throws {
        guard
            let currentVersion = Self.trimmedNonEmpty(currentVersion),
            let candidateVersion = Self.trimmedNonEmpty(candidateVersion)
        else {
            return
        }

        switch candidateVersion.compare(currentVersion, options: .numeric) {
        case .orderedDescending:
            return
        case .orderedSame:
            throw PluginManifestValidationError(messages: [
                "候補バージョン（\(candidateVersion)）は現在のバージョン（\(currentVersion)）と同じです。更新はありません"
            ])
        case .orderedAscending:
            throw PluginManifestValidationError(messages: [
                "アップデートマニフェストの最新版（\(candidateVersion)）は現在のバージョン（\(currentVersion)）より古いため更新できません"
            ])
        }
    }

    public func validateResolvedUpdateVersion(entryVersion: String?, packageVersion: String?)
        throws
    {
        guard
            let entryVersion = Self.trimmedNonEmpty(entryVersion),
            let packageVersion = Self.trimmedNonEmpty(packageVersion),
            entryVersion != packageVersion
        else {
            return
        }

        throw PluginManifestValidationError(messages: [
            "アップデートマニフェストのバージョン（\(entryVersion)）と取得したkppxのマニフェストバージョン（\(packageVersion)）が一致しません。update.jsonだけでなくkppx側のmanifest.jsonも更新してください"
        ])
    }

    public func fetchDataIgnoringCache(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let (data, _) = try await session.data(for: request)
        return data
    }

    public static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
