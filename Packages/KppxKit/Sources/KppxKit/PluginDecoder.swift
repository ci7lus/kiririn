import Foundation
import ZIPFoundation

public struct PluginPackage {
    public let packageURL: URL

    private let archive: Archive

    public init(url: URL) throws {
        self.packageURL = url
        self.archive = try Self.archive(from: url)
        try Self.validateEntries(in: archive)
    }

    public func containsFile(named fileName: String) throws -> Bool {
        let path = try Self.validatedFileName(fileName)
        guard let entry = archive[path] else {
            return false
        }
        return entry.type == .file
    }

    public func fileData(named fileName: String) throws -> Data? {
        let path = try Self.validatedFileName(fileName)
        guard let entry = archive[path], entry.type == .file else {
            return nil
        }

        var output = Data()
        _ = try archive.extract(entry) { chunk in
            output.append(chunk)
        }
        return output
    }

    public func extract(to directoryURL: URL, fileManager: FileManager = .default) throws {
        let destinationURL = directoryURL.standardizedFileURL
        guard destinationURL.isFileURL else {
            throw PluginDecoderError.invalidArchive
        }

        try fileManager.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )

        for entry in archive {
            let path = try Self.validatedFileName(entry.path)
            let isDirectory: Bool
            switch entry.type {
            case .file:
                isDirectory = false
            case .directory:
                isDirectory = true
            case .symlink:
                throw PluginDecoderError.unsupportedEntry
            }
            let outputURL = destinationURL.appending(
                path: path,
                directoryHint: isDirectory ? .isDirectory : .notDirectory
            )
            _ = try archive.extract(entry, to: outputURL)
        }
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
            guard entry.type != .symlink else {
                throw PluginDecoderError.unsupportedEntry
            }
        }
    }

    private static func validatedFileName(_ fileName: String) throws -> String {
        guard !fileName.isEmpty,
            !fileName.hasPrefix("/"),
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

public enum PluginDecoderError: LocalizedError, Equatable {
    case invalidArchive
    case unsupportedEntry

    public var errorDescription: String? {
        switch self {
        case .invalidArchive: return "無効なプラグインパッケージです"
        case .unsupportedEntry: return "シンボリックリンクを含むプラグインパッケージは利用できません"
        }
    }
}

public struct PluginDecoder {
    public static func decode(url: URL) throws -> PluginPackage {
        try PluginPackage(url: url)
    }
}
