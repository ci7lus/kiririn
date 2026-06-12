import ARIBStandardKit
import Foundation
import Testing

@testable import kiririn

struct ModelBehaviorTests {

    @Test func backendTypeFlagsReflectSupportedFeatures() {
        #expect(BackendType.mirakurun.requiresBaseURL)
        #expect(BackendType.mirakurun.supportsLive)
        #expect(!BackendType.mirakurun.supportsRecording)

        #expect(!BackendType.googledrive.requiresBaseURL)
        #expect(!BackendType.googledrive.supportsLive)
        #expect(BackendType.googledrive.supportsRecording)
    }

    @Test func backendConfigurationDecodingDefaultsFeatureFlagsFromBackendType() throws {
        let json = """
            {
              \"id\": \"backend\",
              \"name\": \"Main\",
              \"type\": \"epgstation\",
              \"baseURL\": \"https://example.com/api\"
            }
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(BackendConfiguration.self, from: json)

        #expect(decoded.liveEnabled)
        #expect(decoded.recordingEnabled)
        #expect(decoded.features == [.live, .recording])
        #expect(decoded.effectiveBaseURL == URL(string: "https://example.com/api/"))
    }

    @Test func backendConfigurationFeaturesRespectExplicitFlags() {
        let configuration = BackendConfiguration(
            id: "backend",
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
            backendId: "backend"
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
            backendId: "backend"
        )

        #expect(recorded.displayDate == referenceDate)
        #expect(recorded.playableID == "rec-backend-record-variant-a")
    }

    @Test func localRecordPathRecordIDPercentEncodesReservedCharacters() {
        let encoded = LocalRecordPath.recordID(backendId: "backend/main", recordID: "record id?#1")

        #expect(encoded == "backendmainrecordid1")
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
                backendId: "backend"
            )
        )
        let createdAt = Date(timeIntervalSince1970: 567)

        let downloading = LocalRecordItem(
            id: "item",
            backendId: "backend",
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
            backendId: "backend",
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
            backendId: "backend",
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
                == Playable.stableID(for: .fileURL(downloading.localVideoURL, bookmarkData: nil)))
    }

    @Test func backendConnectionStateStartsDisconnected() {
        let state = BackendConnectionState(backendId: "backend", isEnabled: false)

        #expect(state.backendId == "backend")
        #expect(!state.isEnabled)
        #expect(state.status == .disconnected)
        #expect(state.lastError == nil)
        #expect(state.lastConnectedAt == nil)
    }

    @Test func programCatalogRefreshDecisionHonorsIntervalAndManualForce() {
        let now = Date(timeIntervalSince1970: 50_000)
        let interval = 12.0 * 60 * 60
        let recent = now.addingTimeInterval(-(6 * 60 * 60))
        let stale = now.addingTimeInterval(-(13 * 60 * 60))

        #expect(
            BackendManager.resolveProgramCatalogRefreshDecision(
                policy: .automaticIfDue,
                lastFetchedAt: recent,
                now: now,
                interval: interval,
                networkAllowsRefresh: true
            ) == .skip
        )
        #expect(
            BackendManager.resolveProgramCatalogRefreshDecision(
                policy: .automaticIfDue,
                lastFetchedAt: stale,
                now: now,
                interval: interval,
                networkAllowsRefresh: true
            ) == .fetchNow
        )
        #expect(
            BackendManager.resolveProgramCatalogRefreshDecision(
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

        #expect(!BackendManager.allowsProgramCatalogRefresh(requiresWiFi: true, isOnWiFi: false))
        #expect(BackendManager.allowsProgramCatalogRefresh(requiresWiFi: false, isOnWiFi: false))
        #expect(
            BackendManager.resolveProgramCatalogRefreshDecision(
                policy: .automaticIfDue,
                lastFetchedAt: stale,
                now: now,
                interval: interval,
                networkAllowsRefresh: false
            ) == .queueUntilWiFi
        )
        #expect(
            BackendManager.resolveProgramCatalogRefreshDecision(
                policy: .force,
                lastFetchedAt: now,
                now: now,
                interval: interval,
                networkAllowsRefresh: false
            ) == .queueUntilWiFi
        )
        #expect(
            BackendManager.resolveProgramCatalogRefreshDecision(
                policy: .forceIgnoringNetwork,
                lastFetchedAt: now,
                now: now,
                interval: interval,
                networkAllowsRefresh: false
            ) == .fetchNow
        )
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
