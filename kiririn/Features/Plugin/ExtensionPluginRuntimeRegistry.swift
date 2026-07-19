import Foundation

@MainActor
final class ExtensionPluginRuntimeRegistry {
    static let shared = ExtensionPluginRuntimeRegistry()

    private struct PendingRuntimeLoad {
        let token: UUID
        let task: Task<ExtensionPluginRuntime, Error>
    }

    private struct RuntimeEntry {
        let runtime: ExtensionPluginRuntime
        var useCount: Int
    }

    private var runtimeEntries: [UUID: RuntimeEntry] = [:]
    private var pendingLoads: [UUID: PendingRuntimeLoad] = [:]

    private func makeRuntime(for plugin: PluginDefinition, store: PluginStore) async throws
        -> ExtensionPluginRuntime
    {
        if let entry = runtimeEntries[plugin.id] {
            return entry.runtime
        }

        if let pendingLoad = pendingLoads[plugin.id] {
            return try await resolvePendingLoad(pendingLoad, for: plugin)
        }

        let pendingLoad = PendingRuntimeLoad(
            token: UUID(),
            task: Task { @MainActor in
                let resourceBaseURL = try await store.resourceBaseURL(for: plugin)
                try Task.checkCancellation()
                let manifest = try store.resolvedManifest(
                    for: plugin,
                    resourceBaseURL: resourceBaseURL
                )
                return try await ExtensionPluginRuntime(
                    plugin: plugin,
                    manifest: manifest,
                    resourceBaseURL: resourceBaseURL
                )
            }
        )
        pendingLoads[plugin.id] = pendingLoad
        return try await resolvePendingLoad(pendingLoad, for: plugin)
    }

    func acquireRuntime(for plugin: PluginDefinition, store: PluginStore) async throws
        -> ExtensionPluginRuntime
    {
        let runtime = try await makeRuntime(for: plugin, store: store)
        guard var entry = runtimeEntries[plugin.id], entry.runtime === runtime else {
            runtime.invalidate()
            throw CancellationError()
        }
        entry.useCount += 1
        runtimeEntries[plugin.id] = entry
        return runtime
    }

    func releaseRuntime(_ runtime: ExtensionPluginRuntime) {
        guard var entry = runtimeEntries[runtime.pluginID], entry.runtime === runtime else {
            return
        }

        if entry.useCount > 1 {
            entry.useCount -= 1
            runtimeEntries[runtime.pluginID] = entry
            return
        }

        runtimeEntries[runtime.pluginID] = nil
        runtime.invalidate()
    }

    func invalidate(pluginID: UUID) {
        pendingLoads.removeValue(forKey: pluginID)?.task.cancel()
        runtimeEntries.removeValue(forKey: pluginID)?.runtime.invalidate()
    }

    func invalidateAll() {
        let activeRuntimes = runtimeEntries.values.map(\.runtime)
        let activeLoads = Array(pendingLoads.values)
        runtimeEntries = [:]
        pendingLoads = [:]
        for pendingLoad in activeLoads {
            pendingLoad.task.cancel()
        }
        for runtime in activeRuntimes {
            runtime.invalidate()
        }
    }

    private func resolvePendingLoad(
        _ pendingLoad: PendingRuntimeLoad,
        for plugin: PluginDefinition
    ) async throws -> ExtensionPluginRuntime {
        do {
            let runtime = try await pendingLoad.task.value

            if let existingEntry = runtimeEntries[plugin.id], existingEntry.runtime === runtime {
                return existingEntry.runtime
            }

            guard pendingLoads[plugin.id]?.token == pendingLoad.token else {
                runtime.invalidate()
                throw CancellationError()
            }

            pendingLoads[plugin.id] = nil

            if let existingEntry = runtimeEntries[plugin.id] {
                if existingEntry.runtime !== runtime {
                    runtime.invalidate()
                }
                return existingEntry.runtime
            }

            runtimeEntries[plugin.id] = RuntimeEntry(runtime: runtime, useCount: 0)
            return runtime
        } catch {
            if pendingLoads[plugin.id]?.token == pendingLoad.token {
                pendingLoads[plugin.id] = nil
            }
            throw error
        }
    }
}
