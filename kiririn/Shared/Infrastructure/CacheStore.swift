import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Logging
import Observation

struct CacheDatabaseFailureFeedback: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

private enum CacheStoreError: Error {
    case persistentDatabaseInitializationFailed
}

@Observable
class CacheStore {
    private let logger = Logging.Logger(label: "CacheStore")
    private let dbQueue: DatabaseQueue
    private let databaseURL: URL?

    /// Monotonically increasing counter. Incremented on every playback-position save or delete.
    private(set) var playbackPositionSaveToken: Int = 0
    private(set) var lastSavedPlaybackPosition: (playableID: String, position: Float?)?
    private(set) var databaseFailureFeedback: CacheDatabaseFailureFeedback?

    @ObservationIgnored
    private var didReportDatabaseFailure = false

    init() {
        let persistentDatabaseURL = Self.persistentDatabaseURL()
        var persistentDatabaseError: Error?

        do {
            let persistentQueue = try Self.makeDatabaseQueue(at: persistentDatabaseURL)
            try Self.migrator.migrate(persistentQueue)
            self.dbQueue = persistentQueue
            self.databaseURL = persistentDatabaseURL
            return
        } catch {
            persistentDatabaseError = error
            logger.error(
                "CacheStore database initialization failed, falling back to in-memory DB: \(error)")
        }

        let inMemoryQueue = try! DatabaseQueue()
        try? Self.migrator.migrate(inMemoryQueue)
        self.dbQueue = inMemoryQueue
        self.databaseURL = nil
        reportDatabaseFailureIfNeeded(
            operation: "initialize persistent cache database",
            error: persistentDatabaseError ?? CacheStoreError.persistentDatabaseInitializationFailed
        )
    }

    init(databaseQueue: DatabaseQueue) {
        self.dbQueue = databaseQueue
        self.databaseURL = nil
        try? Self.migrator.migrate(databaseQueue)
    }

    func close() throws {
        try dbQueue.close()
    }

    @discardableResult
    static func deletePersistentDatabaseFiles() throws -> Bool {
        let fileManager = FileManager.default
        var didDeleteFile = false

        for url in persistentDatabaseFileURLs() {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try fileManager.removeItem(at: url)
            didDeleteFile = true
        }

        return didDeleteFile
    }

    #if DEBUG
        func triggerDatabaseFailureFeedbackForDebug() async {
            do {
                _ = try dbQueue.read { db in
                    return try Row.fetchOne(db, sql: "SELECT * FROM cache_store_failure_probe")
                }
            } catch {
                reportDatabaseFailureIfNeeded(operation: "debug cache failure probe", error: error)
            }
        }
    #endif

    private func reportDatabaseFailureIfNeeded(operation: String, error: Error) {
        guard !(error is CancellationError) else { return }
        logger.error("CacheStore database query failed during \(operation): \(error)")
        if let databaseURL {
            logger.error("CacheStore persistent database path: \(databaseURL.path)")
        }
        guard !didReportDatabaseFailure else { return }
        didReportDatabaseFailure = true
        databaseFailureFeedback = CacheDatabaseFailureFeedback(
            message: "キャッシュが破損している可能性があります")
    }

    func cacheServices(_ services: [TVService], serverId: String) async {
        do {
            try await self.dbQueue.write { db in
                try TVService
                    .filter(TVService.Columns.serverId == serverId)
                    .deleteAll(db)
                for service in services {
                    try service.insert(db, onConflict: .replace)
                }
            }
        } catch {
            self.logger.error("Failed to cache services: \(error)")
            reportDatabaseFailureIfNeeded(operation: "cache services", error: error)
        }
    }

    func loadCachedServices(serverId: String) async -> [TVService] {
        do {
            return try await dbQueue.read { db in
                try TVService
                    .filter(TVService.Columns.serverId == serverId)
                    .fetchAll(db)
            }
        } catch {
            reportDatabaseFailureIfNeeded(operation: "load cached services", error: error)
            return []
        }
    }

    func loadFavoriteServices() async -> [FavoriteServiceRecord] {
        do {
            return try await dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT networkId, serviceId, displayOrder FROM favorite_service"
                )
                return rows.map { row in
                    FavoriteServiceRecord(
                        networkId: row["networkId"],
                        serviceId: row["serviceId"],
                        displayOrder: row["displayOrder"]
                    )
                }
            }
        } catch {
            reportDatabaseFailureIfNeeded(operation: "load favorite services", error: error)
            return []
        }
    }

    func saveFavoriteService(_ service: TVService, displayOrder: Int? = nil) async {
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO favorite_service (networkId, serviceId, displayOrder)
                        VALUES (?, ?, ?)
                        ON CONFLICT(networkId, serviceId)
                        DO UPDATE SET
                            displayOrder = COALESCE(excluded.displayOrder, favorite_service.displayOrder)
                        """,
                    arguments: [service.networkId, service.serviceId, displayOrder]
                )
            }
        } catch {
            logger.error("Failed to save favorite service: \(error)")
            reportDatabaseFailureIfNeeded(operation: "save favorite service", error: error)
        }
    }

    func saveFavoriteServices(_ favorites: [FavoriteServiceRecord]) async {
        guard !favorites.isEmpty else { return }

        do {
            try await dbQueue.write { db in
                for favorite in favorites {
                    try db.execute(
                        sql: """
                            UPDATE favorite_service
                            SET displayOrder = ?
                            WHERE networkId = ? AND serviceId = ?
                            """,
                        arguments: [
                            favorite.displayOrder,
                            favorite.networkId,
                            favorite.serviceId,
                        ]
                    )
                }
            }
        } catch {
            logger.error("Failed to save favorite service orders: \(error)")
            reportDatabaseFailureIfNeeded(operation: "save favorite service orders", error: error)
        }
    }

    func deleteFavoriteService(_ service: TVService) async {
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM favorite_service WHERE networkId = ? AND serviceId = ?",
                    arguments: [service.networkId, service.serviceId]
                )
            }
        } catch {
            logger.error("Failed to delete favorite service: \(error)")
            reportDatabaseFailureIfNeeded(operation: "delete favorite service", error: error)
        }
    }

    func cachePrograms(_ programs: [Program], serverId: String) async {
        let now = Date()
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 60 * 60)
        do {
            try await self.dbQueue.write { db in
                try db.execute(
                    sql:
                        "DELETE FROM program WHERE serverId = :serverId AND (endAt > :now OR startAt < :twoDaysAgo)",
                    arguments: ["serverId": serverId, "now": now, "twoDaysAgo": twoDaysAgo]
                )

                for var program in programs {
                    program.updatedAt = now
                    try program.insert(db, onConflict: .replace)
                }

                try Self.upsertLastProgramFullFetchDate(now, serverId: serverId, in: db)
            }
        } catch {
            self.logger.error("Failed to cache programs for server \(serverId): \(error)")
            reportDatabaseFailureIfNeeded(operation: "cache programs", error: error)
        }
    }

    func loadLastProgramFullFetchDates() async -> [String: Date] {
        do {
            return try await dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql:
                        "SELECT serverId, lastSuccessfulProgramFullFetchAt FROM program_fetch_status"
                )
                return Dictionary(
                    uniqueKeysWithValues: rows.map { row in
                        let serverId: String = row["serverId"]
                        let fetchedAt: Date = row["lastSuccessfulProgramFullFetchAt"]
                        return (serverId, fetchedAt)
                    })
            }
        } catch {
            reportDatabaseFailureIfNeeded(
                operation: "load last program full fetch dates", error: error)
            return [:]
        }
    }

    func saveLastProgramFullFetchDate(_ date: Date, serverId: String) async {
        do {
            try await dbQueue.write { db in
                try Self.upsertLastProgramFullFetchDate(date, serverId: serverId, in: db)
            }
        } catch {
            logger.error(
                "Failed to save last program full fetch date for server \(serverId): \(error)")
            reportDatabaseFailureIfNeeded(
                operation: "save last program full fetch date", error: error)
        }
    }

    func loadCachedPrograms(from: Date? = nil, until date: Date) async -> [Program] {
        do {
            return try await dbQueue.read { db in
                var sql = """
                    SELECT * FROM (
                        SELECT *, ROW_NUMBER() OVER (PARTITION BY serviceId, networkId, startAt ORDER BY updatedAt DESC) as rn
                        FROM program
                    ) WHERE rn = 1
                    """

                if from != nil {
                    sql = """
                        SELECT * FROM (
                            SELECT *, ROW_NUMBER() OVER (PARTITION BY serviceId, networkId, startAt ORDER BY updatedAt DESC) as rn
                            FROM program
                            WHERE (startAt >= :from AND startAt < :until)
                               OR (endAt > :from AND startAt < :from)
                               OR (duration = 0 AND startAt >= :from AND startAt < :until)
                        ) WHERE rn = 1
                        """
                } else {
                    sql = """
                        SELECT * FROM (
                            SELECT *, ROW_NUMBER() OVER (PARTITION BY serviceId, networkId, startAt ORDER BY updatedAt DESC) as rn
                            FROM program
                            WHERE startAt < :until OR duration = 0
                        ) WHERE rn = 1
                        """
                }

                return try Program.fetchAll(
                    db, sql: sql, arguments: StatementArguments(["from": from, "until": date]))
            }
        } catch {
            reportDatabaseFailureIfNeeded(operation: "load cached programs", error: error)
            return []
        }
    }

    func searchPrograms(query: String, limit: Int = 200) async -> [Program] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let escaped =
            trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"

        do {
            return try await dbQueue.read { db in
                let sql = """
                    SELECT p.*
                    FROM (
                        SELECT *,
                               ROW_NUMBER() OVER (
                                   PARTITION BY serverId, serviceId, networkId, startAt
                                   ORDER BY updatedAt DESC
                               ) AS rn
                        FROM program
                    ) p
                    INNER JOIN service s
                        ON s.serverId = p.serverId
                       AND s.serviceId = p.serviceId
                       AND s.networkId = p.networkId
                    WHERE p.rn = 1
                      AND (
                            p.name LIKE :pattern ESCAPE '\\'
                         OR p.desc LIKE :pattern ESCAPE '\\'
                         OR p.extended LIKE :pattern ESCAPE '\\'
                         OR s.name LIKE :pattern ESCAPE '\\'
                      )
                    ORDER BY p.startAt DESC, s.name ASC
                    LIMIT :limit
                    """

                return try Program.fetchAll(
                    db,
                    sql: sql,
                    arguments: StatementArguments([
                        "pattern": pattern,
                        "limit": limit,
                    ])
                )
            }
        } catch {
            reportDatabaseFailureIfNeeded(operation: "search programs", error: error)
            return []
        }
    }

    func cacheLogos(_ serviceLogos: [TVServiceLogo]) async {
        do {
            try await self.dbQueue.write { db in
                for serviceLogo in serviceLogos {
                    _ = try Self.upsertServiceLogo(serviceLogo, in: db)
                }
            }
        } catch {
            self.logger.error("Failed to cache logos: \(error)")
            reportDatabaseFailureIfNeeded(operation: "cache logos", error: error)
        }
    }

    func cacheLogo(
        serviceId: Int,
        networkId: Int,
        data: Data,
        preferredID: String? = nil,
        updatedAt: Date = Date()
    ) async -> TVServiceLogo? {
        do {
            return try await dbQueue.write { db in
                let logo = TVServiceLogo(
                    id: preferredID ?? "\(networkId)-\(serviceId)",
                    serviceId: serviceId,
                    networkId: networkId,
                    data: data,
                    updatedAt: updatedAt
                )
                return try Self.upsertServiceLogo(logo, in: db)
            }
        } catch {
            logger.error(
                "Failed to cache logo for service \(networkId)-\(serviceId): \(error)")
            reportDatabaseFailureIfNeeded(operation: "cache logo", error: error)
            return nil
        }
    }

    func loadServiceLogos() async -> [TVServiceLogo] {
        do {
            return try await dbQueue.read { db in
                try TVServiceLogo.fetchAll(db)
            }
        } catch {
            reportDatabaseFailureIfNeeded(operation: "load service logos", error: error)
            return []
        }
    }

    func cleanupOldPrograms() async {
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        else {
            return
        }
        do {
            _ = try await dbQueue.write { db in
                try Program
                    .filter(Program.Columns.endAt < yesterday)
                    .deleteAll(db)
            }
        } catch {
            self.logger.error("Failed to cleanup old programs: \(error)")
            reportDatabaseFailureIfNeeded(operation: "cleanup old programs", error: error)
        }
    }

    func fetchCurrentProgram(for service: TVService) async -> Program? {
        let now = Date()
        do {
            return try await dbQueue.read { db in
                let sql = """
                    SELECT * FROM (
                        SELECT *, ROW_NUMBER() OVER (PARTITION BY serviceId, networkId, startAt ORDER BY updatedAt DESC) as rn
                        FROM program
                        WHERE serviceId = :serviceId AND networkId = :networkId
                          AND startAt < :now
                          AND (endAt > :now OR duration = 0)
                    ) WHERE rn = 1
                    ORDER BY startAt ASC
                    LIMIT 1
                    """
                return try Program.fetchOne(
                    db, sql: sql,
                    arguments: StatementArguments([
                        "serviceId": service.serviceId,
                        "networkId": service.networkId,
                        "now": now,
                    ]))
            }
        } catch {
            reportDatabaseFailureIfNeeded(operation: "fetch current program", error: error)
            return nil
        }
    }

    func fetchNextProgram(for service: TVService) async -> Program? {
        let now = Date()
        do {
            return try await dbQueue.read { db in
                let sql = """
                    SELECT * FROM (
                        SELECT *, ROW_NUMBER() OVER (PARTITION BY serviceId, networkId, startAt ORDER BY updatedAt DESC) as rn
                        FROM program
                        WHERE serviceId = :serviceId AND networkId = :networkId
                          AND startAt >= :now
                    ) WHERE rn = 1
                    ORDER BY startAt ASC
                    LIMIT 1
                    """
                return try Program.fetchOne(
                    db, sql: sql,
                    arguments: StatementArguments([
                        "serviceId": service.serviceId,
                        "networkId": service.networkId,
                        "now": now,
                    ]))
            }
        } catch {
            reportDatabaseFailureIfNeeded(operation: "fetch next program", error: error)
            return nil
        }
    }

    func fetchNextProgram(for service: TVService, currentProgram: Program?) async -> Program? {
        guard let currentProgram else {
            return await fetchNextProgram(for: service)
        }

        do {
            return try await dbQueue.read { db in
                var sql = """
                    SELECT * FROM (
                        SELECT *, ROW_NUMBER() OVER (PARTITION BY serviceId, networkId, startAt ORDER BY updatedAt DESC) as rn
                        FROM program
                        WHERE serviceId = :serviceId AND networkId = :networkId
                    """

                var args: [String: (any DatabaseValueConvertible)?] = [
                    "serviceId": service.serviceId,
                    "networkId": service.networkId,
                ]

                if currentProgram.endAt > currentProgram.startAt,
                    currentProgram.duration > 0,
                    currentProgram.duration != 604_065
                {
                    sql += " AND startAt >= :endAt"
                    args["endAt"] = currentProgram.endAt
                } else {
                    sql += " AND startAt > :startAt"
                    args["startAt"] = currentProgram.startAt
                }

                if let currentEventId = currentProgram.eventId {
                    sql += " AND eventId != :eventId"
                    args["eventId"] = currentEventId
                }

                sql += """
                    ) WHERE rn = 1
                    ORDER BY startAt ASC
                    LIMIT 1
                    """

                let statementArgs = StatementArguments(args)
                return try Program.fetchOne(db, sql: sql, arguments: statementArgs)
            }
        } catch {
            reportDatabaseFailureIfNeeded(
                operation: "fetch next program from current", error: error)
            return nil
        }
    }

    func fetchAllCurrentPrograms() async -> [Program] {
        let now = Date()
        do {
            return try await dbQueue.read { db in
                let sql = """
                    SELECT * FROM (
                        SELECT *, ROW_NUMBER() OVER (PARTITION BY serviceId, networkId, startAt ORDER BY updatedAt DESC) as rn
                        FROM program
                        WHERE startAt < :now
                          AND (endAt > :now OR duration = 0)
                    ) WHERE rn = 1
                    """
                return try Program.fetchAll(
                    db, sql: sql, arguments: StatementArguments(["now": now]))
            }
        } catch {
            reportDatabaseFailureIfNeeded(operation: "fetch all current programs", error: error)
            return []
        }
    }

    func fetchAllNextPrograms() async -> [Program] {
        let now = Date()
        do {
            return try await dbQueue.read { db in
                let sql = """
                    SELECT p.*
                    FROM (
                        SELECT *, ROW_NUMBER() OVER (PARTITION BY serviceId, networkId, startAt ORDER BY updatedAt DESC) as rn
                        FROM program
                    ) p
                    INNER JOIN (
                        SELECT networkId, serviceId, MIN(startAt) AS nextStartAt
                        FROM (
                            SELECT *, ROW_NUMBER() OVER (PARTITION BY serviceId, networkId, startAt ORDER BY updatedAt DESC) as rn
                            FROM program
                        )
                        WHERE rn = 1 AND startAt >= :now
                        GROUP BY networkId, serviceId
                    ) n
                    ON p.networkId = n.networkId
                    AND p.serviceId = n.serviceId
                    AND p.startAt = n.nextStartAt
                    WHERE p.rn = 1
                    """
                return try Program.fetchAll(
                    db, sql: sql, arguments: StatementArguments(["now": now]))
            }
        } catch {
            reportDatabaseFailureIfNeeded(operation: "fetch all next programs", error: error)
            return []
        }
    }

    func cacheCaptureHistoryItem(_ item: CaptureHistoryItem) async {
        do {
            try await self.dbQueue.write { db in
                try item.insert(db, onConflict: .replace)
            }
        } catch {
            self.logger.error("Failed to cache capture history item: \(error)")
            reportDatabaseFailureIfNeeded(operation: "cache capture history item", error: error)
        }
    }

    func updateCaptureHistoryItemVariantPaths(id: String, variantPaths: [String]) async {
        let json: String?
        if variantPaths.isEmpty {
            json = nil
        } else if let data = try? JSONEncoder().encode(variantPaths),
            let str = String(data: data, encoding: .utf8)
        {
            json = str
        } else {
            json = nil
        }
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE capture_history SET variantPaths = ? WHERE id = ?",
                    arguments: [json, id]
                )
            }
        } catch {
            self.logger.error("Failed to update variant paths: \(error)")
            reportDatabaseFailureIfNeeded(
                operation: "update capture history variant paths", error: error)
        }
    }

    func fetchCaptureHistoryItem(id: String) async -> CaptureHistoryItem? {
        do {
            return try await dbQueue.read { db in
                try CaptureHistoryItem
                    .filter(CaptureHistoryItem.Columns.id == id)
                    .fetchOne(db)
            }
        } catch {
            self.logger.error("Failed to fetch capture history item: \(error)")
            reportDatabaseFailureIfNeeded(operation: "fetch capture history item", error: error)
            return nil
        }
    }

    func deleteCaptureHistoryItem(id: String) async {
        do {
            _ = try await self.dbQueue.write { db in
                try CaptureHistoryItem.filter(CaptureHistoryItem.Columns.id == id).deleteAll(db)
            }
        } catch {
            self.logger.error("Failed to delete capture history item: \(error)")
            reportDatabaseFailureIfNeeded(operation: "delete capture history item", error: error)
        }
    }

    func clearCaptureHistory() async {
        do {
            _ = try await self.dbQueue.write { db in
                try CaptureHistoryItem.deleteAll(db)
            }
        } catch {
            self.logger.error("Failed to clear capture history: \(error)")
            reportDatabaseFailureIfNeeded(operation: "clear capture history", error: error)
        }
    }

    func fetchCaptureHistory(searchText: String, limit: Int, offset: Int) async
        -> [CaptureHistoryItem]
    {
        do {
            return try await dbQueue.read { db in
                var request = CaptureHistoryItem.all()
                if !searchText.isEmpty {
                    request = request.filter(
                        CaptureHistoryItem.Columns.programName.like("%\(searchText)%")
                            || CaptureHistoryItem.Columns.serviceName.like("%\(searchText)%")
                            || CaptureHistoryItem.Columns.caption.like("%\(searchText)%")
                    )
                }
                return
                    try request
                    .order(CaptureHistoryItem.Columns.date.desc)
                    .limit(limit, offset: offset)
                    .fetchAll(db)
            }
        } catch {
            reportDatabaseFailureIfNeeded(operation: "fetch capture history", error: error)
            return []
        }
    }

    func savePlaybackPosition(playableID: String, position: Float) async {
        let clamped = min(max(0, Double(position)), 1)
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO playback_position (playableId, position, updatedAt)
                        VALUES (?, ?, ?)
                        ON CONFLICT(playableId)
                        DO UPDATE SET position = excluded.position, updatedAt = excluded.updatedAt
                        """,
                    arguments: [playableID, clamped, Date()]
                )
            }
            logger.info("Saved playback position: id=\(playableID), position=\(clamped)")
            lastSavedPlaybackPosition = (playableID: playableID, position: Float(clamped))
            playbackPositionSaveToken &+= 1
        } catch {
            logger.error("Failed to save playback position: \(error)")
            reportDatabaseFailureIfNeeded(operation: "save playback position", error: error)
        }
    }

    func loadPlaybackPosition(playableID: String) async -> Float? {
        do {
            return try await dbQueue.read { db in
                let value = try Double.fetchOne(
                    db,
                    sql: "SELECT position FROM playback_position WHERE playableId = ?",
                    arguments: [playableID]
                )
                return value.map { Float($0) }
            }
        } catch is CancellationError {
            return nil
        } catch {
            logger.error("Failed to load playback position: \(error)")
            reportDatabaseFailureIfNeeded(operation: "load playback position", error: error)
            return nil
        }
    }

    func deletePlaybackPosition(playableID: String) async {
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM playback_position WHERE playableId = ?",
                    arguments: [playableID]
                )
            }
            logger.info("Deleted playback position: id=\(playableID)")
            lastSavedPlaybackPosition = (playableID: playableID, position: nil)
            playbackPositionSaveToken &+= 1
        } catch {
            logger.error("Failed to delete playback position: \(error)")
            reportDatabaseFailureIfNeeded(operation: "delete playback position", error: error)
        }
    }

    func saveLocalRecord(_ item: LocalRecordItem) async {
        do {
            try await self.dbQueue.write { db in
                try item.insert(db, onConflict: .replace)
            }
        } catch {
            self.logger.error("Failed to save local record: \(error)")
            reportDatabaseFailureIfNeeded(operation: "save local record", error: error)
        }
    }

    func loadLocalRecords() async -> [LocalRecordItem] {
        do {
            return try await dbQueue.read { db in
                try LocalRecordItem.order(LocalRecordItem.Columns.createdAt.desc).fetchAll(db)
            }
        } catch {
            reportDatabaseFailureIfNeeded(operation: "load local records", error: error)
            return []
        }
    }

    func deleteLocalRecord(id: String) async {
        do {
            _ = try await self.dbQueue.write { db in
                try LocalRecordItem.filter(LocalRecordItem.Columns.id == id).deleteAll(db)
            }
        } catch {
            self.logger.error("Failed to delete local record: \(error)")
            reportDatabaseFailureIfNeeded(operation: "delete local record", error: error)
        }
    }
}

extension CacheStore {
    nonisolated fileprivate static func upsertServiceLogo(
        _ serviceLogo: TVServiceLogo, in db: Database
    ) throws
        -> TVServiceLogo?
    {
        let normalizedData = normalizedLogoData(serviceLogo.data)

        let request =
            TVServiceLogo
            .filter(TVServiceLogo.Columns.serviceId == serviceLogo.serviceId)
            .filter(TVServiceLogo.Columns.networkId == serviceLogo.networkId)
        let existingLogos = try request.fetchAll(db)

        if existingLogos.contains(where: { normalizedLogoData($0.data) == normalizedData }) {
            return nil
        }

        if !existingLogos.isEmpty {
            try request.deleteAll(db)
        }

        var normalizedLogo = serviceLogo
        normalizedLogo.data = normalizedData
        if let existingID = existingLogos.first?.id {
            normalizedLogo.id = existingID
        }

        try normalizedLogo.insert(db, onConflict: .replace)
        return normalizedLogo
    }

    nonisolated fileprivate static func normalizedLogoData(_ data: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return data
        }
        let mutableData = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(
                mutableData, "public.png" as CFString, 1, nil
            )
        else {
            return data
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            return data
        }
        return mutableData as Data
    }

    nonisolated fileprivate static func upsertLastProgramFullFetchDate(
        _ date: Date,
        serverId: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO program_fetch_status (serverId, lastSuccessfulProgramFullFetchAt)
                VALUES (:serverId, :fetchedAt)
                ON CONFLICT(serverId)
                DO UPDATE SET lastSuccessfulProgramFullFetchAt = excluded.lastSuccessfulProgramFullFetchAt
                """,
            arguments: ["serverId": serverId, "fetchedAt": date]
        )
    }

    fileprivate static func persistentDatabaseURL() -> URL {
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let directoryURL = appSupportURL.appendingPathComponent("kiririn", isDirectory: true)
        return directoryURL.appendingPathComponent("cache.sqlite")
    }

    fileprivate static func persistentDatabaseFileURLs() -> [URL] {
        let databaseURL = persistentDatabaseURL()
        return [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
    }

    fileprivate static func makeDatabaseQueue(at databaseURL: URL) throws -> DatabaseQueue {
        let directoryURL = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        Logging.Logger(label: "CacheStore").info("cache store path: \(databaseURL.path)")
        return try DatabaseQueue(path: databaseURL.path)
    }

    fileprivate static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("init-20260508") { db in
            try db.create(table: "service") { t in
                t.primaryKey("id", .text)
                t.column("serviceId", .integer).notNull()
                t.column("networkId", .integer).notNull()
                t.column("transportStreamId", .integer)
                t.column("name", .text).notNull()
                t.column("type", .integer).notNull()
                t.column("hasLogoData", .boolean).notNull()
                t.column("remoteControlKeyId", .integer)
                t.column("channel", .jsonText)
                t.column("serverId", .text).notNull()
                t.column("providerIdentifier", .text)
            }

            try db.create(table: "program") { t in
                t.column("id", .text).notNull()
                t.column("serverId", .text).notNull()
                t.primaryKey(["id", "serverId"])

                t.column("eventId", .integer)
                t.column("startAt", .datetime).notNull()
                t.column("endAt", .datetime).notNull()
                t.column("duration", .integer).notNull()
                t.column("genres", .any).notNull()
                t.column("name", .text).notNull()
                t.column("desc", .text)
                t.column("extended", .jsonText)
                t.column("serviceId", .integer).notNull()
                t.column("networkId", .integer).notNull()
                t.column("updatedAt", .datetime)
            }

            try db.create(table: "service_logo") { t in
                t.primaryKey("id", .text)
                t.column("serviceId", .integer).notNull()
                t.column("networkId", .integer).notNull()
                t.column("data", .blob).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "capture_history") { t in
                t.column("id", .text).primaryKey()
                t.column("date", .datetime).notNull().indexed()
                t.column("filePath", .text).notNull()
                t.column("type", .text).notNull()
                t.column("programName", .text).indexed()
                t.column("serviceName", .text).indexed()
                t.column("caption", .text)
                t.column("broadcastTime", .datetime)
                t.column("variantPaths", .text)
            }

            try db.create(table: "playback_position") { t in
                t.column("playableId", .text).primaryKey()
                t.column("position", .double).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
            }

            try db.create(table: "local_record") { t in
                t.column("id", .text).primaryKey()
                t.column("serverId", .text).notNull()
                t.column("name", .text).notNull()
                t.column("serviceName", .text)
                t.column("startAt", .datetime)
                t.column("duration", .double)
                t.column("data", .blob).notNull()
                t.column("videoFileName", .text).notNull()
                t.column("thumbnailData", .blob)
                t.column("downloadStateRaw", .text)
                t.column("downloadErrorMessage", .text)
                t.column("downloadedAt", .datetime)
                t.column("createdAt", .datetime).notNull().indexed()
            }

            try db.create(table: "favorite_service") { t in
                t.column("networkId", .integer).notNull()
                t.column("serviceId", .integer).notNull()
                t.column("displayOrder", .integer)
                t.primaryKey(["networkId", "serviceId"])
            }

            try db.create(table: "program_fetch_status") { t in
                t.column("serverId", .text).primaryKey()
                t.column("lastSuccessfulProgramFullFetchAt", .datetime).notNull()
            }

            try db.create(
                index: "index_program_on_serverId", on: "program", columns: ["serverId"])
            try db.create(
                index: "index_program_on_serviceId_networkId_startAt", on: "program",
                columns: ["serviceId", "networkId", "startAt"])
        }

        return migrator

    }
}
