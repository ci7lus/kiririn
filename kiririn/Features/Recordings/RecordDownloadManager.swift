import Foundation
import GRDB
import Logging

@MainActor
@Observable
final class RecordDownloadManager {
    static let shared = RecordDownloadManager()
    private let logger = Logger(label: "RecordDownloadManager")

    private(set) var localRecords: [LocalRecordItem] = []
    private(set) var isLoadingLocalRecords = false
    /// Active download progress keyed by local-record ID.
    private(set) var downloadProgressByItemId: [String: Double] = [:]

    /// Active download tasks keyed by local-record ID.
    private var activeDownloadTaskById: [String: URLSessionDownloadTask] = [:]

    private init() {}

    // MARK: - Directory

    static var localRecordsDirectoryURL: URL {
        LocalRecordPath.directoryURL
    }

    static func localVideoURL(fileName: String) -> URL {
        LocalRecordPath.videoURL(fileName: fileName)
    }

    static func localRecordID(backendId: String, recordID: String) -> String {
        LocalRecordPath.recordID(backendId: backendId, recordID: recordID)
    }

    private static let invalidLocalVideoFileNameCharacters = CharacterSet(
        charactersIn: "/:\\?%*|\"<>\n\r")

    private static func sanitizedLocalVideoBaseName(from sourceName: String?) -> String? {
        guard let sourceName else { return nil }

        let lastPathComponent = (sourceName as NSString).lastPathComponent
        let baseName = (lastPathComponent as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseName.isEmpty else { return nil }

        let sanitized = baseName.components(separatedBy: invalidLocalVideoFileNameCharacters)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))

        return sanitized.isEmpty ? nil : sanitized
    }

    private func localVideoFileName(title: String, fallback: String, excluding itemID: String)
        -> String
    {
        let fallbackBaseName = (fallback as NSString).deletingPathExtension
        let resolvedBaseName = Self.sanitizedLocalVideoBaseName(from: title) ?? fallbackBaseName

        var suffixNumber = 0
        while true {
            let suffix = suffixNumber == 0 ? "" : " (\(suffixNumber + 1))"
            let candidate = "\(resolvedBaseName)\(suffix).ts"
            if isAvailableLocalVideoFileName(candidate, excluding: itemID) {
                return candidate
            }
            suffixNumber += 1
        }
    }

    private func isAvailableLocalVideoFileName(_ fileName: String, excluding itemID: String)
        -> Bool
    {
        let isUsedByAnotherItem = localRecords.contains {
            $0.id != itemID && $0.videoFileName.caseInsensitiveCompare(fileName) == .orderedSame
        }
        if isUsedByAnotherItem {
            return false
        }
        return !FileManager.default.fileExists(atPath: Self.localVideoURL(fileName: fileName).path)
    }

    private static func createDirectoryExcludedFromBackup(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #if os(iOS)
            var mutableURL = url
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try mutableURL.setResourceValues(resourceValues)
        #endif
    }

    // MARK: - Local Records CRUD

    func reloadLocalRecords() async {
        guard let cacheStore = AppModel.shared.cacheStore else { return }
        isLoadingLocalRecords = true
        let items = await cacheStore.loadLocalRecords()
        localRecords = items
        isLoadingLocalRecords = false
    }

    func deleteLocalRecord(_ item: LocalRecordItem) async {
        guard let cacheStore = AppModel.shared.cacheStore else { return }
        await cacheStore.deleteLocalRecord(id: item.id)
        if let url = localVideoURL(for: item) {
            try? FileManager.default.removeItem(at: url)
        }
        localRecords.removeAll { $0.id == item.id }
    }

    func cancelDownload(id: String) {
        activeDownloadTaskById[id]?.cancel()
        // Cleanup is handled in the completion handler (URLError.cancelled branch).
    }

    // MARK: - Download

    func downloadRecord(_ record: Recorded, manager: BackendManager) {
        guard let provider = manager.recordingProvider(for: record.backendId) else { return }
        guard let variant = record.variants.first else { return }
        let encodedId = Self.localRecordID(backendId: record.backendId, recordID: record.id)

        // Block duplicate starts while the same item is already downloading.
        if activeDownloadTaskById[encodedId] != nil || downloadProgressByItemId[encodedId] != nil {
            logger.info("Skipped duplicate download request: id=\(encodedId)")
            return
        }
        downloadProgressByItemId[encodedId] = 0.0

        Task { @MainActor in
            let fallbackVideoFileName = "\(encodedId).ts"
            let recordData = (try? JSONEncoder().encode(record)) ?? Data()

            var item = LocalRecordItem(
                id: encodedId,
                backendId: record.backendId,
                name: record.name,
                serviceName: record.serviceName,
                startAt: record.startAt,
                duration: record.duration,
                data: recordData,
                videoFileName: fallbackVideoFileName,
                thumbnailData: nil,
                downloadStateRaw: LocalRecordItem.DownloadState.downloading.rawValue,
                downloadErrorMessage: nil,
                downloadedAt: nil,
                createdAt: Date()
            )

            if let cacheStore = AppModel.shared.cacheStore {
                await cacheStore.saveLocalRecord(item)
            }

            if let index = localRecords.firstIndex(where: { $0.id == item.id }) {
                localRecords[index] = item
            } else {
                localRecords.insert(item, at: 0)
            }

            do {
                var playable = try provider.buildRecordedPlayable(record: record, variant: variant)
                if playable.headers.isEmpty {
                    if let headers = try? await provider.fetchHeaders() {
                        playable.headers = headers
                    }
                }
                let videoURL = playable.streamURL

                try Self.createDirectoryExcludedFromBackup(Self.localRecordsDirectoryURL)

                logger.info("Starting download for local record: \(record.name)")

                var request = URLRequest(url: videoURL)
                for (k, v) in playable.headers {
                    request.setValue(v, forHTTPHeaderField: k)
                }

                var progressObservation: NSKeyValueObservation?
                defer { progressObservation?.invalidate() }

                let (tempFileURL, response) = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<(URL, URLResponse), Error>) in

                    let task = URLSession.kiririnShared.downloadTask(with: request) {
                        tempURL, resp, error in
                        if let error {
                            let nsError = error as NSError
                            if nsError.domain == NSURLErrorDomain
                                && nsError.code == NSURLErrorCancelled
                            {
                                continuation.resume(throwing: CancellationError())
                            } else {
                                continuation.resume(throwing: error)
                            }
                            return
                        }
                        guard let tempURL, let resp else {
                            continuation.resume(throwing: URLError(.badServerResponse))
                            return
                        }
                        let stableURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString + ".ts")
                        do {
                            try FileManager.default.moveItem(at: tempURL, to: stableURL)
                            continuation.resume(returning: (stableURL, resp))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }

                    let id = encodedId
                    progressObservation = task.progress.observe(
                        \.fractionCompleted, options: [.new]
                    ) { [weak self] _, change in
                        guard let fraction = change.newValue, fraction > 0 else { return }
                        Task { @MainActor [weak self] in
                            self?.downloadProgressByItemId[id] = fraction
                        }
                    }
                    activeDownloadTaskById[encodedId] = task
                    task.resume()
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw APIError.invalidResponse
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw APIError.httpError(statusCode: httpResponse.statusCode)
                }

                let videoFileName = localVideoFileName(
                    title: record.name,
                    fallback: fallbackVideoFileName,
                    excluding: item.id
                )
                let videoDestURL = Self.localVideoURL(fileName: videoFileName)

                try FileManager.default.moveItem(at: tempFileURL, to: videoDestURL)

                item.videoFileName = videoFileName
                item.thumbnailData = try? await provider.fetchRecordThumbnail(id: record.id)
                item.downloadStateRaw = LocalRecordItem.DownloadState.downloaded.rawValue
                item.downloadErrorMessage = nil
                item.downloadedAt = Date()

                if let cacheStore = AppModel.shared.cacheStore {
                    await cacheStore.saveLocalRecord(item)
                    logger.info("Saved local record to CacheStore: \(item.name)")
                }

            } catch is CancellationError {
                logger.info("Download cancelled for local record: \(record.name)")
                if let cacheStore = AppModel.shared.cacheStore {
                    await cacheStore.deleteLocalRecord(id: encodedId)
                }
                localRecords.removeAll { $0.id == encodedId }
            } catch {
                logger.error("Failed to download local record: \(error)")
                item.downloadStateRaw = LocalRecordItem.DownloadState.failed.rawValue
                item.downloadErrorMessage = error.localizedDescription
                if let cacheStore = AppModel.shared.cacheStore {
                    await cacheStore.saveLocalRecord(item)
                }
            }

            activeDownloadTaskById.removeValue(forKey: encodedId)
            downloadProgressByItemId.removeValue(forKey: encodedId)
            await reloadLocalRecords()
        }
    }

    func localVideoURL(for item: LocalRecordItem) -> URL? {
        let fileURL = Self.localVideoURL(fileName: item.videoFileName)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }
}
