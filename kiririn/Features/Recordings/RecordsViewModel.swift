import Foundation
import Logging

@Observable
final class RecordRowState {
    fileprivate(set) var thumbnailData: Data?
    fileprivate(set) var isThumbnailFailed = false
    fileprivate(set) var playbackPosition: Float?
    @ObservationIgnored fileprivate var playableID: String?
    @ObservationIgnored fileprivate weak var playbackPositionCacheStore: CacheStore?
    @ObservationIgnored fileprivate var playbackPositionLoadToken: Int?

    fileprivate init(playableID: String?) {
        self.playableID = playableID
    }
}

@Observable
class RecordsViewModel {
    private let logger = Logging.Logger(label: "RecordsViewModel")
    private(set) var records: [Recorded] = []
    var isLoading = false
    var hasMore = true
    var searchText = ""
    var errorTitle: String?
    var errorMessage: String?
    var scrolledRecordId: String?
    var hasRestoredScroll = false

    private var pageToken: String?
    private let limit = 20
    @ObservationIgnored private var rowStates: [String: RecordRowState] = [:]
    @ObservationIgnored private var thumbnailRequestIDs: [String: UUID] = [:]
    @ObservationIgnored private var playbackPositionRequestID: UUID?
    @ObservationIgnored private weak var lastPositionCacheStore: CacheStore?
    @ObservationIgnored private var lastPositionSaveToken: Int?

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func recordKey(for record: Recorded) -> String {
        "\(record.serverId)-\(record.id)"
    }

    func rowState(for record: Recorded) -> RecordRowState {
        let key = recordKey(for: record)
        if let state = rowStates[key] { return state }
        let state = RecordRowState(playableID: record.playableID)
        rowStates[key] = state
        return state
    }

    private func prepareRowStates(for records: [Recorded], reset: Bool) {
        for record in records {
            let key = recordKey(for: record)
            let playableID = record.playableID
            if let state = rowStates[key] {
                if state.playableID != playableID {
                    state.playableID = playableID
                    state.playbackPositionLoadToken = nil
                    if state.playbackPosition != nil {
                        state.playbackPosition = nil
                    }
                }
            } else {
                rowStates[key] = RecordRowState(playableID: playableID)
            }
        }
        if reset {
            let validKeys = Set(records.map { recordKey(for: $0) })
            rowStates = rowStates.filter { validKeys.contains($0.key) }
            thumbnailRequestIDs = thumbnailRequestIDs.filter { validKeys.contains($0.key) }
        }
    }

    func cancelPendingThumbnailLoads() {
        thumbnailRequestIDs.removeAll(keepingCapacity: false)
    }

    func loadPlaybackPositionsIfNeeded(cacheStore: CacheStore) async {
        guard !Task.isCancelled else { return }
        let requestID = UUID()
        playbackPositionRequestID = requestID
        defer {
            if playbackPositionRequestID == requestID {
                playbackPositionRequestID = nil
            }
        }
        let saveToken = cacheStore.playbackPositionSaveToken
        if lastPositionCacheStore === cacheStore,
            let previousToken = lastPositionSaveToken,
            previousToken &+ 1 == saveToken,
            let entry = cacheStore.lastSavedPlaybackPosition
        {
            for record in records {
                guard let state = rowStates[recordKey(for: record)] else { continue }
                if state.playableID == entry.playableID {
                    state.playbackPositionCacheStore = cacheStore
                    state.playbackPositionLoadToken = saveToken
                    if state.playbackPosition != entry.position {
                        state.playbackPosition = entry.position
                    }
                } else if state.playbackPositionCacheStore === cacheStore,
                    state.playbackPositionLoadToken == previousToken
                {
                    state.playbackPositionLoadToken = saveToken
                }
            }
        }
        var pendingStates: [String: RecordRowState] = [:]
        for record in records {
            let key = recordKey(for: record)
            guard let state = rowStates[key], state.playableID != nil,
                state.playbackPositionCacheStore !== cacheStore
                    || state.playbackPositionLoadToken != saveToken
            else { continue }
            pendingStates[key] = state
        }
        await withTaskGroup(of: (String, String, Float?).self) { group in
            for (key, state) in pendingStates {
                guard let playableID = state.playableID else { continue }
                group.addTask {
                    let position = await cacheStore.loadPlaybackPosition(playableID: playableID)
                    return (key, playableID, position)
                }
            }
            for await (key, playableID, position) in group {
                guard !Task.isCancelled, playbackPositionRequestID == requestID,
                    cacheStore.playbackPositionSaveToken == saveToken
                else {
                    group.cancelAll()
                    return
                }
                guard let state = pendingStates[key], rowStates[key] === state,
                    state.playableID == playableID
                else { continue }
                state.playbackPositionCacheStore = cacheStore
                state.playbackPositionLoadToken = saveToken
                if state.playbackPosition != position {
                    state.playbackPosition = position
                }
            }
        }
        guard !Task.isCancelled, playbackPositionRequestID == requestID,
            cacheStore.playbackPositionSaveToken == saveToken
        else { return }
        lastPositionCacheStore = cacheStore
        lastPositionSaveToken = saveToken
    }

    func loadThumbnailIfNeeded(for record: Recorded, manager: ServerManager) async {
        guard !Task.isCancelled, record.hasThumbnail else { return }
        let key = recordKey(for: record)
        guard let state = rowStates[key], state.thumbnailData == nil,
            !state.isThumbnailFailed, thumbnailRequestIDs[key] == nil
        else { return }
        guard manager.recordingProvider(for: record.serverId) != nil else {
            state.isThumbnailFailed = true
            return
        }

        let requestID = UUID()
        thumbnailRequestIDs[key] = requestID
        defer {
            if thumbnailRequestIDs[key] == requestID {
                thumbnailRequestIDs.removeValue(forKey: key)
            }
        }

        do {
            let data = try await manager.fetchRecordThumbnail(
                serverId: record.serverId, id: record.id)
            guard !Task.isCancelled, thumbnailRequestIDs[key] == requestID,
                rowStates[key] === state
            else { return }
            if let data, !data.isEmpty {
                if state.thumbnailData != data {
                    state.thumbnailData = data
                }
            } else if !state.isThumbnailFailed {
                state.isThumbnailFailed = true
            }
        } catch {
            guard !Task.isCancelled, thumbnailRequestIDs[key] == requestID,
                rowStates[key] === state, !isCancellationError(error)
            else { return }
            logger.error("failed to get thumbnail: \(error)")
            if !state.isThumbnailFailed {
                state.isThumbnailFailed = true
            }
        }
    }

    func loadRecords(
        manager: ServerManager, serverId: String, reset: Bool = false, force: Bool = false
    ) async {
        if isLoading {
            guard force else { return }
            while isLoading && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if Task.isCancelled { return }
        }
        let previousPageToken = pageToken
        let previousHasMore = hasMore
        let previousScrolledRecordID = scrolledRecordId
        let previousErrorTitle = errorTitle
        let previousErrorMessage = errorMessage

        if reset {
            pageToken = nil
            hasMore = true
            scrolledRecordId = nil
        }
        guard hasMore else { return }
        isLoading = true
        errorTitle = nil
        errorMessage = nil

        guard manager.recordingProvider(for: serverId) != nil else {
            errorTitle = "サーバーに接続できませんでした"
            errorMessage = "サーバーが利用できません"
            hasMore = false
            isLoading = false
            return
        }

        do {
            let result = try await manager.fetchRecords(
                serverId: serverId,
                pageToken: pageToken,
                limit: limit,
                keyword: searchText.isEmpty ? nil : searchText
            )
            try Task.checkCancellation()
            prepareRowStates(for: result.records, reset: reset)
            if reset {
                records = result.records
            } else {
                records.append(contentsOf: result.records)
            }
            pageToken = result.nextPageToken
            hasMore = result.nextPageToken != nil
        } catch {
            if Task.isCancelled || isCancellationError(error) {
                if reset {
                    pageToken = previousPageToken
                    hasMore = previousHasMore
                    scrolledRecordId = previousScrolledRecordID
                    errorTitle = previousErrorTitle
                    errorMessage = previousErrorMessage
                }
                isLoading = false
                return
            }
            if reset {
                records = []
                rowStates = [:]
                thumbnailRequestIDs = [:]
                pageToken = nil
            }
            hasMore = false
            logger.error(
                "failed to load records for server \(serverId): \(error.localizedDescription)")
            let feedback = errorFeedback(for: error)
            errorTitle = feedback.title
            errorMessage = feedback.message
        }
        isLoading = false
    }

    private func errorFeedback(for error: Error) -> (title: String, message: String) {
        if let apiError = error as? APIError {
            let title =
                switch apiError {
                case .invalidURL:
                    "サーバー設定を確認してください"
                case .invalidResponse, .httpError, .decodingError, .notFound:
                    "通信に失敗しました"
                }
            return (title, apiError.briefDescription)
        }

        if let urlError = error as? URLError {
            let message =
                switch urlError.code {
                case .timedOut:
                    "接続がタイムアウトしました"
                case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                    "サーバーに接続できませんでした"
                case .networkConnectionLost, .notConnectedToInternet:
                    "ネットワーク接続を確認してください"
                default:
                    "サーバーとの通信中にエラーが発生しました"
                }
            return ("通信に失敗しました", message)
        }

        return ("録画一覧を読み込めませんでした", "不明なエラーが発生しました")
    }
}
