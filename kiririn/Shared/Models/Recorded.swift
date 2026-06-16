import ARIBStandardKit
import Foundation
import OrderedCollections

nonisolated struct Recorded: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var desc: String?
    var extended: OrderedDictionary<String, String>?
    var serviceName: String?
    var serviceId: Int?
    var networkId: Int?
    var startAt: Date?
    var duration: TimeInterval?
    /// 録画開始時刻が不明な場合の参考日時
    var referenceDate: Date? = nil
    var genres: [ProgramGenre]
    var variants: [RecordedVariant]
    var isRecording: Bool
    var hasThumbnail: Bool
    var backendId: String

    var endAt: Date? {
        guard let startAt, let duration else { return nil }
        return startAt.addingTimeInterval(duration)
    }

    /// 表示用の日時。startAt が不明な場合は referenceDate にフォールバックする。
    var displayDate: Date? {
        startAt ?? referenceDate
    }

    var playableID: String? {
        guard let variant = variants.first else { return nil }
        return Playable.stableID(
            for: .recordedFile(recordId: id, variantId: variant.id, backendId: backendId))
    }

    func synthesizedService() -> TVService? {
        let trimmedName = serviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedName.isEmpty else { return nil }
        let serviceIdValue = serviceId ?? 0
        let networkIdValue = networkId ?? 0
        return TVService(
            id: "record-\(backendId)-\(networkIdValue)-\(serviceIdValue)-\(id)",
            providerIdentifier: nil,
            serviceId: serviceIdValue,
            networkId: networkIdValue,
            transportStreamId: nil,
            name: trimmedName,
            type: .digitalTelevision,
            remoteControlKeyId: nil,
            hasLogoData: false,
            channel: nil,
            backendId: backendId
        )
    }

    func toProgram() -> Program? {
        guard let startAt, let duration, let endAt else { return nil }
        return Program(
            id: "record-\(backendId)-\(id)",
            backendId: backendId,
            eventId: nil,
            serviceId: serviceId ?? 0,
            networkId: networkId ?? 0,
            startAt: startAt,
            endAt: endAt,
            duration: duration,
            name: name,
            desc: desc,
            extended: extended,
            genres: genres,
            updatedAt: nil
        )
    }
}

nonisolated struct RecordedVariant: Codable, Identifiable, Sendable {
    var id: String
    var name: String
}
