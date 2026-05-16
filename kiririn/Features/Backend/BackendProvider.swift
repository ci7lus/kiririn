import Foundation

protocol BackendProvider {
    func checkConnection() async throws
    func fetchHeaders() async throws -> [String: String]
}

protocol LiveBackendProvider: BackendProvider {
    func fetchServices() async throws -> [TVService]
    func fetchPrograms() async throws -> [Program]
    func fetchServiceLogoData(for service: TVService) async throws -> Data?
    func buildLiveStreamPlayable(service: TVService, currentProgram: Program?) throws -> Playable
}

protocol RecordingBackendProvider: BackendProvider {
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
