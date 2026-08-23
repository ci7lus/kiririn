import Foundation
import KppxKit
import Logging

@MainActor
final class PlaybackOpenCoordinator {
    private enum Target: Hashable {
        case url(String)
        case service(networkId: Int, serviceId: Int)
    }

    private let logger = Logger(label: "PlaybackOpenCoordinator")
    private let manager: ServerManager
    private let playerState: PlayerState
    private var activePlayerStates: [PlayerState] = []
    private var managerSetupWaiter: @MainActor () async -> Void = {}
    private var pendingOpenTasks: [Target: Task<Void, Error>] = [:]
    #if os(macOS)
        private static let pendingOpenTargetTimeout: Duration = .seconds(5)
        private var pendingOpenTargets: Set<Target> = []
        private var pendingOpenTargetExpirationTasks: [Target: Task<Void, Never>] = [:]
    #endif

    init(manager: ServerManager, playerState: PlayerState) {
        self.manager = manager
        self.playerState = playerState
    }

    func configureManagerSetupWaiter(_ waiter: @escaping @MainActor () async -> Void) {
        managerSetupWaiter = waiter
    }

    func register(_ state: PlayerState) {
        guard !activePlayerStates.contains(where: { $0 === state }) else { return }
        activePlayerStates.append(state)
    }

    func unregister(_ state: PlayerState) {
        activePlayerStates.removeAll { $0 === state }
    }

    func openURL(_ rawURL: String) async throws {
        guard let url = Self.validatedMediaURL(from: rawURL) else {
            throw KiririnOpenError.invalidURL
        }

        let target = Target.url(url.absoluteString)
        try await executeOpenRequest(target: target) { [weak self] in
            guard let self else { throw KiririnOpenError.invalidURL }
            try self.performOpenURL(url, target: target)
        }
    }

    func openService(_ request: ServiceOpenRequest) async throws {
        guard
            ServiceOpenRequest.isValidIdentifier(request.networkId),
            ServiceOpenRequest.isValidIdentifier(request.serviceId)
        else {
            throw KiririnOpenError.invalidService
        }

        let preferredServerId = request.preferredServerId?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedRequest = ServiceOpenRequest(
            networkId: request.networkId,
            serviceId: request.serviceId,
            preferredServerId: preferredServerId?.isEmpty == false ? preferredServerId : nil
        )
        let target = Target.service(
            networkId: normalizedRequest.networkId,
            serviceId: normalizedRequest.serviceId
        )

        try await executeOpenRequest(target: target) { [weak self] in
            guard let self else { throw KiririnOpenError.serviceUnavailable }
            try await self.performOpenService(normalizedRequest, target: target)
        }
    }

    #if os(macOS)
        func markOpenRequestStarted(for playable: Playable) {
            guard let target = openTarget(for: playable) else { return }
            clearPendingOpenTarget(target)
        }
    #endif

    func handleOpenDeepLink(components: URLComponents) {
        let pathComponents = components.path.split(separator: "/").map(String.init)
        switch pathComponents {
        case []:
            handleURLDeepLink(components: components)
        case ["service"]:
            handleServiceDeepLink(components: components)
        default:
            logger.warning("deep link open rejected: unsupported path")
        }
    }

    private func handleURLDeepLink(components: URLComponents) {
        guard let mediaURL = parseMediaURL(from: components) else {
            logger.warning("deep link open rejected: invalid media url")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await openURL(mediaURL.absoluteString)
            } catch {
                logger.warning("deep link open rejected: \(error.localizedDescription)")
            }
        }
    }

    private func handleServiceDeepLink(components: URLComponents) {
        guard let request = ServiceOpenRequest(components: components) else {
            logger.warning("deep link service rejected: invalid parameters")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await openService(request)
            } catch {
                logger.warning("deep link service rejected: \(error.localizedDescription)")
            }
        }
    }

    private func executeOpenRequest(
        target: Target,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        if isAlreadyOpen(target) {
            return
        }

        if let pendingTask = pendingOpenTasks[target] {
            try await pendingTask.value
            return
        }

        let task = Task { @MainActor in
            try await operation()
        }
        pendingOpenTasks[target] = task

        do {
            try await task.value
            pendingOpenTasks.removeValue(forKey: target)
        } catch {
            pendingOpenTasks.removeValue(forKey: target)
            throw error
        }
    }

    private func isAlreadyOpen(_ target: Target) -> Bool {
        #if os(macOS)
            if pendingOpenTargets.contains(target) {
                return true
            }
        #endif

        for state in activePlayerStates {
            guard let playable = state.currentPlayable else { continue }
            switch target {
            case .url(let expectedURL):
                guard case .directURL(let currentURL) = playable.source,
                    let normalizedURL = Self.validatedMediaURL(from: currentURL.absoluteString),
                    normalizedURL.absoluteString == expectedURL
                else {
                    continue
                }
                return true
            case .service(let networkId, let serviceId):
                guard case .liveService = playable.source,
                    let service = playable.displayService,
                    service.networkId == networkId,
                    service.serviceId == serviceId
                else {
                    continue
                }
                return true
            }
        }
        return false
    }

    private func performOpenURL(_ url: URL, target: Target) throws {
        guard !isAlreadyOpen(target) else { return }

        let playable = Playable(
            streamURL: url,
            source: .directURL(url)
        )
        dispatchOpenPlayable(playable, target: target)
        logger.info("open URL accepted: \(url.absoluteString)")
    }

    private func performOpenService(
        _ request: ServiceOpenRequest,
        target: Target
    ) async throws {
        await managerSetupWaiter()

        let candidates = manager.playbackCandidates(
            networkId: request.networkId,
            serviceId: request.serviceId,
            preferredServerId: request.preferredServerId
        )
        guard !candidates.isEmpty else {
            throw KiririnOpenError.serviceNotFound
        }

        for initialCandidate in candidates {
            var candidate = initialCandidate
            if manager.connectionStates[candidate.serverId]?.status != .connected {
                _ = await manager.connect(serverId: candidate.serverId)
                guard manager.connectionStates[candidate.serverId]?.status == .connected else {
                    continue
                }
                guard
                    let refreshedCandidate = manager.playbackCandidates(
                        networkId: request.networkId,
                        serviceId: request.serviceId,
                        preferredServerId: candidate.serverId
                    ).first(where: { $0.serverId == candidate.serverId })
                else {
                    continue
                }
                candidate = refreshedCandidate
            }

            guard let provider = manager.liveProvider(for: candidate.serverId) else {
                continue
            }
            let currentProgram = await manager.currentProgram(for: candidate)
            guard
                let playable = try? provider.buildLiveStreamPlayable(
                    service: candidate,
                    currentProgram: currentProgram
                )
            else {
                continue
            }

            if isAlreadyOpen(target) {
                return
            }

            dispatchOpenPlayable(playable, target: target)
            logger.info(
                "open service accepted: networkId=\(request.networkId), serviceId=\(request.serviceId), serverId=\(candidate.serverId)"
            )
            return
        }

        throw KiririnOpenError.serviceUnavailable
    }

    private func dispatchOpenPlayable(_ playable: Playable, target: Target) {
        #if os(macOS)
            markPendingOpenTarget(target)
            NotificationCenter.default.post(name: .requestOpenPlayable, object: playable)
        #else
            playerState.play(playable: playable)
        #endif
    }

    #if os(macOS)
        private func markPendingOpenTarget(_ target: Target) {
            pendingOpenTargets.insert(target)
            pendingOpenTargetExpirationTasks.removeValue(forKey: target)?.cancel()
            pendingOpenTargetExpirationTasks[target] = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: Self.pendingOpenTargetTimeout)
                } catch {
                    return
                }

                guard let self, pendingOpenTargets.remove(target) != nil else { return }
                pendingOpenTargetExpirationTasks.removeValue(forKey: target)
                logger.warning(
                    "open request expired before playback started: \(String(describing: target))")
            }
        }

        private func clearPendingOpenTarget(_ target: Target) {
            pendingOpenTargets.remove(target)
            pendingOpenTargetExpirationTasks.removeValue(forKey: target)?.cancel()
        }

        private func openTarget(for playable: Playable) -> Target? {
            switch playable.source {
            case .directURL(let url):
                guard let normalizedURL = Self.validatedMediaURL(from: url.absoluteString) else {
                    return nil
                }
                return .url(normalizedURL.absoluteString)
            case .liveService:
                guard let service = playable.displayService else { return nil }
                return .service(networkId: service.networkId, serviceId: service.serviceId)
            case .recordedFile, .fileURL:
                return nil
            }
        }
    #endif

    private func parseMediaURL(from components: URLComponents) -> URL? {
        guard let rawValue = components.queryItems?.first(where: { $0.name == "url" })?.value else {
            return nil
        }

        let candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        if let parsedURL = Self.validatedMediaURL(from: candidate) {
            return parsedURL
        }

        if let decodedCandidate = candidate.removingPercentEncoding,
            decodedCandidate != candidate,
            let parsedURL = Self.validatedMediaURL(from: decodedCandidate)
        {
            return parsedURL
        }

        return nil
    }

    nonisolated static func validatedMediaURL(from candidate: String) -> URL? {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedCandidate),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty
        else {
            return nil
        }

        components.scheme = scheme
        return components.url
    }
}
