import ARIBStandardKit
import Foundation
import GRDB
import Testing

@testable import kiririn

struct ModelBehaviorTests {

    @Test func serverTypeFlagsReflectSupportedFeatures() {
        #expect(ServerType.mirakurun.requiresBaseURL)
        #expect(ServerType.mirakurun.supportsLive)
        #expect(!ServerType.mirakurun.supportsRecording)

        #expect(!ServerType.googledrive.requiresBaseURL)
        #expect(!ServerType.googledrive.supportsLive)
        #expect(ServerType.googledrive.supportsRecording)
    }

    @Test func serverConfigurationDecodingDefaultsFeatureFlagsFromServerType() throws {
        let json = """
            {
              \"id\": \"server\",
              \"name\": \"Main\",
              \"type\": \"epgstation\",
              \"baseURL\": \"https://example.com/api\"
            }
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: json)

        #expect(decoded.liveEnabled)
        #expect(decoded.recordingEnabled)
        #expect(decoded.features == [.live, .recording])
        #expect(decoded.effectiveBaseURL == URL(string: "https://example.com/api/"))
    }

    @Test func serverConfigurationFeaturesRespectExplicitFlags() {
        let configuration = ServerConfiguration(
            id: "server",
            name: "Drive",
            type: .googledrive,
            baseURL: nil,
            liveEnabled: true,
            recordingEnabled: true
        )

        #expect(!configuration.supports(.live))
        #expect(configuration.supports(.recording))
        #expect(configuration.features == [.recording])
        #expect(configuration.effectiveBaseURL == nil)
    }

    @Test func tvServiceKeepsRawNameForBroadcastTextRendering() {
        let service = TVService(
            id: "service",
            serviceId: 10,
            networkId: 20,
            transportStreamId: nil,
            name: "🈐テストサービス",
            type: .uhdtv,
            remoteControlKeyId: 1,
            hasLogoData: true,
            channel: .init(id: "gr011", type: "GR"),
            serverId: "server"
        )

        #expect(service.name == "🈐テストサービス")
        #expect(service.unifiedServiceKey == "20-10")
        #expect(service.type.description == "4K/8K放送 (UHDTV)")
        #expect(service.name.aribBroadcastDisplaySegments().map(\.text) == ["手", "テストサービス"])
    }

    @Test func recordedDisplayDateFallsBackToReferenceDateAndPlayableIDUsesFirstVariant() {
        let referenceDate = Date(timeIntervalSince1970: 1_234)
        let recorded = Recorded(
            id: "record",
            name: "録画",
            desc: nil,
            extended: nil,
            serviceName: nil,
            startAt: nil,
            duration: 120,
            referenceDate: referenceDate,
            genres: [],
            variants: [.init(id: "variant-a", name: "HD")],
            isRecording: false,
            hasThumbnail: false,
            serverId: "server"
        )

        #expect(recorded.displayDate == referenceDate)
        #expect(recorded.playableID == "rec-server-record-variant-a")
    }

    @Test func localRecordPathRecordIDPercentEncodesReservedCharacters() {
        let encoded = LocalRecordPath.recordID(
            serverId: "server/main", recordID: "record id?#1")

        #expect(encoded == "server%2Fmain%5Frecord%20id%3F%231")
    }

    @Test func localRecordItemUsesPersistedStateWhileVideoFileIsMissing() throws {
        let payload = try JSONEncoder().encode(
            Recorded(
                id: "record",
                name: "録画",
                desc: nil,
                extended: nil,
                serviceName: "サービス",
                startAt: nil,
                duration: nil,
                referenceDate: nil,
                genres: [],
                variants: [.init(id: "variant", name: "HD")],
                isRecording: false,
                hasThumbnail: false,
                serverId: "server"
            )
        )
        let createdAt = Date(timeIntervalSince1970: 567)

        let downloading = LocalRecordItem(
            id: "item",
            serverId: "server",
            name: "動画",
            serviceName: nil,
            startAt: nil,
            duration: nil,
            data: payload,
            videoFileName: "missing.ts",
            thumbnailData: nil,
            downloadStateRaw: LocalRecordItem.DownloadState.downloading.rawValue,
            createdAt: createdAt
        )
        let failed = LocalRecordItem(
            id: "item",
            serverId: "server",
            name: "動画",
            serviceName: nil,
            startAt: nil,
            duration: nil,
            data: payload,
            videoFileName: "missing.ts",
            thumbnailData: nil,
            downloadStateRaw: LocalRecordItem.DownloadState.failed.rawValue,
            downloadErrorMessage: "network",
            createdAt: createdAt
        )
        let missing = LocalRecordItem(
            id: "item",
            serverId: "server",
            name: "動画",
            serviceName: nil,
            startAt: nil,
            duration: nil,
            data: payload,
            videoFileName: "missing.ts",
            thumbnailData: nil,
            downloadStateRaw: LocalRecordItem.DownloadState.downloaded.rawValue,
            createdAt: createdAt
        )

        #expect(downloading.downloadState == .downloading)
        #expect(failed.downloadState == .failed)
        #expect(missing.downloadState == .missing)
        #expect(downloading.displayDate == createdAt)
        #expect(downloading.recorded?.id == "record")
        #expect(
            downloading.playableID
                == Playable.stableID(for: .fileURL(downloading.localVideoURL, bookmarkData: nil))
        )
    }

    @Test func serverConnectionStateStartsDisconnected() {
        let state = ServerConnectionState(serverId: "server", isEnabled: false)

        #expect(state.serverId == "server")
        #expect(!state.isEnabled)
        #expect(state.status == .disconnected)
        #expect(state.lastError == nil)
        #expect(state.lastErrorDetail == nil)
        #expect(state.lastConnectedAt == nil)
    }

    @Test @MainActor func playbackCandidatesUseStableManagerSnapshot() {
        guard let defaults = UserDefaults(suiteName: "kiririn.tests.\(UUID().uuidString)") else {
            return
        }
        let configuration = ServerConfiguration(
            id: "server",
            name: "Main",
            type: .mirakurun,
            baseURL: "https://example.com"
        )
        let configStore = ServerConfigStore(localDefaults: defaults)
        configStore.configurations = [configuration]
        configStore.enabledStates[configuration.id] = true
        let manager = ServerManager(configStore: configStore)
        let service = TVService(
            id: "service",
            serviceId: 10,
            networkId: 20,
            transportStreamId: nil,
            name: "サービス",
            type: .digitalTelevision,
            remoteControlKeyId: nil,
            hasLogoData: false,
            channel: nil,
            serverId: configuration.id
        )

        #expect(manager.playbackCandidates(for: service).map(\.id) == [service.id])
        let revision = manager.playbackCandidatesRevision

        manager.serverAvailabilityDidChange()

        #expect(manager.playbackCandidatesRevision > revision)
        #expect(manager.playbackCandidates(for: service).map(\.id) == [service.id])
    }

    @Test @MainActor func connectedTransitionRefreshesPlaybackCandidateOrder() async throws {
        guard let defaults = UserDefaults(suiteName: "kiririn.tests.\(UUID().uuidString)") else {
            return
        }
        let configurations = [
            ServerConfiguration(
                id: "server-a",
                name: "A",
                type: .mirakurun,
                baseURL: "https://a.example.com"
            ),
            ServerConfiguration(
                id: "server-b",
                name: "B",
                type: .mirakurun,
                baseURL: "https://b.example.com"
            ),
        ]
        let configStore = ServerConfigStore(localDefaults: defaults)
        configStore.configurations = configurations
        configStore.enabledStates = ["server-a": true, "server-b": true]
        let cacheStore = CacheStore(databaseQueue: try DatabaseQueue())
        let serviceA = TVService(
            id: "service-a",
            serviceId: 10,
            networkId: 20,
            transportStreamId: nil,
            name: "A",
            type: .digitalTelevision,
            remoteControlKeyId: nil,
            hasLogoData: false,
            channel: nil,
            serverId: "server-a"
        )
        let serviceB = TVService(
            id: "service-b",
            serviceId: 10,
            networkId: 20,
            transportStreamId: nil,
            name: "B",
            type: .digitalTelevision,
            remoteControlKeyId: nil,
            hasLogoData: false,
            channel: nil,
            serverId: "server-b"
        )
        await cacheStore.cacheServices([serviceA], serverId: "server-a")
        await cacheStore.cacheServices([serviceB], serverId: "server-b")

        let manager = ServerManager(configStore: configStore)
        await manager.setCacheStore(cacheStore)
        guard let aggregatedService = manager.services.first else {
            return
        }
        #expect(
            manager.playbackCandidates(for: aggregatedService).map(\.serverId)
                == ["server-a", "server-b"]
        )
        manager.connectionStates["server-b"]?.status = .connected
        manager.serverAvailabilityDidChange()
        guard let reorderedService = manager.services.first else {
            return
        }

        #expect(
            manager.playbackCandidates(for: reorderedService).map(\.serverId)
                == ["server-b", "server-a"]
        )
    }

    @Test func programCatalogRefreshDecisionHonorsIntervalAndManualForce() {
        let now = Date(timeIntervalSince1970: 50_000)
        let interval = 12.0 * 60 * 60
        let recent = now.addingTimeInterval(-(6 * 60 * 60))
        let stale = now.addingTimeInterval(-(13 * 60 * 60))

        #expect(
            ServerManager.resolveProgramCatalogRefreshDecision(
                policy: .automaticIfDue,
                lastFetchedAt: recent,
                now: now,
                interval: interval,
                networkAllowsRefresh: true
            ) == .skip
        )
        #expect(
            ServerManager.resolveProgramCatalogRefreshDecision(
                policy: .automaticIfDue,
                lastFetchedAt: stale,
                now: now,
                interval: interval,
                networkAllowsRefresh: true
            ) == .fetchNow
        )
        #expect(
            ServerManager.resolveProgramCatalogRefreshDecision(
                policy: .forceIgnoringNetwork,
                lastFetchedAt: recent,
                now: now,
                interval: interval,
                networkAllowsRefresh: false
            ) == .fetchNow
        )
    }

    @Test func programCatalogRefreshDecisionQueuesUntilWiFiWhenRequired() {
        let now = Date(timeIntervalSince1970: 50_000)
        let interval = 12.0 * 60 * 60
        let stale = now.addingTimeInterval(-(13 * 60 * 60))

        #expect(!ServerManager.allowsProgramCatalogRefresh(requiresWiFi: true, isOnWiFi: false))
        #expect(ServerManager.allowsProgramCatalogRefresh(requiresWiFi: false, isOnWiFi: false))
        #expect(
            ServerManager.resolveProgramCatalogRefreshDecision(
                policy: .automaticIfDue,
                lastFetchedAt: stale,
                now: now,
                interval: interval,
                networkAllowsRefresh: false
            ) == .queueUntilWiFi
        )
        #expect(
            ServerManager.resolveProgramCatalogRefreshDecision(
                policy: .force,
                lastFetchedAt: now,
                now: now,
                interval: interval,
                networkAllowsRefresh: false
            ) == .queueUntilWiFi
        )
        #expect(
            ServerManager.resolveProgramCatalogRefreshDecision(
                policy: .forceIgnoringNetwork,
                lastFetchedAt: now,
                now: now,
                interval: interval,
                networkAllowsRefresh: false
            ) == .fetchNow
        )
    }

    @Test func programCatalogRefreshPolicyMergesToStrongestRequest() {
        #expect(
            ProgramCatalogRefreshPolicy.none.merged(with: .automaticIfDue)
                == .automaticIfDue
        )
        #expect(
            ProgramCatalogRefreshPolicy.automaticIfDue.merged(with: .force)
                == .force
        )
        #expect(
            ProgramCatalogRefreshPolicy.force.merged(with: .forceIgnoringNetwork)
                == .forceIgnoringNetwork
        )
        #expect(ProgramCatalogRefreshPolicy.force.satisfies(.automaticIfDue))
        #expect(!ProgramCatalogRefreshPolicy.force.satisfies(.forceIgnoringNetwork))
    }

    @Test func playableSourceLegacyDirectURLArrayDecodesFileURLsAsFileSource() throws {
        let url = URL(filePath: "/tmp/video.ts")
        let jsonData = "{\"directURL\":[\"\(url.absoluteString)\",null]}".data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PlayableSource.self, from: jsonData)

        var matchedFileURL = false
        if case .fileURL(let decodedURL, let bookmarkData) = decoded {
            matchedFileURL = true
            #expect(decodedURL == url)
            #expect(bookmarkData == nil)
        }
        #expect(matchedFileURL)
        #expect(decoded.isRestorablePositionSource)
    }

    @Test func playableProgramOverrideCanInferMissingStartAt() {
        let endAt = Date(timeIntervalSince1970: 5_000)
        let override = PlayableProgramOverride(
            serviceId: 10,
            networkId: 20,
            endAt: endAt,
            duration: 120,
            name: "特番"
        )

        let resolved = override.toProgramOrNil()

        #expect(resolved?.startAt == endAt.addingTimeInterval(-120))
        #expect(resolved?.endAt == endAt)
        #expect(resolved?.duration == 120)
        #expect(resolved?.name == "特番")
    }

    @Test func playableServiceOverrideRequiresServiceAndNetworkIDs() {
        let missingIDs = PlayableServiceOverride(name: "Only Name")
        let resolved = PlayableServiceOverride(serviceId: 10, networkId: 20, name: "Override")
            .toServiceOrNil()

        #expect(missingIDs.toServiceOrNil() == nil)
        #expect(resolved?.id == "override-20-10")
        #expect(resolved?.name == "Override")
    }

    @Test func playableRawTitleFallsBackToFileNameAndHost() {
        let fileURLPlayable = Playable(
            streamURL: URL(filePath: "/tmp/clip.ts"),
            source: .fileURL(URL(filePath: "/tmp/clip.ts"), bookmarkData: nil)
        )
        let remotePlayable = Playable(
            streamURL: URL(string: "https://example.com")!,
            source: .directURL(URL(string: "https://example.com")!)
        )

        #expect(fileURLPlayable.title == "clip.ts")
        #expect(remotePlayable.title == "example.com")
    }
}
