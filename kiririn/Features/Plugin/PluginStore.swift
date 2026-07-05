import ApkSignatureVerifierKit
import Darwin
import Foundation
import KppxKit
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

struct PluginInstallPreview: Identifiable {
    fileprivate enum Payload {
        case package(archiveURL: URL)
        case localFolder(url: URL, bookmarkData: Data?)
    }

    let id = UUID()
    let sourceType: PluginSourceType
    let manifest: ExtensionPluginManifest
    let packageAuthentication: APKAuthentication
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
            packageAuthentication: APKAuthentication,
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
    var packageAuthentication: APKAuthentication

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
        packageAuthentication: APKAuthentication = .unsigned
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
                APKAuthentication.self,
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

@Observable
class PluginStore {
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let pluginsKey = "kiririn.plugin.definitions"
    private let developerModeKey = "kiririn.plugin.developer_mode_enabled"
    private let pluginDirectoryName = "Plugins"
    private static let webKitExtractedArchivePrefix = "WebKitExtractedArchive-"
    private static let currentAppVersion =
        PluginManifestParser.trimmedNonEmpty(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        ?? "0"
    private static let localManifestReloadEvents: DispatchSource.FileSystemEvent = [
        .write,
        .delete,
        .rename,
        .extend,
    ]
    private static let packageSignatureRequirement: APKSignatureRequirement = {
        #if os(iOS) && !DEBUG
            return .required
        #else
            return .optional
        #endif
    }()
    private let packageSignatureVerifier: ApkSignatureVerifierKit
    private let manifestParser = PluginManifestParser()
    private let updateResolver: PluginUpdateResolver

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
        packageSignatureVerifier: ApkSignatureVerifierKit =
            ApkSignatureVerifierKit(
                trustedChainPEMData: TrustedCertificateChain.data,
                ignoreExpiry: true
            )
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.packageSignatureVerifier = packageSignatureVerifier
        self.updateResolver = PluginUpdateResolver(
            currentAppVersion: Self.currentAppVersion,
            session: .kiririnShared
        )
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
                "IDが一致しません。別のプラグインのため更新を中止しました"
            ])
        }

        let signerMismatch = !signerMatchesForUpdate(previous: previous, preview: preview)
        if signerMismatch, !isDeveloperModeEnabled {
            throw PluginManifestValidationError(messages: [
                "開発者モードが無効なため、署名元が一致しないプラグインへの更新は利用できません"
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

    func previewStoredPlugin(for plugin: PluginDefinition) throws -> PluginInstallPreview {
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
            updated.resourceHash = try PluginManifestParser.resourceHash(forArchiveURL: archiveURL)
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
        return resourceURL.appending(path: PluginManifestParser.extensionManifestFileName)
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
        let manifest = try manifestParser.parse(
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

        for fileURL in files
        where fileURL.lastPathComponent.hasPrefix(Self.webKitExtractedArchivePrefix) {
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
            let manifest = try manifestParser.parse(inArchive: package)
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
        let manifest = try manifestParser.parse(
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

    func downloadPackage(
        from url: URL,
        progressHandler: @escaping (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> URL {
        try await PackageDownloader.download(from: url, progressHandler: progressHandler)
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

        let entry = try await updateResolver.resolveUpdateEntry(
            fromUpdateManifestURL: url,
            manifestID: previous.manifestID,
            currentVersion: previous.manifestVersion
        )
        guard let packageURL = URL(string: entry.updateLink) else {
            throw PluginManifestValidationError(messages: [
                "アップデートのダウンロードURLが有効ではありません"
            ])
        }
        let updateHash = try updateResolver.parseUpdateHash(entry.updateHash)
        let tempURL = try await PackageDownloader.download(from: packageURL)
        defer {
            try? fileManager.removeItem(at: tempURL)
        }
        if let updateHash {
            let fileData = try Data(contentsOf: tempURL)
            guard updateHash.matches(data: fileData) else {
                throw PluginManifestValidationError(messages: [
                    "アップデート検証用ハッシュがダウンロードしたプラグインと一致しません"
                ])
            }
        }

        let basePreview = try previewPlugin(packageURL: tempURL, sourceType: .kppx)
        let preview = PluginInstallPreview(
            sourceType: basePreview.sourceType,
            manifest: basePreview.manifest,
            packageAuthentication: basePreview.packageAuthentication,
            updateInfoURL: PluginManifestParser.trimmedNonEmpty(entry.updateInfoURL)
                .flatMap(URL.init(string:)),
            installWarnings: basePreview.installWarnings,
            payload: basePreview.payload
        )
        try updateResolver.validateResolvedUpdateVersion(
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

        try updateResolver.validateUpdateVersion(
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
        let manifest = try manifestParser.parse(
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

        return try extractedResourceBaseURL(forArchiveURL: archiveURL(for: plugin))
    }

    private func extractedResourceBaseURL(forArchiveURL archiveURL: URL) throws -> URL {
        let resourceHash = try PluginManifestParser.resourceHash(forArchiveURL: archiveURL)
        let extractedURL = extractedArchiveURL(resourceHash: resourceHash)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: extractedURL.path(percentEncoded: false),
            isDirectory: &isDirectory
        ) {
            if isDirectory.boolValue {
                return extractedURL
            }
            try fileManager.removeItem(at: extractedURL)
        }

        let package = try PluginDecoder.decode(url: archiveURL)
        let stagingURL = fileManager.temporaryDirectory.appending(
            path: "\(Self.webKitExtractedArchivePrefix)staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try? fileManager.removeItem(at: stagingURL)
        defer {
            try? fileManager.removeItem(at: stagingURL)
        }

        try package.extract(to: stagingURL, fileManager: fileManager)
        if fileManager.fileExists(atPath: extractedURL.path(percentEncoded: false)) {
            return extractedURL
        }
        do {
            try fileManager.moveItem(at: stagingURL, to: extractedURL)
        } catch {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(
                atPath: extractedURL.path(percentEncoded: false),
                isDirectory: &isDirectory
            ),
                isDirectory.boolValue
            {
                return extractedURL
            }
            throw error
        }
        return extractedURL
    }

    private func extractedArchiveURL(resourceHash: String) -> URL {
        let hashPrefix = String(resourceHash.prefix(16))
        return fileManager.temporaryDirectory.appending(
            path: "\(Self.webKitExtractedArchivePrefix)\(hashPrefix)",
            directoryHint: .isDirectory
        )
    }

    private func refreshExtensionBundlePlugin(_ plugin: PluginDefinition) throws -> PluginDefinition
    {
        let resourceURL = try resourceBaseURL(for: plugin)
        let manifest = try manifestParser.parse(
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

        let currentHash = try PluginManifestParser.resourceHash(
            forArchiveURL: archiveURL(for: plugin))
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
        packageAuthentication: APKAuthentication,
        replacing previous: PluginDefinition? = nil
    ) throws -> PluginDefinition {
        try ensureUniqueManifestID(manifest.manifestID, excluding: previous)

        try ensurePluginDirectoryExists()
        let archiveFileName = PluginManifestParser.archiveFileName(for: manifest.manifestID)
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
            resourceHash: try PluginManifestParser.resourceHash(forArchiveURL: installedArchiveURL),
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

    private func validatePackageSignatureRequirement(
        _ authentication: APKAuthentication,
        sourceType: PluginSourceType
    ) throws {
        guard sourceType != .localFolder else { return }
        guard Self.packageSignatureRequirement == .required, !authentication.isSigned else {
            return
        }
        throw PluginManifestValidationError(messages: [
            "プラグインに有効な署名がありません"
        ])
    }

    private func validateDeveloperModeRequirement(
        _ authentication: APKAuthentication,
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
        _ authentication: APKAuthentication,
        sourceType: PluginSourceType
    ) -> Bool {
        guard sourceType != .localFolder else {
            return false
        }
        return authentication.state == .verified
    }

    private func developerModeRestrictionMessage(
        for authentication: APKAuthentication,
        sourceType: PluginSourceType,
        actionLabel: String
    ) -> String {
        if sourceType == .localFolder {
            return "ローカルフォルダのプラグインを\(actionLabel)できません。\(actionLabel)するには開発者モードを有効にしてください"
        }

        switch authentication.state {
        case .unsigned:
            return "未署名のプラグインを\(actionLabel)できません。\(actionLabel)するには開発者モードを有効にしてください"
        case .selfSigned:
            return "自己署名のプラグインを\(actionLabel)できません。\(actionLabel)するには開発者モードを有効にしてください"
        case .revoked:
            return "失効済み署名のプラグインを\(actionLabel)できません。\(actionLabel)するには開発者モードを有効にしてください"
        case .verified:
            return "不明なエラー。認証済み署名のプラグインを\(actionLabel)できません"
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
        if plugin.sourceType == .localFolder {
            return try resourceBaseURL(for: plugin)
        }
        return pluginDirectoryURL.appending(path: plugin.resourceBasePath)
    }

    private func validateManifestRuntimeCompatibility(_ manifest: ExtensionPluginManifest) throws
        -> [String]
    {
        var violations: [String] = []
        let currentVersion = Self.currentAppVersion

        if let minVersion = PluginManifestParser.trimmedNonEmpty(manifest.strictMinVersion),
            currentVersion.compare(minVersion, options: .numeric) == .orderedAscending
        {
            violations.append(
                "インストールに必要な最小バージョン（\(minVersion)）を満たしていません（現在: \(currentVersion)）"
            )
        }

        if let maxVersion = PluginManifestParser.trimmedNonEmpty(manifest.strictMaxVersion),
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

    private func upsertPlugin(_ plugin: PluginDefinition) {
        if let index = plugins.firstIndex(where: { $0.id == plugin.id }) {
            plugins[index] = plugin
        } else {
            plugins.append(plugin)
        }
    }
}
