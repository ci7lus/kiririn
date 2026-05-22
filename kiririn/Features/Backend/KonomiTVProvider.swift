import Foundation

final class KonomiTVProvider: RecordingBackendProvider {
    let configuration: BackendConfiguration
    private let client: APIClient

    private var isRecordingEnabled: Bool {
        configuration.features.contains(.recording)
    }

    init(configuration: BackendConfiguration) {
        self.configuration = configuration
        self.client = APIClient(configuration: configuration)
    }

    func checkConnection() async throws {
        // バージョン情報取得APIを使用して接続確認を行う
        let _: KonomiTVVersionInfo = try await client.request(path: "api/version")
    }

    func fetchHeaders() async throws -> [String: String] {
        client.defaultHeaders
    }

    func fetchRecords(pageToken: String?, limit: Int, keyword: String?) async throws
        -> RecordsResult
    {
        guard isRecordingEnabled else { return RecordsResult(records: [], nextPageToken: nil) }

        let page = Int(pageToken ?? "1") ?? 1
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "page", value: "\(page)")
        ]

        let path: String
        if let keyword = keyword, !keyword.isEmpty {
            path = "api/videos/search"
            queryItems.append(URLQueryItem(name: "query", value: keyword))
        } else {
            path = "api/videos"
        }

        let response: KonomiTVRecordedPrograms = try await client.request(
            path: path,
            queryItems: queryItems
        )

        let records = response.recordedPrograms.map { $0.toRecord(backendId: configuration.id) }

        // KonomiTVの1ページは30件固定
        let pageSize = 30
        let nextPage = page + 1
        let hasNextPage = (page * pageSize) < response.total
        let nextPageToken = hasNextPage ? "\(nextPage)" : nil

        return RecordsResult(records: records, nextPageToken: nextPageToken)
    }

    func fetchRecord(id: String) async throws -> Recorded {
        guard isRecordingEnabled else {
            throw URLError(.dataNotAllowed)
        }
        let program: KonomiTVRecordedProgram = try await client.request(path: "api/videos/\(id)")
        return program.toRecord(backendId: configuration.id)
    }

    func fetchRecordThumbnail(id: String) async throws -> Data? {
        return try await client.requestData(path: "api/videos/\(id)/thumbnail")
    }

    func buildRecordedPlayable(record: Recorded, variant: RecordedVariant) throws -> Playable {
        guard let streamURL = client.buildStreamURL(path: "api/videos/\(record.id)/download") else {
            throw APIError.invalidURL
        }
        return Playable(
            streamURL: streamURL,
            headers: client.defaultHeaders,
            backendId: configuration.id,
            source: .recordedFile(
                recordId: record.id, variantId: variant.id, backendId: record.backendId),
            program: buildRecordedProgram(record: record),
            service: nil
        )
    }

    private func buildRecordedProgram(record: Recorded) -> Program? {
        guard let startAt = record.startAt,
            let duration = record.duration,
            let endAt = record.endAt
        else {
            return nil
        }

        return Program(
            id: "record-\(record.backendId)-\(record.id)",
            backendId: record.backendId,
            eventId: nil,
            serviceId: 0,
            networkId: 0,
            startAt: startAt,
            endAt: endAt,
            duration: duration,
            name: record.name,
            desc: record.desc,
            extended: record.extended,
            genres: record.genres,
            updatedAt: nil
        )
    }
}

// MARK: - KonomiTV API Models

private nonisolated struct KonomiTVVersionInfo: Codable, Sendable {
    let version: String
}

private nonisolated struct KonomiTVRecordedPrograms: Codable, Sendable {
    let total: Int
    let recordedPrograms: [KonomiTVRecordedProgram]

    private enum CodingKeys: String, CodingKey {
        case total
        case recordedPrograms = "recorded_programs"
    }
}

private nonisolated struct KonomiTVRecordedProgram: Codable, Sendable {
    let id: Int
    let title: String
    let description: String
    let startTime: String
    let endTime: String
    let duration: Double
    let genres: [KonomiTVGenre]?
    let channel: KonomiTVChannel?
    let recordedVideo: KonomiTVRecordedVideo?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case startTime = "start_time"
        case endTime = "end_time"
        case duration
        case genres
        case channel
        case recordedVideo = "recorded_video"
    }

    func toRecord(backendId: String) -> Recorded {
        let start = parseDate(startTime) ?? Date()

        let programGenres = genres?.compactMap { $0.toProgramGenre() } ?? []

        return Recorded(
            id: "\(id)",
            name: title,
            desc: description,
            extended: nil,
            serviceName: channel?.name,
            serviceId: nil,
            networkId: nil,
            startAt: start,
            duration: duration,
            genres: programGenres,
            variants: [RecordedVariant(id: "default", name: "Default")],
            isRecording: recordedVideo?.status == "Recording",
            hasThumbnail: true,
            backendId: backendId
        )
    }

    private func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        // マイクロ秒(6桁)を含む形式
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ"
        if let date = formatter.date(from: string) {
            return date
        }

        // 秒のみの形式
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return formatter.date(from: string)
    }
}

private nonisolated struct KonomiTVGenre: Codable, Sendable {
    let major: String
    let middle: String

    func toProgramGenre() -> ProgramGenre? {
        let lv1 = ProgramGenre.level1(for: major) ?? 0xF
        let lv2 = ProgramGenre.level2(for: middle, in: lv1)
        return ProgramGenre(lv1: lv1, lv2: lv2)
    }
}

private nonisolated struct KonomiTVChannel: Codable, Sendable {
    let name: String
}

private nonisolated struct KonomiTVRecordedVideo: Codable, Sendable {
    let id: Int
    let status: String
}
