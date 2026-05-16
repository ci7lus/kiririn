import Foundation

nonisolated enum LocalRecordPath {
    static var directoryURL: URL {
        #if os(iOS)
            let documentsURL = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first!
            return documentsURL.appendingPathComponent("LocalRecords", isDirectory: true)
        #else
            let appSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            return appSupportURL.appendingPathComponent("kiririn/LocalRecords", isDirectory: true)
        #endif
    }

    static func videoURL(fileName: String) -> URL {
        directoryURL.appendingPathComponent(fileName)
    }

    static func recordID(backendId: String, recordID: String) -> String {
        "\(backendId)_\(recordID)".addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? UUID().uuidString
    }
}
