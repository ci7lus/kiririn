import CryptoKit
import Darwin
import Foundation
import Logging

private let logger = Logger(label: "PluginStore")
enum PluginSourceType: String, Codable, Sendable {
    case remoteUrl
    case localFile
    case localFolder

    var localizedLabel: String {
        switch self {
        case .localFile:
            return "kkpx"
        case .remoteUrl:
            return "配布 URL"
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
        case package(archiveData: Data)
        case localFolder(url: URL, bookmarkData: Data?)
    }

    let id = UUID()
    let sourceType: PluginSourceType
    let manifest: ExtensionPluginManifest

    fileprivate let payload: Payload
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

    init(
        id: UUID,
        name: String,
        isEnabled: Bool = true,
        sourceType: PluginSourceType = .localFile,
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
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        sourceType =
            try container.decodeIfPresent(PluginSourceType.self, forKey: .sourceType) ?? .localFile
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
    }

    func supports(area: PluginDisplayArea) -> Bool {
        guard let supported = manifestSupportedAreas else { return true }
        return supported.contains(area)
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

    private enum CodingKeys: String, CodingKey {
        case version
        case updateLink = "update_link"
    }
}

@Observable
class PluginStore {
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let pluginsKey = "kiririn.plugin.definitions"
    private let pluginDirectoryName = "Plugins"
    private static let extensionManifestFileName = "manifest.json"
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
    private static let prohibitedExtensionManifestKeys: Set<String> = [
        "content_scripts",
        "commands",
        "action",
        "browser_action",
        "page_action",
    ]

    var fileReadErrorMessage: String?
    var droppedPluginAlertMessage: String?
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

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
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
        refreshPluginsFromFiles()
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

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        if enabled, plugins[index].isBlocked {
            return
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
                "内容確認が必要なプラグインをブロックしました: \(pluginList)。内容を確認し、問題なければ再有効化してください。")
        }
        fileReadErrorMessage = nil
    }

    func clearFileReadErrorMessage() {
        fileReadErrorMessage = nil
    }

    func clearDroppedPluginAlertMessage() {
        droppedPluginAlertMessage = nil
    }

    private func markPluginBlocked(_ plugin: PluginDefinition) -> PluginDefinition {
        var updated = plugin
        updated.isBlocked = true
        updated.isEnabled = false
        return updated
    }

    private func blockedPluginAlertMessage(for pluginName: String) -> String {
        "プラグイン「\(pluginName)」は内容確認が必要なためブロックしました。内容を確認し、問題なければ再有効化してください。"
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

        let plugin = plugins[index]
        guard preview.manifest.manifestID == plugin.manifestID else {
            throw PluginManifestValidationError(messages: [
                "browser_specific_settings.kiririn.id が一致しません。再登録してください（既存: \(plugin.manifestID) / マニフェスト: \(preview.manifest.manifestID)）"
            ])
        }

        var updated = plugin

        switch preview.payload {
        case .package(let archiveData):
            guard plugin.sourceType != .localFolder else {
                throw PluginManifestValidationError(messages: [
                    "保存済みのローカルフォルダを読み込めませんでした"
                ])
            }
            updated.resourceHash = Self.resourceHash(forArchiveData: archiveData)
        case .localFolder(let url, let bookmarkData):
            guard plugin.sourceType == .localFolder else {
                throw PluginManifestValidationError(messages: [
                    "保存済みの package を読み込めませんでした"
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
                "browser_specific_settings.kiririn.id が一致しません。再登録してください（既存: \(plugin.manifestID) / マニフェスト: \(manifest.manifestID)）"
            ])
        }

        resolvedManifestCache[plugin.id] = manifest
        return manifest
    }

    private func ensurePluginDirectoryExists() throws {
        try fileManager.createDirectory(at: pluginDirectoryURL, withIntermediateDirectories: true)
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
        packageData: Data,
        sourceType: PluginSourceType
    ) throws -> PluginInstallPreview {
        let package = try PluginDecoder.decode(data: packageData)
        let manifest = try Self.parseExtensionManifest(
            inArchive: package
        )

        return PluginInstallPreview(
            sourceType: sourceType,
            manifest: manifest,
            payload: .package(archiveData: package.archiveData)
        )
    }

    func previewPlugin(localFolderURL: URL, bookmarkData: Data?) throws -> PluginInstallPreview {
        let manifest = try Self.parseExtensionManifest(
            atResourceURL: localFolderURL,
            fileManager: fileManager
        )

        return PluginInstallPreview(
            sourceType: .localFolder,
            manifest: manifest,
            payload: .localFolder(url: localFolderURL, bookmarkData: bookmarkData)
        )
    }

    func previewPlugin(fromRemoteURL url: URL) async throws -> PluginInstallPreview {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw PluginManifestValidationError(messages: ["URL は http(s) である必要があります"])
        }

        let (data, _) = try await URLSession.kiririnShared.data(from: url)
        return try previewPlugin(packageData: data, sourceType: .remoteUrl)
    }

    @discardableResult
    func installPlugin(from preview: PluginInstallPreview) throws -> PluginDefinition {
        switch preview.payload {
        case .package(let archiveData):
            let plugin = try installPluginPackage(
                archiveData: archiveData,
                manifest: preview.manifest,
                sourceType: preview.sourceType
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
                manifestID: preview.manifest.manifestID
            )
            resolvedManifestCache[plugin.id] = preview.manifest
            upsertPlugin(plugin)
            return plugin
        }
    }

    func addPlugin(
        packageData: Data,
        sourceType: PluginSourceType
    ) throws {
        let preview = try previewPlugin(packageData: packageData, sourceType: sourceType)
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
        withPackageData packageData: Data,
        sourceType: PluginSourceType
    ) throws {
        let package = try PluginDecoder.decode(data: packageData)
        let manifest = try Self.parseExtensionManifest(
            inArchive: package
        )
        guard manifest.manifestID == previous.manifestID else {
            throw PluginManifestValidationError(messages: [
                "browser_specific_settings.kiririn.id が一致しません。別のプラグイン package のため更新を中止しました"
            ])
        }
        let plugin = try installPluginPackage(
            archiveData: package.archiveData,
            manifest: manifest,
            sourceType: sourceType,
            replacing: previous
        )
        upsertPlugin(plugin)
    }

    func overwritePlugin(fromUpdateManifestURL url: URL, previous: PluginDefinition) async throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw PluginManifestValidationError(messages: ["URL は http(s) である必要があります"])
        }

        let packageURL = try await resolvePackageURL(fromUpdateManifestURL: url, plugin: previous)
        let (data, _) = try await URLSession.kiririnShared.data(from: packageURL)

        try overwritePlugin(
            previous,
            withPackageData: data,
            sourceType: .remoteUrl
        )
    }

    func overwritePlugin(
        _ previous: PluginDefinition,
        withLocalFolderURL localFolderURL: URL,
        bookmarkData: Data?
    ) throws {
        let manifest = try Self.parseExtensionManifest(
            atResourceURL: localFolderURL,
            fileManager: fileManager
        )

        guard manifest.manifestID == previous.manifestID else {
            throw PluginManifestValidationError(messages: [
                "browser_specific_settings.kiririn.id が一致しません。別のローカルフォルダのため更新を中止しました"
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
                "browser_specific_settings.kiririn.id が一致しません。再登録してください（既存: \(plugin.manifestID) / マニフェスト: \(manifest.manifestID)）"
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
        archiveData: Data,
        manifest: ExtensionPluginManifest,
        sourceType: PluginSourceType,
        replacing previous: PluginDefinition? = nil
    ) throws -> PluginDefinition {
        try ensureUniqueManifestID(manifest.manifestID, excluding: previous)

        try ensurePluginDirectoryExists()
        let archiveFileName = Self.archiveFileName(for: manifest.manifestID)
        let installedArchiveURL = pluginDirectoryURL.appending(path: archiveFileName)

        if let previous,
            previous.sourceType != .localFolder,
            previous.resourceBasePath != archiveFileName
        {
            removePluginResourceIfNeeded(previous)
        }
        try archiveData.write(to: installedArchiveURL, options: .atomic)

        let plugin = PluginDefinition(
            id: previous?.id ?? UUID(),
            name: manifest.displayName,
            isEnabled: previous?.isEnabled ?? true,
            sourceType: sourceType,
            resourceBasePath: archiveFileName,
            resourceBookmark: nil,
            resourceHash: Self.resourceHash(forArchiveData: archiveData),
            isBlocked: false,
            manifestUpdateURL: manifest.manifestUpdateURL,
            manifestVersion: manifest.version,
            manifestAuthor: manifest.author,
            manifestLink: manifest.homepageURL,
            manifestSupportedAreas: manifest.displayAreas,
            manifestID: manifest.manifestID
        )

        resolvedManifestCache[plugin.id] = manifest
        return plugin
    }

    private func resolvePackageURL(fromUpdateManifestURL url: URL, plugin: PluginDefinition)
        async throws
        -> URL
    {
        guard !plugin.manifestID.isEmpty else {
            throw PluginManifestValidationError(messages: [
                "browser_specific_settings.kiririn.id が設定されていないため更新先を解決できません"
            ])
        }

        let (data, _) = try await URLSession.kiririnShared.data(from: url)

        let updateManifest: GeckoUpdateManifest
        do {
            updateManifest = try JSONDecoder().decode(GeckoUpdateManifest.self, from: data)
        } catch {
            throw PluginManifestValidationError(messages: [
                "update manifest の JSON を読み取れません: \(error.localizedDescription)"
            ])
        }

        guard let addon = updateManifest.addons[plugin.manifestID] else {
            throw PluginManifestValidationError(messages: [
                "update manifest に browser_specific_settings.kiririn.id \"\(plugin.manifestID)\" の定義がありません"
            ])
        }

        let entry = addon.updates
            .sorted {
                ($0.version ?? "").compare($1.version ?? "", options: .numeric)
                    == .orderedDescending
            }
            .first {
                URL(string: $0.updateLink).map {
                    ($0.scheme?.lowercased() ?? "") == "https"
                } == true
            }

        guard let entry, let packageURL = URL(string: entry.updateLink) else {
            throw PluginManifestValidationError(messages: [
                "update manifest に有効な https の update_link がありません"
            ])
        }

        return packageURL
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
        case .localFile, .remoteUrl:
            let archiveData = try archiveData(for: plugin)
            preview = try previewPlugin(packageData: archiveData, sourceType: plugin.sourceType)
        }
        guard preview.manifest.manifestID == plugin.manifestID else {
            throw PluginManifestValidationError(messages: [
                "browser_specific_settings.kiririn.id が一致しません。再登録してください（既存: \(plugin.manifestID) / マニフェスト: \(preview.manifest.manifestID)）"
            ])
        }
        return preview
    }

    private func archiveData(for plugin: PluginDefinition) throws -> Data {
        let resourceURL = try resourceBaseURL(for: plugin)
        do {
            return try Data(contentsOf: resourceURL)
        } catch {
            throw PluginManifestValidationError(messages: [
                "プラグイン package の読み込みに失敗しました: \(error.localizedDescription)"
            ])
        }
    }

    private static func resourceHash(forArchiveURL archiveURL: URL) throws -> String {
        do {
            return resourceHash(forArchiveData: try Data(contentsOf: archiveURL))
        } catch {
            throw PluginManifestValidationError(messages: [
                "プラグイン package の読み込みに失敗しました: \(error.localizedDescription)"
            ])
        }
    }

    private static func resourceHash(forArchiveData archiveData: Data) -> String {
        SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
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
            let package = try PluginDecoder.decode(data: try Data(contentsOf: resourceURL))
            return try parseExtensionManifest(
                inArchive: package
            )
        } catch let error as PluginManifestValidationError {
            throw error
        } catch {
            throw PluginManifestValidationError(messages: [
                "プラグイン package の読み込みに失敗しました: \(error.localizedDescription)"
            ])
        }
    }

    private static func parseExtensionManifest(inArchive archive: PluginPackage) throws
        -> ExtensionPluginManifest
    {
        guard
            let manifestData = try archive.fileData(named: extensionManifestFileName)
        else {
            throw PluginManifestValidationError(messages: ["manifest.json が見つかりません"])
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
            throw PluginManifestValidationError(messages: ["manifest.json が見つかりません"])
        }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw PluginManifestValidationError(messages: [
                "manifest.json の読み込みに失敗しました: \(error.localizedDescription)"
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
                throw PluginManifestValidationError(messages: ["manifest.json の形式が不正です"])
            }
            root = object
        } catch let error as PluginManifestValidationError {
            throw error
        } catch {
            throw PluginManifestValidationError(messages: [
                "manifest.json の JSON を読み取れません: \(error.localizedDescription)"
            ])
        }

        var errors: [String] = []
        for prohibitedKey in prohibitedExtensionManifestKeys where root[prohibitedKey] != nil {
            errors.append("\(prohibitedKey) はサポートしていません")
        }

        let displayName = trimmedNonEmpty(root["name"] as? String)
        if displayName == nil {
            errors.append("name が指定されていません")
        }

        let version = trimmedNonEmpty(root["version"] as? String)
        if version == nil {
            errors.append("version が指定されていません")
        }

        let browserSpecificSettings = root["browser_specific_settings"] as? [String: Any]
        let kiririn = browserSpecificSettings?["kiririn"] as? [String: Any]
        let manifestID = trimmedNonEmpty(kiririn?["id"] as? String)
        if manifestID == nil {
            errors.append("browser_specific_settings.kiririn.id が指定されていません")
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

        // WKWebExtension がサポートする background キー
        let supportedBackgroundKeys: Set<String> = [
            "page", "scripts", "service_worker", "persistent", "preferred_environment",
        ]
        if let background {
            let unsupportedKeys = background.keys
                .filter { !supportedBackgroundKeys.contains($0) }
                .sorted()
            if !unsupportedKeys.isEmpty {
                errors.append(
                    "サポートしていない background 設定があります: \(unsupportedKeys.joined(separator: ", "))"
                )
            }
        }

        let manifestUpdateURL = trimmedNonEmpty(kiririn?["update_url"] as? String)
        if let manifestUpdateURL,
            URL(string: manifestUpdateURL).map({
                ["http", "https"].contains($0.scheme?.lowercased() ?? "")
            }) != true
        {
            errors.append("browser_specific_settings.kiririn.update_url は http(s) URL である必要があります")
        }

        let permissions = (root["permissions"] as? [String]) ?? []
        let invalidPermissions = permissions.filter { !allowedExtensionPermissions.contains($0) }
        if !invalidPermissions.isEmpty {
            errors.append(
                "許可されていない permissions があります: \(invalidPermissions.joined(separator: ", "))")
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
                "browser_specific_settings.kiririn.views.overlay.page, browser_specific_settings.kiririn.views.panel.page, options_ui.page の少なくとも1つが必要です"
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
