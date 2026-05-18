import Foundation
import GRDB
import Testing

@testable import kiririn

struct StoreBehaviorTests {

    @Test func backendConfigStorePersistsConfigurationsAndEnabledStates() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BackendConfigStore(localDefaults: defaults)
        let config = BackendConfiguration(
            id: "backend-1",
            name: "Main",
            type: .epgstation,
            baseURL: "https://example.com"
        )

        store.addConfiguration(config)
        store.setEnabled(false, for: config.id)

        let reloaded = BackendConfigStore(localDefaults: defaults)
        #expect(reloaded.configurations == [config])
        #expect(!reloaded.isEnabled(config.id))
    }

    @Test func backendConfigStoreCanMoveUpdateAndRemoveConfigurations() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BackendConfigStore(localDefaults: defaults)
        let first = BackendConfiguration(
            id: "a", name: "A", type: .mirakurun, baseURL: "https://a.example")
        let second = BackendConfiguration(
            id: "b", name: "B", type: .epgstation, baseURL: "https://b.example")
        let third = BackendConfiguration(id: "c", name: "C", type: .googledrive, baseURL: nil)

        store.addConfiguration(first)
        store.addConfiguration(second)
        store.addConfiguration(third)

        store.moveConfiguration(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(store.configurations.map(\.id) == ["b", "c", "a"])

        let moved = store.moveConfiguration(id: "a", delta: -1)
        #expect(moved)
        #expect(store.configurations.map(\.id) == ["b", "a", "c"])

        var updatedSecond = second
        updatedSecond.name = "B Updated"
        store.updateConfiguration(updatedSecond)
        store.removeConfiguration(id: "c")

        let reloaded = BackendConfigStore(localDefaults: defaults)
        #expect(reloaded.configurations.map(\.id) == ["b", "a"])
        #expect(reloaded.configurations.first?.name == "B Updated")
        #expect(reloaded.isEnabled("c"))
    }

    @MainActor @Test func cacheStorePersistsLastProgramFullFetchDates() async throws {
        let dbQueue = try DatabaseQueue()
        let store = CacheStore(databaseQueue: dbQueue)

        await store.saveLastProgramFullFetchDate(
            Date(timeIntervalSince1970: 1_234),
            backendId: "backend-1"
        )
        await store.saveLastProgramFullFetchDate(
            Date(timeIntervalSince1970: 5_678),
            backendId: "backend-2"
        )

        let reloaded = CacheStore(databaseQueue: dbQueue)
        let dates = await reloaded.loadLastProgramFullFetchDates()

        #expect(dates["backend-1"] == Date(timeIntervalSince1970: 1_234))
        #expect(dates["backend-2"] == Date(timeIntervalSince1970: 5_678))
    }

    @MainActor @Test func cacheStorePersistsFavoriteServiceDisplayOrder() async throws {
        let dbQueue = try DatabaseQueue()
        let store = CacheStore(databaseQueue: dbQueue)

        let first = TVService(
            id: "service-1",
            providerIdentifier: nil,
            serviceId: 101,
            networkId: 1,
            transportStreamId: nil,
            name: "NHK総合",
            type: .digitalTelevision,
            remoteControlKeyId: 1,
            hasLogoData: false,
            channel: .init(id: "gr011", type: "GR"),
            backendId: "backend-1"
        )
        let second = TVService(
            id: "service-2",
            providerIdentifier: nil,
            serviceId: 102,
            networkId: 1,
            transportStreamId: nil,
            name: "Eテレ",
            type: .digitalTelevision,
            remoteControlKeyId: 2,
            hasLogoData: false,
            channel: .init(id: "gr021", type: "GR"),
            backendId: "backend-1"
        )
        await store.saveFavoriteService(first)
        await store.saveFavoriteService(second)
        await store.saveFavoriteServices([
            FavoriteServiceRecord(
                networkId: 1,
                serviceId: 101,
                displayOrder: 1
            ),
            FavoriteServiceRecord(
                networkId: 1,
                serviceId: 102,
                displayOrder: 0
            ),
        ])

        let reloaded = CacheStore(databaseQueue: dbQueue)
        let favorites = await reloaded.loadFavoriteServices()
        let favoriteByKey = Dictionary(
            uniqueKeysWithValues: favorites.map { ($0.unifiedServiceKey, $0) }
        )

        #expect(favoriteByKey["1-101"]?.displayOrder == 1)
        #expect(favoriteByKey["1-102"]?.displayOrder == 0)
    }

    @Test func pluginStoreParsesManifest() throws {
        let html = validPluginHTML(
            name: "Sample Plugin",
            identifier: "sample-plugin",
            version: "1.2.3",
            author: "Tester",
            url: "https://example.com/plugin",
            displayAreas: [.playerOverlay, .pluginSettings],
            contextId: "context-1",
            allowedURLPatterns: ["https://example\\.com/.*"]
        )

        let manifest = try PluginStore.parseManifest(from: html)

        #expect(manifest.name == "Sample Plugin")
        #expect(manifest.version == "1.2.3")
        #expect(manifest.author == "Tester")
        #expect(manifest.url == "https://example.com/plugin")
        #expect(manifest.identifier == "sample-plugin")
        #expect(manifest.contextId == "context-1")
        #expect(manifest.displayAreas == [.playerOverlay, .pluginSettings])
        #expect(manifest.allowedURLPatterns == ["https://example\\.com/.*"])
    }

    @Test func pluginStoreStableIdentifiersAreDeterministicUUIDv5() throws {
        let (firstDefaults, firstSuiteName) = makeIsolatedDefaults()
        defer { firstDefaults.removePersistentDomain(forName: firstSuiteName) }

        let (secondDefaults, secondSuiteName) = makeIsolatedDefaults()
        defer { secondDefaults.removePersistentDomain(forName: secondSuiteName) }

        let (thirdDefaults, thirdSuiteName) = makeIsolatedDefaults()
        defer { thirdDefaults.removePersistentDomain(forName: thirdSuiteName) }

        let firstStore = PluginStore(defaults: firstDefaults)
        let secondStore = PluginStore(defaults: secondDefaults)
        let thirdStore = PluginStore(defaults: thirdDefaults)

        try firstStore.addPlugin(
            htmlContent: validPluginHTML(
                name: "First Plugin", identifier: "sample-plugin", displayAreas: [.playerOverlay]))
        try secondStore.addPlugin(
            htmlContent: validPluginHTML(
                name: "Second Plugin", identifier: "sample-plugin", displayAreas: [.playerOverlay]))
        try thirdStore.addPlugin(
            htmlContent: validPluginHTML(
                name: "Third Plugin", identifier: "other-plugin", displayAreas: [.playerOverlay]))

        let firstID = try #require(firstStore.plugins.first?.id)
        let secondID = try #require(secondStore.plugins.first?.id)
        let thirdID = try #require(thirdStore.plugins.first?.id)

        #expect(firstID == secondID)
        #expect(firstID != thirdID)
        #expect(firstID.uuidString.split(separator: "-")[2].first == "5")
    }

    @Test func pluginStoreValidationReportsInvalidManifestFields() {
        let html = pluginHTML(
            manifestJSON: """
                {
                  "name": "Broken Plugin",
                  "identifier": "broken/plugin",
                  "version": "1.0.0",
                  "author": "Tester",
                  "url": "ftp://example.com/plugin",
                  "displayAreas": ["invalidArea"],
                  "contextId": "Invalid_Context",
                  "allowedURLPatterns": ["["]
                }
                """
        )

        do {
            try PluginStore.validateManifest(from: html)
            #expect(Bool(false))
        } catch let error as PluginManifestValidationError {
            #expect(error.messages.contains { $0.contains("identifier") })
            #expect(error.messages.contains { $0.contains("displayAreas") })
            #expect(error.messages.contains { $0.contains("url") })
            #expect(error.messages.contains { $0.contains("contextId") })
            #expect(error.messages.contains { $0.contains("allowedURLPatterns") })
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func pluginStoreValidationRequiresVersionAuthorAndURL() {
        let html = pluginHTML(
            manifestJSON: """
                {
                  "name": "Broken Plugin",
                  "identifier": "broken-plugin",
                  "displayAreas": ["playerOverlay"]
                }
                """
        )

        do {
            try PluginStore.validateManifest(from: html)
            #expect(Bool(false))
        } catch let error as PluginManifestValidationError {
            #expect(error.messages.contains { $0.contains("version") })
            #expect(error.messages.contains { $0.contains("author") })
            #expect(error.messages.contains { $0.contains("url") })
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func pluginStoreValidationRequiresPlainJSONManifestScript() {
        let html = """
            <html>
            <head></head>
            <body></body>
            </html>
            """

        do {
            try PluginStore.validateManifest(from: html)
            #expect(Bool(false))
        } catch let error as PluginManifestValidationError {
            #expect(error.messages.contains { $0.contains("kiririn-plugin-manifest") })
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func pluginStorePersistsAddUpdateMoveAndEnableOperations() throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PluginStore(defaults: defaults)
        try store.addPlugin(
            htmlContent: validPluginHTML(
                name: "First Plugin", identifier: "first", displayAreas: [.playerOverlay]))
        try store.addPlugin(
            htmlContent: validPluginHTML(
                name: "Second Plugin", identifier: "second", displayAreas: [.pluginSettings]))

        let firstID = try #require(store.plugins.first?.id)
        let secondID = try #require(store.plugins.last?.id)

        #expect(store.plugins.map(\.id) == [firstID, secondID])

        store.setEnabled(false, for: firstID)
        let moved = store.movePlugin(id: secondID, delta: -1)
        #expect(moved)
        #expect(store.plugins.map(\.manifestID) == ["second", "first"])

        var updated = #require(store.plugin(id: secondID))
        updated.htmlContent = validPluginHTML(
            name: "Second Updated", identifier: "second", displayAreas: [.pluginSettings])
        store.updatePlugin(updated)

        let reloaded = PluginStore(defaults: defaults)
        #expect(reloaded.plugins.map(\.manifestID) == ["second", "first"])
        #expect(reloaded.plugins.first?.name == "Second Updated")
        #expect(reloaded.plugin(id: firstID)?.isEnabled == false)
        #expect(reloaded.plugin(id: secondID)?.supports(area: .pluginSettings) == true)
    }

    @Test func pluginStoreRejectsDuplicateIdentifierImports() throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PluginStore(defaults: defaults)
        try store.addPlugin(
            htmlContent: validPluginHTML(
                name: "First Plugin", identifier: "duplicate", displayAreas: [.playerOverlay]))

        do {
            try store.addPlugin(
                htmlContent: validPluginHTML(
                    name: "Second Plugin", identifier: "duplicate", displayAreas: [.pluginSettings])
            )
            #expect(Bool(false))
        } catch let error as PluginManifestValidationError {
            #expect(error.messages.contains { $0.contains("すでに登録") })
            #expect(store.plugins.count == 1)
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func pluginStoreDropsPersistedPluginsWithLegacyIDs() throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PluginStore(defaults: defaults)
        try store.addPlugin(
            htmlContent: validPluginHTML(
                name: "Only Plugin", identifier: "normalized", displayAreas: [.pluginScreen]))

        var tampered = try #require(store.plugins.first)
        tampered.id = UUID()
        store.plugins = [tampered]

        let reloaded = PluginStore(defaults: defaults)
        #expect(reloaded.plugins.isEmpty)
    }

    @Test func pluginStoreRejectsIdentifierChangesDuringUpdate() throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PluginStore(defaults: defaults)
        try store.addPlugin(
            htmlContent: validPluginHTML(
                name: "Only Plugin", identifier: "only", displayAreas: [.pluginScreen]))

        var plugin = try #require(store.plugins.first)
        plugin.htmlContent = validPluginHTML(
            name: "Only Plugin", identifier: "renamed", displayAreas: [.pluginScreen])

        store.updatePlugin(plugin)

        #expect(store.fileReadErrorMessage?.contains("プラグインIDが一致しません") == true)
        #expect(store.plugins.first?.manifestID == "only")
        #expect(store.plugins.first?.id == plugin.id)
    }

    @Test func pluginStoreRemoveDeletesPersistedPlugin() throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PluginStore(defaults: defaults)
        try store.addPlugin(
            htmlContent: validPluginHTML(
                name: "Only Plugin", identifier: "only", displayAreas: [.pluginScreen]))
        let pluginID = try #require(store.plugins.first?.id)

        store.removePlugin(id: pluginID)

        let reloaded = PluginStore(defaults: defaults)
        #expect(reloaded.plugins.isEmpty)
    }

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "kiririn.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func validPluginHTML(
        name: String,
        identifier: String,
        version: String = "1.0.0",
        author: String = "Tester",
        url: String = "https://example.com/plugin",
        displayAreas: [PluginDisplayArea],
        contextId: String? = nil,
        allowedURLPatterns: [String]? = nil
    ) -> String {
        var manifest: [String: Any] = [
            "name": name,
            "identifier": identifier,
            "version": version,
            "author": author,
            "url": url,
            "displayAreas": displayAreas.map(\.rawValue),
        ]
        if let contextId {
            manifest["contextId"] = contextId
        }
        if let allowedURLPatterns {
            manifest["allowedURLPatterns"] = allowedURLPatterns
        }

        guard
            let data = try? JSONSerialization.data(
                withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            preconditionFailure("Failed to encode plugin manifest")
        }

        return pluginHTML(manifestJSON: json)
    }

    private func pluginHTML(manifestJSON: String) -> String {
        """
        <html>
        <head>
          <script id="kiririn-plugin-manifest" type="application/json">
          \(manifestJSON)
          </script>
        </head>
        <body></body>
        </html>
        """
    }
}
