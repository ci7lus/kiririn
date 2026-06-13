import Foundation

public final class PackageDownloadDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked
    Sendable
{
    public let progressHandler: (Int64, Int64) -> Void
    var continuation: CheckedContinuation<URL, Error>?
    private var savedError: Error?
    private var downloadedFileURL: URL?

    public init(progressHandler: @escaping (Int64, Int64) -> Void = { _, _ in }) {
        self.progressHandler = progressHandler
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progressHandler(totalBytesWritten, totalBytesExpectedToWrite)
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("plugin_download_\(UUID().uuidString).kppx")
            try FileManager.default.moveItem(at: location, to: tempURL)
            downloadedFileURL = tempURL
        } catch {
            savedError = error
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let c = continuation else { return }
        continuation = nil
        if let error = error ?? savedError {
            downloadedFileURL.map { try? FileManager.default.removeItem(at: $0) }
            c.resume(throwing: error)
        } else if let url = downloadedFileURL {
            c.resume(returning: url)
        } else {
            downloadedFileURL.map { try? FileManager.default.removeItem(at: $0) }
            c.resume(
                throwing: NSError(
                    domain: "PackageDownload", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "ダウンロードに失敗しました"]
                )
            )
        }
    }
}

public enum PackageDownloader {
    public static func download(
        from url: URL,
        progressHandler: @escaping (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> URL {
        let delegate = PackageDownloadDelegate(progressHandler: progressHandler)
        let session = URLSession(
            configuration: .default, delegate: delegate, delegateQueue: .main)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let task = session.downloadTask(with: request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
            session.invalidateAndCancel()
        }
    }
}
