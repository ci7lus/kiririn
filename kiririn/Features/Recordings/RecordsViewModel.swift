import Foundation
import Logging

@Observable
class RecordsViewModel {
    private let logger = Logging.Logger(label: "RecordsViewModel")
    var records: [Recorded] = []
    var thumbnailDataByRecordKey: [String: Data] = [:]
    var playbackPositionByPlayableId: [String: Float] = [:]
    var isLoading = false
    var hasMore = true
    var searchText = ""
    var errorMessage: String?
    var scrolledRecordId: String?
    var hasRestoredScroll = false

    private var pageToken: String?
    private let limit = 20
    private var loadingThumbnailKeys: Set<String> = []
    private var failedThumbnailKeys: Set<String> = []

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

    private func thumbnailKey(for record: Recorded) -> String {
        "\(record.backendId)-\(record.id)"
    }

    func thumbnailData(for record: Recorded) -> Data? {
        thumbnailDataByRecordKey[thumbnailKey(for: record)]
    }

    func isThumbnailFailed(for record: Recorded) -> Bool {
        failedThumbnailKeys.contains(thumbnailKey(for: record))
    }

    func playbackPosition(for record: Recorded) -> Float? {
        guard let playableId = record.playableID else { return nil }
        return playbackPositionByPlayableId[playableId]
    }

    func loadPlaybackPositions(for records: [Recorded], cacheStore: CacheStore) async {
        await withTaskGroup(of: (String, Float?).self) { group in
            for record in records {
                guard let playableId = record.playableID else { continue }
                let id = playableId
                group.addTask {
                    let position = await cacheStore.loadPlaybackPosition(playableID: id)
                    return (id, position)
                }
            }
            for await (playableId, position) in group {
                if let position {
                    playbackPositionByPlayableId[playableId] = position
                }
            }
        }
    }

    func loadThumbnailIfNeeded(for record: Recorded, manager: BackendManager) async {
        guard record.hasThumbnail else { return }
        let key = thumbnailKey(for: record)
        guard thumbnailDataByRecordKey[key] == nil else { return }
        guard !failedThumbnailKeys.contains(key) else { return }
        guard !loadingThumbnailKeys.contains(key) else { return }
        guard manager.recordingProvider(for: record.backendId) != nil else {
            failedThumbnailKeys.insert(key)
            return
        }

        loadingThumbnailKeys.insert(key)
        defer { loadingThumbnailKeys.remove(key) }

        do {
            if let data = try await manager.fetchRecordThumbnail(
                backendId: record.backendId, id: record.id), !data.isEmpty
            {
                thumbnailDataByRecordKey[key] = data
            } else {
                failedThumbnailKeys.insert(key)
            }
        } catch {
            logger.error("failed to get thumbnail: \(error)")
            failedThumbnailKeys.insert(key)
        }
    }

    func loadRecords(
        manager: BackendManager, backendId: String, reset: Bool = false, force: Bool = false
    ) async {
        if isLoading {
            guard force else { return }
            while isLoading && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if Task.isCancelled { return }
        }
        let previousRecords = records
        let previousThumbnailDataByRecordKey = thumbnailDataByRecordKey
        let previousLoadingThumbnailKeys = loadingThumbnailKeys
        let previousFailedThumbnailKeys = failedThumbnailKeys
        let previousPageToken = pageToken
        let previousHasMore = hasMore
        let previousErrorMessage = errorMessage

        if reset {
            pageToken = nil
            hasMore = true
            scrolledRecordId = nil
        }
        guard hasMore else { return }
        isLoading = true
        errorMessage = nil

        guard manager.recordingProvider(for: backendId) != nil else {
            errorMessage = "バックエンドが利用できません"
            hasMore = false
            isLoading = false
            return
        }

        do {
            let result = try await manager.fetchRecords(
                backendId: backendId,
                pageToken: pageToken,
                limit: limit,
                keyword: searchText.isEmpty ? nil : searchText
            )
            if reset {
                records = result.records
                let validKeys = Set(result.records.map { thumbnailKey(for: $0) })
                thumbnailDataByRecordKey = thumbnailDataByRecordKey.filter {
                    validKeys.contains($0.key)
                }
                loadingThumbnailKeys = loadingThumbnailKeys.filter { validKeys.contains($0) }
                failedThumbnailKeys = failedThumbnailKeys.filter { validKeys.contains($0) }
            } else {
                records.append(contentsOf: result.records)
            }
            pageToken = result.nextPageToken
            hasMore = result.nextPageToken != nil
        } catch {
            if Task.isCancelled || isCancellationError(error) {
                if reset {
                    records = previousRecords
                    thumbnailDataByRecordKey = previousThumbnailDataByRecordKey
                    loadingThumbnailKeys = previousLoadingThumbnailKeys
                    failedThumbnailKeys = previousFailedThumbnailKeys
                    pageToken = previousPageToken
                    hasMore = previousHasMore
                    errorMessage = previousErrorMessage
                }
                isLoading = false
                return
            }
            if reset {
                records = previousRecords
                thumbnailDataByRecordKey = previousThumbnailDataByRecordKey
                loadingThumbnailKeys = previousLoadingThumbnailKeys
                failedThumbnailKeys = previousFailedThumbnailKeys
                pageToken = previousPageToken
                hasMore = previousHasMore
            } else {
                hasMore = false
            }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
