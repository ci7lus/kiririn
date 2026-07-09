import Foundation

protocol ServerProvider {
    func checkConnection() async throws -> String?
    func fetchHeaders() async throws -> [String: String]
    func cancelInFlightRequests()
}

protocol LiveServerProvider: ServerProvider {
    func fetchServices() async throws -> [TVService]
    func fetchPrograms() async throws -> [Program]
    func fetchServiceLogoData(for service: TVService) async throws -> Data?
    func buildLiveStreamPlayable(service: TVService, currentProgram: Program?) throws -> Playable
}

protocol RecordingServerProvider: ServerProvider {
    func fetchRecords(pageToken: String?, limit: Int, keyword: String?) async throws
        -> RecordsResult
    func fetchRecord(id: String) async throws -> Recorded
    func fetchRecordThumbnail(id: String) async throws -> Data?
    func buildRecordedPlayable(record: Recorded, variant: RecordedVariant) throws -> Playable
}

nonisolated struct RecordsResult: Sendable {
    let records: [Recorded]
    let nextPageToken: String?
}
