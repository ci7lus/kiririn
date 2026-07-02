import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Logging
import Observation

@Observable
class CacheStore {
    private let logger = Logging.Logger(label: "CacheStore")
    private let dbQueue: DatabaseQueue

    /// Monotonically increasing counter. Incremented on every playback-position save or delete.
    private(set) var playbackPositionSaveToken: Int = 0
    private(set) var lastSavedPlaybackPosition: (playableID: String, position: Float?)?

    init() {
        do {
            let persistentQueue = try Self.makeDatabaseQueue()
            try Self.migrator.migrate(persistentQueue)
            self.dbQueue = persistentQueue
            return
        } catch {
            logger.error(
                "CacheStore database initialization failed, falling back to in-memory DB: \(error)")
        }

        let inMemoryQueue = try! DatabaseQueue()
        try? Self.migrator.migrate(inMemoryQueue)
        self.dbQueue = inMemoryQueue
    }

    init(databaseQueue: DatabaseQueue) {
        self.dbQueue = databaseQueue
        try? Self.migrator.migrate(databaseQueue)
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
        }
    }

    func loadCachedServices(serverId: String) async -> [TVService] {
        guard
            let cached = try? await dbQueue.read({ db in
                try TVService
                    .filter(TVService.Columns.serverId == serverId)
                    .fetchAll(db)
            })
        else { return [] }
        return cached
    }

    func loadFavoriteServices() async -> [FavoriteServiceRecord] {
        guard
            let favorites = try? await dbQueue.read({ db in
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
            })
        else { return [] }
        return favorites
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
        }
    }

    func loadLastProgramFullFetchDates() async -> [String: Date] {
        guard
            let dates = try? await dbQueue.read({ db in
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
            })
        else {
            return [:]
        }

        return dates
    }

    func saveLastProgramFullFetchDate(_ date: Date, serverId: String) async {
        do {
            try await dbQueue.write { db in
                try Self.upsertLastProgramFullFetchDate(date, serverId: serverId, in: db)
            }
        } catch {
            logger.error(
                "Failed to save last program full fetch date for server \(serverId): \(error)")
        }
    }

    func loadCachedPrograms(from: Date? = nil, until date: Date) async -> [Program] {
        guard
            let cached = try? await dbQueue.read({ db in
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
            })
        else { return [] }
        return cached
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

        return
            (try? await dbQueue.read { db in
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
            }) ?? []
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
            return nil
        }
    }

    func loadServiceLogos() async -> [TVServiceLogo] {
        guard
            let cached = try? await dbQueue.read({ db in
                try TVServiceLogo.fetchAll(db)
            })
        else { return [] }
        return cached
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
        }
    }

    func fetchCurrentProgram(for service: TVService) async -> Program? {
        let now = Date()
        return try? await dbQueue.read { db in
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
    }

    func fetchNextProgram(for service: TVService) async -> Program? {
        let now = Date()
        return try? await dbQueue.read { db in
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
    }

    func fetchNextProgram(for service: TVService, currentProgram: Program?) async -> Program? {
        guard let currentProgram else {
            return await fetchNextProgram(for: service)
        }

        return try? await dbQueue.read { db in
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
    }

    func fetchAllCurrentPrograms() async -> [Program] {
        let now = Date()
        return
            (try? await dbQueue.read { db in
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
            }) ?? []
    }

    func fetchAllNextPrograms() async -> [Program] {
        let now = Date()
        return
            (try? await dbQueue.read { db in
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
            }) ?? []
    }

    func cacheCaptureHistoryItem(_ item: CaptureHistoryItem) async {
        do {
            try await self.dbQueue.write { db in
                try item.insert(db, onConflict: .replace)
            }
        } catch {
            self.logger.error("Failed to cache capture history item: \(error)")
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
        }
    }

    func clearCaptureHistory() async {
        do {
            _ = try await self.dbQueue.write { db in
                try CaptureHistoryItem.deleteAll(db)
            }
        } catch {
            self.logger.error("Failed to clear capture history: \(error)")
        }
    }

    func fetchCaptureHistory(searchText: String, limit: Int, offset: Int) async
        -> [CaptureHistoryItem]
    {
        guard
            let cached = try? await dbQueue.read({ db in
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
            })
        else { return [] }
        return cached
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
        }
    }

    func saveLocalRecord(_ item: LocalRecordItem) async {
        do {
            try await self.dbQueue.write { db in
                try item.insert(db, onConflict: .replace)
            }
        } catch {
            self.logger.error("Failed to save local record: \(error)")
        }
    }

    func loadLocalRecords() async -> [LocalRecordItem] {
        guard
            let cached = try? await dbQueue.read({ db in
                try LocalRecordItem.order(LocalRecordItem.Columns.createdAt.desc).fetchAll(db)
            })
        else { return [] }
        return cached
    }

    func deleteLocalRecord(id: String) async {
        do {
            _ = try await self.dbQueue.write { db in
                try LocalRecordItem.filter(LocalRecordItem.Columns.id == id).deleteAll(db)
            }
        } catch {
            self.logger.error("Failed to delete local record: \(error)")
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

    fileprivate static func makeDatabaseQueue() throws -> DatabaseQueue {
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let directoryURL = appSupportURL.appendingPathComponent("kiririn", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let databaseURL = directoryURL.appendingPathComponent("cache.sqlite")
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
                t.column("backendId", .text).notNull()
                t.column("providerIdentifier", .text)
            }

            try db.create(table: "program") { t in
                t.column("id", .text).notNull()
                t.column("backendId", .text).notNull()
                t.primaryKey(["id", "backendId"])

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
                t.column("backendId", .text).notNull()
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
                t.column("backendId", .text).primaryKey()
                t.column("lastSuccessfulProgramFullFetchAt", .datetime).notNull()
            }

            try db.create(
                index: "index_program_on_backendId", on: "program", columns: ["backendId"])
            try db.create(
                index: "index_program_on_serviceId_networkId_startAt", on: "program",
                columns: ["serviceId", "networkId", "startAt"])
        }

        migrator.registerMigration("rename-server-id-columns-20260702") { db in
            try db.execute(sql: "DROP INDEX IF EXISTS index_program_on_backendId")

            let serviceColumns = Set(
                try Row.fetchAll(db, sql: "PRAGMA table_info(service)")
                    .map { row -> String in row["name"] })
            if serviceColumns.contains("backendId"), !serviceColumns.contains("serverId") {
                try db.execute(sql: "ALTER TABLE service RENAME COLUMN backendId TO serverId")
            }

            let programColumns = Set(
                try Row.fetchAll(db, sql: "PRAGMA table_info(program)")
                    .map { row -> String in row["name"] })
            if programColumns.contains("backendId"), !programColumns.contains("serverId") {
                try db.execute(sql: "ALTER TABLE program RENAME COLUMN backendId TO serverId")
            }

            let localRecordColumns = Set(
                try Row.fetchAll(db, sql: "PRAGMA table_info(local_record)")
                    .map { row -> String in row["name"] })
            if localRecordColumns.contains("backendId"), !localRecordColumns.contains("serverId") {
                try db.execute(sql: "ALTER TABLE local_record RENAME COLUMN backendId TO serverId")
            }

            let programFetchStatusColumns = Set(
                try Row.fetchAll(db, sql: "PRAGMA table_info(program_fetch_status)")
                    .map { row -> String in row["name"] })
            if programFetchStatusColumns.contains("backendId"),
                !programFetchStatusColumns.contains("serverId")
            {
                try db.execute(
                    sql: "ALTER TABLE program_fetch_status RENAME COLUMN backendId TO serverId")
            }

            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS index_program_on_serverId ON program(serverId)"
            )
        }

        return migrator

    }
}
