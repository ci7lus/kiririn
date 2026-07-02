import Foundation

nonisolated enum LocalRecordPath {
    static var directoryURL: URL {
        #if os(iOS)
            let documentsURL = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first!
            return documentsURL.appendingPathComponent("Downloads", isDirectory: true)
        #else
            let appSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            return appSupportURL.appendingPathComponent(
                "kiririn/Downloads", isDirectory: true)
        #endif
    }

    static func videoURL(fileName: String) -> URL {
        directoryURL.appendingPathComponent(fileName)
    }

    static func recordID(serverId: String, recordID: String) -> String {
        "\(serverId)_\(recordID)".addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? UUID().uuidString
    }
}
