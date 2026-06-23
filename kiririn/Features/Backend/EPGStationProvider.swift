import ARIBStandardKit
import Foundation
import OrderedCollections

final class EPGStationProvider: LiveBackendProvider, RecordingBackendProvider {
    let configuration: BackendConfiguration
    private let client: APIClient
    private var channels: [Int64: EPGStationChannel] = [:]
    private var recordedItems: [Int64: EPGStationRecordedItem] = [:]
    private let broadcastStore = BroadcastStore()

    private var isLiveEnabled: Bool {
        configuration.features.contains(.live)
    }

    private var isRecordingEnabled: Bool {
        configuration.features.contains(.recording)
    }

    init(configuration: BackendConfiguration) {
        self.configuration = configuration
        self.client = APIClient(configuration: configuration)
    }

    func checkConnection() async throws -> String? {
        async let configTask: EPGStationConfig = client.request(path: "api/config")
        async let versionTask: String? = fetchVersion()

        let config = try await configTask
        let version = await versionTask
        await broadcastStore.update(config.broadcast ?? [:])
        return version
    }

    private func fetchVersion() async -> String? {
        do {
            let info: EPGStationVersionInfo = try await client.request(path: "api/version")
            return info.version
        } catch {
            return nil
        }
    }

    func fetchHeaders() async throws -> [String: String] {
        client.defaultHeaders
    }

    private func fetchEPGStationServices(isCacheAllowed: Bool = false) async throws -> [Int64:
        EPGStationChannel]
    {
        if isCacheAllowed && !channels.isEmpty {
            return channels
        }
        let response: [EPGStationChannel] = try await client.request(path: "api/channels")
        channels = Dictionary(uniqueKeysWithValues: response.map { ($0.id, $0) })
        return channels
    }

    func fetchServices() async throws -> [TVService] {
        guard isLiveEnabled else { return [] }
        return (try await fetchEPGStationServices()).values.map {
            $0.toTVService(backendId: configuration.id)
        }
    }

    func fetchPrograms() async throws -> [Program] {
        guard isLiveEnabled else { return [] }
        let currentBroadcast = await broadcastStore.current()

        let startAt = Int(Date().timeIntervalSince1970)
        let endAt = startAt + 60 * 60 * 24 * 7

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "startAt", value: "\(startAt)"),
            URLQueryItem(name: "endAt", value: "\(endAt)"),
            URLQueryItem(name: "isHalfWidth", value: "true"),
        ]
        for (key, enabled) in currentBroadcast where enabled {
            queryItems.append(URLQueryItem(name: key, value: "true"))
        }

        let response: [EPGStationScheduleChannel] = try await client.request(
            path: "api/schedules",
            queryItems: queryItems
        )
        return response.flatMap { channel in
            channel.programs.map {
                $0.toProgram(channel: channel.channel, backendId: configuration.id)
            }
        }
    }

    func buildLiveStreamPlayable(service: TVService, currentProgram: Program?) throws -> Playable {
        guard let providerIdentifier = service.providerIdentifier,
            let streamURL = client.buildStreamURL(
                path: "api/streams/live/\(providerIdentifier)/m2ts",
                queryItems: [URLQueryItem(name: "mode", value: "0")]
            )
        else {
            throw APIError.invalidURL
        }
        return Playable(
            streamURL: streamURL,
            headers: client.defaultHeaders,
            backendId: configuration.id,
            source: .liveService(serviceUniqueId: service.id),
            program: currentProgram,
            service: service
        )
    }

    func fetchRecords(pageToken: String?, limit: Int, keyword: String?) async throws
        -> RecordsResult
    {
        guard isRecordingEnabled else { return RecordsResult(records: [], nextPageToken: nil) }
        let offset = Int(pageToken ?? "0") ?? 0
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "isHalfWidth", value: "true"),
        ]
        if let keyword, !keyword.isEmpty {
            queryItems.append(URLQueryItem(name: "keyword", value: keyword))
        }
        let response: EPGStationRecordsResponse = try await client.request(
            path: "api/recorded",
            queryItems: queryItems
        )
        let chs = try await fetchEPGStationServices(isCacheAllowed: true)
        let records = response.records.map {
            $0.toRecord(backendId: configuration.id, channel: chs[$0.channelId ?? 0] ?? nil)
        }
        for record in response.records {
            recordedItems[record.id] = record
        }

        let nextOffset = offset + records.count
        let nextPageToken = nextOffset < response.total ? "\(nextOffset)" : nil

        return RecordsResult(records: records, nextPageToken: nextPageToken)
    }

    func fetchRecord(id: String) async throws -> Recorded {
        guard isRecordingEnabled else {
            throw URLError(.dataNotAllowed)
        }
        let raw: EPGStationRecordedItem = try await client.request(
            path: "api/recorded/\(id)",
            queryItems: [URLQueryItem(name: "isHalfWidth", value: "true")]
        )
        recordedItems[raw.id] = raw
        let chs = try await fetchEPGStationServices(isCacheAllowed: true)
        return raw.toRecord(backendId: configuration.id, channel: chs[raw.channelId ?? 0] ?? nil)
    }

    func fetchServiceLogoData(for service: TVService) async throws -> Data? {
        if !service.hasLogoData {
            return nil
        }
        guard let providerIdentifier = service.providerIdentifier else { return nil }
        return try await client.requestData(path: "api/channels/\(providerIdentifier)/logo")
    }

    func fetchRecordThumbnail(id: String) async throws -> Data? {
        let item: EPGStationRecordedItem
        if let cached = recordedItems[Int64(id) ?? 0] {
            item = cached
        } else {
            item = try await client.request(
                path: "api/recorded/\(id)",
                queryItems: [URLQueryItem(name: "isHalfWidth", value: "true")]
            )
            recordedItems[item.id] = item
        }
        guard let thumbnailId = item.thumbnails?.first else { return nil }
        return try await client.requestData(path: "api/thumbnails/\(thumbnailId)")
    }

    func buildRecordedPlayable(record: Recorded, variant: RecordedVariant) throws -> Playable {
        guard let streamURL = client.buildStreamURL(path: "api/videos/\(variant.id)") else {
            throw APIError.invalidURL
        }
        return Playable(
            streamURL: streamURL,
            headers: client.defaultHeaders,
            backendId: configuration.id,
            source: .recordedFile(
                recordId: record.id, variantId: variant.id, backendId: record.backendId),
            program: buildRecordedProgram(record: record),
            service: record.synthesizedService()
        )
    }

    private func buildRecordedProgram(record: Recorded) -> Program? {
        record.toProgram()
    }

    private actor BroadcastStore {
        private var value: [String: Bool] = [:]

        func update(_ newValue: [String: Bool]) {
            value = newValue
        }

        func current() -> [String: Bool] {
            value
        }
    }
}

private nonisolated struct EPGStationConfig: Codable, Sendable {
    let broadcast: [String: Bool]?
}

private nonisolated struct EPGStationVersionInfo: Codable, Sendable {
    let version: String?
}

private nonisolated struct EPGStationChannel: Codable, Sendable {
    let id: Int64
    let serviceId: Int
    let networkId: Int
    let name: String
    let halfWidthName: String?
    let hasLogoData: Bool
    let channelType: String?
    let type: Int?
    let remoteControlKeyId: Int?

    func toTVService(backendId: String) -> TVService {
        TVService(
            id: "\(backendId)-\(id)",
            providerIdentifier: "\(id)",
            serviceId: serviceId,
            networkId: networkId,
            transportStreamId: nil,
            name: halfWidthName ?? name,
            type: TVService.ServiceType(rawValue: type ?? 0)
                ?? TVService.ServiceType.digitalTelevision,
            remoteControlKeyId: remoteControlKeyId,
            hasLogoData: hasLogoData,
            channel: channelType != nil
                ? TVService.Channel(id: channelType!, type: channelType!) : nil,
            backendId: backendId
        )
    }
}

private nonisolated struct EPGStationSchedules: Codable, Sendable {
    let programs: [EPGStationProgram]
}

private nonisolated struct EPGStationScheduleChannel: Codable, Sendable {
    let channel: EPGStationChannel
    let programs: [EPGStationProgram]
}

private nonisolated struct EPGStationProgram: Codable, Sendable {
    let id: Int64
    let channelId: Int64
    let startAt: Int64
    let endAt: Int64
    let duration: Int
    let isFree: Bool?
    let name: String?
    let halfWidthName: String?
    let description: String?
    let halfWidthDescription: String?
    let extended: String?
    let halfWidthExtended: String?
    let genres: [EPGStationGenre]?

    func toProgram(channel: EPGStationChannel, backendId: String) -> Program {
        let start = Date(timeIntervalSince1970: TimeInterval(startAt) / 1000.0)
        let end = Date(timeIntervalSince1970: TimeInterval(endAt) / 1000.0)
        let computedDuration = end.timeIntervalSince(start)
        return Program(
            id: "\(id)",
            backendId: backendId,
            eventId: nil,
            serviceId: channel.serviceId,
            networkId: channel.networkId,
            startAt: start,
            endAt: end,
            duration: computedDuration > 0 ? computedDuration : TimeInterval(duration) / 1000.0,
            name: halfWidthName ?? name ?? "",
            desc: halfWidthDescription ?? description,
            extended: Self.parseExtended(halfWidthExtended ?? extended),
            genres: genres?.map { ProgramGenre(lv1: $0.lv1, lv2: $0.lv2) } ?? [],
            updatedAt: nil
        )
    }

    private static func parseExtended(_ raw: String?) -> OrderedDictionary<String, String>? {
        guard let raw, !raw.isEmpty else { return nil }
        let lines = raw.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }
        var result = OrderedDictionary<String, String>()
        var index = 0
        while index + 1 < lines.count {
            let key = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                result[key] = value
            }
            index += 2
        }
        return result.isEmpty ? nil : result
    }
}

private nonisolated struct EPGStationGenre: Codable, Sendable {
    let lv1: Int
    let lv2: Int?
}

private nonisolated struct EPGStationRecordsResponse: Codable, Sendable {
    let records: [EPGStationRecordedItem]
    let total: Int
}

private nonisolated struct EPGStationRecordedItem: Codable, Sendable {
    let id: Int64
    let channelId: Int64?
    let startAt: Int64
    let endAt: Int64
    let name: String?
    let halfWidthName: String?
    let description: String?
    let halfWidthDescription: String?
    let extended: String?
    let halfWidthExtended: String?
    let genres: [EPGStationGenre]?
    let videoFiles: [EPGStationVideoFile]?
    let isRecording: Bool?
    let isProtected: Bool?
    let thumbnails: [Int64]?

    func toRecord(backendId: String, channel: EPGStationChannel?) -> Recorded {
        let start = Date(timeIntervalSince1970: TimeInterval(startAt) / 1000.0)
        let end = Date(timeIntervalSince1970: TimeInterval(endAt) / 1000.0)
        return Recorded(
            id: "\(id)",
            name: halfWidthName ?? name ?? "",
            desc: halfWidthDescription ?? description,
            extended: nil,
            serviceName: channel?.halfWidthName ?? channel?.name,
            serviceId: channel?.serviceId,
            networkId: channel?.networkId,
            startAt: start,
            duration: end.timeIntervalSince(start),
            genres: genres?.map { ProgramGenre(lv1: $0.lv1, lv2: $0.lv2) } ?? [],
            variants: videoFiles?.map { $0.toRecordedVariant() } ?? [],
            isRecording: isRecording ?? false,
            hasThumbnail: (thumbnails?.count ?? 0) > 0,
            backendId: backendId
        )
    }
}

private nonisolated struct EPGStationVideoFile: Codable, Sendable {
    let id: Int64
    let name: String
    let filename: String?
    let type: String
    let size: Int64?

    func toRecordedVariant() -> RecordedVariant {
        RecordedVariant(
            id: "\(id)",
            name: name
        )
    }
}
