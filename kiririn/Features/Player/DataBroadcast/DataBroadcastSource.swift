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
    /// Authoritative carousel state without opening SSE. Unused by the session
    /// today (every SSE connection starts with a `snapshot` event), kept for
    /// diagnostics.
    let stateURL: URL
    let headers: [String: String]
    private let baseURL: URL

    init(eventsURL: URL, stateURL: URL, headers: [String: String], baseURL: URL) {
        self.eventsURL = eventsURL
        self.stateURL = stateURL
        self.headers = headers
        self.baseURL = baseURL
    }

    /// Immutable per-generation module URL. A module is identified by
    /// download ID + module ID + version, so the URL never changes content and
    /// a superseded generation 404s instead of silently returning new bytes.
    /// Returns the resource manifest (JSON); `/raw` and `/resources/{id}` hang
    /// off the same path.
    func moduleVersionURL(componentTag: Int, downloadId: UInt32, moduleId: Int, version: Int) -> URL
    {
        baseURL
            .appendingPathComponent("components")
            .appendingPathComponent("\(componentTag)")
            .appendingPathComponent("carousels")
            .appendingPathComponent("\(downloadId)")
            .appendingPathComponent("modules")
            .appendingPathComponent("\(moduleId)")
            .appendingPathComponent("versions")
            .appendingPathComponent("\(version)")
    }

    func moduleResourceURL(
        componentTag: Int, downloadId: UInt32, moduleId: Int, version: Int, resourceId: String
    ) -> URL {
        moduleVersionURL(
            componentTag: componentTag, downloadId: downloadId, moduleId: moduleId,
            version: version
        )
        .appendingPathComponent("resources")
        .appendingPathComponent(resourceId)
    }
}
