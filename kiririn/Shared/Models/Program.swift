import ARIBStandardKit
import Foundation
import GRDB
import OrderedCollections
import SwiftUI

nonisolated struct Program: Codable, Identifiable, Sendable, Equatable, Hashable, FetchableRecord,
    PersistableRecord
{
    var id: String
    var backendId: String

    var eventId: Int?
    var serviceId: Int
    var networkId: Int

    var startAt: Date
    var endAt: Date
    var duration: TimeInterval
    var name: String
    var desc: String?
    var extended: OrderedDictionary<String, String>?
    var genres: [ProgramGenre]
    var updatedAt: Date?

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let backendId = Column(CodingKeys.backendId)
        static let eventId = Column(CodingKeys.eventId)
        static let serviceId = Column(CodingKeys.serviceId)
        static let networkId = Column(CodingKeys.networkId)

        static let startAt = Column(CodingKeys.startAt)
        static let endAt = Column(CodingKeys.endAt)
        static let duration = Column(CodingKeys.duration)
        static let name = Column(CodingKeys.name)
        static let desc = Column(CodingKeys.desc)
        static let extended = Column(CodingKeys.extended)
        static let genres = Column(CodingKeys.genres)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }
}
