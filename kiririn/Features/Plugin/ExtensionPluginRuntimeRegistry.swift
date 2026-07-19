import Foundation
import KppxKit

@MainActor
final class ExtensionPluginRuntimeRegistry {
    static let shared = ExtensionPluginRuntimeRegistry()

    private struct PendingRuntimeLoad {
        let token: UUID
        let task: Task<ExtensionPluginRuntime, Error>
        var waiterCount: Int
    }

    private struct RuntimeEntry {
        let runtime: ExtensionPluginRuntime
        var useCount: Int
    }

    private struct PendingWaiterState {
        let isCurrentGeneration: Bool
        let hasRemainingWaiters: Bool
    }

    private var runtimeEntries: [UUID: RuntimeEntry] = [:]
    private var pendingLoads: [UUID: PendingRuntimeLoad] = [:]

    private func pendingRuntimeLoad(
        for plugin: PluginDefinition,
        store: PluginStore
    ) -> PendingRuntimeLoad {
        if var pendingLoad = pendingLoads[plugin.id] {
            pendingLoad.waiterCount += 1
            pendingLoads[plugin.id] = pendingLoad
            return pendingLoad
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
            },
            waiterCount: 1
        )
        pendingLoads[plugin.id] = pendingLoad
        return pendingLoad
    }

    func acquireRuntime(for plugin: PluginDefinition, store: PluginStore) async throws
        -> ExtensionPluginRuntime
    {
        if var entry = runtimeEntries[plugin.id] {
            entry.useCount += 1
            runtimeEntries[plugin.id] = entry
            return entry.runtime
        }

        let pendingLoad = pendingRuntimeLoad(for: plugin, store: store)
        return try await resolvePendingLoad(
            pendingLoad,
            for: plugin,
            store: store
        )
    }

    func releaseRuntime(_ runtime: ExtensionPluginRuntime) {
        guard var entry = runtimeEntries[runtime.pluginID], entry.runtime === runtime else {
            return
        }

        guard entry.useCount > 0 else { return }

        if entry.useCount > 1 {
            entry.useCount -= 1
            runtimeEntries[runtime.pluginID] = entry
            return
        }

        if runtime.manifest.isBackgroundExists || pendingLoads[runtime.pluginID] != nil {
            // background content と未解決の待機者は表示中の WebView の有無から独立して保持する。
            entry.useCount = 0
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
        for plugin: PluginDefinition,
        store: PluginStore
    ) async throws -> ExtensionPluginRuntime {
        let runtime: ExtensionPluginRuntime
        do {
            runtime = try await pendingLoad.task.value
        } catch {
            if pendingLoads[plugin.id]?.token == pendingLoad.token {
                pendingLoads[plugin.id] = nil
            }
            throw error
        }

        let waiterState = finishPendingWaiter(pendingLoad, pluginID: plugin.id)
        if Task.isCancelled {
            if !waiterState.hasRemainingWaiters {
                discardRuntimeIfUnused(runtime)
            }
            throw CancellationError()
        }

        if var existingEntry = runtimeEntries[plugin.id] {
            if existingEntry.runtime !== runtime {
                runtime.invalidate()
            }

            existingEntry.useCount += 1
            runtimeEntries[plugin.id] = existingEntry
            return existingEntry.runtime
        }

        guard waiterState.isCurrentGeneration else {
            runtime.invalidate()
            return try await acquireRuntime(for: plugin, store: store)
        }

        runtimeEntries[plugin.id] = RuntimeEntry(runtime: runtime, useCount: 1)
        return runtime
    }

    private func finishPendingWaiter(
        _ pendingLoad: PendingRuntimeLoad,
        pluginID: UUID
    ) -> PendingWaiterState {
        guard var currentPendingLoad = pendingLoads[pluginID],
            currentPendingLoad.token == pendingLoad.token
        else {
            return PendingWaiterState(
                isCurrentGeneration: false,
                hasRemainingWaiters: false
            )
        }

        currentPendingLoad.waiterCount -= 1
        let hasRemainingWaiters = currentPendingLoad.waiterCount > 0
        pendingLoads[pluginID] = hasRemainingWaiters ? currentPendingLoad : nil
        return PendingWaiterState(
            isCurrentGeneration: true,
            hasRemainingWaiters: hasRemainingWaiters
        )
    }

    private func discardRuntimeIfUnused(_ runtime: ExtensionPluginRuntime) {
        guard let entry = runtimeEntries[runtime.pluginID], entry.runtime === runtime else {
            runtime.invalidate()
            return
        }
        guard entry.useCount == 0, !runtime.manifest.isBackgroundExists else { return }
        runtimeEntries[runtime.pluginID] = nil
        runtime.invalidate()
    }
}
