import CryptoKit
import Foundation
import Logging

private let logger = Logger(label: "PluginStore")

private struct PluginManifestPayload: Decodable {
    let name: String?
    let identifier: String?
    let version: String?
    let author: String?
    let url: String?
    let displayAreas: [String]?
    let contextId: String?
    let allowedURLPatterns: [String]?
}

struct PluginManifest: Equatable {
    let name: String
    let identifier: String
    let version: String
    let author: String
    let url: String
    let displayAreas: [PluginDisplayArea]
    let contextId: String?
    let allowedURLPatterns: [String]?
}

struct PluginDefinition: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var htmlContent: String
    var htmlFilePath: String
    var isEnabled: Bool
    var manifestVersion: String?
    var manifestAuthor: String?
    var manifestLink: String?
    var manifestSupportedAreas: [PluginDisplayArea]?
    var manifestID: String
    var manifestContextId: String?
    var manifestAllowedURLPatterns: [String]?

    init(
        id: UUID,
        name: String,
        htmlContent: String,
        htmlFilePath: String = "",
        isEnabled: Bool = true,
        manifestVersion: String? = nil,
        manifestAuthor: String? = nil,
        manifestLink: String? = nil,
        manifestSupportedAreas: [PluginDisplayArea]? = nil,
        manifestID: String,
        manifestContextId: String? = nil,
        manifestAllowedURLPatterns: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.htmlContent = htmlContent
        self.htmlFilePath = htmlFilePath
        self.isEnabled = isEnabled
        self.manifestVersion = manifestVersion
        self.manifestAuthor = manifestAuthor
        self.manifestLink = manifestLink
        self.manifestSupportedAreas = manifestSupportedAreas
        self.manifestID = manifestID
        self.manifestContextId = manifestContextId
        self.manifestAllowedURLPatterns = manifestAllowedURLPatterns
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case htmlFilePath
        case isEnabled
        case manifestVersion
        case manifestAuthor
        case manifestLink
        case manifestSupportedAreas
        case manifestID
        case manifestContextId
        case manifestAllowedURLPatterns
        case htmlContent
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        htmlFilePath = try container.decodeIfPresent(String.self, forKey: .htmlFilePath) ?? ""
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        manifestVersion = try container.decodeIfPresent(String.self, forKey: .manifestVersion)
        manifestAuthor = try container.decodeIfPresent(String.self, forKey: .manifestAuthor)
        manifestLink = try container.decodeIfPresent(String.self, forKey: .manifestLink)
        manifestSupportedAreas = try container.decodeIfPresent(
            [PluginDisplayArea].self, forKey: .manifestSupportedAreas)
        manifestID = try container.decode(String.self, forKey: .manifestID)
        manifestContextId = try container.decodeIfPresent(String.self, forKey: .manifestContextId)
        manifestAllowedURLPatterns = try container.decodeIfPresent(
            [String].self, forKey: .manifestAllowedURLPatterns)
        htmlContent = try container.decodeIfPresent(String.self, forKey: .htmlContent) ?? ""
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(htmlFilePath, forKey: .htmlFilePath)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(manifestVersion, forKey: .manifestVersion)
        try container.encodeIfPresent(manifestAuthor, forKey: .manifestAuthor)
        try container.encodeIfPresent(manifestLink, forKey: .manifestLink)
        try container.encodeIfPresent(manifestSupportedAreas, forKey: .manifestSupportedAreas)
        try container.encode(manifestID, forKey: .manifestID)
        try container.encodeIfPresent(manifestContextId, forKey: .manifestContextId)
        try container.encodeIfPresent(
            manifestAllowedURLPatterns, forKey: .manifestAllowedURLPatterns)
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

@Observable
class PluginStore {
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let pluginsKey = "kiririn.plugin.definitions"
    private let pluginDirectoryName = "Plugins"
    private static let manifestScriptID = "kiririn-plugin-manifest"
    private static let manifestScriptType = "application/json"
    private static let identifierPattern = "^[A-Za-z0-9._-]{1,128}$"
    private static let pluginNamespaceID = UUID(uuidString: "f6ac7b64-1b6a-4f84-9f6a-2f52d5cf7304")!

    var fileReadErrorMessage: String?

    var plugins: [PluginDefinition] {
        didSet { persistPlugins() }
    }

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.plugins = []

        try? ensurePluginDirectoryExists()

        let initialPlugins: [PluginDefinition]
        if let data = defaults.data(forKey: pluginsKey),
            let decoded = try? JSONDecoder().decode([PluginDefinition].self, from: data)
        {
            initialPlugins = decoded
        } else {
            if defaults.data(forKey: pluginsKey) != nil {
                defaults.removeObject(forKey: pluginsKey)
            }
            initialPlugins = []
        }

        self.plugins = initialPlugins
        refreshPluginsFromFiles()
    }

    func addPlugin(htmlContent: String) throws {
        let manifest = try Self.parseManifest(from: htmlContent)
        let pluginID = Self.stablePluginID(for: manifest.identifier)
        try ensureUniquePluginID(pluginID, manifestIdentifier: manifest.identifier)
        let htmlFilePath = try saveHTMLContent(htmlContent, for: pluginID)
        let plugin = PluginDefinition(
            id: pluginID,
            name: manifest.name,
            htmlContent: htmlContent,
            htmlFilePath: htmlFilePath,
            manifestVersion: manifest.version,
            manifestAuthor: manifest.author,
            manifestLink: manifest.url,
            manifestSupportedAreas: manifest.displayAreas,
            manifestID: manifest.identifier,
            manifestContextId: manifest.contextId,
            manifestAllowedURLPatterns: manifest.allowedURLPatterns
        )
        plugins.append(plugin)
    }

    func updatePlugin(_ plugin: PluginDefinition) {
        guard let index = plugins.firstIndex(where: { $0.id == plugin.id }) else { return }
        var updated = plugin
        do {
            updated = try syncManifestAndPersistHTML(for: updated, previous: plugins[index])
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
        removePluginFileIfExists(path: removed.htmlFilePath)
    }

    func plugin(id: UUID) -> PluginDefinition? {
        plugins.first { $0.id == id }
    }

    func plugin(manifestID: String) -> PluginDefinition? {
        plugins.first { $0.manifestID == manifestID }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
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
            fileReadErrorMessage = nil
            return
        }

        var refreshedPlugins: [PluginDefinition] = []
        refreshedPlugins.reserveCapacity(plugins.count)

        for plugin in plugins {
            do {
                let refreshed = try reloadPluginFromFile(plugin)
                refreshedPlugins.append(refreshed)
            } catch {
                logger.debug("Failed to reload plugin \(plugin.id): \(error.localizedDescription)")
            }
        }

        if refreshedPlugins != plugins {
            plugins = refreshedPlugins
        }
        fileReadErrorMessage = nil
    }

    func clearFileReadErrorMessage() {
        fileReadErrorMessage = nil
    }

    private func persistPlugins() {
        guard let data = try? JSONEncoder().encode(plugins) else { return }
        defaults.set(data, forKey: pluginsKey)
    }

    private func syncManifestAndPersistHTML(
        for plugin: PluginDefinition, previous: PluginDefinition
    ) throws -> PluginDefinition {
        let html = plugin.htmlContent
        guard !html.isEmpty else {
            throw PluginManifestValidationError(messages: ["プラグインのHTMLが空です"])
        }

        let manifest = try Self.parseManifest(from: html)
        let fileManifestID = manifest.identifier
        if previous.manifestID != fileManifestID {
            throw PluginManifestValidationError(messages: [
                "プラグインIDが一致しません。読み取りを中止しました（既存: \"\(previous.manifestID)\" / マニフェスト: \"\(fileManifestID)\"）"
            ])
        }

        let expectedPluginID = Self.stablePluginID(for: fileManifestID)
        if previous.id != expectedPluginID {
            throw PluginManifestValidationError(messages: [
                "内部プラグインIDが一致しません。プラグインを再登録してください（既存: \"\(previous.id.uuidString)\" / 期待値: \"\(expectedPluginID.uuidString)\"）"
            ])
        }
        try ensureUniquePluginID(
            expectedPluginID, manifestIdentifier: fileManifestID, excluding: previous)

        var updated = plugin
        updated.id = expectedPluginID
        updated.manifestID = fileManifestID
        updated.manifestVersion = manifest.version
        updated.manifestAuthor = manifest.author
        updated.manifestLink = manifest.url
        updated.manifestSupportedAreas = manifest.displayAreas
        updated.manifestContextId = manifest.contextId
        updated.manifestAllowedURLPatterns = manifest.allowedURLPatterns
        updated.name = manifest.name
        updated.htmlFilePath = try saveHTMLContent(html, for: plugin.id)
        return updated
    }

    private func reloadPluginFromFile(_ plugin: PluginDefinition) throws -> PluginDefinition {
        let path = plugin.htmlFilePath
        guard !path.isEmpty else {
            throw PluginManifestValidationError(messages: ["\(plugin.name): 保存ファイルが見つかりません"])
        }

        let url = pluginDirectoryURL.appending(path: path)
        let html: String
        do {
            html = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PluginManifestValidationError(messages: [
                "\(plugin.name): ファイルの読み込みに失敗しました: \(error.localizedDescription)"
            ])
        }

        let manifest = try Self.parseManifest(from: html)
        let fileManifestID = manifest.identifier

        if plugin.manifestID != fileManifestID {
            throw PluginManifestValidationError(messages: [
                "\(plugin.name): プラグインIDが一致しないため読み取りを中止しました（既存: \"\(plugin.manifestID)\" / マニフェスト: \"\(fileManifestID)\"）"
            ])
        }

        let expectedPluginID = Self.stablePluginID(for: fileManifestID)
        if plugin.id != expectedPluginID {
            throw PluginManifestValidationError(messages: [
                "\(plugin.name): 内部プラグインIDが一致しないため読み取りを中止しました。プラグインを再登録してください"
            ])
        }
        try ensureUniquePluginID(
            expectedPluginID, manifestIdentifier: fileManifestID, excluding: plugin)

        var updated = plugin
        updated.id = expectedPluginID
        updated.htmlContent = html
        updated.htmlFilePath = path
        updated.name = manifest.name
        updated.manifestVersion = manifest.version
        updated.manifestAuthor = manifest.author
        updated.manifestLink = manifest.url
        updated.manifestSupportedAreas = manifest.displayAreas
        updated.manifestContextId = manifest.contextId
        updated.manifestAllowedURLPatterns = manifest.allowedURLPatterns
        return updated
    }

    var pluginDirectoryURL: URL {
        let base =
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appending(path: pluginDirectoryName, directoryHint: .isDirectory)
    }

    private func ensurePluginDirectoryExists() throws {
        try fileManager.createDirectory(at: pluginDirectoryURL, withIntermediateDirectories: true)
    }

    private func saveHTMLContent(_ html: String, for pluginID: UUID) throws -> String {
        try ensurePluginDirectoryExists()
        let fileName = "\(pluginID.uuidString).html"
        let fileURL = pluginDirectoryURL.appending(path: fileName)
        try html.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileName
    }

    private func removePluginFileIfExists(path: String) {
        guard !path.isEmpty else { return }
        let fileURL = pluginDirectoryURL.appending(path: path)
        try? fileManager.removeItem(at: fileURL)
    }

    private func ensureUniquePluginID(
        _ pluginID: UUID, manifestIdentifier: String,
        excluding existingPlugin: PluginDefinition? = nil
    ) throws {
        guard
            let collision = plugins.first(where: { candidate in
                guard candidate.id == pluginID else { return false }
                guard let existingPlugin else { return true }
                return candidate != existingPlugin
            })
        else {
            return
        }

        throw PluginManifestValidationError(messages: [
            "identifier \"\(manifestIdentifier)\" のプラグインはすでに登録されています: \"\(collision.name)\""
        ])
    }

    static func stablePluginID(for identifier: String) -> UUID {
        var namespaceBytes = pluginNamespaceID.uuid
        var hashInput = Data(withUnsafeBytes(of: &namespaceBytes) { Array($0) })
        hashInput.append(contentsOf: identifier.utf8)

        var digestBytes = Array(Insecure.SHA1.hash(data: hashInput).prefix(16))
        digestBytes[6] = (digestBytes[6] & 0x0F) | 0x50
        digestBytes[8] = (digestBytes[8] & 0x3F) | 0x80

        return UUID(
            uuid: (
                digestBytes[0], digestBytes[1], digestBytes[2], digestBytes[3],
                digestBytes[4], digestBytes[5], digestBytes[6], digestBytes[7],
                digestBytes[8], digestBytes[9], digestBytes[10], digestBytes[11],
                digestBytes[12], digestBytes[13], digestBytes[14], digestBytes[15]
            ))
    }

    private static func attributeValue(name: String, in attributes: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            "(?is)\\b\(escaped)\\s*=\\s*\"([^\"]*)\"",
            "(?is)\\b\(escaped)\\s*=\\s*'([^']*)'",
            "(?is)\\b\(escaped)\\s*=\\s*([^\\s>]+)",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(
                    in: attributes, range: NSRange(location: 0, length: attributes.utf16.count)),
                let range = Range(match.range(at: 1), in: attributes)
            else { continue }
            let value = String(attributes[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func manifestScriptBodies(in html: String) -> [String] {
        let pattern = "(?is)<script\\b([^>]*)>(.*?)</script>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let matches = regex.matches(in: html, range: NSRange(location: 0, length: html.utf16.count))
        return matches.compactMap { match in
            guard let attributesRange = Range(match.range(at: 1), in: html),
                let bodyRange = Range(match.range(at: 2), in: html)
            else {
                return nil
            }

            let attributes = String(html[attributesRange])
            let type = attributeValue(name: "type", in: attributes)?.lowercased()
            let id = attributeValue(name: "id", in: attributes)

            guard type == manifestScriptType, id == manifestScriptID else {
                return nil
            }

            return String(html[bodyRange])
        }
    }

    private static func manifestData(from html: String) throws -> Data {
        let bodies = manifestScriptBodies(in: html)
        if bodies.isEmpty {
            throw PluginManifestValidationError(messages: [
                "id=\"\(manifestScriptID)\" の application/json マニフェストが見つかりません"
            ])
        }

        if bodies.count > 1 {
            throw PluginManifestValidationError(messages: [
                "id=\"\(manifestScriptID)\" の application/json マニフェストは1つだけ定義してください"
            ])
        }

        let json = bodies[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !json.isEmpty else {
            throw PluginManifestValidationError(messages: ["プラグインマニフェストが空です"])
        }
        guard let data = json.data(using: .utf8) else {
            throw PluginManifestValidationError(messages: ["プラグインマニフェストを UTF-8 として読み取れません"])
        }
        return data
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    static func parseManifest(from html: String) throws -> PluginManifest {
        let data = try manifestData(from: html)
        let payload: PluginManifestPayload
        do {
            payload = try JSONDecoder().decode(PluginManifestPayload.self, from: data)
        } catch {
            throw PluginManifestValidationError(messages: [
                "プラグインマニフェストの JSON を読み取れません: \(error.localizedDescription)"
            ])
        }

        var errors: [String] = []

        let name = trimmedNonEmpty(payload.name)
        if name == nil {
            errors.append("name が指定されていません")
        }

        let identifier = trimmedNonEmpty(payload.identifier)
        if identifier == nil {
            errors.append("identifier が指定されていません。プラグインには一意なIDが必要です")
        } else if let identifier {
            let isValid =
                (try? NSRegularExpression(pattern: identifierPattern))
                .map {
                    $0.firstMatch(
                        in: identifier, range: NSRange(location: 0, length: identifier.utf16.count))
                        != nil
                }
                ?? false
            if !isValid {
                errors.append(
                    "identifier は英数字、ピリオド、アンダースコア、ハイフンのみ使用可能で、1〜128文字である必要があります: \"\(identifier)\"")
            }
        }

        let version = trimmedNonEmpty(payload.version)
        if version == nil {
            errors.append("version が指定されていません")
        }

        let author = trimmedNonEmpty(payload.author)
        if author == nil {
            errors.append("author が指定されていません")
        }

        let url = trimmedNonEmpty(payload.url)
        if url == nil {
            errors.append("url が指定されていません")
        }

        let validAreas = PluginDisplayArea.allCases.map { "\"" + $0.rawValue + "\"" }.joined(
            separator: ", ")
        let parsedAreas: [PluginDisplayArea]?
        if let rawAreas = payload.displayAreas {
            let normalizedAreas = rawAreas.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if normalizedAreas.isEmpty {
                errors.append("displayAreas が指定されていません。表示するエリアを配列で指定してください\n有効な値: \(validAreas)")
                parsedAreas = nil
            } else {
                let invalidAreas = normalizedAreas.filter { PluginDisplayArea(rawValue: $0) == nil }
                if !invalidAreas.isEmpty {
                    errors.append(
                        "displayAreas に認識できない値があります: \(invalidAreas.map { "\"\($0)\"" }.joined(separator: ", "))\n有効な値: \(validAreas)"
                    )
                }
                parsedAreas =
                    invalidAreas.isEmpty
                    ? normalizedAreas.compactMap(PluginDisplayArea.init(rawValue:)) : nil
            }
        } else {
            errors.append("displayAreas が指定されていません。表示するエリアを配列で指定してください\n有効な値: \(validAreas)")
            parsedAreas = nil
        }

        if let url {
            let isValid =
                URL(string: url).map { $0.scheme == "http" || $0.scheme == "https" } ?? false
            if !isValid {
                errors.append("url が有効なURLではありません: \"\(url)\"")
            }
        }

        let contextId = trimmedNonEmpty(payload.contextId)
        if let contextId {
            let isValid =
                (try? NSRegularExpression(pattern: "^[a-z0-9-]{1,63}$"))
                .map {
                    $0.firstMatch(
                        in: contextId, range: NSRange(location: 0, length: contextId.utf16.count))
                        != nil
                }
                ?? false
            if !isValid {
                errors.append("contextId は小文字英数字とハイフンのみ使用可能で、1〜63文字である必要があります: \"\(contextId)\"")
            }
        }

        let allowedURLPatterns = payload.allowedURLPatterns?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let allowedURLPatterns {
            var invalidPatterns: [String] = []
            for pattern in allowedURLPatterns {
                if (try? NSRegularExpression(pattern: pattern)) == nil {
                    invalidPatterns.append(pattern)
                }
            }
            if !invalidPatterns.isEmpty {
                errors.append(
                    "allowedURLPatterns に無効な正規表現が含まれています: \(invalidPatterns.map { "\"\($0)\"" }.joined(separator: ", "))"
                )
            }
        }

        if !errors.isEmpty {
            throw PluginManifestValidationError(messages: errors)
        }

        guard let name,
            let identifier,
            let version,
            let author,
            let url,
            let displayAreas = parsedAreas
        else {
            throw PluginManifestValidationError(messages: ["プラグインマニフェストの内部状態が不正です"])
        }

        return PluginManifest(
            name: name,
            identifier: identifier,
            version: version,
            author: author,
            url: url,
            displayAreas: displayAreas,
            contextId: contextId,
            allowedURLPatterns: allowedURLPatterns
        )
    }

    static func validateManifest(from html: String) throws {
        _ = try parseManifest(from: html)
    }

    static func displayName(from html: String, fallback: String) -> String {
        guard let name = try? parseManifest(from: html).name else {
            return fallback
        }
        return name
    }
}
