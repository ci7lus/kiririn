import Foundation
import ZIPFoundation

struct PluginPackage {
    let packageURL: URL

    private let archive: Archive

    init(url: URL) throws {
        self.packageURL = url
        self.archive = try Self.archive(from: url)
        try Self.validateEntries(in: archive)
    }

    func containsFile(named fileName: String) throws -> Bool {
        let path = try Self.validatedFileName(fileName)
        guard let entry = archive[path] else {
            return false
        }
        return entry.type != .directory
    }

    func fileData(named fileName: String) throws -> Data? {
        let path = try Self.validatedFileName(fileName)
        guard let entry = archive[path], entry.type != .directory else {
            return nil
        }

        var output = Data()
        _ = try archive.extract(entry) { chunk in
            output.append(chunk)
        }
        return output
    }

    private static func archive(from url: URL) throws -> Archive {
        do {
            return try Archive(url: url, accessMode: .read)
        } catch {
            throw PluginDecoderError.invalidArchive
        }
    }

    private static func validateEntries(in archive: Archive) throws {
        for entry in archive {
            _ = try validatedFileName(entry.path)
        }
    }

    private static func validatedFileName(_ fileName: String) throws -> String {
        guard !fileName.hasPrefix("/"),
            !fileName.split(separator: "/").contains("..")
        else {
            throw NSError(
                domain: "PluginPackage", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Unsafe ZIP file path"]
            )
        }
        return fileName
    }
}

enum PluginDecoderError: LocalizedError {
    case invalidArchive

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "無効なプラグインパッケージです"
        }
    }
}

struct PluginDecoder {
    static func decode(url: URL) throws -> PluginPackage {
        try PluginPackage(url: url)
    }
}
