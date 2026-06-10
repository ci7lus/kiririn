import CryptoKit
import Darwin
import Foundation
import Logging

private let logger = Logger(label: "PluginStore")
enum PluginSourceType: String, Codable, Sendable {
    case kppx
    case localFolder

    var localizedLabel: String {
        switch self {
        case .kppx:
            return "kppx"
        case .localFolder:
            return "ローカルフォルダ"
        }
    }
}

struct ExtensionPluginManifest: Equatable {
    let manifestID: String
    let displayName: String
    let version: String?
    let author: String?
    let homepageURL: String?
    let summary: String?
    let displayAreas: [PluginDisplayArea]
    let overlayPage: String?
    let panelPage: String?
    let optionsPage: String?
    let isBackgroundExists: Bool
    let strictMinVersion: String?
    let strictMaxVersion: String?
    let manifestUpdateURL: String?
    let requestedPermissions: [String]
    let requestedHostPermissions: [String]

    func pagePath(for area: PluginDisplayArea) -> String? {
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

struct PluginInstallPreview: Identifiable {
    fileprivate enum Payload {
        case package(archiveURL: URL)
        case localFolder(url: URL, bookmarkData: Data?)
    }

    let id = UUID()
    let sourceType: PluginSourceType
    let manifest: ExtensionPluginManifest
    let packageAuthentication: PluginPackageAuthentication
    let updateInfoURL: URL?
    let installWarnings: [String]

    fileprivate let payload: Payload
}

#if DEBUG
    // PluginSignatureBehaviorTests で利用するテスト用イニシャライザ
    extension PluginInstallPreview {
        static func testing(
            sourceType: PluginSourceType = .kppx,
            manifest: ExtensionPluginManifest,
            packageAuthentication: PluginPackageAuthentication,
            updateInfoURL: URL? = nil,
            installWarnings: [String] = [],
            archiveURL: URL = URL(fileURLWithPath: "/dev/null")
        ) -> PluginInstallPreview {
            PluginInstallPreview(
                sourceType: sourceType,
                manifest: manifest,
                packageAuthentication: packageAuthentication,
                updateInfoURL: updateInfoURL,
                installWarnings: installWarnings,
                payload: .package(archiveURL: archiveURL)
            )
        }
    }
#endif

enum PluginInstallRouting {
    case install
    case update(pluginID: UUID, signerMismatch: Bool)
}

struct PluginDefinition: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var sourceType: PluginSourceType
    var resourceBasePath: String
    var resourceBookmark: Data?
    var resourceHash: String?
    var isBlocked: Bool
    var manifestUpdateURL: String?
    var manifestVersion: String?
    var manifestAuthor: String?
    var manifestLink: String?
    var manifestSupportedAreas: [PluginDisplayArea]?
    var manifestID: String
    var packageAuthentication: PluginPackageAuthentication

    init(
        id: UUID,
        name: String,
        isEnabled: Bool = true,
        sourceType: PluginSourceType = .kppx,
        resourceBasePath: String = "",
        resourceBookmark: Data? = nil,
        resourceHash: String? = nil,
        isBlocked: Bool = false,
        manifestUpdateURL: String? = nil,
        manifestVersion: String? = nil,
        manifestAuthor: String? = nil,
        manifestLink: String? = nil,
        manifestSupportedAreas: [PluginDisplayArea]? = nil,
        manifestID: String,
        packageAuthentication: PluginPackageAuthentication = .unsigned
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.sourceType = sourceType
        self.resourceBasePath = resourceBasePath
        self.resourceBookmark = resourceBookmark
        self.resourceHash = resourceHash
        self.isBlocked = isBlocked
        self.manifestUpdateURL = manifestUpdateURL
        self.manifestVersion = manifestVersion
        self.manifestAuthor = manifestAuthor
        self.manifestLink = manifestLink
        self.manifestSupportedAreas = manifestSupportedAreas
        self.manifestID = manifestID
        self.packageAuthentication = packageAuthentication
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case isEnabled
        case sourceType
        case resourceBasePath
        case resourceBookmark
        case resourceHash
        case isBlocked
        case manifestUpdateURL
        case manifestVersion
        case manifestAuthor
        case manifestLink
        case manifestSupportedAreas
        case manifestID
        case packageAuthentication
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        sourceType =
            try container.decodeIfPresent(PluginSourceType.self, forKey: .sourceType) ?? .kppx
        resourceBasePath = try container.decode(String.self, forKey: .resourceBasePath)
        resourceBookmark = try container.decodeIfPresent(Data.self, forKey: .resourceBookmark)
        resourceHash = try container.decodeIfPresent(String.self, forKey: .resourceHash)
        isBlocked = try container.decodeIfPresent(Bool.self, forKey: .isBlocked) ?? false
        manifestUpdateURL = try container.decodeIfPresent(String.self, forKey: .manifestUpdateURL)
        manifestVersion = try container.decodeIfPresent(String.self, forKey: .manifestVersion)
        manifestAuthor = try container.decodeIfPresent(String.self, forKey: .manifestAuthor)
        manifestLink = try container.decodeIfPresent(String.self, forKey: .manifestLink)
        manifestSupportedAreas = try container.decodeIfPresent(
            [PluginDisplayArea].self, forKey: .manifestSupportedAreas)
        manifestID = try container.decode(String.self, forKey: .manifestID)
        packageAuthentication =
            try container.decodeIfPresent(
                PluginPackageAuthentication.self,
                forKey: .packageAuthentication
            ) ?? .unsigned
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(sourceType, forKey: .sourceType)
        try container.encode(resourceBasePath, forKey: .resourceBasePath)
        try container.encodeIfPresent(resourceBookmark, forKey: .resourceBookmark)
        if sourceType != .localFolder {
            try container.encodeIfPresent(resourceHash, forKey: .resourceHash)
        }
        try container.encode(isBlocked, forKey: .isBlocked)
        try container.encodeIfPresent(manifestUpdateURL, forKey: .manifestUpdateURL)
        try container.encodeIfPresent(manifestVersion, forKey: .manifestVersion)
        try container.encodeIfPresent(manifestAuthor, forKey: .manifestAuthor)
        try container.encodeIfPresent(manifestLink, forKey: .manifestLink)
        try container.encodeIfPresent(manifestSupportedAreas, forKey: .manifestSupportedAreas)
        try container.encode(manifestID, forKey: .manifestID)
        try container.encode(packageAuthentication, forKey: .packageAuthentication)
    }

    func supports(area: PluginDisplayArea) -> Bool {
        guard let supported = manifestSupportedAreas else { return true }
        return supported.contains(area)
    }

    var canCheckForUpdates: Bool {
        guard sourceType != .localFolder,
            manifestUpdateURL != nil
        else {
            return false
        }
        return packageAuthentication.isSigned
    }
}

struct PluginManifestValidationError: LocalizedError {
    let messages: [String]
    var errorDescription: String? { messages.joined(separator: "\n") }
}

private struct GeckoUpdateManifest: Decodable {
    let addons: [String: GeckoUpdateManifestAddon]
}

private struct GeckoUpdateManifestAddon: Decodable {
    let updates: [GeckoUpdateManifestEntry]
}

private struct GeckoUpdateManifestEntry: Decodable {
    let version: String?
    let updateLink: String
    let updateHash: String?
    let updateInfoURL: String?
    let applications: GeckoUpdateManifestApplications?

    private enum CodingKeys: String, CodingKey {
        case version
        case updateLink = "update_link"
        case updateHash = "update_hash"
        case updateInfoURL = "update_info_url"
        case applications
    }
}

private struct GeckoUpdateManifestApplications: Decodable {
    let kiririn: GeckoUpdateManifestKiririnApplication?
}

private struct GeckoUpdateManifestKiririnApplication: Decodable {
    let strictMinVersion: String?
    let strictMaxVersion: String?
    let advisoryMaxVersion: String?

    private enum CodingKeys: String, CodingKey {
        case strictMinVersion = "strict_min_version"
        case strictMaxVersion = "strict_max_version"
        case advisoryMaxVersion = "advisory_max_version"
    }
}

private struct GeckoUpdateHash {
    private static let hexadecimalCharacters = CharacterSet(
        charactersIn: "0123456789abcdefABCDEF"
    )

    enum Algorithm {
        case sha256
        case sha512
    }

    let algorithm: Algorithm
    let expectedHex: String

    init?(_ rawValue: String?) {
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

    func matches(data: Data) -> Bool {
        let actualHex: String
        switch algorithm {
        case .sha256:
            actualHex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .sha512:
            actualHex = SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return actualHex == expectedHex
    }
}

@Observable
class PluginStore {
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let pluginsKey = "kiririn.plugin.definitions"
    private let developerModeKey = "kiririn.plugin.developer_mode_enabled"
    private let pluginDirectoryName = "Plugins"
    private static let extensionManifestFileName = "manifest.json"
    private static let currentAppVersion =
        trimmedNonEmpty(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        ?? "0"
    private static let localManifestReloadEvents: DispatchSource.FileSystemEvent = [
        .write,
        .delete,
        .rename,
        .extend,
    ]
    private static let allowedExtensionPermissions: Set<String> = [
        "storage",
        "unlimitedStorage",
    ]
    private static let packageSignatureRequirement: PluginPackageSignatureRequirement = .optional
    private static let prohibitedExtensionManifestKeys: Set<String> = [
        "content_scripts",
        "commands",
        "action",
        "browser_action",
        "page_action",
    ]
    private let packageSignatureVerifier: PluginPackageSignatureVerifier

    var fileReadErrorMessage: String?
    var droppedPluginAlertMessage: String?
    var isDeveloperModeEnabled: Bool
    @ObservationIgnored var onLocalFolderManifestChanged: ((UUID) -> Void)?

    private var resolvedManifestCache: [UUID: ExtensionPluginManifest] = [:]
    @ObservationIgnored private var localManifestWatchers: [UUID: DispatchSourceFileSystemObject] =
        [:]
    @ObservationIgnored private var localManifestWatcherPaths: [UUID: String] = [:]
    @ObservationIgnored private var pendingLocalManifestReloads: [UUID: DispatchWorkItem] = [:]

    var plugins: [PluginDefinition] {
        didSet {
            persistPlugins()
            syncLocalManifestWatchers()
        }
    }

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        packageSignatureVerifier: PluginPackageSignatureVerifier = .shared
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.packageSignatureVerifier = packageSignatureVerifier
        self.isDeveloperModeEnabled = defaults.bool(forKey: developerModeKey)
        self.plugins = []

        try? ensurePluginDirectoryExists()

        let initialPlugins: [PluginDefinition]
        let droppedStoredPlugins: [PluginDefinition]
        if let data = defaults.data(forKey: pluginsKey),
            let decoded = try? JSONDecoder().decode([PluginDefinition].self, from: data)
        {
            droppedStoredPlugins = decoded.filter { $0.resourceBasePath.isEmpty }
            initialPlugins = decoded.filter { !$0.resourceBasePath.isEmpty }
        } else {
            if defaults.data(forKey: pluginsKey) != nil {
                defaults.removeObject(forKey: pluginsKey)
            }
            droppedStoredPlugins = []
            initialPlugins = []
        }

        for plugin in droppedStoredPlugins {
            cleanupRemovedPlugin(plugin)
        }

        self.plugins = initialPlugins
        cleanupOrphanedFiles()
        cleanupWebKitExtractedArchives()
        refreshPluginsFromFiles()
        enforceDeveloperModeRestrictionsIfNeeded()
        syncLocalManifestWatchers()
        if !droppedStoredPlugins.isEmpty {
            appendDroppedPluginAlertMessage(
                "読み込めなかったプラグインを削除しました（\(droppedStoredPlugins.count)件）")
        }
    }

    deinit {
        stopAllLocalManifestWatchers()
    }

    func updatePlugin(_ plugin: PluginDefinition) {
        guard let index = plugins.firstIndex(where: { $0.id == plugin.id }) else { return }

        var updated = plugin
        do {
            updated = try refreshExtensionBundlePlugin(updated)
            plugins[index] = updated
            fileReadErrorMessage = nil
        } catch {
            fileReadErrorMessage = error.localizedDescription
        }
    }

    func removePlugin(id: UUID) {
        guard let removed = plugins.first(where: { $0.id == id }) else {
            plugins.removeAll { $0.id == id }
            return
        }
        plugins.removeAll { $0.id == id }
        resolvedManifestCache[id] = nil
        cleanupRemovedPlugin(removed)
    }

    func plugin(id: UUID) -> PluginDefinition? {
        plugins.first { $0.id == id }
    }

    func plugin(manifestID: String) -> PluginDefinition? {
        plugins.first { $0.manifestID == manifestID }
    }

    func installRouting(for preview: PluginInstallPreview) throws -> PluginInstallRouting {
        guard let previous = plugin(manifestID: preview.manifest.manifestID) else {
            return .install
        }
        return try updateRouting(replacing: previous, with: preview)
    }

    func updateRouting(replacing previous: PluginDefinition, with preview: PluginInstallPreview)
        throws
        -> PluginInstallRouting
    {
        guard preview.manifest.manifestID == previous.manifestID else {
            throw PluginManifestValidationError(messages: [
                "IDが一致しません。別のプラグインパッケージのため更新を中止しました"
            ])
        }

        let signerMismatch = !signerMatchesForUpdate(previous: previous, preview: preview)
        if signerMismatch, !isDeveloperModeEnabled {
            throw PluginManifestValidationError(messages: [
                "開発者モードが無効なため、署名元が一致しないkppxへの更新は利用できません"
            ])
        }

        return .update(pluginID: previous.id, signerMismatch: signerMismatch)
    }

    func setDeveloperModeEnabled(_ enabled: Bool) {
        guard isDeveloperModeEnabled != enabled else { return }
        isDeveloperModeEnabled = enabled
        defaults.set(enabled, forKey: developerModeKey)
        enforceDeveloperModeRestrictionsIfNeeded()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) throws {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        if enabled, plugins[index].isBlocked {
            return
        }

        if enabled {
            try validateDeveloperModeRequirement(
                plugins[index].packageAuthentication,
                sourceType: plugins[index].sourceType,
                actionLabel: "有効化"
            )
        }
        plugins[index].isEnabled = enabled
    }

    func movePlugins(from source: IndexSet, to destination: Int) {
        let movingPlugins = source.map { plugins[$0] }
        let adjustedDestination = source.reduce(destination) { partialResult, index in
            index < destination ? partialResult - 1 : partialResult
        }

        for index in source.sorted(by: >) {
            plugins.remove(at: index)
        }

        plugins.insert(contentsOf: movingPlugins, at: adjustedDestination)
    }

    func movePlugin(id: UUID, delta: Int) -> Bool {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return false }
        let newIndex = index + delta
        guard newIndex >= 0 && newIndex < plugins.count else { return false }
        movePlugins(
            from: IndexSet(integer: index),
            to: newIndex > index ? newIndex + 1 : newIndex
        )
        return true
    }

    func refreshPluginsFromFiles() {
        guard !plugins.isEmpty else {
            resolvedManifestCache = [:]
            fileReadErrorMessage = nil
            return
        }

        resolvedManifestCache = [:]
        var refreshedPlugins: [PluginDefinition] = []
        refreshedPlugins.reserveCapacity(plugins.count)
        var blockedPluginNames: [String] = []

        for plugin in plugins {
            do {
                let refreshed = try refreshExtensionBundlePlugin(plugin)
                refreshedPlugins.append(refreshed)
            } catch {
                logger.debug("Failed to reload plugin \(plugin.id): \(error.localizedDescription)")
                resolvedManifestCache[plugin.id] = nil
                refreshedPlugins.append(markPluginBlocked(plugin))
                if !plugin.isBlocked {
                    blockedPluginNames.append(plugin.name)
                }
            }
        }

        if refreshedPlugins != plugins {
            plugins = refreshedPlugins
        }
        if !blockedPluginNames.isEmpty {
            let pluginList = blockedPluginNames.joined(separator: "、")
            appendDroppedPluginAlertMessage(
                "内容確認が必要なプラグインをブロックしました: \(pluginList)。内容を確認し、問題なければ再有効化してください")
        }
        fileReadErrorMessage = nil
    }

    func clearFileReadErrorMessage() {
        fileReadErrorMessage = nil
    }

    func clearDroppedPluginAlertMessage() {
        droppedPluginAlertMessage = nil
    }

    func discardPreviewInstall(_ preview: PluginInstallPreview) {
        if case .package(let archiveURL) = preview.payload,
            archiveURL.lastPathComponent.hasPrefix("staging_")
        {
            try? fileManager.removeItem(at: archiveURL)
        }
    }

    private func stagePackageCopyIfNeeded(from sourceURL: URL) throws -> URL {
        if sourceURL.path.hasPrefix(pluginDirectoryURL.path) {
            return sourceURL
        }
        try ensurePluginDirectoryExists()
        let stagingName = "staging_\(UUID().uuidString).kppx"
        let stagingURL = pluginDirectoryURL.appending(path: stagingName)
        try fileManager.copyItem(at: sourceURL, to: stagingURL)
        return stagingURL
    }

    private func markPluginBlocked(_ plugin: PluginDefinition) -> PluginDefinition {
        var updated = plugin
        updated.isBlocked = true
        updated.isEnabled = false
        return updated
    }

    private func blockedPluginAlertMessage(for pluginName: String) -> String {
        "プラグイン「\(pluginName)」は内容確認が必要なためブロックしました。内容を確認し、問題なければ再有効化してください"
    }

    func previewStoredPlugin(for id: UUID) throws -> PluginInstallPreview {
        guard let plugin = plugin(id: id) else {
            throw PluginManifestValidationError(messages: ["プラグインが見つかりません"])
        }
        return try previewStoredPlugin(for: plugin)
    }

    @discardableResult
    func reenableBlockedPlugin(id: UUID, with preview: PluginInstallPreview) throws
        -> PluginDefinition
    {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else {
            throw PluginManifestValidationError(messages: ["プラグインが見つかりません"])
        }

        try validateDeveloperModeRequirement(
            preview.packageAuthentication,
            sourceType: preview.sourceType,
            actionLabel: "有効化"
        )

        let plugin = plugins[index]
        guard preview.manifest.manifestID == plugin.manifestID else {
            throw PluginManifestValidationError(messages: [
                "IDが一致しません。再登録してください（既存: \(plugin.manifestID) / マニフェスト: \(preview.manifest.manifestID)）"
            ])
        }

        var updated = plugin

        switch preview.payload {
        case .package(let archiveURL):
            guard plugin.sourceType != .localFolder else {
                throw PluginManifestValidationError(messages: [
                    "保存済みのローカルフォルダを読み込めませんでした"
                ])
            }
            updated.resourceHash = try Self.resourceHash(forArchiveURL: archiveURL)
        case .localFolder(let url, let bookmarkData):
            guard plugin.sourceType == .localFolder else {
                throw PluginManifestValidationError(messages: [
                    "保存済みのパッケージを読み込めませんでした"
                ])
            }
            updated.resourceBasePath = url.path(percentEncoded: false)
            updated.resourceBookmark = bookmarkData
            updated.resourceHash = nil
        }

        updated.isBlocked = false
        updated.isEnabled = true
        updated.name = preview.manifest.displayName
        updated.manifestVersion = preview.manifest.version
        updated.manifestAuthor = preview.manifest.author
        updated.manifestLink = preview.manifest.homepageURL
        updated.manifestSupportedAreas = preview.manifest.displayAreas
        updated.manifestUpdateURL = preview.manifest.manifestUpdateURL

        resolvedManifestCache[updated.id] = preview.manifest
        plugins[index] = updated
        return updated
    }

    private func syncLocalManifestWatchers() {
        let localPlugins = plugins.filter { $0.sourceType == .localFolder }
        let localPluginIDs = Set(localPlugins.map(\.id))

        for pluginID in Array(localManifestWatchers.keys) where !localPluginIDs.contains(pluginID) {
            stopLocalManifestWatcher(pluginID: pluginID)
        }

        for plugin in localPlugins {
            guard let manifestURL = localManifestURL(for: plugin) else {
                stopLocalManifestWatcher(pluginID: plugin.id)
                continue
            }

            let manifestPath = manifestURL.path(percentEncoded: false)
            if localManifestWatcherPaths[plugin.id] == manifestPath {
                continue
            }

            stopLocalManifestWatcher(pluginID: plugin.id)
            startLocalManifestWatcher(pluginID: plugin.id, manifestURL: manifestURL)
        }
    }

    private func localManifestURL(for plugin: PluginDefinition) -> URL? {
        guard plugin.sourceType == .localFolder,
            let resourceURL = try? resourceBaseURL(for: plugin)
        else {
            return nil
        }
        return resourceURL.appending(path: Self.extensionManifestFileName)
    }

    private func startLocalManifestWatcher(pluginID: UUID, manifestURL: URL) {
        let manifestPath = manifestURL.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: manifestPath) else {
            return
        }

        let fileDescriptor = open(manifestPath, O_RDONLY)
        guard fileDescriptor >= 0 else {
            logger.debug("Failed to watch local plugin manifest: \(manifestPath)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: Self.localManifestReloadEvents,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            let shouldReload =
                events.contains(.write)
                || events.contains(.delete)
                || events.contains(.rename)
                || events.contains(.extend)
            guard shouldReload else { return }
            self.stopLocalManifestWatcher(pluginID: pluginID)
            self.scheduleLocalManifestReload(pluginID: pluginID)
        }
        source.setCancelHandler {
            close(fileDescriptor)
        }

        localManifestWatchers[pluginID] = source
        localManifestWatcherPaths[pluginID] = manifestPath
        source.resume()
    }

    private func stopLocalManifestWatcher(pluginID: UUID) {
        pendingLocalManifestReloads[pluginID]?.cancel()
        pendingLocalManifestReloads[pluginID] = nil
        localManifestWatcherPaths[pluginID] = nil
        localManifestWatchers.removeValue(forKey: pluginID)?.cancel()
    }

    private func stopAllLocalManifestWatchers() {
        for workItem in pendingLocalManifestReloads.values {
            workItem.cancel()
        }
        pendingLocalManifestReloads = [:]
        localManifestWatcherPaths = [:]
        for source in localManifestWatchers.values {
            source.cancel()
        }
        localManifestWatchers = [:]
    }

    private func scheduleLocalManifestReload(pluginID: UUID) {
        pendingLocalManifestReloads[pluginID]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.reloadLocalFolderPluginAfterManifestChange(pluginID: pluginID)
        }
        pendingLocalManifestReloads[pluginID] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func reloadLocalFolderPluginAfterManifestChange(pluginID: UUID) {
        pendingLocalManifestReloads[pluginID] = nil
        defer { syncLocalManifestWatchers() }

        guard let index = plugins.firstIndex(where: { $0.id == pluginID }),
            plugins[index].sourceType == .localFolder
        else {
            return
        }

        let plugin = plugins[index]
        do {
            let refreshed = try refreshExtensionBundlePlugin(plugin)
            if let currentIndex = plugins.firstIndex(where: { $0.id == pluginID }) {
                plugins[currentIndex] = refreshed
            }
            fileReadErrorMessage = nil
            onLocalFolderManifestChanged?(pluginID)
        } catch {
            resolvedManifestCache[pluginID] = nil
            if let currentIndex = plugins.firstIndex(where: { $0.id == pluginID }) {
                plugins[currentIndex] = markPluginBlocked(plugin)
            }
            fileReadErrorMessage = error.localizedDescription
            if !plugin.isBlocked {
                appendDroppedPluginAlertMessage(blockedPluginAlertMessage(for: plugin.name))
            }
            logger.warning(
                "Failed to reload local plugin manifest \(pluginID): \(error.localizedDescription)"
            )
        }
    }

    private func appendDroppedPluginAlertMessage(_ message: String) {
        guard !message.isEmpty else { return }
        if let existing = droppedPluginAlertMessage, !existing.isEmpty {
            droppedPluginAlertMessage = existing + "\n" + message
        } else {
            droppedPluginAlertMessage = message
        }
    }

    private func persistPlugins() {
        guard let data = try? JSONEncoder().encode(plugins) else { return }
        defaults.set(data, forKey: pluginsKey)
    }

    var pluginDirectoryURL: URL {
        let base =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appending(path: pluginDirectoryName, directoryHint: .isDirectory)
    }

    func resolvedManifest(for id: UUID) -> ExtensionPluginManifest? {
        resolvedManifestCache[id]
    }

    func resolvedManifest(for plugin: PluginDefinition) throws -> ExtensionPluginManifest {
        if let manifest = resolvedManifestCache[plugin.id] {
            return manifest
        }

        let resourceURL = try resourceBaseURL(for: plugin)
        let manifest = try Self.parseExtensionManifest(
            atResourceURL: resourceURL,
            fileManager: fileManager
        )

        guard manifest.manifestID == plugin.manifestID else {
            throw PluginManifestValidationError(messages: [
                "IDが一致しません。再登録してください（既存: \(plugin.manifestID) / マニフェスト: \(manifest.manifestID)）"
            ])
        }

        resolvedManifestCache[plugin.id] = manifest
        return manifest
    }

    private func ensurePluginDirectoryExists() throws {
        try fileManager.createDirectory(at: pluginDirectoryURL, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var url = pluginDirectoryURL
        try? url.setResourceValues(resourceValues)
    }

    private func cleanupOrphanedFiles() {
        let knownBaseNames = Set(
            plugins.compactMap { plugin -> String? in
                guard plugin.sourceType != .localFolder,
                    !plugin.resourceBasePath.isEmpty
                else { return nil }
                return plugin.resourceBasePath
            }
        )

        guard
            let files = try? fileManager.contentsOfDirectory(
                at: pluginDirectoryURL,
                includingPropertiesForKeys: nil
            )
        else {
            return
        }

        for fileURL in files where !knownBaseNames.contains(fileURL.lastPathComponent) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func cleanupWebKitExtractedArchives() {
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: fileManager.temporaryDirectory,
                includingPropertiesForKeys: nil
            )
        else {
            return
        }

        for fileURL in files where fileURL.lastPathComponent.hasPrefix("WebKitExtractedArchive-") {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func removePluginResourceIfNeeded(_ plugin: PluginDefinition) {
        guard plugin.sourceType != .localFolder, !plugin.resourceBasePath.isEmpty else {
            return
        }
        let fileURL = pluginDirectoryURL.appending(path: plugin.resourceBasePath)
        try? fileManager.removeItem(at: fileURL)
    }

    private func cleanupRemovedPlugin(_ plugin: PluginDefinition) {
        let pluginID = plugin.id

        Task { @MainActor in
            defer {
                ExtensionPluginRuntimeRegistry.shared.invalidate(pluginID: pluginID)
                resolvedManifestCache[pluginID] = nil
                removePluginResourceIfNeeded(plugin)
            }

            do {
                _ = try await PluginWebsiteDataStore.removeAllData(for: plugin, store: self)
            } catch {
                logger.warning(
                    "Failed to remove plugin web data for \(pluginID): \(error.localizedDescription)"
                )
            }
        }
    }

    private func ensureUniqueManifestID(
        _ manifestIdentifier: String,
        excluding existingPlugin: PluginDefinition? = nil
    ) throws {
        guard
            let collision = plugins.first(where: { candidate in
                guard candidate.manifestID == manifestIdentifier else { return false }
                guard let existingPlugin else { return true }
                return candidate.id != existingPlugin.id
            })
        else {
            return
        }

        throw PluginManifestValidationError(messages: [
            "identifier \"\(manifestIdentifier)\" のプラグインはすでに登録されています: \"\(collision.name)\""
        ])
    }

    func previewPlugin(
        packageURL: URL,
        sourceType: PluginSourceType
    ) throws -> PluginInstallPreview {
        let workingURL = try stagePackageCopyIfNeeded(from: packageURL)
        let isStaged = (workingURL != packageURL)

        do {
            let package = try PluginDecoder.decode(url: workingURL)
            let packageAuthentication = try packageSignatureVerifier.verify(
                packageURL: workingURL
            )
            try validatePackageSignatureRequirement(
                packageAuthentication,
                sourceType: sourceType
            )
            try validateDeveloperModeRequirement(
                packageAuthentication,
                sourceType: sourceType,
                actionLabel: "追加"
            )
            let manifest = try Self.parseExtensionManifest(
                inArchive: package
            )
            let installWarnings = try validateManifestRuntimeCompatibility(manifest)

            return PluginInstallPreview(
                sourceType: sourceType,
                manifest: manifest,
                packageAuthentication: packageAuthentication,
                updateInfoURL: nil,
                installWarnings: installWarnings,
                payload: .package(archiveURL: workingURL)
            )
        } catch {
            if isStaged {
                try? fileManager.removeItem(at: workingURL)
            }
            throw error
        }
    }

    func previewPlugin(localFolderURL: URL, bookmarkData: Data?) throws -> PluginInstallPreview {
        try validateDeveloperModeRequirement(
            .unsigned,
            sourceType: .localFolder,
            actionLabel: "追加"
        )
        let manifest = try Self.parseExtensionManifest(
            atResourceURL: localFolderURL,
            fileManager: fileManager
        )
        let installWarnings = try validateManifestRuntimeCompatibility(manifest)

        return PluginInstallPreview(
            sourceType: .localFolder,
            manifest: manifest,
            packageAuthentication: .unsigned,
            updateInfoURL: nil,
            installWarnings: installWarnings,
            payload: .localFolder(url: localFolderURL, bookmarkData: bookmarkData)
        )
    }

    func previewPlugin(fromRemoteURL url: URL) async throws -> PluginInstallPreview {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw PluginManifestValidationError(messages: ["URLはhttp(s)である必要があります"])
        }

        let tempURL = try await downloadPackage(from: url)
        defer {
            try? fileManager.removeItem(at: tempURL)
        }
        return try previewPlugin(packageURL: tempURL, sourceType: .kppx)
    }

    @discardableResult
    func installPlugin(from preview: PluginInstallPreview) throws -> PluginDefinition {
        switch preview.payload {
        case .package(let archiveURL):
            let plugin = try installPluginPackage(
                archiveURL: archiveURL,
                manifest: preview.manifest,
                sourceType: preview.sourceType,
                packageAuthentication: preview.packageAuthentication
            )
            upsertPlugin(plugin)
            return plugin
        case .localFolder(let url, let bookmarkData):
            try ensureUniqueManifestID(preview.manifest.manifestID)

            let plugin = PluginDefinition(
                id: UUID(),
                name: preview.manifest.displayName,
                sourceType: .localFolder,
                resourceBasePath: url.path(percentEncoded: false),
                resourceBookmark: bookmarkData,
                resourceHash: nil,
                isBlocked: false,
                manifestUpdateURL: preview.manifest.manifestUpdateURL,
                manifestVersion: preview.manifest.version,
                manifestAuthor: preview.manifest.author,
                manifestLink: preview.manifest.homepageURL,
                manifestSupportedAreas: preview.manifest.displayAreas,
                manifestID: preview.manifest.manifestID,
                packageAuthentication: .unsigned
            )
            resolvedManifestCache[plugin.id] = preview.manifest
            upsertPlugin(plugin)
            return plugin
        }
    }

    func addPlugin(
        packageURL: URL,
        sourceType: PluginSourceType
    ) throws {
        let preview = try previewPlugin(packageURL: packageURL, sourceType: sourceType)
        try installPlugin(from: preview)
    }

    func addPlugin(localFolderURL: URL, bookmarkData: Data?) throws {
        let preview = try previewPlugin(localFolderURL: localFolderURL, bookmarkData: bookmarkData)
        try installPlugin(from: preview)
    }

    func addPlugin(fromRemoteURL url: URL) async throws {
        let preview = try await previewPlugin(fromRemoteURL: url)
        try installPlugin(from: preview)
    }

    func overwritePlugin(
        _ previous: PluginDefinition,
        withPackageURL packageURL: URL,
        sourceType: PluginSourceType
    ) throws {
        let preview = try previewPlugin(packageURL: packageURL, sourceType: sourceType)
        _ = try updateRouting(replacing: previous, with: preview)
        _ = try overwritePlugin(previous, with: preview)
    }

    @discardableResult
    func overwritePlugin(_ previous: PluginDefinition, with preview: PluginInstallPreview) throws
        -> PluginDefinition
    {
        guard preview.manifest.manifestID == previous.manifestID else {
            throw PluginManifestValidationError(messages: [
                "IDが一致しません。別のプラグインパッケージのため更新を中止しました"
            ])
        }

        switch preview.payload {
        case .package(let archiveURL):
            let plugin = try installPluginPackage(
                archiveURL: archiveURL,
                manifest: preview.manifest,
                sourceType: preview.sourceType,
                packageAuthentication: preview.packageAuthentication,
                replacing: previous
            )
            upsertPlugin(plugin)
            return plugin
        case .localFolder:
            throw PluginManifestValidationError(messages: [
                "更新モードではローカルフォルダを利用できません"
            ])
        }
    }

    func previewPlugin(fromUpdateManifestURL url: URL, previous: PluginDefinition) async throws
        -> PluginInstallPreview
    {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw PluginManifestValidationError(messages: ["URLはhttp(s)である必要があります"])
        }
        guard previous.packageAuthentication.isSigned else {
            throw PluginManifestValidationError(messages: [
                "未署名パッケージはアップデートによる更新を利用できません"
            ])
        }

        let entry = try await resolveUpdateEntry(fromUpdateManifestURL: url, plugin: previous)
        guard let packageURL = URL(string: entry.updateLink) else {
            throw PluginManifestValidationError(messages: [
                "アップデートのダウンロードURLが有効ではありません"
            ])
        }
        let updateHash = try parseUpdateHash(entry.updateHash)
        let tempURL = try await downloadPackage(from: packageURL)
        defer {
            try? fileManager.removeItem(at: tempURL)
        }
        if let updateHash {
            let fileData = try Data(contentsOf: tempURL)
            guard updateHash.matches(data: fileData) else {
                throw PluginManifestValidationError(messages: [
                    "アップデート検証用ハッシュがダウンロードしたkppxと一致しません"
                ])
            }
        }

        let basePreview = try previewPlugin(packageURL: tempURL, sourceType: .kppx)
        let preview = PluginInstallPreview(
            sourceType: basePreview.sourceType,
            manifest: basePreview.manifest,
            packageAuthentication: basePreview.packageAuthentication,
            updateInfoURL: Self.trimmedNonEmpty(entry.updateInfoURL).flatMap(URL.init(string:)),
            installWarnings: basePreview.installWarnings,
            payload: basePreview.payload
        )
        try validateResolvedUpdateVersion(
            entryVersion: entry.version,
            packageVersion: preview.manifest.version
        )
        guard preview.packageAuthentication.isSigned else {
            throw PluginManifestValidationError(messages: [
                "アップデートで取得したパッケージに署名がありません"
            ])
        }
        guard
            matchingSignerKeyHashes(
                lhs: previous.packageAuthentication.signerKeyHashes,
                rhs: preview.packageAuthentication.signerKeyHashes
            )
        else {
            throw PluginManifestValidationError(messages: [
                "アップデートで取得したパッケージの署名鍵が既存パッケージと一致しません"
            ])
        }
        guard case .package = preview.payload else {
            throw PluginManifestValidationError(messages: ["プラグインパッケージの読み込みに失敗しました"])
        }
        guard preview.manifest.manifestID == previous.manifestID else {
            throw PluginManifestValidationError(messages: [
                "プラグインIDが一致しません。別のプラグインパッケージのため更新を中止しました"
            ])
        }

        try validateUpdateVersion(
            currentVersion: previous.manifestVersion,
            candidateVersion: preview.manifest.version
        )

        return preview
    }

    func overwritePlugin(fromUpdateManifestURL url: URL, previous: PluginDefinition) async throws {
        let preview = try await previewPlugin(fromUpdateManifestURL: url, previous: previous)
        _ = try overwritePlugin(previous, with: preview)
    }

    func overwritePlugin(
        _ previous: PluginDefinition,
        withLocalFolderURL localFolderURL: URL,
        bookmarkData: Data?
    ) throws {
        guard isDeveloperModeEnabled else {
            throw PluginManifestValidationError(messages: [
                "開発者モードが無効なため、ローカルフォルダの差し替えは利用できません"
            ])
        }
        let manifest = try Self.parseExtensionManifest(
            atResourceURL: localFolderURL,
            fileManager: fileManager
        )

        guard manifest.manifestID == previous.manifestID else {
            throw PluginManifestValidationError(messages: [
                "プラグインIDが一致しません。別のローカルフォルダのため更新を中止しました"
            ])
        }

        var updated = previous
        updated.sourceType = .localFolder
        updated.resourceBasePath = localFolderURL.path(percentEncoded: false)
        updated.resourceBookmark = bookmarkData
        updated.resourceHash = nil
        updated.isBlocked = false
        updated.manifestUpdateURL = manifest.manifestUpdateURL
        updated.name = manifest.displayName
        updated.manifestVersion = manifest.version
        updated.manifestAuthor = manifest.author
        updated.manifestLink = manifest.homepageURL
        updated.manifestSupportedAreas = manifest.displayAreas
        updated.manifestID = manifest.manifestID

        resolvedManifestCache[updated.id] = manifest
        upsertPlugin(updated)
    }

    func extensionPagePath(for plugin: PluginDefinition, area: PluginDisplayArea) -> String? {
        resolvedManifestCache[plugin.id]?.pagePath(for: area)
    }

    func resourceBaseURL(for plugin: PluginDefinition) throws -> URL {
        if plugin.sourceType == .localFolder {
            if let bookmark = plugin.resourceBookmark {
                var isStale = false
                #if os(macOS)
                    let bookmarkOptions: URL.BookmarkResolutionOptions = [
                        .withSecurityScope, .withoutUI,
                    ]
                #else
                    let bookmarkOptions: URL.BookmarkResolutionOptions = []
                #endif
                let resolvedURL = try URL(
                    resolvingBookmarkData: bookmark,
                    options: bookmarkOptions,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                #if os(macOS)
                    _ = resolvedURL.startAccessingSecurityScopedResource()
                #endif
                return resolvedURL
            }

            return URL(fileURLWithPath: plugin.resourceBasePath, isDirectory: true)
        }

        return pluginDirectoryURL.appending(
            path: plugin.resourceBasePath)
    }

    private func refreshExtensionBundlePlugin(_ plugin: PluginDefinition) throws -> PluginDefinition
    {
        let resourceURL = try resourceBaseURL(for: plugin)
        let manifest = try Self.parseExtensionManifest(
            atResourceURL: resourceURL,
            fileManager: fileManager
        )

        guard manifest.manifestID == plugin.manifestID else {
            throw PluginManifestValidationError(messages: [
                "IDが一致しません。再登録してください（既存: \(plugin.manifestID) / マニフェスト: \(manifest.manifestID)）"
            ])
        }

        resolvedManifestCache[plugin.id] = manifest

        var updated = plugin
        updated.name = manifest.displayName
        updated.manifestVersion = manifest.version
        updated.manifestAuthor = manifest.author
        updated.manifestLink = manifest.homepageURL
        updated.manifestSupportedAreas = manifest.displayAreas
        updated.manifestID = manifest.manifestID
        updated.manifestUpdateURL = manifest.manifestUpdateURL

        if plugin.sourceType == .localFolder {
            updated.packageAuthentication = .unsigned
            updated.resourceHash = nil
            if updated.isBlocked {
                updated.isEnabled = false
            }
            return updated
        }

        let currentHash = try Self.resourceHash(forArchiveURL: resourceURL)
        if let storedHash = plugin.resourceHash {
            if storedHash != currentHash {
                updated = markPluginBlocked(updated)
                if !plugin.isBlocked {
                    appendDroppedPluginAlertMessage(blockedPluginAlertMessage(for: updated.name))
                }
                return updated
            }
        } else {
            updated.resourceHash = currentHash
        }

        if updated.isBlocked {
            updated.isEnabled = false
        }
        return updated
    }

    private func installPluginPackage(
        archiveURL: URL,
        manifest: ExtensionPluginManifest,
        sourceType: PluginSourceType,
        packageAuthentication: PluginPackageAuthentication,
        replacing previous: PluginDefinition? = nil
    ) throws -> PluginDefinition {
        try ensureUniqueManifestID(manifest.manifestID, excluding: previous)

        try ensurePluginDirectoryExists()
        let archiveFileName = Self.archiveFileName(for: manifest.manifestID)
        let installedArchiveURL = pluginDirectoryURL.appending(path: archiveFileName)

        let needsStagingCleanup = (archiveURL != installedArchiveURL)
        defer {
            if needsStagingCleanup {
                try? fileManager.removeItem(at: archiveURL)
            }
        }

        if let previous,
            previous.sourceType != .localFolder,
            previous.resourceBasePath != archiveFileName
        {
            removePluginResourceIfNeeded(previous)
        }

        if archiveURL != installedArchiveURL {
            if fileManager.fileExists(atPath: installedArchiveURL.path) {
                try fileManager.removeItem(at: installedArchiveURL)
            }
            try fileManager.moveItem(at: archiveURL, to: installedArchiveURL)
        }

        let plugin = PluginDefinition(
            id: previous?.id ?? UUID(),
            name: manifest.displayName,
            isEnabled: previous?.isEnabled ?? true,
            sourceType: sourceType,
            resourceBasePath: archiveFileName,
            resourceBookmark: nil,
            resourceHash: try Self.resourceHash(forArchiveURL: installedArchiveURL),
            isBlocked: false,
            manifestUpdateURL: manifest.manifestUpdateURL,
            manifestVersion: manifest.version,
            manifestAuthor: manifest.author,
            manifestLink: manifest.homepageURL,
            manifestSupportedAreas: manifest.displayAreas,
            manifestID: manifest.manifestID,
            packageAuthentication: packageAuthentication
        )

        resolvedManifestCache[plugin.id] = manifest
        return plugin
    }

    private func resolveUpdateEntry(fromUpdateManifestURL url: URL, plugin: PluginDefinition)
        async throws
        -> GeckoUpdateManifestEntry
    {
        guard !plugin.manifestID.isEmpty else {
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

        guard let addon = updateManifest.addons[plugin.manifestID] else {
            throw PluginManifestValidationError(messages: [
                "アップデートマニフェストにID \"\(plugin.manifestID)\" の定義がありません"
            ])
        }

        let compatibleEntries = addon.updates.filter(isCompatibleUpdateEntry)
        guard !compatibleEntries.isEmpty else {
            throw PluginManifestValidationError(messages: [
                "このバージョンのKiririnに対応した更新候補がありません"
            ])
        }

        let entry =
            compatibleEntries
            .sorted {
                ($0.version ?? "").compare($1.version ?? "", options: .numeric)
                    == .orderedDescending
            }
            .first(where: supportsUpdateDownload)

        guard let entry else {
            throw PluginManifestValidationError(messages: [
                "アップデートマニフェストに利用できるダウンロードURLがありません"
            ])
        }

        try validateUpdateVersion(
            currentVersion: plugin.manifestVersion,
            candidateVersion: entry.version
        )

        return entry
    }

    private func isCompatibleUpdateEntry(_ entry: GeckoUpdateManifestEntry) -> Bool {
        guard let applications = entry.applications else {
            return true
        }
        guard let kiririn = applications.kiririn else {
            return false
        }

        let currentVersion = Self.currentAppVersion
        if let minVersion = Self.trimmedNonEmpty(kiririn.strictMinVersion),
            currentVersion.compare(minVersion, options: .numeric) == .orderedAscending
        {
            return false
        }
        if let maxVersion = Self.trimmedNonEmpty(kiririn.strictMaxVersion),
            maxVersion != "*",
            currentVersion.compare(maxVersion, options: .numeric) == .orderedDescending
        {
            return false
        }

        return true
    }

    private func supportsUpdateDownload(_ entry: GeckoUpdateManifestEntry) -> Bool {
        guard
            let url = URL(string: entry.updateLink),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme)
        else {
            return false
        }

        return scheme == "https" || Self.trimmedNonEmpty(entry.updateHash) != nil
    }

    func downloadPackage(
        from url: URL,
        progressHandler: @escaping (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> URL {
        let delegate = PackageDownloadDelegate(progressHandler: progressHandler)
        let session = URLSession(
            configuration: .default, delegate: delegate, delegateQueue: .main)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let task = session.downloadTask(with: request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
            session.invalidateAndCancel()
        }
    }

    private func fetchDataIgnoringCache(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let (data, _) = try await URLSession.kiririnShared.data(for: request)
        return data
    }

    private func validateUpdateVersion(currentVersion: String?, candidateVersion: String?) throws {
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

    private func validateResolvedUpdateVersion(entryVersion: String?, packageVersion: String?)
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

    private func validateManifestRuntimeCompatibility(_ manifest: ExtensionPluginManifest) throws
        -> [String]
    {
        var violations: [String] = []
        let currentVersion = Self.currentAppVersion

        if let minVersion = Self.trimmedNonEmpty(manifest.strictMinVersion),
            currentVersion.compare(minVersion, options: .numeric) == .orderedAscending
        {
            violations.append(
                "インストールに必要な最小バージョン（\(minVersion)）を満たしていません（現在: \(currentVersion)）"
            )
        }

        if let maxVersion = Self.trimmedNonEmpty(manifest.strictMaxVersion),
            maxVersion != "*",
            currentVersion.compare(maxVersion, options: .numeric) == .orderedDescending
        {
            violations.append(
                "インストール可能な最大バージョン（\(maxVersion)）を超えています（現在: \(currentVersion)）"
            )
        }

        guard !violations.isEmpty else {
            return []
        }

        if isDeveloperModeEnabled {
            return violations
        }

        throw PluginManifestValidationError(
            messages: [
                "このプラグインは現在のアプリバージョンと互換性がありません。強制的に有効にするには開発者モードを有効にしてください"
            ] + violations)
    }

    private func parseUpdateHash(_ rawValue: String?) throws -> GeckoUpdateHash? {
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

    private func upsertPlugin(_ plugin: PluginDefinition) {
        if let index = plugins.firstIndex(where: { $0.id == plugin.id }) {
            plugins[index] = plugin
        } else {
            plugins.append(plugin)
        }
    }

    private static func archiveFileName(for manifestID: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-@")
        )
        let sanitized = manifestID.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? String(scalar) : "_"
        }.joined()
        return "\(sanitized).kppx"
    }

    private func previewStoredPlugin(for plugin: PluginDefinition) throws -> PluginInstallPreview {
        let preview: PluginInstallPreview
        switch plugin.sourceType {
        case .localFolder:
            let localFolderURL = try resourceBaseURL(for: plugin)
            preview = try previewPlugin(
                localFolderURL: localFolderURL,
                bookmarkData: plugin.resourceBookmark
            )
        case .kppx:
            let resourceURL = try archiveURL(for: plugin)
            preview = try previewPlugin(packageURL: resourceURL, sourceType: plugin.sourceType)
        }
        guard preview.manifest.manifestID == plugin.manifestID else {
            throw PluginManifestValidationError(messages: [
                "プラグインIDが一致しません。再登録してください（既存: \(plugin.manifestID) / 追加中: \(preview.manifest.manifestID)）"
            ])
        }
        return preview
    }

    private func validatePackageSignatureRequirement(
        _ authentication: PluginPackageAuthentication,
        sourceType: PluginSourceType
    ) throws {
        guard sourceType != .localFolder else { return }
        guard Self.packageSignatureRequirement == .required, !authentication.isSigned else {
            return
        }
        throw PluginManifestValidationError(messages: [
            "このビルドでは署名付きkppxパッケージのみ追加できます"
        ])
    }

    private func validateDeveloperModeRequirement(
        _ authentication: PluginPackageAuthentication,
        sourceType: PluginSourceType,
        actionLabel: String
    ) throws {
        guard
            isDeveloperModeEnabled || isStandardModeAllowed(authentication, sourceType: sourceType)
        else {
            throw PluginManifestValidationError(messages: [
                developerModeRestrictionMessage(
                    for: authentication,
                    sourceType: sourceType,
                    actionLabel: actionLabel
                )
            ])
        }
    }

    func signerMatchesForUpdate(previous: PluginDefinition, preview: PluginInstallPreview) -> Bool {
        guard previous.packageAuthentication.isSigned,
            preview.packageAuthentication.isSigned
        else {
            return false
        }
        return matchingSignerKeyHashes(
            lhs: previous.packageAuthentication.signerKeyHashes,
            rhs: preview.packageAuthentication.signerKeyHashes
        )
    }

    private func matchingSignerKeyHashes(lhs: [String], rhs: [String]) -> Bool {
        lhs.sorted() == rhs.sorted()
    }

    private func isStandardModeAllowed(
        _ authentication: PluginPackageAuthentication,
        sourceType: PluginSourceType
    ) -> Bool {
        guard sourceType != .localFolder else {
            return false
        }
        return authentication.state == .verified
    }

    private func developerModeRestrictionMessage(
        for authentication: PluginPackageAuthentication,
        sourceType: PluginSourceType,
        actionLabel: String
    ) -> String {
        if sourceType == .localFolder {
            return "ローカルフォルダのプラグインを\(actionLabel)できません。\(actionLabel)するには開発者モードを有効にしてください"
        }

        switch authentication.state {
        case .unsigned:
            return "未署名のkppxを\(actionLabel)できません。\(actionLabel)するには開発者モードを有効にしてください"
        case .selfSigned:
            return "自己署名のkppxを\(actionLabel)できません。\(actionLabel)するには開発者モードを有効にしてください"
        case .revoked:
            return "失効済み署名のkppxを\(actionLabel)できません。\(actionLabel)するには開発者モードを有効にしてください"
        case .verified:
            return "不明なエラー。認証済み署名のkppxを\(actionLabel)できません"
        }
    }

    private func enforceDeveloperModeRestrictionsIfNeeded() {
        guard !isDeveloperModeEnabled else { return }

        var updatedPlugins = plugins
        var changed = false
        for index in updatedPlugins.indices {
            guard updatedPlugins[index].isEnabled else { continue }
            guard
                !isStandardModeAllowed(
                    updatedPlugins[index].packageAuthentication,
                    sourceType: updatedPlugins[index].sourceType
                )
            else {
                continue
            }
            updatedPlugins[index].isEnabled = false
            changed = true
        }

        if changed {
            plugins = updatedPlugins
        }
    }

    private func archiveURL(for plugin: PluginDefinition) throws -> URL {
        try resourceBaseURL(for: plugin)
    }

    private static func resourceHash(forArchiveURL archiveURL: URL) throws -> String {
        do {
            let data = try Data(contentsOf: archiveURL)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } catch {
            throw PluginManifestValidationError(messages: [
                "プラグインパッケージの読み込みに失敗しました: \(error.localizedDescription)"
            ])
        }
    }

    private static func parseExtensionManifest(
        atResourceURL resourceURL: URL,
        fileManager: FileManager
    ) throws -> ExtensionPluginManifest {
        var isDirectory: ObjCBool = false
        let resourcePath = resourceURL.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: resourcePath, isDirectory: &isDirectory) else {
            logger.info("プラグインリソースが見つかりません：\(resourcePath)")
            throw PluginManifestValidationError(messages: ["プラグインリソースが見つかりません"])
        }

        if isDirectory.boolValue {
            return try parseExtensionManifest(inDirectory: resourceURL, fileManager: fileManager)
        }

        do {
            let package = try PluginDecoder.decode(url: resourceURL)
            return try parseExtensionManifest(
                inArchive: package
            )
        } catch let error as PluginManifestValidationError {
            throw error
        } catch {
            throw PluginManifestValidationError(messages: [
                "プラグインパッケージの読み込みに失敗しました: \(error.localizedDescription)"
            ])
        }
    }

    private static func parseExtensionManifest(inArchive archive: PluginPackage) throws
        -> ExtensionPluginManifest
    {
        guard
            let manifestData = try archive.fileData(named: extensionManifestFileName)
        else {
            throw PluginManifestValidationError(messages: ["manifest.jsonが見つかりません"])
        }

        return try parseExtensionManifest(
            manifestData: manifestData,
            resourceExists: { path in
                (try? archive.containsFile(named: path)) == true
            }
        )
    }

    private static func parseExtensionManifest(
        inDirectory directoryURL: URL,
        fileManager: FileManager
    ) throws -> ExtensionPluginManifest {
        let manifestURL = directoryURL.appending(path: extensionManifestFileName)
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

        return try parseExtensionManifest(
            manifestData: data,
            resourceExists: { path in
                fileManager.fileExists(
                    atPath: directoryURL.appending(path: path).path(percentEncoded: false)
                )
            }
        )
    }

    private static func parseExtensionManifest(
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
        for prohibitedKey in prohibitedExtensionManifestKeys where root[prohibitedKey] != nil {
            errors.append("\(prohibitedKey)はサポートしていません")
        }

        let displayName = trimmedNonEmpty(root["name"] as? String)
        if displayName == nil {
            errors.append("nameが指定されていません")
        }

        let version = trimmedNonEmpty(root["version"] as? String)
        if version == nil {
            errors.append("versionが指定されていません")
        }

        let browserSpecificSettings = root["browser_specific_settings"] as? [String: Any]
        let kiririn = browserSpecificSettings?["kiririn"] as? [String: Any]
        let manifestID = trimmedNonEmpty(kiririn?["id"] as? String)
        if manifestID == nil {
            errors.append("プラグインマニフェストにIDが指定されていません")
        }

        let optionsUI = root["options_ui"] as? [String: Any]
        let background = root["background"] as? [String: Any]
        let kiririnViews = kiririn?["views"] as? [String: Any]
        let overlay = kiririnViews?["overlay"] as? [String: Any]
        let panel = kiririnViews?["panel"] as? [String: Any]

        let optionsPage = validatedRelativeResourcePath(
            optionsUI?["page"] as? String,
            label: "options_ui.page",
            resourceExists: resourceExists,
            errors: &errors
        )
        let overlayPage = validatedRelativeResourcePath(
            overlay?["page"] as? String,
            label: "browser_specific_settings.kiririn.views.overlay.page",
            resourceExists: resourceExists,
            errors: &errors
        )
        let panelPage = validatedRelativeResourcePath(
            panel?["page"] as? String,
            label: "browser_specific_settings.kiririn.views.panel.page",
            resourceExists: resourceExists,
            errors: &errors
        )
        if let scripts = background?["scripts"] as? [String] {
            for (index, script) in scripts.enumerated() {
                _ = validatedRelativeResourcePath(
                    script,
                    label: "background.scripts[\(index)]",
                    resourceExists: resourceExists,
                    errors: &errors
                )
            }
        }

        _ = validatedRelativeResourcePath(
            background?["service_worker"] as? String,
            label: "background.service_worker",
            resourceExists: resourceExists,
            errors: &errors
        )

        // WKWebExtensionがサポートするbackgroundキー
        let supportedBackgroundKeys: Set<String> = [
            "page", "scripts", "service_worker", "persistent", "preferred_environment",
        ]
        if let background {
            let unsupportedKeys = background.keys
                .filter { !supportedBackgroundKeys.contains($0) }
                .sorted()
            if !unsupportedKeys.isEmpty {
                errors.append(
                    "サポートしていないバックグラウンド設定があります: \(unsupportedKeys.joined(separator: ", "))"
                )
            }
        }

        let manifestUpdateURL = trimmedNonEmpty(kiririn?["update_url"] as? String)
        let strictMinVersion = trimmedNonEmpty(kiririn?["strict_min_version"] as? String)
        let strictMaxVersion = trimmedNonEmpty(kiririn?["strict_max_version"] as? String)

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
        let invalidPermissions = permissions.filter { !allowedExtensionPermissions.contains($0) }
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
            author: trimmedNonEmpty(root["author"] as? String),
            homepageURL: trimmedNonEmpty(root["homepage_url"] as? String),
            summary: trimmedNonEmpty(root["description"] as? String),
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

    private static func validatedRelativeResourcePath(
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

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

}

private final class PackageDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Int64, Int64) -> Void
    var continuation: CheckedContinuation<URL, Error>?
    private var savedError: Error?
    private var downloadedFileURL: URL?

    init(progressHandler: @escaping (Int64, Int64) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progressHandler(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("plugin_download_\(UUID().uuidString).kppx")
            try FileManager.default.moveItem(at: location, to: tempURL)
            downloadedFileURL = tempURL
        } catch {
            savedError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let c = continuation else { return }
        continuation = nil
        if let error = error ?? savedError {
            downloadedFileURL.map { try? FileManager.default.removeItem(at: $0) }
            c.resume(throwing: error)
        } else if let url = downloadedFileURL {
            c.resume(returning: url)
        } else {
            downloadedFileURL.map { try? FileManager.default.removeItem(at: $0) }
            c.resume(
                throwing: PluginManifestValidationError(
                    messages: ["ダウンロードに失敗しました"]
                )
            )
        }
    }
}
