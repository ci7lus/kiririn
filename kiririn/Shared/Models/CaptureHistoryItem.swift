import Foundation
import GRDB

enum CaptureType: String, Codable, Sendable {
    case image
    case video
}

struct CaptureHistoryItem: Identifiable, Codable, Equatable, FetchableRecord, PersistableRecord,
    Sendable
{
    let id: String
    let date: Date
    let filePath: String
    let type: CaptureType
    let programName: String?
    let serviceName: String?
    let caption: String?
    let broadcastTime: Date?
    /// 追加バリアントのファイルパス群。filePath が index 0、以降が variants。
    let variantPaths: [String]

    init(
        id: String,
        date: Date,
        filePath: String,
        type: CaptureType,
        programName: String?,
        serviceName: String?,
        caption: String? = nil,
        broadcastTime: Date? = nil,
        variantPaths: [String] = []
    ) {
        self.id = id
        self.date = date
        self.filePath = filePath
        self.type = type
        self.programName = programName
        self.serviceName = serviceName
        self.caption = caption
        self.broadcastTime = broadcastTime
        self.variantPaths = variantPaths
    }

    var displayDate: String {
        date.formatted(.displayDateTimeFull)
    }

    var fileURL: URL {
        Self.resolveURL(path: filePath)
    }

    /// index 0 = 元画像、1 以降は variantPaths の各要素に対応する。
    func variantFileURL(at index: Int) -> URL {
        if index == 0 { return fileURL }
        let variantIndex = index - 1
        guard variantIndex < variantPaths.count else { return fileURL }
        return Self.resolveURL(path: variantPaths[variantIndex])
    }

    var allFileURLs: [URL] {
        [fileURL] + variantPaths.map { Self.resolveURL(path: $0) }
    }

    func withVariantPaths(_ paths: [String]) -> CaptureHistoryItem {
        CaptureHistoryItem(
            id: id, date: date, filePath: filePath, type: type,
            programName: programName, serviceName: serviceName,
            caption: caption, broadcastTime: broadcastTime,
            variantPaths: paths
        )
    }

    private static func resolveURL(path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        } else {
            let documentsURL = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask)[0]
            return documentsURL.appendingPathComponent(path)
        }
    }

    // MARK: - FetchableRecord

    init(row: Row) throws {
        id = row["id"]
        date = row["date"]
        filePath = row["filePath"]
        type = CaptureType(rawValue: row["type"] ?? "") ?? .image
        programName = row["programName"]
        serviceName = row["serviceName"]
        caption = row["caption"]
        broadcastTime = row["broadcastTime"]
        variantPaths = Self.decodeVariantPaths(row["variantPaths"])
    }

    private static func decodeVariantPaths(_ value: DatabaseValue) -> [String] {
        guard case .string(let str) = value.storage,
            let data = str.data(using: .utf8),
            let paths = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return paths
    }

    // MARK: - PersistableRecord

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["date"] = date
        container["filePath"] = filePath
        container["type"] = type.rawValue
        container["programName"] = programName
        container["serviceName"] = serviceName
        container["caption"] = caption
        container["broadcastTime"] = broadcastTime
        if variantPaths.isEmpty {
            container["variantPaths"] = nil as String?
        } else if let data = try? JSONEncoder().encode(variantPaths),
            let str = String(data: data, encoding: .utf8)
        {
            container["variantPaths"] = str
        }
    }
}

extension CaptureHistoryItem: TableRecord {
    static let databaseSelection: [any SQLSelectable] = [AllColumns()]
    static let databaseTableName = "capture_history"

    enum Columns: String, ColumnExpression {
        case id, date, filePath, type, programName, serviceName, caption, broadcastTime,
            variantPaths
    }
}
