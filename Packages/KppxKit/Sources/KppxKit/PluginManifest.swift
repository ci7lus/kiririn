import CryptoKit
import Foundation

public enum PluginDisplayArea: String, Codable, CaseIterable, Sendable {
    case overlay = "overlay"
    case options = "options"
    case panel = "panel"
}

public enum PluginPermission: String, Codable, CaseIterable, Sendable {
    case storage
    case unlimitedStorage
}

extension PluginPermission {
    public var localizedName: String {
        switch self {
        case .storage: return "ストレージ"
        case .unlimitedStorage: return "無制限のストレージ"
        }
    }

    public static func localizedName(for rawValue: String) -> String? {
        PluginPermission(rawValue: rawValue)?.localizedName
    }
}

public struct ExtensionPluginManifest: Equatable, Sendable {
    public let manifestID: String
    public let displayName: String
    public let version: String?
    public let author: String?
    public let homepageURL: String?
    public let summary: String?
    public let displayAreas: [PluginDisplayArea]
    public let overlayPage: String?
    public let panelPage: String?
    public let optionsPage: String?
    public let isBackgroundExists: Bool
    public let strictMinVersion: String?
    public let strictMaxVersion: String?
    public let manifestUpdateURL: String?
    public let requestedPermissions: [String]
    public let requestedHostPermissions: [String]

    public init(
        manifestID: String,
        displayName: String,
        version: String? = nil,
        author: String? = nil,
        homepageURL: String? = nil,
        summary: String? = nil,
        displayAreas: [PluginDisplayArea],
        overlayPage: String? = nil,
        panelPage: String? = nil,
        optionsPage: String? = nil,
        isBackgroundExists: Bool = false,
        strictMinVersion: String? = nil,
        strictMaxVersion: String? = nil,
        manifestUpdateURL: String? = nil,
        requestedPermissions: [String] = [],
        requestedHostPermissions: [String] = []
    ) {
        self.manifestID = manifestID
        self.displayName = displayName
        self.version = version
        self.author = author
        self.homepageURL = homepageURL
        self.summary = summary
        self.displayAreas = displayAreas
        self.overlayPage = overlayPage
        self.panelPage = panelPage
        self.optionsPage = optionsPage
        self.isBackgroundExists = isBackgroundExists
        self.strictMinVersion = strictMinVersion
        self.strictMaxVersion = strictMaxVersion
        self.manifestUpdateURL = manifestUpdateURL
        self.requestedPermissions = requestedPermissions
        self.requestedHostPermissions = requestedHostPermissions
    }

    public func pagePath(for area: PluginDisplayArea) -> String? {
        switch area {
        case .overlay:
            overlayPage
        case .panel:
            panelPage
        case .options:
            optionsPage
        }
    }
}

public struct PluginManifestValidationError: LocalizedError {
    public let messages: [String]

    public init(messages: [String]) {
        self.messages = messages
    }

    public var errorDescription: String? { messages.joined(separator: "\n") }
}

public struct PluginManifestParser: Sendable {
    public static let extensionManifestFileName = "manifest.json"
    public static let allowedExtensionPermissions: Set<String> = [
        "storage",
        "unlimitedStorage",
    ]
    public static let prohibitedExtensionManifestKeys: Set<String> = [
        "content_scripts",
        "commands",
        "action",
        "browser_action",
        "page_action",
    ]

    public init() {}

    public func parse(
        atResourceURL resourceURL: URL,
        fileManager: FileManager = .default
    ) throws -> ExtensionPluginManifest {
        var isDirectory: ObjCBool = false
        let resourcePath = resourceURL.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: resourcePath, isDirectory: &isDirectory) else {
            throw PluginManifestValidationError(messages: ["プラグインリソースが見つかりません"])
        }

        if isDirectory.boolValue {
            return try parse(inDirectory: resourceURL, fileManager: fileManager)
        }

        do {
            let package = try PluginDecoder.decode(url: resourceURL)
            return try parse(inArchive: package)
        } catch let error as PluginManifestValidationError {
            throw error
        } catch {
            throw PluginManifestValidationError(messages: [
                "プラグインパッケージの読み込みに失敗しました: \(error.localizedDescription)"
            ])
        }
    }

    public func parse(inArchive archive: PluginPackage) throws -> ExtensionPluginManifest {
        guard
            let manifestData = try archive.fileData(named: Self.extensionManifestFileName)
        else {
            throw PluginManifestValidationError(messages: ["manifest.jsonが見つかりません"])
        }

        return try parse(
            manifestData: manifestData,
            resourceExists: { path in
                (try? archive.containsFile(named: path)) == true
            }
        )
    }

    public func parse(
        inDirectory directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> ExtensionPluginManifest {
        let manifestURL = directoryURL.appending(path: Self.extensionManifestFileName)
        guard fileManager.fileExists(atPath: manifestURL.path(percentEncoded: false)) else {
            throw PluginManifestValidationError(messages: ["manifest.jsonが見つかりません"])
        }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw PluginManifestValidationError(messages: [
                "manifest.jsonの読み込みに失敗しました: \(error.localizedDescription)"
            ])
        }

        return try parse(
            manifestData: data,
            resourceExists: { path in
                fileManager.fileExists(
                    atPath: directoryURL.appending(path: path).path(percentEncoded: false)
                )
            }
        )
    }

    public func parse(
        manifestData data: Data,
        resourceExists: (String) -> Bool
    ) throws -> ExtensionPluginManifest {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PluginManifestValidationError(messages: ["manifest.jsonの形式が不正です"])
            }
            root = object
        } catch let error as PluginManifestValidationError {
            throw error
        } catch {
            throw PluginManifestValidationError(messages: [
                "manifest.jsonのJSONを読み取れません: \(error.localizedDescription)"
            ])
        }

        var errors: [String] = []
        for prohibitedKey in Self.prohibitedExtensionManifestKeys where root[prohibitedKey] != nil {
            errors.append("\(prohibitedKey)はサポートしていません")
        }

        let displayName = Self.trimmedNonEmpty(root["name"] as? String)
        if displayName == nil {
            errors.append("nameが指定されていません")
        }

        let version = Self.trimmedNonEmpty(root["version"] as? String)
        if version == nil {
            errors.append("versionが指定されていません")
        }

        let browserSpecificSettings = root["browser_specific_settings"] as? [String: Any]
        let kiririn = browserSpecificSettings?["kiririn"] as? [String: Any]
        let manifestID = Self.trimmedNonEmpty(kiririn?["id"] as? String)
        if manifestID == nil {
            errors.append("プラグインマニフェストにIDが指定されていません")
        }

        let optionsUI = root["options_ui"] as? [String: Any]
        let background = root["background"] as? [String: Any]
        let kiririnViews = kiririn?["views"] as? [String: Any]
        let overlay = kiririnViews?["overlay"] as? [String: Any]
        let panel = kiririnViews?["panel"] as? [String: Any]

        let optionsPage = Self.validatedRelativeResourcePath(
            optionsUI?["page"] as? String,
            label: "options_ui.page",
            resourceExists: resourceExists,
            errors: &errors
        )
        let overlayPage = Self.validatedRelativeResourcePath(
            overlay?["page"] as? String,
            label: "browser_specific_settings.kiririn.views.overlay.page",
            resourceExists: resourceExists,
            errors: &errors
        )
        let panelPage = Self.validatedRelativeResourcePath(
            panel?["page"] as? String,
            label: "browser_specific_settings.kiririn.views.panel.page",
            resourceExists: resourceExists,
            errors: &errors
        )
        if let scripts = background?["scripts"] as? [String] {
            for (index, script) in scripts.enumerated() {
                _ = Self.validatedRelativeResourcePath(
                    script,
                    label: "background.scripts[\(index)]",
                    resourceExists: resourceExists,
                    errors: &errors
                )
            }
        }

        _ = Self.validatedRelativeResourcePath(
            background?["service_worker"] as? String,
            label: "background.service_worker",
            resourceExists: resourceExists,
            errors: &errors
        )

        let supportedBackgroundKeys: Set<String> = [
            "page", "scripts", "service_worker", "persistent", "preferred_environment",
        ]
        if let background {
            let unsupportedKeys = background.keys
                .filter { !supportedBackgroundKeys.contains($0) }
                .sorted()
            if !unsupportedKeys.isEmpty {
                let joined = unsupportedKeys.joined(separator: ", ")
                errors.append(
                    "サポートしていないバックグラウンド設定があります: \(joined)"
                )
            }
        }

        let manifestUpdateURL = Self.trimmedNonEmpty(kiririn?["update_url"] as? String)
        let strictMinVersion = Self.trimmedNonEmpty(kiririn?["strict_min_version"] as? String)
        let strictMaxVersion = Self.trimmedNonEmpty(kiririn?["strict_max_version"] as? String)

        if let strictMinVersion,
            let strictMaxVersion,
            strictMaxVersion != "*",
            strictMinVersion.compare(strictMaxVersion, options: .numeric) == .orderedDescending
        {
            errors.append(
                "インストールに必要な最小バージョンは最大バージョン以下である必要があります"
            )
        }

        if let manifestUpdateURL,
            URL(string: manifestUpdateURL).map({
                ["http", "https"].contains($0.scheme?.lowercased() ?? "")
            }) != true
        {
            errors.append("アップデート用URLはhttp(s)URLである必要があります")
        }

        let permissions = (root["permissions"] as? [String]) ?? []
        let invalidPermissions = permissions.filter {
            !Self.allowedExtensionPermissions.contains($0)
        }
        if !invalidPermissions.isEmpty {
            errors.append(
                "permissionsに許可されていない値があります: \(invalidPermissions.joined(separator: ", "))")
        }

        let hostPermissions = (root["host_permissions"] as? [String]) ?? []

        var displayAreas: [PluginDisplayArea] = []
        if overlayPage != nil {
            displayAreas.append(.overlay)
        }
        if panelPage != nil {
            displayAreas.append(.panel)
        }
        if optionsPage != nil {
            displayAreas.append(.options)
        }
        if displayAreas.isEmpty {
            errors.append(
                "表示ページはオーバーレイ、パネル、設定画面の少なくとも1つが必要です"
            )
        }

        if !errors.isEmpty {
            throw PluginManifestValidationError(messages: errors)
        }

        return ExtensionPluginManifest(
            manifestID: manifestID ?? "",
            displayName: displayName ?? "",
            version: version,
            author: Self.trimmedNonEmpty(root["author"] as? String),
            homepageURL: Self.trimmedNonEmpty(root["homepage_url"] as? String),
            summary: Self.trimmedNonEmpty(root["description"] as? String),
            displayAreas: displayAreas,
            overlayPage: overlayPage,
            panelPage: panelPage,
            optionsPage: optionsPage,
            isBackgroundExists: background != nil,
            strictMinVersion: strictMinVersion,
            strictMaxVersion: strictMaxVersion,
            manifestUpdateURL: manifestUpdateURL,
            requestedPermissions: permissions,
            requestedHostPermissions: hostPermissions
        )
    }

    public static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    public static func archiveFileName(for manifestID: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-@")
        )
        let sanitized = manifestID.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? String(scalar) : "_"
        }.joined()
        return "\(sanitized).kppx"
    }

    public static func resourceHash(forArchiveURL archiveURL: URL) throws -> String {
        do {
            let handle = try FileHandle(forReadingFrom: archiveURL)
            defer {
                try? handle.close()
            }

            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                guard !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            throw PluginManifestValidationError(messages: [
                "プラグインパッケージの読み込みに失敗しました: \(error.localizedDescription)"
            ])
        }
    }

    static func validatedRelativeResourcePath(
        _ rawPath: String?,
        label: String,
        resourceExists: (String) -> Bool,
        errors: inout [String]
    ) -> String? {
        guard let path = trimmedNonEmpty(rawPath) else {
            return nil
        }

        if path.hasPrefix("/") || path.contains("..") {
            errors.append("\(label) は相対パスである必要があります")
            return nil
        }

        guard resourceExists(path) else {
            errors.append("\(label) が指すファイルが存在しません: \(path)")
            return nil
        }

        return path
    }
}
