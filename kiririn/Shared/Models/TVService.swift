import Foundation
import GRDB

nonisolated struct TVService: Codable, Identifiable, Sendable, Hashable, FetchableRecord,
    PersistableRecord
{
    var id: String
    var providerIdentifier: String?

    var serviceId: Int
    var networkId: Int
    var transportStreamId: Int?

    var name: String
    var type: ServiceType
    var remoteControlKeyId: Int?
    var hasLogoData: Bool

    struct Channel: Codable, Hashable {
        var id: String
        var type: String
    }

    enum ServiceType: Int, Codable {
        /// デジタルテレビジョン放送
        case digitalTelevision = 0x01
        /// デジタルラジオ（音声）放送
        case digitalRadio = 0x02
        /// NVOD（Near Video On Demand）基準サービス
        case nvodReferenceService = 0x04
        /// データ放送
        case dataBroadcast = 0x0C
        /// 1セグメント放送サービス (タイプA)
        case oneSegServiceA = 0xA1
        /// 1セグメント放送サービス (タイプB)
        case oneSegServiceB = 0xA2
        /// 1セグメント放送サービス (タイプC)
        case oneSegServiceC = 0xA3
        /// 1セグメント放送サービス (タイプD)
        case oneSegServiceD = 0xA4
        /// エンジニアリングサービス
        case engineeringService = 0xA5
        /// 臨時サービス
        case temporaryService = 0xAD
        /// 蓄積型放送サービス
        case storageBroadcastService = 0xC0
        /// 4K/8K放送 (UHDTV)
        case uhdtv = 0xC4

        var description: String {
            switch self {
            case .digitalTelevision:
                return "デジタルテレビジョン放送"
            case .digitalRadio:
                return "デジタルラジオ（音声）放送"
            case .nvodReferenceService:
                return "NVOD基準サービス"
            case .dataBroadcast:
                return "データ放送"
            case .oneSegServiceA, .oneSegServiceB, .oneSegServiceC, .oneSegServiceD:
                return "1セグメント放送サービス"
            case .engineeringService:
                return "エンジニアリングサービス"
            case .temporaryService:
                return "臨時サービス"
            case .storageBroadcastService:
                return "蓄積型放送サービス"
            case .uhdtv:
                return "4K/8K放送 (UHDTV)"
            }
        }
    }

    var channel: Channel?

    var backendId: String
    var favoritedAt: Date? = nil

    private enum CodingKeys: String, CodingKey {
        case id
        case providerIdentifier
        case serviceId
        case networkId
        case transportStreamId
        case name
        case type
        case remoteControlKeyId
        case hasLogoData
        case channel
        case backendId
    }

    var unifiedServiceKey: String {
        "\(networkId)-\(serviceId)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TVService, rhs: TVService) -> Bool {
        lhs.id == rhs.id
    }

    static var databaseTableName: String {
        return "service"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let providerIdentifier = Column(CodingKeys.providerIdentifier)
        static let serviceId = Column(CodingKeys.serviceId)
        static let networkId = Column(CodingKeys.networkId)
        static let transportStreamId = Column(CodingKeys.transportStreamId)
        static let name = Column(CodingKeys.name)
        static let type = Column(CodingKeys.type)
        static let hasLogoData = Column(CodingKeys.hasLogoData)
        static let remoteControlKeyId = Column(CodingKeys.remoteControlKeyId)
        static let channel = Column(CodingKeys.channel)
        static let backendId = Column(CodingKeys.backendId)
    }
}

nonisolated struct TVServiceLogo: Codable, FetchableRecord, PersistableRecord {
    var id: String
    var serviceId: Int
    var networkId: Int
    var data: Data
    var updatedAt: Date

    static var databaseTableName: String {
        return "service_logo"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let serviceId = Column(CodingKeys.serviceId)
        static let networkId = Column(CodingKeys.networkId)
        static let data = Column(CodingKeys.data)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }
}
