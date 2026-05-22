import Foundation
import ZIPFoundation

struct PluginPackage {
    let archiveData: Data

    private let archive: Archive

    init(data: Data) throws {
        self.archiveData = data
        self.archive = try Self.archive(from: data)
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

    private static func archive(from data: Data) throws -> Archive {
        do {
            return try Archive(data: data, accessMode: .read)
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
    static func decode(data: Data) throws -> PluginPackage {
        try PluginPackage(data: data)
    }
}
