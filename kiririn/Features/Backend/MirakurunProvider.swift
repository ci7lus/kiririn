import ARIBStandardKit
import Foundation
import OrderedCollections

final class MirakurunProvider: LiveBackendProvider {
    let configuration: BackendConfiguration
    private let client: APIClient

    init(configuration: BackendConfiguration) {
        self.configuration = configuration
        self.client = APIClient(configuration: configuration)
    }

    func checkConnection() async throws {
        let _: MirakurunStatus = try await client.request(path: "api/status")
    }

    func fetchHeaders() async throws -> [String: String] {
        client.defaultHeaders
    }

    func fetchServices() async throws -> [TVService] {
        let raw: [MirakurunService] = try await client.request(path: "api/services")
        return raw.map { $0.toTVService(backendId: configuration.id) }
    }

    func fetchPrograms() async throws -> [Program] {
        let raw: [MirakurunProgram] = try await client.request(path: "api/programs")
        return raw.map { $0.toProgram(backendId: configuration.id) }
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
            backendId: configuration.id,
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

    func toTVService(backendId: String) -> TVService {
        TVService(
            id: "\(backendId)-\(id)",
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
            backendId: backendId,
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

    func toProgram(backendId: String) -> Program {
        let startAt = Date(timeIntervalSince1970: TimeInterval(startAt) / 1000.0)
        let duration = TimeInterval(duration) / 1000.0
        return Program(
            id: "\(id)",
            backendId: backendId,
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
