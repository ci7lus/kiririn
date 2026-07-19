import WebKit

@MainActor
enum PluginWebsiteDataStore {
    private static let extensionDataTypes = WKWebExtensionController.allExtensionDataTypes
    private static let websiteDataTypes = WKWebsiteDataStore.allWebsiteDataTypes()

    static func unregisterServiceWorkers(for plugin: PluginDefinition) async {
        guard let host = try? ExtensionPluginContextConfiguration.websiteDataHost(for: plugin.id)
        else { return }
        let swTypes: Set<String> = [WKWebsiteDataTypeServiceWorkerRegistrations]
        let dataStore = WKWebsiteDataStore.default()
        let records = await matchingRecords(forHost: host, dataStore: dataStore)
        guard !records.isEmpty else { return }
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: swTypes, for: records) {
                continuation.resume(returning: ())
            }
        }
    }

    @MainActor
    static func removeAllData(for plugin: PluginDefinition, store: PluginStore) async throws
        -> Bool
    {
        let removedWebsiteData = try await removeWebsiteData(for: plugin)

        do {
            let runtime = try await ExtensionPluginRuntimeRegistry.shared.acquireRuntime(
                for: plugin,
                store: store
            )
            defer {
                ExtensionPluginRuntimeRegistry.shared.releaseRuntime(runtime)
            }
            let removedExtensionData = await removeExtensionData(for: runtime)
            return removedExtensionData || removedWebsiteData
        } catch {
            if removedWebsiteData {
                return true
            }
            throw error
        }
    }

    private static func removeExtensionData(for runtime: ExtensionPluginRuntime) async -> Bool {
        guard
            let record = await runtime.controller.dataRecord(
                ofTypes: extensionDataTypes,
                for: runtime.context
            )
        else {
            return false
        }

        let removableTypes = record.containedDataTypes.intersection(extensionDataTypes)
        guard !removableTypes.isEmpty else { return false }

        await runtime.controller.removeData(ofTypes: removableTypes, from: [record])
        return true
    }

    private static func removeWebsiteData(for plugin: PluginDefinition) async throws -> Bool {
        let host = try ExtensionPluginContextConfiguration.websiteDataHost(for: plugin.id)
        return await removeWebsiteData(forHost: host)
    }

    private static func removeWebsiteData(forHost host: String) async -> Bool {
        let dataStore = WKWebsiteDataStore.default()
        let records = await matchingRecords(forHost: host, dataStore: dataStore)
        guard !records.isEmpty else { return false }

        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: websiteDataTypes, for: records) {
                continuation.resume(returning: ())
            }
        }

        return true
    }

    private static func matchingRecords(forHost host: String, dataStore: WKWebsiteDataStore) async
        -> [WKWebsiteDataRecord]
    {
        let normalizedHost = host.lowercased()

        return await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: websiteDataTypes) { records in
                continuation.resume(
                    returning: records.filter {
                        let displayName = $0.displayName.lowercased()
                        return displayName == normalizedHost
                            || displayName.hasSuffix(".\(normalizedHost)")
                    })
            }
        }
    }
}
