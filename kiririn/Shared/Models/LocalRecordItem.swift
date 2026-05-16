import Foundation
import GRDB

#if os(macOS)
    import AppKit
#endif

nonisolated struct LocalRecordItem: Codable, FetchableRecord, PersistableRecord, Identifiable,
    Sendable
{
    static let databaseTableName = "local_record"

    nonisolated enum DownloadState: String, Codable, Sendable {
        case downloading
        case downloaded
        case failed
        case missing
    }

    var id: String
    var backendId: String
    var name: String
    var serviceName: String?
    var startAt: Date?
    var duration: TimeInterval?
    var data: Data  // JSON-encoded Recorded
    var videoFileName: String
    var thumbnailData: Data?
    var downloadStateRaw: String?
    var downloadErrorMessage: String?
    var downloadedAt: Date?
    var createdAt: Date

    enum Columns: String, ColumnExpression {
        case id, backendId, name, serviceName, startAt, duration, data, videoFileName,
            thumbnailData, downloadStateRaw, downloadErrorMessage, downloadedAt, createdAt
    }

    init(
        id: String,
        backendId: String,
        name: String,
        serviceName: String?,
        startAt: Date?,
        duration: TimeInterval?,
        data: Data,
        videoFileName: String,
        thumbnailData: Data?,
        downloadStateRaw: String? = nil,
        downloadErrorMessage: String? = nil,
        downloadedAt: Date? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.backendId = backendId
        self.name = name
        self.serviceName = serviceName
        self.startAt = startAt
        self.duration = duration
        self.data = data
        self.videoFileName = videoFileName
        self.thumbnailData = thumbnailData
        self.downloadStateRaw = downloadStateRaw
        self.downloadErrorMessage = downloadErrorMessage
        self.downloadedAt = downloadedAt
        self.createdAt = createdAt
    }

    var recorded: Recorded? {
        try? JSONDecoder().decode(Recorded.self, from: data)
    }

    /// 表示用の日時。startAt が不明な場合は createdAt にフォールバックする。
    var displayDate: Date {
        startAt ?? createdAt
    }

    var localVideoURL: URL {
        LocalRecordPath.videoURL(fileName: videoFileName)
    }

    /// Stable playable ID that matches `Playable.stableID(for:)` after `normalizeIdentity()`.
    var playableID: String {
        Playable.stableID(for: .fileURL(localVideoURL, bookmarkData: nil))
    }

    var isVideoFilePresent: Bool {
        FileManager.default.fileExists(atPath: localVideoURL.path)
    }

    var downloadState: DownloadState {
        if isVideoFilePresent {
            return .downloaded
        }
        if let raw = downloadStateRaw, let state = DownloadState(rawValue: raw) {
            switch state {
            case .downloading, .failed:
                return state
            case .downloaded, .missing:
                return .missing
            }
        }
        return .missing
    }

    #if os(macOS)
        @discardableResult
        func revealInFinder() -> Bool {
            guard isVideoFilePresent else { return false }
            NSWorkspace.shared.activateFileViewerSelecting([localVideoURL])
            return true
        }
    #endif
}
