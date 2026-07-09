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

enum ServerManagerError: LocalizedError {
    case recordingServerUnavailable

    var errorDescription: String? {
        switch self {
        case .recordingServerUnavailable:
            return "サーバーが利用できません"
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

nonisolated struct PlaybackReconnectionState: Sendable, Equatable {
    let needsReconnection: Bool
    let hasConnectingCandidate: Bool

    var isAwaitingReconnection: Bool {
        needsReconnection && !hasConnectingCandidate
    }
}

#if !os(macOS)
    nonisolated private enum ProgramFetchNetworkState: Sendable {
        case unresolved
        case wifi
        case nonWiFi
    }
#endif

@Observable
class ServerManager {
    private struct FavoriteServiceState: Sendable {
        var displayOrder: Int?
    }

    private let logger = Logging.Logger(label: "ServerManager")
    private let programFullFetchInterval: TimeInterval = 12 * 60 * 60
    private let periodicProgramRefreshCheckInterval: Duration = .seconds(60 * 60)
    let configStore: ServerConfigStore
    var connectionStates: [String: ServerConnectionState] = [:]
    var providers: [String: any ServerProvider] = [:]
    private var providerConfigurations: [String: ServerConfiguration] = [:]

    private var cacheStore: CacheStore!
    private var serviceVariantsByAggregatedServiceId: [String: [TVService]] = [:]
    private var serviceListVariantsByAggregatedServiceId: [String: [TVService]] = [:]
    private var servicesByUniqueId: [String: TVService] = [:]
    private var cachedServicesByServer: [String: [TVService]] = [:]
    private var favoriteStatesByUnifiedKey: [String: FavoriteServiceState] = [:]
    @ObservationIgnored
    private var lastProgramFullFetchDatesByServer: [String: Date] = [:]
    @ObservationIgnored
    private var pendingProgramFullFetchServerIDs: Set<String> = []
    @ObservationIgnored
    private var periodicProgramRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var serverOperationGenerations: [String: Int] = [:]
    @ObservationIgnored
    private var isAutomaticProgramRefreshEvaluationRunning = false
    #if !os(macOS)
        @ObservationIgnored
        private var networkMonitor: NWPathMonitor?
        @ObservationIgnored
        private var initialNetworkStateContinuations: [CheckedContinuation<Void, Never>] = []
        @ObservationIgnored
        private let networkMonitorQueue = DispatchQueue(label: "ServerManager.NetworkPathMonitor")
        @ObservationIgnored
        private var programFetchNetworkState: ProgramFetchNetworkState = .unresolved
    #endif

    var isCacheReady = false
    var serviceListServices: [TVService] = []
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
    private(set) var communicationFailureCount = 0
    private(set) var serverSyncCount = 0

    init(configStore: ServerConfigStore) {
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
        var servicesByServer: [String: [TVService]] = [:]

        for config in configStore.configurations {
            servicesByServer[config.id] = await cacheStore.loadCachedServices(serverId: config.id)
        }
        cachedServicesByServer = servicesByServer
        favoriteStatesByUnifiedKey = Dictionary(
            uniqueKeysWithValues: await cacheStore.loadFavoriteServices().map { favorite in
                (
                    favorite.unifiedServiceKey,
                    FavoriteServiceState(
                        displayOrder: favorite.displayOrder
                    )
                )
            }
        )
        lastProgramFullFetchDatesByServer = await cacheStore.loadLastProgramFullFetchDates()

        rebuildAggregatedData()

        mergeLogos(await cacheStore.loadServiceLogos())

        isCacheReady = true
    }

    func setupProviders() {
        for config in configStore.configurations {
            if providers[config.id] != nil {
                if providerConfigurations[config.id] != config {
                    cancelInFlightRequests(serverId: config.id)
                    providers[config.id] = createProvider(for: config)
                    providerConfigurations[config.id] = config
                    connectionStates[config.id]?.status = .disconnected
                    connectionStates[config.id]?.lastError = nil
                    connectionStates[config.id]?.lastErrorDetail = nil
                    connectionStates[config.id]?.version = nil
                }
            } else {
                let provider = createProvider(for: config)
                providers[config.id] = provider
                providerConfigurations[config.id] = config
            }
            if connectionStates[config.id] == nil {
                let state = ServerConnectionState(
                    serverId: config.id,
                    isEnabled: configStore.isEnabled(config.id)
                )
                connectionStates[config.id] = state
            }
        }

        let validIds = Set(configStore.configurations.map(\.id))
        for key in providers.keys where !validIds.contains(key) {
            cancelInFlightRequests(serverId: key)
            providers.removeValue(forKey: key)
            providerConfigurations.removeValue(forKey: key)
            connectionStates.removeValue(forKey: key)
            cachedServicesByServer[key] = nil
            lastProgramFullFetchDatesByServer[key] = nil
            pendingProgramFullFetchServerIDs.remove(key)
            serverOperationGenerations.removeValue(forKey: key)
        }

        serverSyncCount += 1
        rebuildAggregatedData()
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func noteCommunicationFailure(for error: Error) {
        guard !isCancellationError(error) else { return }
        communicationFailureCount += 1
    }

    private func cancelInFlightRequests(serverId: String) {
        serverOperationGenerations[serverId, default: 0] += 1
        providers[serverId]?.cancelInFlightRequests()
    }

    private func operationGeneration(for serverId: String) -> Int {
        serverOperationGenerations[serverId] ?? 0
    }

    private func isStaleOperation(serverId: String, generation: Int) -> Bool {
        operationGeneration(for: serverId) != generation
    }

    private func errorFeedback(for error: Error) -> (
        brief: String, detail: ServerOperationFeedbackContent
    ) {
        if let apiError = error as? APIError {
            return (apiError.briefDescription, apiError.feedbackContent)
        }
        return (
            error.localizedDescription,
            ServerOperationFeedbackContent(title: error.localizedDescription)
        )
    }

    private func clearLastError(for state: ServerConnectionState) {
        state.lastError = nil
        state.lastErrorDetail = nil
    }

    private func recordLastError(_ error: Error, for state: ServerConnectionState) -> String {
        let feedback = errorFeedback(for: error)
        state.lastError = feedback.brief
        state.lastErrorDetail = feedback.detail
        return feedback.brief
    }

    private func createProvider(for config: ServerConfiguration) -> any ServerProvider {
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

    private func serverLogDescription(for serverId: String) -> String {
        if let config = providerConfigurations[serverId]
            ?? configStore.configurations.first(where: { $0.id == serverId })
        {
            return "server \(config.name) (\(config.type.displayName), id: \(config.id))"
        }
        return "server id \(serverId)"
    }

    func connectAll() async {
        setupProviders()
        rebuildAggregatedData()

        for config in configStore.configurations {
            guard let state = connectionStates[config.id], state.isEnabled else { continue }
            await connect(serverId: config.id, programRefreshPolicy: .automaticIfDue)
        }
    }

    @discardableResult
    func connect(
        serverId: String,
        programRefreshPolicy: ProgramCatalogRefreshPolicy = .none
    ) async -> ProgramCatalogRefreshExecutionResult {
        let generation = operationGeneration(for: serverId)
        guard let provider = providers[serverId],
            let state = connectionStates[serverId]
        else { return .skipped }
        guard state.isEnabled else {
            state.status = .disconnected
            clearLastError(for: state)
            state.version = nil
            rebuildAggregatedData()
            return .skipped
        }
        guard state.status != .connecting else {
            return .skipped
        }

        state.status = .connecting
        clearLastError(for: state)
        state.version = nil
        loadingTaskCount += 1
        defer { loadingTaskCount = max(0, loadingTaskCount - 1) }

        do {
            let version = try await provider.checkConnection()
            guard !isStaleOperation(serverId: serverId, generation: generation) else {
                return .skipped
            }
            state.status = .connected
            state.lastConnectedAt = Date()
            state.version = version
            return await refreshData(
                serverId: serverId, programRefreshPolicy: programRefreshPolicy)
        } catch {
            guard !isStaleOperation(serverId: serverId, generation: generation) else {
                return .skipped
            }
            state.status = .error
            let message = recordLastError(error, for: state)
            state.version = nil
            noteCommunicationFailure(for: error)
            rebuildAggregatedData()
            return .failed(message)
        }
    }

    @discardableResult
    func refreshData(
        serverId: String,
        programRefreshPolicy: ProgramCatalogRefreshPolicy = .none
    ) async -> ProgramCatalogRefreshExecutionResult {
        let generation = operationGeneration(for: serverId)
        guard let provider = liveProvider(for: serverId),
            let state = connectionStates[serverId],
            state.status == .connected
        else { return .skipped }
        loadingTaskCount += 1
        defer { loadingTaskCount = max(0, loadingTaskCount - 1) }

        do {
            let fetchedServices = try await provider.fetchServices()
            guard !isStaleOperation(serverId: serverId, generation: generation) else {
                return .skipped
            }
            cachedServicesByServer[serverId] = fetchedServices
            await cacheStore.cacheServices(fetchedServices, serverId: serverId)
            rebuildAggregatedData()

            let fetchedLogos = await fetchLogoData(
                for: fetchedServices,
                provider: provider
            )
            guard !isStaleOperation(serverId: serverId, generation: generation) else {
                return .skipped
            }
            mergeLogos(fetchedLogos)
            await cacheStore.cacheLogos(fetchedLogos)
            rebuildAggregatedData()

            switch await programCatalogRefreshDecision(for: serverId, policy: programRefreshPolicy)
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
                    guard !isStaleOperation(serverId: serverId, generation: generation) else {
                        return .skipped
                    }
                    await cacheStore.cachePrograms(fetchedPrograms, serverId: serverId)
                    clearLastError(for: state)
                    lastProgramFullFetchDatesByServer[serverId] = Date()
                    pendingProgramFullFetchServerIDs.remove(serverId)
                    rebuildAggregatedData()
                    return .refreshed
                } catch {
                    guard !isStaleOperation(serverId: serverId, generation: generation) else {
                        return .skipped
                    }
                    state.status = .error
                    let message = recordLastError(error, for: state)
                    state.version = nil
                    noteCommunicationFailure(for: error)
                    logger.error(
                        "Failed to refresh program catalog for \(serverLogDescription(for: serverId)): \(error)"
                    )
                    rebuildAggregatedData()
                    return .failed(message)
                }
            }
        } catch {
            guard !isStaleOperation(serverId: serverId, generation: generation) else {
                return .skipped
            }
            state.status = .error
            let message = recordLastError(error, for: state)
            state.version = nil
            noteCommunicationFailure(for: error)
            rebuildAggregatedData()
            return .failed(message)
        }
    }

    func refreshAllData() async {
        for config in configStore.configurations {
            guard let state = connectionStates[config.id],
                state.isEnabled, state.status == .connected
            else { continue }
            await refreshData(serverId: config.id, programRefreshPolicy: .force)
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

    func refreshProgramsManually(serverId: String) async -> ManualProgramCatalogRefreshResult {
        guard cacheStore != nil,
            isServerEnabled(serverId),
            serverSupports(.live, serverId: serverId)
        else {
            return .unavailable
        }

        let refreshResult: ProgramCatalogRefreshExecutionResult

        if connectionStates[serverId]?.status == .connected {
            refreshResult = await refreshData(
                serverId: serverId,
                programRefreshPolicy: .forceIgnoringNetwork
            )
        } else {
            refreshResult = await connect(
                serverId: serverId,
                programRefreshPolicy: .forceIgnoringNetwork
            )
        }

        if case .queuedUntilWiFi = refreshResult {
            return .queuedUntilWiFi
        }

        if case .failed(let message) = refreshResult {
            return .failed(message)
        }

        if let state = connectionStates[serverId], state.status == .error {
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
        for serverId: String,
        policy: ProgramCatalogRefreshPolicy,
        now: Date = Date()
    ) async -> ProgramCatalogRefreshDecision {
        guard policy != .none else { return .skip }
        guard serverSupports(.live, serverId: serverId), isServerEnabled(serverId) else {
            pendingProgramFullFetchServerIDs.remove(serverId)
            return .skip
        }

        let lastFetchedAt = lastProgramFullFetchDatesByServer[serverId]
        if policy == .automaticIfDue,
            !Self.isProgramCatalogRefreshDue(
                lastFetchedAt: lastFetchedAt,
                now: now,
                interval: programFullFetchInterval
            )
        {
            pendingProgramFullFetchServerIDs.remove(serverId)
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
            pendingProgramFullFetchServerIDs.insert(serverId)
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

            await refreshData(serverId: config.id, programRefreshPolicy: .automaticIfDue)
        }
    }

    private func retryPendingProgramCatalogRefreshes() async {
        let queuedServerIDs = configStore.configurations.map(\.id).filter {
            pendingProgramFullFetchServerIDs.contains($0)
        }

        for serverId in queuedServerIDs {
            guard isServerEnabled(serverId), serverSupports(.live, serverId: serverId) else {
                pendingProgramFullFetchServerIDs.remove(serverId)
                continue
            }

            pendingProgramFullFetchServerIDs.remove(serverId)

            if connectionStates[serverId]?.status == .connected {
                await refreshData(serverId: serverId, programRefreshPolicy: .force)
            } else {
                await connect(serverId: serverId, programRefreshPolicy: .force)
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
            for continuation in continuations {
                continuation.resume()
            }

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

    func serverAvailabilityDidChange() {
        serverSyncCount += 1
        rebuildAggregatedData()
    }

    private func rebuildAggregatedData() {
        let playbackData = buildAggregatedServiceData(includesConnectionErrors: false)
        let serviceListData = buildAggregatedServiceData(includesConnectionErrors: true)

        serviceVariantsByAggregatedServiceId = playbackData.variantsByAggregatedServiceId
        serviceListVariantsByAggregatedServiceId = serviceListData.variantsByAggregatedServiceId
        servicesByUniqueId = playbackData.resolvedServicesByUniqueId
        services = playbackData.services
        serviceListServices = serviceListData.services
    }

    private struct AggregatedServiceData {
        var services: [TVService]
        var variantsByAggregatedServiceId: [String: [TVService]]
        var resolvedServicesByUniqueId: [String: TVService]
    }

    private func buildAggregatedServiceData(includesConnectionErrors: Bool) -> AggregatedServiceData
    {
        var variantsByMergedKey: [String: [TVService]] = [:]
        var variantsByAggregatedServiceId: [String: [TVService]] = [:]
        var resolvedServicesByUniqueId: [String: TVService] = [:]

        for config in configStore.configurations {
            let shouldInclude =
                includesConnectionErrors
                ? shouldIncludeServerInServiceListAggregation(serverId: config.id)
                : shouldIncludeServerInAggregation(serverId: config.id)
            guard shouldInclude else { continue }

            let cachedServices = cachedServicesByServer[config.id] ?? []

            for service in cachedServices {
                let mergedKey = service.unifiedServiceKey
                var resolvedService = service
                resolvedService.favoritedAt =
                    favoriteStatesByUnifiedKey[mergedKey] != nil ? .distantPast : nil
                variantsByMergedKey[mergedKey, default: []].append(resolvedService)
                resolvedServicesByUniqueId[resolvedService.id] = resolvedService
            }
        }

        var mergedServices: [TVService] = []
        for (_, variants) in variantsByMergedKey {
            let sortedVariants = sortServicesByServerPriority(variants)
            guard let preferred = preferredServiceVariant(from: sortedVariants) else { continue }

            mergedServices.append(preferred)
            variantsByAggregatedServiceId[preferred.id] = sortedVariants
        }

        return AggregatedServiceData(
            services: mergedServices,
            variantsByAggregatedServiceId: variantsByAggregatedServiceId,
            resolvedServicesByUniqueId: resolvedServicesByUniqueId
        )
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

    private func shouldIncludeServerInAggregation(serverId: String) -> Bool {
        guard isServerEnabled(serverId) else { return false }
        guard serverSupports(.live, serverId: serverId) else { return false }
        guard let state = connectionStates[serverId] else { return true }
        return state.status != .error
    }

    private func shouldIncludeServerInServiceListAggregation(serverId: String) -> Bool {
        guard isServerEnabled(serverId) else { return false }
        return serverSupports(.live, serverId: serverId)
    }

    private func sortServicesByServerPriority(_ services: [TVService]) -> [TVService] {
        let order = Dictionary(
            uniqueKeysWithValues: configStore.configurations.enumerated().map { ($1.id, $0) })
        return services.sorted { lhs, rhs in
            let lConnected = connectionStates[lhs.serverId]?.status == .connected
            let rConnected = connectionStates[rhs.serverId]?.status == .connected
            if lConnected != rConnected {
                return lConnected
            }
            return (order[lhs.serverId] ?? Int.max) < (order[rhs.serverId] ?? Int.max)
        }
    }

    private func preferredServiceVariant(from variants: [TVService]) -> TVService? {
        variants.first
    }

    private func fetchLogoData(
        for services: [TVService],
        provider: any LiveServerProvider
    ) async
        -> [TVServiceLogo]
    {
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
        favoriteStatesByUnifiedKey[service.unifiedServiceKey] != nil
    }

    func favoriteDisplayOrder(for service: TVService) -> Int? {
        favoriteStatesByUnifiedKey[service.unifiedServiceKey]?.displayOrder
    }

    var hasFavoriteServices: Bool {
        !favoriteStatesByUnifiedKey.isEmpty
    }

    func toggleFavorite(_ service: TVService) async {
        await setFavorite(service, isFavorite: !isFavorite(service))
    }

    func setFavorite(_ service: TVService, isFavorite: Bool) async {
        let key = service.unifiedServiceKey

        if isFavorite {
            let currentState = favoriteStatesByUnifiedKey[key]
            let nextState = FavoriteServiceState(
                displayOrder: currentState?.displayOrder ?? nextFavoriteDisplayOrder()
            )
            await cacheStore.saveFavoriteService(
                service,
                displayOrder: nextState.displayOrder
            )
            favoriteStatesByUnifiedKey[key] = nextState
        } else {
            await cacheStore.deleteFavoriteService(service)
            favoriteStatesByUnifiedKey.removeValue(forKey: key)
        }

        rebuildAggregatedData()
    }

    func setFavoriteDisplayOrders(_ serviceKeysByGroup: [[String]]) async {
        var updatedRecords: [FavoriteServiceRecord] = []

        for (displayOrder, serviceKeys) in serviceKeysByGroup.enumerated() {
            for serviceKey in serviceKeys {
                guard favoriteStatesByUnifiedKey[serviceKey] != nil else { continue }
                favoriteStatesByUnifiedKey[serviceKey] = FavoriteServiceState(
                    displayOrder: displayOrder
                )

                if let record = FavoriteServiceRecord(
                    unifiedServiceKey: serviceKey,
                    displayOrder: displayOrder
                ) {
                    updatedRecords.append(record)
                }
            }
        }

        await cacheStore.saveFavoriteServices(updatedRecords)
        rebuildAggregatedData()
    }

    private func nextFavoriteDisplayOrder() -> Int? {
        let currentOrders = favoriteStatesByUnifiedKey.values.compactMap(\.displayOrder)
        guard let maxOrder = currentOrders.max() else { return nil }
        return maxOrder + 1
    }

    func playbackCandidates(for service: TVService) -> [TVService] {
        candidateServices(for: service)
    }

    func connectedPlaybackCandidates(for service: TVService) -> [TVService] {
        candidateServices(for: service).filter {
            connectionStates[$0.serverId]?.status == .connected
        }
    }

    func reconnectionCandidates(for service: TVService) -> [TVService] {
        serviceListCandidateServices(for: service).filter {
            connectionStates[$0.serverId]?.status != .connected
        }
    }

    func playbackReconnectionState(for service: TVService) -> PlaybackReconnectionState {
        let connectedCandidates = connectedPlaybackCandidates(for: service)
        let reconnectionCandidates = reconnectionCandidates(for: service)
        let hasConnectingCandidate = reconnectionCandidates.contains {
            connectionStates[$0.serverId]?.status == .connecting
        }

        return PlaybackReconnectionState(
            needsReconnection: connectedCandidates.isEmpty && !reconnectionCandidates.isEmpty,
            hasConnectingCandidate: hasConnectingCandidate
        )
    }

    func needsReconnectionForPlayback(_ service: TVService) -> Bool {
        playbackReconnectionState(for: service).needsReconnection
    }

    private func candidateServices(for service: TVService) -> [TVService] {
        if let variants = serviceVariantsByAggregatedServiceId[service.id] {
            return sortServicesByServerPriority(variants).filter {
                isServerEnabled($0.serverId) && serverSupports(.live, serverId: $0.serverId)
            }
        }
        guard isServerEnabled(service.serverId),
            serverSupports(.live, serverId: service.serverId)
        else { return [] }
        return [service]
    }

    private func serviceListCandidateServices(for service: TVService) -> [TVService] {
        if let variants = serviceListVariantsByAggregatedServiceId[service.id] {
            return sortServicesByServerPriority(variants).filter {
                isServerEnabled($0.serverId) && serverSupports(.live, serverId: $0.serverId)
            }
        }
        return candidateServices(for: service)
    }

    func serverDisplayName(_ serverId: String) -> String {
        serverName(serverId)
    }

    func serverFullDisplayName(_ serverId: String) -> String {
        let name = serverName(serverId)
        let typeName = serverTypeName(serverId)
        if typeName.isEmpty {
            return name
        }
        return "\(name) (\(typeName))"
    }

    func serverName(_ serverId: String) -> String {
        let config = configStore.configurations.first(where: { $0.id == serverId })
        if let config {
            return config.name
        }
        return serverId
    }

    func serverTypeName(_ serverId: String) -> String {
        let config = configStore.configurations.first(where: { $0.id == serverId })
        if let config {
            return config.type.displayName
        }
        return ""
    }

    func liveProvider(for serverId: String) -> (any LiveServerProvider)? {
        guard isServerEnabled(serverId) else { return nil }
        guard serverSupports(.live, serverId: serverId) else { return nil }
        return providers[serverId] as? (any LiveServerProvider)
    }

    func recordingProvider(for serverId: String) -> (any RecordingServerProvider)? {
        guard isServerEnabled(serverId) else { return nil }
        guard serverSupports(.recording, serverId: serverId) else { return nil }
        return providers[serverId] as? (any RecordingServerProvider)
    }

    func fetchRecords(serverId: String, pageToken: String?, limit: Int, keyword: String?)
        async throws -> RecordsResult
    {
        guard let provider = recordingProvider(for: serverId) else {
            throw ServerManagerError.recordingServerUnavailable
        }
        loadingTaskCount += 1
        defer { loadingTaskCount = max(0, loadingTaskCount - 1) }
        do {
            return try await provider.fetchRecords(
                pageToken: pageToken, limit: limit, keyword: keyword)
        } catch {
            noteCommunicationFailure(for: error)
            throw error
        }
    }

    func fetchRecord(serverId: String, id: String) async throws -> Recorded {
        guard let provider = recordingProvider(for: serverId) else {
            throw ServerManagerError.recordingServerUnavailable
        }
        loadingTaskCount += 1
        defer { loadingTaskCount = max(0, loadingTaskCount - 1) }
        do {
            return try await provider.fetchRecord(id: id)
        } catch {
            noteCommunicationFailure(for: error)
            throw error
        }
    }

    func fetchRecordThumbnail(serverId: String, id: String) async throws -> Data? {
        guard let provider = recordingProvider(for: serverId) else {
            throw ServerManagerError.recordingServerUnavailable
        }
        return try await provider.fetchRecordThumbnail(id: id)
    }

    var recordingServerIds: [String] {
        let _ = serverSyncCount
        let ids = configStore.configurations
            .filter { $0.features.contains(.recording) && isServerEnabled($0.id) }
            .map(\.id)
        return ids
    }

    func isServerEnabled(_ serverId: String) -> Bool {
        return configStore.isEnabled(serverId)
    }

    private func serverSupports(_ feature: ServerFeature, serverId: String) -> Bool {
        return configStore.configurations
            .first(where: { $0.id == serverId })?
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
