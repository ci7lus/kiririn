import ARIBStandardKit
import Foundation
import OrderedCollections

final class MirakurunProvider: LiveServerProvider {
    let configuration: ServerConfiguration
    private let client: APIClient

    init(configuration: ServerConfiguration) {
        self.configuration = configuration
        self.client = APIClient(configuration: configuration)
    }

    func checkConnection() async throws -> String? {
        let status: MirakurunStatus = try await client.request(path: "api/status")
        return status.version
    }

    func cancelInFlightRequests() {
        client.cancelInFlightRequests()
    }

    func fetchHeaders() async throws -> [String: String] {
        client.defaultHeaders
    }

    func fetchServices() async throws -> [TVService] {
        let raw: [MirakurunService] = try await client.request(path: "api/services")
        return raw.map { $0.toTVService(serverId: configuration.id) }
    }

    func fetchPrograms() async throws -> [Program] {
        let raw: [MirakurunProgram] = try await client.request(path: "api/programs")
        return raw.map { $0.toProgram(serverId: configuration.id) }
    }

    func fetchServiceLogoData(for service: TVService) async throws -> Data? {
        if !service.hasLogoData {
            return nil
        }
        guard let providerIdentifier = service.providerIdentifier else { return nil }
        return try await client.requestData(path: "api/services/\(providerIdentifier)/logo")
    }

    func buildLiveStreamPlayable(service: TVService, currentProgram: Program?) throws -> Playable {
        guard let providerIdentifier = service.providerIdentifier,
            let streamURL = client.buildStreamURL(path: "api/services/\(providerIdentifier)/stream")
        else {
            throw APIError.invalidURL
        }
        return Playable(
            streamURL: streamURL,
            headers: client.defaultHeaders,
            serverId: configuration.id,
            source: .liveService(serviceUniqueId: service.id),
            program: currentProgram,
            service: service
        )
    }
}

private nonisolated struct MirakurunStatus: Codable, Sendable {
    let time: Int64?
    let version: String?
}

private nonisolated struct MirakurunService: Codable, Sendable {
    let id: Int64
    let serviceId: Int
    let networkId: Int
    let name: String
    let type: Int
    let logoId: Int?
    let hasLogoData: Bool?
    let remoteControlKeyId: Int?
    let transportStreamId: Int?
    let channel: MirakurunChannel?

    func toTVService(serverId: String) -> TVService {
        TVService(
            id: "\(serverId)-\(id)",
            providerIdentifier: "\(id)",
            serviceId: serviceId,
            networkId: networkId,
            transportStreamId: transportStreamId,
            name: name,
            type: TVService.ServiceType(rawValue: type) ?? TVService.ServiceType.digitalTelevision,
            remoteControlKeyId: remoteControlKeyId,
            hasLogoData: hasLogoData ?? false,
            channel: {
                if let c = channel, let ch = c.channel, let ty = c.type {
                    return TVService.Channel(id: ch, type: ty)
                }
                return nil
            }(),
            serverId: serverId,
        )
    }
}

private nonisolated struct MirakurunChannel: Codable, Sendable {
    let type: String?
    let channel: String?
}

private nonisolated struct MirakurunProgram: Codable, Sendable {
    let id: Int64
    let eventId: Int?
    let serviceId: Int
    let networkId: Int
    let startAt: Int64
    let duration: Int
    let isFree: Bool?
    let name: String?
    let description: String?
    let extended: [String: String]?
    let genres: [MirakurunGenre]?

    func toProgram(serverId: String) -> Program {
        let startAt = Date(timeIntervalSince1970: TimeInterval(startAt) / 1000.0)
        let duration = TimeInterval(duration) / 1000.0
        return Program(
            id: "\(id)",
            serverId: serverId,
            eventId: eventId,
            serviceId: serviceId,
            networkId: networkId,
            startAt: startAt,
            endAt: startAt.addingTimeInterval(duration),
            duration: duration,
            name: name ?? "",
            desc: description,
            extended: extended.map { OrderedDictionary(uniqueKeysWithValues: $0) },
            genres: genres?.map { ProgramGenre(lv1: $0.lv1, lv2: $0.lv2) } ?? [],
            updatedAt: nil
        )
    }
}

private nonisolated struct MirakurunGenre: Codable, Sendable {
    let lv1: Int
    let lv2: Int?
}
