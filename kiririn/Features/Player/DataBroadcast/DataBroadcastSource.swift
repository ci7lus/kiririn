import Foundation

/// Mahiron (https://github.com/rokoucha/Mahiron)'s data-broadcast SSE/module API,
/// scoped to a single Mirakurun-style service item. Only providers that expose
/// this (currently only `MirakurunProvider`, and only against a Mahiron server)
/// support データ放送.
protocol DataBroadcastProviding {
    func dataBroadcastEndpoint(for service: TVService) -> DataBroadcastEndpoint?
}

nonisolated struct DataBroadcastEndpoint: Sendable {
    let eventsURL: URL
    let headers: [String: String]
    private let moduleBaseURL: URL

    init(eventsURL: URL, headers: [String: String], moduleBaseURL: URL) {
        self.eventsURL = eventsURL
        self.headers = headers
        self.moduleBaseURL = moduleBaseURL
    }

    func moduleURL(componentTag: Int, moduleId: Int) -> URL {
        moduleBaseURL
            .appendingPathComponent("\(componentTag)")
            .appendingPathComponent("\(moduleId)")
    }
}
