import Foundation
import OrderedCollections

nonisolated enum PlayableSource: Codable, Hashable, Sendable {
    case liveService(serviceUniqueId: String)
    case recordedFile(recordId: String, variantId: String, backendId: String)
    case fileURL(URL, bookmarkData: Data?)
    case directURL(URL)

    private enum CodingKeys: String, CodingKey {
        case liveService
        case recordedFile
        case fileURL
        case directURL
    }

    private enum LiveServiceKeys: String, CodingKey {
        case serviceUniqueId
    }

    private enum RecordedFileKeys: String, CodingKey {
        case recordId
        case variantId
        case backendId
    }

    private enum FileURLKeys: String, CodingKey {
        case url
        case bookmarkData
    }

    // Legacy synthesized associated-value coding keys for directURL(URL, bookmarkData: Data?)
    private enum LegacyDirectURLKeys: String, CodingKey {
        case _0
        case bookmarkData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.liveService) {
            let nested = try container.nestedContainer(
                keyedBy: LiveServiceKeys.self, forKey: .liveService)
            self = .liveService(
                serviceUniqueId: try nested.decode(String.self, forKey: .serviceUniqueId))
            return
        }

        if container.contains(.recordedFile) {
            let nested = try container.nestedContainer(
                keyedBy: RecordedFileKeys.self, forKey: .recordedFile)
            self = .recordedFile(
                recordId: try nested.decode(String.self, forKey: .recordId),
                variantId: try nested.decode(String.self, forKey: .variantId),
                backendId: try nested.decode(String.self, forKey: .backendId)
            )
            return
        }

        if container.contains(.fileURL) {
            let nested = try container.nestedContainer(keyedBy: FileURLKeys.self, forKey: .fileURL)
            self = .fileURL(
                try nested.decode(URL.self, forKey: .url),
                bookmarkData: try nested.decodeIfPresent(Data.self, forKey: .bookmarkData)
            )
            return
        }

        if container.contains(.directURL) {
            if let url = try? container.decode(URL.self, forKey: .directURL) {
                self = .directURL(url)
                return
            }

            if let nested = try? container.nestedContainer(
                keyedBy: LegacyDirectURLKeys.self, forKey: .directURL)
            {
                let url = try nested.decode(URL.self, forKey: ._0)
                let bookmarkData = try nested.decodeIfPresent(Data.self, forKey: .bookmarkData)
                if url.isFileURL || bookmarkData != nil {
                    self = .fileURL(url, bookmarkData: bookmarkData)
                } else {
                    self = .directURL(url)
                }
                return
            }

            if var nested = try? container.nestedUnkeyedContainer(forKey: .directURL) {
                let url = try nested.decode(URL.self)
                let bookmarkData = try nested.decodeIfPresent(Data.self)
                if url.isFileURL || bookmarkData != nil {
                    self = .fileURL(url, bookmarkData: bookmarkData)
                } else {
                    self = .directURL(url)
                }
                return
            }
        }

        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unknown PlayableSource format")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .liveService(let serviceUniqueId):
            var nested = container.nestedContainer(
                keyedBy: LiveServiceKeys.self, forKey: .liveService)
            try nested.encode(serviceUniqueId, forKey: .serviceUniqueId)
        case .recordedFile(let recordId, let variantId, let backendId):
            var nested = container.nestedContainer(
                keyedBy: RecordedFileKeys.self, forKey: .recordedFile)
            try nested.encode(recordId, forKey: .recordId)
            try nested.encode(variantId, forKey: .variantId)
            try nested.encode(backendId, forKey: .backendId)
        case .fileURL(let url, let bookmarkData):
            var nested = container.nestedContainer(keyedBy: FileURLKeys.self, forKey: .fileURL)
            try nested.encode(url, forKey: .url)
            try nested.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
        case .directURL(let url):
            try container.encode(url, forKey: .directURL)
        }
    }
}

extension PlayableSource {
    var isRestorablePositionSource: Bool {
        switch self {
        case .recordedFile, .fileURL, .directURL:
            return true
        case .liveService:
            return false
        }
    }
}

nonisolated struct PlayableProgramOverride: Codable, Sendable, Equatable, Hashable {
    var eventId: Int?
    var serviceId: Int?
    var networkId: Int?
    var startAt: Date?
    var endAt: Date?
    var duration: TimeInterval?
    var name: String?
    var desc: String?
    var extended: OrderedDictionary<String, String>?
    var genres: [ProgramGenre]?

    init(
        eventId: Int? = nil,
        serviceId: Int? = nil,
        networkId: Int? = nil,
        startAt: Date? = nil,
        endAt: Date? = nil,
        duration: TimeInterval? = nil,
        name: String? = nil,
        desc: String? = nil,
        extended: OrderedDictionary<String, String>? = nil,
        genres: [ProgramGenre]? = nil
    ) {
        self.eventId = eventId
        self.serviceId = serviceId
        self.networkId = networkId
        self.startAt = startAt
        self.endAt = endAt
        self.duration = duration
        self.name = name
        self.desc = desc
        self.extended = extended
        self.genres = genres
    }

    init(program: Program) {
        self.eventId = program.eventId
        self.serviceId = program.serviceId
        self.networkId = program.networkId
        self.startAt = program.startAt
        self.endAt = program.endAt
        self.duration = program.duration
        self.name = program.name
        self.desc = program.desc
        self.extended = program.extended
        self.genres = program.genres
    }

    func applying(to base: Program) -> Program {
        return Program(
            id: base.id,
            backendId: base.backendId,
            eventId: eventId ?? base.eventId,
            serviceId: serviceId ?? base.serviceId,
            networkId: networkId ?? base.networkId,
            startAt: startAt ?? base.startAt,
            endAt: endAt ?? base.endAt,
            duration: duration ?? base.duration,
            name: name ?? base.name,
            desc: desc ?? base.desc,
            extended: extended ?? base.extended,
            genres: genres ?? base.genres,
            updatedAt: nil
        )
    }

    func toProgramOrNil() -> Program? {
        let resolvedStartAt: Date?
        if let startAt {
            resolvedStartAt = startAt
        } else if let endAt, let duration {
            resolvedStartAt = endAt.addingTimeInterval(-duration)
        } else {
            resolvedStartAt = nil
        }

        let resolvedDuration: TimeInterval?
        if let duration {
            resolvedDuration = duration
        } else if let startAt = resolvedStartAt, let endAt {
            resolvedDuration = endAt.timeIntervalSince(startAt)
        } else {
            resolvedDuration = nil
        }

        guard let startAt = resolvedStartAt,
            let duration = resolvedDuration
        else {
            return nil
        }
        let endAt = endAt ?? startAt.addingTimeInterval(duration)

        return Program(
            id:
                "override-\(Int(startAt.timeIntervalSince1970))-\(serviceId ?? 0)-\(networkId ?? 0)",
            backendId: "override",
            eventId: eventId,
            serviceId: serviceId ?? 0,
            networkId: networkId ?? 0,
            startAt: startAt,
            endAt: endAt,
            duration: duration,
            name: name ?? "不明",
            desc: desc,
            extended: extended,
            genres: genres ?? [],
            updatedAt: nil
        )
    }
}

nonisolated struct PlayableServiceOverride: Codable, Sendable, Equatable, Hashable {
    var serviceId: Int?
    var networkId: Int?
    var name: String?

    init(
        serviceId: Int? = nil,
        networkId: Int? = nil,
        name: String? = nil
    ) {
        self.serviceId = serviceId
        self.networkId = networkId
        self.name = name
    }

    init(service: TVService) {
        self.serviceId = service.serviceId
        self.networkId = service.networkId
        self.name = service.name
    }

    func applying(to base: TVService) -> TVService {
        TVService(
            id: base.id,
            providerIdentifier: base.providerIdentifier,
            serviceId: serviceId ?? base.serviceId,
            networkId: networkId ?? base.networkId,
            transportStreamId: base.transportStreamId,
            name: name ?? base.name,
            type: base.type,
            remoteControlKeyId: base.remoteControlKeyId,
            hasLogoData: base.hasLogoData,
            channel: base.channel,
            backendId: base.backendId
        )
    }

    func toServiceOrNil() -> TVService? {
        guard let serviceId, let networkId else {
            return nil
        }
        return TVService(
            id: "override-\(networkId)-\(serviceId)",
            providerIdentifier: nil,
            serviceId: serviceId,
            networkId: networkId,
            transportStreamId: nil,
            name: name ?? "不明",
            type: .digitalTelevision,
            remoteControlKeyId: nil,
            hasLogoData: false,
            channel: nil,
            backendId: "override"
        )
    }
}

nonisolated struct Playable: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var streamURL: URL
    var headers: [String: String]
    var backendId: String?
    var source: PlayableSource
    var program: Program?
    var service: TVService?
    var overriddenProgram: PlayableProgramOverride?
    var overriddenService: PlayableServiceOverride?
    var initialNetworkTime: Date?
    var isSeekable: Bool
    var length: TimeInterval?

    var displayProgram: Program? {
        if let program {
            if let overriddenProgram {
                return overriddenProgram.applying(to: program)
            }
            return program
        }
        return overriddenProgram?.toProgramOrNil()
    }

    var displayService: TVService? {
        let base: TVService?
        if let service {
            base = service
        } else if let program = displayProgram, program.serviceId != 0 {
            base = TVService(
                id: "inferred-\(program.networkId)-\(program.serviceId)",
                providerIdentifier: nil,
                serviceId: program.serviceId,
                networkId: program.networkId,
                transportStreamId: nil,
                name: "不明",
                type: .digitalTelevision,
                remoteControlKeyId: nil,
                hasLogoData: false,
                channel: nil,
                backendId: "inferred"
            )
        } else {
            base = nil
        }

        if let base {
            if let overriddenService {
                return overriddenService.applying(to: base)
            }
            return base
        }
        return overriddenService?.toServiceOrNil()
    }

    var serviceName: String? {
        displayService?.name
    }

    var title: String {
        if let title = displayProgram?.name, !title.isEmpty {
            return title
        }
        if let title = overriddenProgram?.name, !title.isEmpty {
            return title
        }
        if let name = serviceName, !name.isEmpty {
            return name
        }
        switch source {
        case .fileURL(let url, _), .directURL(let url):
            let fileName = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fileName.isEmpty {
                return fileName
            }
            return url.host ?? "URL再生"
        default:
            return "不明"
        }
    }

    var subtitle: String? {
        displayProgram?.desc ?? overriddenProgram?.desc
    }

    init(
        streamURL: URL,
        headers: [String: String] = [:],
        backendId: String? = nil,
        source: PlayableSource,
        program: Program? = nil,
        service: TVService? = nil
    ) {
        self.id = Self.stableID(for: source)
        self.streamURL = streamURL
        self.headers = headers
        self.backendId = backendId
        self.source = source
        self.program = program
        self.service = service
        self.overriddenService = nil
        self.initialNetworkTime = nil
        self.isSeekable = false
        self.length = 0
    }

    static func stableID(for source: PlayableSource) -> String {
        switch source {
        case .liveService(let serviceUniqueId):
            return "live-\(serviceUniqueId)"
        case .recordedFile(let recordId, let variantId, let backendId):
            return "rec-\(backendId)-\(recordId)-\(variantId)"
        case .fileURL(let url, _), .directURL(let url):
            return "direct-\(url.absoluteString)"
        }
    }

    mutating func normalizeIdentity() {
        id = Self.stableID(for: source)
    }

    func toPluginSchema() -> [String: Any] {
        var dict: [String: Any] = [:]
        dict["id"] = id
        dict["title"] = title
        dict["subtitle"] = subtitle
        dict["initialNetworkTime"] = initialNetworkTime?.timeIntervalSince1970 as Any
        dict["isSeekable"] = isSeekable
        dict["length"] = length as Any

        if let program = displayProgram {
            dict["program"] = [
                "name": program.name,
                "description": program.desc ?? "",
                "startAt": program.startAt.timeIntervalSince1970,
                "endAt": program.endAt.timeIntervalSince1970,
                "duration": program.duration,
                "eventId": program.eventId as Any,
                "extended": program.extended?.map { [$0.key, $0.value] } ?? [],
                "genres": program.genres.map {
                    ["lv1": $0.lv1, "lv2": $0.lv2 as Any, "name": $0.displayName]
                },
            ]
        }

        if let service = displayService {
            var serviceDict: [String: Any] = [
                "name": service.name,
                "serviceId": service.serviceId,
                "networkId": service.networkId,
                "type": [
                    "value": service.type.rawValue,
                    "description": service.type.description,
                ],
            ]
            if let channel = service.channel {
                serviceDict["channel"] = [
                    "id": channel.id,
                    "type": channel.type,
                ]
            }
            dict["service"] = serviceDict
        }

        return dict
    }
}

extension URL.BookmarkCreationOptions {
    static var securityScoped: URL.BookmarkCreationOptions {
        #if os(macOS)
            return .withSecurityScope
        #else
            return []
        #endif
    }
}

extension URL.BookmarkResolutionOptions {
    static var securityScoped: URL.BookmarkResolutionOptions {
        #if os(macOS)
            return .withSecurityScope
        #else
            return []
        #endif
    }
}
