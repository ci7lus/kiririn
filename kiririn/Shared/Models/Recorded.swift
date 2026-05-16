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
}

nonisolated struct RecordedVariant: Codable, Identifiable, Sendable {
    var id: String
    var name: String
}
