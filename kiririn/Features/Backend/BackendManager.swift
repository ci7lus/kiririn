import Foundation
import Logging
import Network

#if canImport(UIKit)
    import UIKit
    typealias PlatformImage = UIImage
#elseif canImport(AppKit)
    import AppKit
    typealias PlatformImage = NSImage
#else
    typealias PlatformImage = Any
#endif

enum BackendManagerError: LocalizedError {
    case recordingBackendUnavailable

    var errorDescription: String? {
        switch self {
        case .recordingBackendUnavailable:
            return "バックエンドが利用できません"
        }
    }
}

nonisolated enum ProgramCatalogRefreshPolicy: Sendable {
    case none
    case automaticIfDue
    case force
    case forceIgnoringNetwork
}

nonisolated enum ManualProgramCatalogRefreshResult: Sendable, Equatable {
    case refreshed
    case queuedUntilWiFi
    case unavailable
    case failed(String)
}

nonisolated enum ProgramCatalogRefreshDecision: Sendable, Equatable {
    case skip
    case fetchNow
    case queueUntilWiFi
}

nonisolated enum ProgramCatalogRefreshExecutionResult: Sendable, Equatable {
    case skipped
    case queuedUntilWiFi
    case refreshed
    case failed(String)
}

#if !os(macOS)
    nonisolated private enum ProgramFetchNetworkState: Sendable {
        case unresolved
        case wifi
        case nonWiFi
    }
#endif

@Observable
class BackendManager {
    private let logger = Logging.Logger(label: "BackendManager")
    private let programFullFetchInterval: TimeInterval = 12 * 60 * 60
    private let periodicProgramRefreshCheckInterval: Duration = .seconds(60 * 60)
    let configStore: BackendConfigStore
    var connectionStates: [String: BackendConnectionState] = [:]
    var providers: [String: any BackendProvider] = [:]
    private var providerConfigurations: [String: BackendConfiguration] = [:]

    private var cacheStore: CacheStore!
    private var serviceVariantsByAggregatedServiceId: [String: [TVService]] = [:]
    private var servicesByUniqueId: [String: TVService] = [:]
    private var cachedServicesByBackend: [String: [TVService]] = [:]
    private var favoriteServiceDatesByUnifiedKey: [String: Date] = [:]
    @ObservationIgnored
    private var lastProgramFullFetchDatesByBackend: [String: Date] = [:]
    @ObservationIgnored
    private var pendingProgramFullFetchBackendIDs: Set<String> = []
    @ObservationIgnored
    private var periodicProgramRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var isAutomaticProgramRefreshEvaluationRunning = false
    #if !os(macOS)
        @ObservationIgnored
        private var networkMonitor: NWPathMonitor?
        @ObservationIgnored
        private var initialNetworkStateContinuations: [CheckedContinuation<Void, Never>] = []
        @ObservationIgnored
        private let networkMonitorQueue = DispatchQueue(label: "BackendManager.NetworkPathMonitor")
        @ObservationIgnored
        private var programFetchNetworkState: ProgramFetchNetworkState = .unresolved
    #endif

    var isCacheReady = false
    var services: [TVService] = []
    var logos: [TVServiceLogo] = [] {
        didSet {
            rebuildLogoCache()
        }
    }
    private var logosByServiceKey: [String: Data] = [:]
    private var logoImagesByServiceKey: [String: PlatformImage] = [:]
    var loadingTaskCount = 0
    var isDataLoading: Bool { loadingTaskCount > 0 }
    private(set) var backendSyncCount = 0

    init(configStore: BackendConfigStore) {
        self.configStore = configStore
        setupProviders()
        #if !os(macOS)
            startNetworkMonitoringIfNeeded()
        #endif
    }

    deinit {
        periodicProgramRefreshTask?.cancel()
        #if !os(macOS)
            networkMonitor?.cancel()
        #endif
    }

    func setCacheStore(_ cacheStore: CacheStore) async {
        self.cacheStore = cacheStore
        CaptureService.shared.setCacheStore(cacheStore)
        await loadCachedData()
        startPeriodicProgramRefreshTaskIfNeeded()
    }

    private func loadCachedData() async {
        var servicesByBackend: [String: [TVService]] = [:]

        for config in configStore.configurations {
            servicesByBackend[config.id] = await cacheStore.loadCachedServices(backendId: config.id)
        }
        cachedServicesByBackend = servicesByBackend
        favoriteServiceDatesByUnifiedKey = await cacheStore.loadFavoriteServiceDates()
        lastProgramFullFetchDatesByBackend = await cacheStore.loadLastProgramFullFetchDates()

        rebuildAggregatedData()

        mergeLogos(await cacheStore.loadServiceLogos())

        isCacheReady = true
    }

    func setupProviders() {
        for config in configStore.configurations {
            if providers[config.id] != nil {
                if providerConfigurations[config.id] != config {
                    providers[config.id] = createProvider(for: config)
                    providerConfigurations[config.id] = config
                    connectionStates[config.id]?.status = .disconnected
                    connectionStates[config.id]?.lastError = nil
                }
            } else {
                let provider = createProvider(for: config)
                providers[config.id] = provider
                providerConfigurations[config.id] = config
            }
            if connectionStates[config.id] == nil {
                let state = BackendConnectionState(
                    backendId: config.id,
                    isEnabled: configStore.isEnabled(config.id)
                )
                connectionStates[config.id] = state
            }
        }

        let validIds = Set(configStore.configurations.map(\.id))
        for key in providers.keys where !validIds.contains(key) {
            providers.removeValue(forKey: key)
            providerConfigurations.removeValue(forKey: key)
            connectionStates.removeValue(forKey: key)
            cachedServicesByBackend[key] = nil
            lastProgramFullFetchDatesByBackend[key] = nil
            pendingProgramFullFetchBackendIDs.remove(key)
        }

        backendSyncCount += 1
        rebuildAggregatedData()
    }

    private func createProvider(for config: BackendConfiguration) -> any BackendProvider {
        switch config.type {
        case .mirakurun:
            return MirakurunProvider(configuration: config)
        case .epgstation:
            return EPGStationProvider(configuration: config)
        case .googledrive:
            let provider = GoogleDriveProvider(configuration: config)
            provider.onConfigurationUpdated = { [weak self] newConfig in
                Task { @MainActor [weak self] in
                    self?.configStore.updateConfiguration(newConfig)
                    self?.providerConfigurations[newConfig.id] = newConfig
                }
            }
            return provider
        case .konomitv:
            return KonomiTVProvider(configuration: config)
        }
    }

    private func backendLogDescription(for backendId: String) -> String {
        if let config = providerConfigurations[backendId]
            ?? configStore.configurations.first(where: { $0.id == backendId })
        {
            return "backend \(config.name) (\(config.type.displayName), id: \(config.id))"
        }
        return "backend id \(backendId)"
    }

    func connectAll() async {
        setupProviders()
        rebuildAggregatedData()

        for config in configStore.configurations {
            guard let state = connectionStates[config.id], state.isEnabled else { continue }
            await connect(backendId: config.id, programRefreshPolicy: .automaticIfDue)
        }
    }

    @discardableResult
    func connect(
        backendId: String,
        programRefreshPolicy: ProgramCatalogRefreshPolicy = .none
    ) async -> ProgramCatalogRefreshExecutionResult {
        guard let provider = providers[backendId],
            let state = connectionStates[backendId]
        else { return .skipped }
        guard state.isEnabled else {
            state.status = .disconnected
            state.lastError = nil
            rebuildAggregatedData()
            return .skipped
        }

        state.status = .connecting
        state.lastError = nil
        loadingTaskCount += 1
        defer { loadingTaskCount = max(0, loadingTaskCount - 1) }

        do {
            try await provider.checkConnection()
            state.status = .connected
            state.lastConnectedAt = Date()
            return await refreshData(
                backendId: backendId, programRefreshPolicy: programRefreshPolicy)
        } catch {
            state.status = .error
            state.lastError = error.localizedDescription
            rebuildAggregatedData()
            return .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func refreshData(
        backendId: String,
        programRefreshPolicy: ProgramCatalogRefreshPolicy = .none
    ) async -> ProgramCatalogRefreshExecutionResult {
        guard let provider = liveProvider(for: backendId),
            let state = connectionStates[backendId],
            state.status == .connected
        else { return .skipped }
        loadingTaskCount += 1
        defer { loadingTaskCount = max(0, loadingTaskCount - 1) }

        do {
            let fetchedServices = try await provider.fetchServices()
            cachedServicesByBackend[backendId] = fetchedServices
            await cacheStore.cacheServices(fetchedServices, backendId: backendId)
            rebuildAggregatedData()

            let fetchedLogos = await fetchLogoData(for: fetchedServices, backendId: backendId)
            mergeLogos(fetchedLogos)
            await cacheStore.cacheLogos(fetchedLogos)
            rebuildAggregatedData()

            switch await programCatalogRefreshDecision(for: backendId, policy: programRefreshPolicy)
            {
            case .skip:
                rebuildAggregatedData()
                return .skipped
            case .queueUntilWiFi:
                rebuildAggregatedData()
                return .queuedUntilWiFi
            case .fetchNow:
                do {
                    let fetchedPrograms = try await provider.fetchPrograms()
                    await cacheStore.cachePrograms(fetchedPrograms, backendId: backendId)
                    state.lastError = nil
                    lastProgramFullFetchDatesByBackend[backendId] = Date()
                    pendingProgramFullFetchBackendIDs.remove(backendId)
                    rebuildAggregatedData()
                    return .refreshed
                } catch {
                    state.lastError = error.localizedDescription
                    logger.error(
                        "Failed to refresh program catalog for \(backendLogDescription(for: backendId)): \(error)"
                    )
                    rebuildAggregatedData()
                    return .failed(error.localizedDescription)
                }
            }
        } catch {
            state.status = .error
            state.lastError = error.localizedDescription
            rebuildAggregatedData()
            return .failed(error.localizedDescription)
        }
    }

    func refreshAllData() async {
        for config in configStore.configurations {
            guard let state = connectionStates[config.id],
                state.isEnabled, state.status == .connected
            else { continue }
            await refreshData(backendId: config.id, programRefreshPolicy: .force)
        }
    }

    func handleAppDidBecomeActive() async {
        #if !os(macOS)
            if await isProgramCatalogRefreshAllowedOnCurrentNetwork() {
                await retryPendingProgramCatalogRefreshes()
            }
        #endif
        await reevaluateAutomaticProgramCatalogRefreshes()
    }

    func refreshProgramsManually(backendId: String) async -> ManualProgramCatalogRefreshResult {
        guard cacheStore != nil,
            isBackendEnabled(backendId),
            backendSupports(.live, backendId: backendId)
        else {
            return .unavailable
        }

        let refreshResult: ProgramCatalogRefreshExecutionResult

        if connectionStates[backendId]?.status == .connected {
            refreshResult = await refreshData(
                backendId: backendId,
                programRefreshPolicy: .forceIgnoringNetwork
            )
        } else {
            refreshResult = await connect(
                backendId: backendId,
                programRefreshPolicy: .forceIgnoringNetwork
            )
        }

        if case .queuedUntilWiFi = refreshResult {
            return .queuedUntilWiFi
        }

        if case .failed(let message) = refreshResult {
            return .failed(message)
        }

        if let state = connectionStates[backendId], state.status == .error {
            return .failed(state.lastError ?? "番組情報の再取得に失敗しました")
        }

        return .refreshed
    }

    nonisolated static func allowsProgramCatalogRefresh(requiresWiFi: Bool, isOnWiFi: Bool) -> Bool
    {
        !requiresWiFi || isOnWiFi
    }

    nonisolated static func isProgramCatalogRefreshDue(
        lastFetchedAt: Date?,
        now: Date,
        interval: TimeInterval
    ) -> Bool {
        guard let lastFetchedAt else { return true }
        return now.timeIntervalSince(lastFetchedAt) >= interval
    }

    nonisolated static func resolveProgramCatalogRefreshDecision(
        policy: ProgramCatalogRefreshPolicy,
        lastFetchedAt: Date?,
        now: Date,
        interval: TimeInterval,
        networkAllowsRefresh: Bool
    ) -> ProgramCatalogRefreshDecision {
        switch policy {
        case .none:
            return .skip
        case .automaticIfDue:
            guard
                isProgramCatalogRefreshDue(
                    lastFetchedAt: lastFetchedAt,
                    now: now,
                    interval: interval
                )
            else {
                return .skip
            }
        case .force:
            break
        case .forceIgnoringNetwork:
            return .fetchNow
        }

        return networkAllowsRefresh ? .fetchNow : .queueUntilWiFi
    }

    private func programCatalogRefreshDecision(
        for backendId: String,
        policy: ProgramCatalogRefreshPolicy,
        now: Date = Date()
    ) async -> ProgramCatalogRefreshDecision {
        guard policy != .none else { return .skip }
        guard backendSupports(.live, backendId: backendId), isBackendEnabled(backendId) else {
            pendingProgramFullFetchBackendIDs.remove(backendId)
            return .skip
        }

        let lastFetchedAt = lastProgramFullFetchDatesByBackend[backendId]
        if policy == .automaticIfDue,
            !Self.isProgramCatalogRefreshDue(
                lastFetchedAt: lastFetchedAt,
                now: now,
                interval: programFullFetchInterval
            )
        {
            pendingProgramFullFetchBackendIDs.remove(backendId)
            return .skip
        }

        let decision = Self.resolveProgramCatalogRefreshDecision(
            policy: policy,
            lastFetchedAt: lastFetchedAt,
            now: now,
            interval: programFullFetchInterval,
            networkAllowsRefresh: await isProgramCatalogRefreshAllowedOnCurrentNetwork()
        )

        if decision == .queueUntilWiFi {
            pendingProgramFullFetchBackendIDs.insert(backendId)
        }

        return decision
    }

    private func reevaluateAutomaticProgramCatalogRefreshes() async {
        guard cacheStore != nil else { return }
        guard !isAutomaticProgramRefreshEvaluationRunning else { return }
        isAutomaticProgramRefreshEvaluationRunning = true
        defer { isAutomaticProgramRefreshEvaluationRunning = false }

        for config in configStore.configurations {
            guard config.features.contains(.live),
                let state = connectionStates[config.id],
                state.isEnabled,
                state.status == .connected
            else {
                continue
            }

            await refreshData(backendId: config.id, programRefreshPolicy: .automaticIfDue)
        }
    }

    private func retryPendingProgramCatalogRefreshes() async {
        let queuedBackendIDs = configStore.configurations.map(\.id).filter {
            pendingProgramFullFetchBackendIDs.contains($0)
        }

        for backendId in queuedBackendIDs {
            guard isBackendEnabled(backendId), backendSupports(.live, backendId: backendId) else {
                pendingProgramFullFetchBackendIDs.remove(backendId)
                continue
            }

            pendingProgramFullFetchBackendIDs.remove(backendId)

            if connectionStates[backendId]?.status == .connected {
                await refreshData(backendId: backendId, programRefreshPolicy: .force)
            } else {
                await connect(backendId: backendId, programRefreshPolicy: .force)
            }
        }
    }

    private func startPeriodicProgramRefreshTaskIfNeeded() {
        guard periodicProgramRefreshTask == nil else { return }

        periodicProgramRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: self?.periodicProgramRefreshCheckInterval ?? .seconds(60 * 60))
                } catch {
                    return
                }

                guard let self else { return }
                await self.reevaluateAutomaticProgramCatalogRefreshes()
            }
        }
    }

    private func isProgramCatalogRefreshAllowedOnCurrentNetwork() async -> Bool {
        #if os(macOS)
            return Self.allowsProgramCatalogRefresh(requiresWiFi: false, isOnWiFi: false)
        #else
            await waitForInitialProgramFetchNetworkStateIfNeeded()
            return Self.allowsProgramCatalogRefresh(
                requiresWiFi: true,
                isOnWiFi: programFetchNetworkState == .wifi
            )
        #endif
    }

    #if !os(macOS)
        private func startNetworkMonitoringIfNeeded() {
            guard networkMonitor == nil else { return }

            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let nextState = Self.programFetchNetworkState(for: path)
                Task { @MainActor [weak self] in
                    await self?.updateProgramFetchNetworkState(nextState)
                }
            }
            monitor.start(queue: networkMonitorQueue)
            networkMonitor = monitor
        }

        private func waitForInitialProgramFetchNetworkStateIfNeeded() async {
            startNetworkMonitoringIfNeeded()
            guard programFetchNetworkState == .unresolved else { return }

            await withCheckedContinuation { continuation in
                initialNetworkStateContinuations.append(continuation)
            }
        }

        private func updateProgramFetchNetworkState(_ newState: ProgramFetchNetworkState) async {
            let previousState = programFetchNetworkState
            programFetchNetworkState = newState

            let continuations = initialNetworkStateContinuations
            initialNetworkStateContinuations.removeAll()
            continuations.forEach { $0.resume() }

            guard previousState != .wifi, newState == .wifi else { return }
            await retryPendingProgramCatalogRefreshes()
            await reevaluateAutomaticProgramCatalogRefreshes()
        }

        nonisolated private static func programFetchNetworkState(for path: NWPath)
            -> ProgramFetchNetworkState
        {
            guard path.status == .satisfied, path.usesInterfaceType(.wifi) else {
                return .nonWiFi
            }

            return .wifi
        }
    #endif

    func backendAvailabilityDidChange() {
        backendSyncCount += 1
        rebuildAggregatedData()
    }

    private func rebuildAggregatedData() {
        var variantsByMergedKey: [String: [TVService]] = [:]
        var variantsByAggregatedServiceId: [String: [TVService]] = [:]
        var resolvedServicesByUniqueId: [String: TVService] = [:]

        for config in configStore.configurations {
            guard shouldIncludeBackendInAggregation(backendId: config.id) else { continue }

            let cachedServices = cachedServicesByBackend[config.id] ?? []

            for service in cachedServices {
                let mergedKey = service.unifiedServiceKey
                var resolvedService = service
                resolvedService.favoritedAt = favoriteServiceDatesByUnifiedKey[mergedKey]
                variantsByMergedKey[mergedKey, default: []].append(resolvedService)
                resolvedServicesByUniqueId[resolvedService.id] = resolvedService
            }
        }

        var mergedServices: [TVService] = []
        for (_, variants) in variantsByMergedKey {
            let sortedVariants = sortServicesByBackendPriority(variants)
            guard let preferred = preferredServiceVariant(from: sortedVariants) else { continue }

            mergedServices.append(preferred)
            variantsByAggregatedServiceId[preferred.id] = sortedVariants
        }

        serviceVariantsByAggregatedServiceId = variantsByAggregatedServiceId
        servicesByUniqueId = resolvedServicesByUniqueId
        services = mergedServices
    }

    private func rebuildLogoCache() {
        var dataCache: [String: Data] = [:]
        var imageCache: [String: PlatformImage] = [:]
        for logo in logos {
            let key = "\(logo.networkId)-\(logo.serviceId)"
            dataCache[key] = logo.data

            #if canImport(UIKit)
                if let image = UIImage(data: logo.data) {
                    imageCache[key] = image
                }
            #elseif canImport(AppKit)
                if let image = NSImage(data: logo.data) {
                    imageCache[key] = image
                }
            #endif
        }
        logosByServiceKey = dataCache
        logoImagesByServiceKey = imageCache
    }

    func updateLogo(_ logo: TVServiceLogo) {
        mergeLogos([logo])
    }

    private func mergeLogos(_ incomingLogos: [TVServiceLogo]) {
        guard !incomingLogos.isEmpty else { return }

        var mergedLogos = logos
        for logo in incomingLogos {
            if let index = mergedLogos.firstIndex(where: {
                $0.serviceId == logo.serviceId && $0.networkId == logo.networkId
            }) {
                mergedLogos[index] = logo
            } else {
                mergedLogos.append(logo)
            }
        }
        logos = mergedLogos
    }

    private func shouldIncludeBackendInAggregation(backendId: String) -> Bool {
        guard isBackendEnabled(backendId) else { return false }
        guard backendSupports(.live, backendId: backendId) else { return false }
        guard let state = connectionStates[backendId] else { return true }
        return state.status != .error
    }

    private func sortServicesByBackendPriority(_ services: [TVService]) -> [TVService] {
        let order = Dictionary(
            uniqueKeysWithValues: configStore.configurations.enumerated().map { ($1.id, $0) })
        return services.sorted { lhs, rhs in
            let lConnected = connectionStates[lhs.backendId]?.status == .connected
            let rConnected = connectionStates[rhs.backendId]?.status == .connected
            if lConnected != rConnected {
                return lConnected
            }
            return (order[lhs.backendId] ?? Int.max) < (order[rhs.backendId] ?? Int.max)
        }
    }

    private func preferredServiceVariant(from variants: [TVService]) -> TVService? {
        variants.first
    }

    private func fetchLogoData(for services: [TVService], backendId: String) async
        -> [TVServiceLogo]
    {
        guard let provider = providers[backendId] as? any LiveBackendProvider else { return [] }

        return await withTaskGroup(of: TVServiceLogo?.self) { group in
            let oneweekago = Date().addingTimeInterval(-86400 * 7)
            var result: [TVServiceLogo] = []

            for service in services {
                if !service.hasLogoData {
                    continue
                }
                let cachedLogo = logos.first(where: {
                    $0.serviceId == service.serviceId && $0.networkId == service.networkId
                })
                // 7日以上経過した場合は再取得する
                if let cachedLogo, cachedLogo.updatedAt > oneweekago {
                    result.append(cachedLogo)
                    continue
                }
                group.addTask {
                    do {
                        let data = try await provider.fetchServiceLogoData(for: service)
                        guard let data else { return nil }
                        return TVServiceLogo(
                            id: service.id,
                            serviceId: service.serviceId,
                            networkId: service.networkId,
                            data: data,
                            updatedAt: Date()
                        )
                    } catch {
                        self.logger.error(
                            "Failed to fetch logo data for service \(service.name): \(error)")
                        return nil
                    }
                }
            }

            for await logo in group {
                if let logo {
                    result.append(logo)
                }
            }
            return result
        }
    }

    func logoImage(for service: TVService) -> PlatformImage? {
        let key = "\(service.networkId)-\(service.serviceId)"
        return logoImagesByServiceKey[key]
    }

    func isFavorite(_ service: TVService) -> Bool {
        favoriteServiceDatesByUnifiedKey[service.unifiedServiceKey] != nil
    }

    func favoriteDate(for service: TVService) -> Date? {
        favoriteServiceDatesByUnifiedKey[service.unifiedServiceKey]
    }

    var hasFavoriteServices: Bool {
        !favoriteServiceDatesByUnifiedKey.isEmpty
    }

    func toggleFavorite(_ service: TVService) async {
        await setFavorite(service, isFavorite: !isFavorite(service))
    }

    func setFavorite(_ service: TVService, isFavorite: Bool) async {
        let key = service.unifiedServiceKey

        if isFavorite {
            let favoritedAt = favoriteServiceDatesByUnifiedKey[key] ?? Date()
            await cacheStore.saveFavoriteService(service, favoritedAt: favoritedAt)
            favoriteServiceDatesByUnifiedKey[key] = favoritedAt
        } else {
            await cacheStore.deleteFavoriteService(service)
            favoriteServiceDatesByUnifiedKey.removeValue(forKey: key)
        }

        rebuildAggregatedData()
    }

    func playbackCandidates(for service: TVService) -> [TVService] {
        if let variants = serviceVariantsByAggregatedServiceId[service.id] {
            return sortServicesByBackendPriority(variants).filter {
                isBackendEnabled($0.backendId) && backendSupports(.live, backendId: $0.backendId)
            }
        }
        guard isBackendEnabled(service.backendId),
            backendSupports(.live, backendId: service.backendId)
        else { return [] }
        return [service]
    }

    func backendDisplayName(_ backendId: String) -> String {
        backendName(backendId)
    }

    func backendFullDisplayName(_ backendId: String) -> String {
        let name = backendName(backendId)
        let typeName = backendTypeName(backendId)
        if typeName.isEmpty {
            return name
        }
        return "\(name) (\(typeName))"
    }

    func backendName(_ backendId: String) -> String {
        let config = configStore.configurations.first(where: { $0.id == backendId })
        if let config {
            return config.name
        }
        return backendId
    }

    func backendTypeName(_ backendId: String) -> String {
        let config = configStore.configurations.first(where: { $0.id == backendId })
        if let config {
            return config.type.displayName
        }
        return ""
    }

    func liveProvider(for backendId: String) -> (any LiveBackendProvider)? {
        guard isBackendEnabled(backendId) else { return nil }
        guard backendSupports(.live, backendId: backendId) else { return nil }
        return providers[backendId] as? (any LiveBackendProvider)
    }

    func recordingProvider(for backendId: String) -> (any RecordingBackendProvider)? {
        guard isBackendEnabled(backendId) else { return nil }
        guard backendSupports(.recording, backendId: backendId) else { return nil }
        return providers[backendId] as? (any RecordingBackendProvider)
    }

    func fetchRecords(backendId: String, pageToken: String?, limit: Int, keyword: String?)
        async throws -> RecordsResult
    {
        guard let provider = recordingProvider(for: backendId) else {
            throw BackendManagerError.recordingBackendUnavailable
        }
        loadingTaskCount += 1
        defer { loadingTaskCount = max(0, loadingTaskCount - 1) }
        return try await provider.fetchRecords(pageToken: pageToken, limit: limit, keyword: keyword)
    }

    func fetchRecord(backendId: String, id: String) async throws -> Recorded {
        guard let provider = recordingProvider(for: backendId) else {
            throw BackendManagerError.recordingBackendUnavailable
        }
        loadingTaskCount += 1
        defer { loadingTaskCount = max(0, loadingTaskCount - 1) }
        return try await provider.fetchRecord(id: id)
    }

    func fetchRecordThumbnail(backendId: String, id: String) async throws -> Data? {
        guard let provider = recordingProvider(for: backendId) else {
            throw BackendManagerError.recordingBackendUnavailable
        }
        return try await provider.fetchRecordThumbnail(id: id)
    }

    var recordingBackendIds: [String] {
        let _ = backendSyncCount
        let ids = configStore.configurations
            .filter { $0.features.contains(.recording) && isBackendEnabled($0.id) }
            .map(\.id)
        return ids
    }

    func isBackendEnabled(_ backendId: String) -> Bool {
        return configStore.isEnabled(backendId)
    }

    private func backendSupports(_ feature: BackendFeature, backendId: String) -> Bool {
        return configStore.configurations
            .first(where: { $0.id == backendId })?
            .features.contains(feature) == true
    }

    func currentProgram(for service: TVService) async -> Program? {
        await cacheStore.fetchCurrentProgram(for: service)
    }

    func currentProgram(serviceUniqueId: String) async -> Program? {
        let service =
            servicesByUniqueId[serviceUniqueId]
            ?? services.first(where: { $0.id == serviceUniqueId })
        guard let service else { return nil }
        return await cacheStore.fetchCurrentProgram(for: service)
    }

    func service(serviceUniqueId: String) -> TVService? {
        servicesByUniqueId[serviceUniqueId] ?? services.first(where: { $0.id == serviceUniqueId })
    }

    func nextProgram(serviceUniqueId: String) async -> Program? {
        let service =
            servicesByUniqueId[serviceUniqueId]
            ?? services.first(where: { $0.id == serviceUniqueId })
        guard let service else { return nil }
        return await cacheStore.fetchNextProgram(for: service)
    }

    func nextProgram(for service: TVService, currentProgram: Program?) async -> Program? {
        await cacheStore.fetchNextProgram(for: service, currentProgram: currentProgram)
    }

    func nextProgram(serviceUniqueId: String, currentProgram: Program?) async -> Program? {
        let service =
            servicesByUniqueId[serviceUniqueId]
            ?? services.first(where: { $0.id == serviceUniqueId })
        guard let service else { return nil }
        return await cacheStore.fetchNextProgram(for: service, currentProgram: currentProgram)
    }

    func fetchAllCurrentPrograms() async -> [Program] {
        await cacheStore.fetchAllCurrentPrograms()
    }

    func fetchAllNextPrograms() async -> [Program] {
        await cacheStore.fetchAllNextPrograms()
    }

    func fetchCachedPrograms(from: Date? = nil, until date: Date) async -> [Program] {
        await cacheStore.loadCachedPrograms(from: from, until: date)
    }

    func searchCachedPrograms(query: String, limit: Int = 200) async -> [Program] {
        await cacheStore.searchPrograms(query: query, limit: limit)
    }
}
