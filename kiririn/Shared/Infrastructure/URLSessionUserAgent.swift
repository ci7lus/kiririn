import Foundation

enum KiririnUserAgent {
    nonisolated(unsafe) static var urlSessionUserAgent: String {
        "Mozilla/5.0 (\(platformToken)) kiririn/\(appVersion)"
    }

    nonisolated(unsafe) private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1"
    }

    nonisolated(unsafe) private static var platformToken: String {
        #if os(macOS)
            return "Macintosh; Intel Mac OS X 10_15_7"
        #else
            return "iPhone; CPU iPhone OS 18_7 like Mac OS X"
        #endif
    }
}

extension URLSessionConfiguration {
    nonisolated(unsafe) static var kiririnDefault: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers["User-Agent"] = KiririnUserAgent.urlSessionUserAgent
        configuration.httpAdditionalHeaders = headers
        return configuration
    }
}

extension URLSession {
    static let kiririnShared: URLSession = {
        URLSession(configuration: .kiririnDefault)
    }()

    nonisolated func cancelAllTasks() {
        getAllTasks { tasks in
            for task in tasks {
                task.cancel()
            }
        }
    }
}
