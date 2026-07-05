import Foundation
import Testing

@testable import KppxKit

struct PluginDecoderTests {

    @Test func decodesValidPackage() throws {
        let packageData = storedZIPData(files: [
            ("manifest.json", Data("{}".utf8))
        ])
        let tempURL = try tempFileForTest(data: packageData, suffix: "kppx")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let package = try PluginDecoder.decode(url: tempURL)

        #expect(try package.containsFile(named: "manifest.json"))
    }

    @Test func readsFileData() throws {
        let contents = Data("hello plugin".utf8)
        let packageData = storedZIPData(files: [
            ("manifest.json", contents)
        ])
        let tempURL = try tempFileForTest(data: packageData, suffix: "kppx")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let package = try PluginDecoder.decode(url: tempURL)

        let data = try #require(try package.fileData(named: "manifest.json"))
        #expect(data == contents)
    }

    @Test func returnsNilForMissingFile() throws {
        let packageData = storedZIPData(files: [
            ("manifest.json", Data("{}".utf8))
        ])
        let tempURL = try tempFileForTest(data: packageData, suffix: "kppx")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let package = try PluginDecoder.decode(url: tempURL)

        let data = try package.fileData(named: "missing.html")
        #expect(data == nil)
    }

    @Test func extractsPackageToDirectory() throws {
        let contents = Data("hello plugin".utf8)
        let packageData = storedZIPData(files: [
            ("manifest.json", Data("{}".utf8)),
            ("pages/panel.html", contents),
        ])
        let tempURL = try tempFileForTest(data: packageData, suffix: "kppx")
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "plugin_extract_\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let package = try PluginDecoder.decode(url: tempURL)
        try package.extract(to: outputURL)

        let extractedURL = outputURL.appending(path: "pages/panel.html")
        #expect(try Data(contentsOf: extractedURL) == contents)
    }

    @Test func rejectsAbsolutePath() throws {
        let packageData = storedZIPData(files: [
            ("/etc/passwd", Data("danger".utf8))
        ])
        let tempURL = try tempFileForTest(data: packageData, suffix: "kppx")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try PluginDecoder.decode(url: tempURL)
            #expect(Bool(false))
        } catch {
            #expect(Bool(true))
        }
    }

    @Test func rejectsInvalidArchive() throws {
        let tempURL = try tempFileForTest(data: Data([0x00, 0x01, 0x02]), suffix: "kppx")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try PluginDecoder.decode(url: tempURL)
            #expect(Bool(false))
        } catch let error as PluginDecoderError {
            #expect(error == .invalidArchive)
        } catch {
            #expect(Bool(false))
        }
    }
}

private func storedZIPData(files: [(String, Data)]) -> Data {
    var localEntries = Data()
    var centralDirectory = Data()

    for (path, contents) in files {
        let pathData = Data(path.utf8)
        let crc = crc32(contents)
        let localHeaderOffset = UInt32(localEntries.count)

        localEntries.append(littleEndian(UInt32(0x0403_4b50)))
        localEntries.append(littleEndian(UInt16(20)))
        localEntries.append(littleEndian(UInt16(0)))
        localEntries.append(littleEndian(UInt16(0)))
        localEntries.append(littleEndian(UInt16(0)))
        localEntries.append(littleEndian(UInt16(0)))
        localEntries.append(littleEndian(crc))
        localEntries.append(littleEndian(UInt32(contents.count)))
        localEntries.append(littleEndian(UInt32(contents.count)))
        localEntries.append(littleEndian(UInt16(pathData.count)))
        localEntries.append(littleEndian(UInt16(0)))
        localEntries.append(pathData)
        localEntries.append(contents)

        centralDirectory.append(littleEndian(UInt32(0x0201_4b50)))
        centralDirectory.append(littleEndian(UInt16(20)))
        centralDirectory.append(littleEndian(UInt16(20)))
        centralDirectory.append(littleEndian(UInt16(0)))
        centralDirectory.append(littleEndian(UInt16(0)))
        centralDirectory.append(littleEndian(UInt16(0)))
        centralDirectory.append(littleEndian(UInt16(0)))
        centralDirectory.append(littleEndian(crc))
        centralDirectory.append(littleEndian(UInt32(contents.count)))
        centralDirectory.append(littleEndian(UInt32(contents.count)))
        centralDirectory.append(littleEndian(UInt16(pathData.count)))
        centralDirectory.append(littleEndian(UInt16(0)))
        centralDirectory.append(littleEndian(UInt16(0)))
        centralDirectory.append(littleEndian(UInt16(0)))
        centralDirectory.append(littleEndian(UInt16(0)))
        centralDirectory.append(littleEndian(UInt32(0)))
        centralDirectory.append(littleEndian(localHeaderOffset))
        centralDirectory.append(pathData)
    }

    let centralDirectoryOffset = UInt32(localEntries.count)

    var output = localEntries
    output.append(centralDirectory)
    output.append(littleEndian(UInt32(0x0605_4b50)))
    output.append(littleEndian(UInt16(0)))
    output.append(littleEndian(UInt16(0)))
    output.append(littleEndian(UInt16(files.count)))
    output.append(littleEndian(UInt16(files.count)))
    output.append(littleEndian(UInt32(centralDirectory.count)))
    output.append(littleEndian(centralDirectoryOffset))
    output.append(littleEndian(UInt16(0)))
    return output
}

private func littleEndian(_ value: UInt16) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func littleEndian(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func tempFileForTest(data: Data, suffix: String = "kppx") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "test_\(UUID().uuidString).\(suffix)")
    try data.write(to: url)
    return url
}

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            let mask = UInt32(bitPattern: -Int32(crc & 1))
            crc = (crc >> 1) ^ (0xedb8_8320 & mask)
        }
    }
    return ~crc
}
