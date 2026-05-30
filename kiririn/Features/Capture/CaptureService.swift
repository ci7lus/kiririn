import Combine
import Foundation
import ImageIO
import Logging
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

enum PluginCaptureVariant: String, Codable, Sendable {
    case original
    case composite
}

struct PluginCaptureBlobReference: Codable, Equatable, Sendable {
    let playerID: String
    let captureID: String
    let variant: PluginCaptureVariant
    let overlayPluginManifestIDs: [String]
}

struct PluginCaptureEvent: Codable, Equatable, Sendable {
    let playerID: String
    let captureID: String
    let capturedAt: Date
    let references: [PluginCaptureBlobReference]
}

struct PluginCaptureBlob: Sendable {
    let data: Data
    let mimeType: String
}

@MainActor
final class CaptureService: ObservableObject {
    static let shared = CaptureService()
    private let logger = Logging.Logger(label: "CaptureService")

    @Published var captureFolder: URL?
    @Published var shouldIncludeIniCloudBackup: Bool {
        didSet {
            UserDefaults.standard.set(shouldIncludeIniCloudBackup, forKey: iCloudBackupKey)
            updateiCloudBackupExclusion()
        }
    }
    @Published var shouldCopyCaptureToClipboard: Bool {
        didSet {
            UserDefaults.standard.set(
                shouldCopyCaptureToClipboard, forKey: copyCaptureToClipboardKey)
        }
    }
    @Published var shouldCompositePluginOverlay: Bool {
        didSet {
            UserDefaults.standard.set(
                shouldCompositePluginOverlay, forKey: compositePluginOverlayKey)
        }
    }
    @Published var clipboardTarget: CaptureClipboardTarget {
        didSet {
            UserDefaults.standard.set(clipboardTarget.rawValue, forKey: clipboardTargetKey)
        }
    }

    let didAddCapture = PassthroughSubject<(playerID: String?, CaptureHistoryItem), Never>()
    let didUpdateCapture = PassthroughSubject<CaptureHistoryItem, Never>()
    let didClearHistory = PassthroughSubject<Void, Never>()
    let didCaptureForPlugin = PassthroughSubject<PluginCaptureEvent, Never>()

    private let folderBookmarkKey = "kiririn.capture.folder.bookmark"
    private let iCloudBackupKey = "kiririn.capture.icloud_backup"
    private let copyCaptureToClipboardKey = "kiririn.capture.copy_to_clipboard"
    private let compositePluginOverlayKey = "kiririn.capture.composite_plugin_overlay"
    private let clipboardTargetKey = "kiririn.capture.clipboard_target"
    private var cacheStore: CacheStore?

    var isExternalFolderSelected: Bool {
        #if os(macOS)
            return UserDefaults.standard.data(forKey: folderBookmarkKey) != nil
        #else
            return false
        #endif
    }

    init() {
        self.shouldIncludeIniCloudBackup = UserDefaults.standard.bool(forKey: iCloudBackupKey)
        self.shouldCopyCaptureToClipboard = UserDefaults.standard.bool(
            forKey: copyCaptureToClipboardKey)
        self.shouldCompositePluginOverlay = UserDefaults.standard.bool(
            forKey: compositePluginOverlayKey)
        self.clipboardTarget =
            CaptureClipboardTarget(
                rawValue: UserDefaults.standard.string(forKey: "kiririn.capture.clipboard_target")
                    ?? ""
            ) ?? .original
        loadCaptureFolder()
        updateiCloudBackupExclusion()
    }

    func setCacheStore(_ store: CacheStore) {
        self.cacheStore = store
    }

    func saveCapture(
        tempURL: URL,
        programName: String?,
        serviceName: String?,
        playerID: String? = nil,
        caption: String? = nil,
        broadcastTime: Date? = nil,
        overlayImage: CGImage? = nil,
        overlayPluginManifestIDs: [String] = []
    ) async throws {
        applyMetadata(
            to: tempURL, programName: programName, serviceName: serviceName, caption: caption,
            date: broadcastTime)
        let savedPath: String
        if isExternalFolderSelected {
            do {
                savedPath = try saveToFolder(
                    tempURL: tempURL, programName: programName, serviceName: serviceName,
                    extension: "jpg")
            } catch {
                savedPath = try saveToSandbox(
                    tempURL: tempURL, programName: programName, serviceName: serviceName,
                    extension: "jpg")
            }
        } else {
            savedPath = try saveToSandbox(
                tempURL: tempURL, programName: programName, serviceName: serviceName,
                extension: "jpg")
        }
        let item = await addToHistory(
            path: savedPath, type: .image, programName: programName, serviceName: serviceName,
            caption: caption, broadcastTime: broadcastTime)

        didAddCapture.send((playerID: playerID, item))

        var itemForPluginEvent = item
        var effectiveOverlayPluginManifestIDs: [String] = []
        var compositeURLForCopy: URL?

        if shouldCompositePluginOverlay, let overlay = overlayImage,
            let compositePath = try? await saveCompositedCapturePath(
                savedPath: savedPath,
                overlayImage: overlay,
                programName: programName,
                serviceName: serviceName,
                caption: caption,
                broadcastTime: broadcastTime,
                overlayPluginManifestIDs: overlayPluginManifestIDs
            )
        {
            let updatedItem = item.withVariantPaths(item.variantPaths + [compositePath])
            await cacheStore?.updateCaptureHistoryItemVariantPaths(
                id: updatedItem.id, variantPaths: updatedItem.variantPaths)
            didUpdateCapture.send(updatedItem)
            itemForPluginEvent = updatedItem
            effectiveOverlayPluginManifestIDs = overlayPluginManifestIDs
            compositeURLForCopy = updatedItem.variantFileURL(at: 1)

        }

        if let playerID {
            didCaptureForPlugin.send(
                makePluginCaptureEvent(
                    item: itemForPluginEvent,
                    playerID: playerID,
                    overlayPluginManifestIDs: effectiveOverlayPluginManifestIDs
                )
            )
        }

        if shouldCopyCaptureToClipboard {
            switch clipboardTarget {
            case .original:
                _ = copyToClipboard(url: item.fileURL)
            case .composite:
                if let compositeURLForCopy {
                    let copied = copyToClipboard(url: compositeURLForCopy)
                    if !copied {
                        _ = copyToClipboard(url: item.fileURL)
                    }
                } else {
                    _ = copyToClipboard(url: item.fileURL)
                }
            }
        }
    }

    func saveRecording(
        tempURL: URL, programName: String?, serviceName: String?, caption: String? = nil,
        broadcastTime: Date? = nil
    ) async throws {
        let savedPath: String
        let ext = tempURL.pathExtension.isEmpty ? "ts" : tempURL.pathExtension

        if isExternalFolderSelected {
            do {
                savedPath = try saveToFolder(
                    tempURL: tempURL, programName: programName, serviceName: serviceName,
                    extension: ext)
            } catch {
                savedPath = try saveToSandbox(
                    tempURL: tempURL, programName: programName, serviceName: serviceName,
                    extension: ext)
            }
        } else {
            savedPath = try saveToSandbox(
                tempURL: tempURL, programName: programName, serviceName: serviceName, extension: ext
            )
        }
        let item = await addToHistory(
            path: savedPath, type: .video, programName: programName, serviceName: serviceName,
            caption: caption, broadcastTime: broadcastTime)
        didAddCapture.send((playerID: nil, item))
    }

    func captureBlob(for reference: PluginCaptureBlobReference) async -> PluginCaptureBlob? {
        guard let item = await cacheStore?.fetchCaptureHistoryItem(id: reference.captureID),
            let targetURL = Self.captureURL(for: reference.variant, in: item)
        else {
            return nil
        }

        guard
            let data = await Task.detached(
                priority: .utility,
                operation: {
                    try? Data(contentsOf: targetURL)
                }
            ).value
        else {
            return nil
        }

        return PluginCaptureBlob(data: data, mimeType: Self.mimeType(for: targetURL))
    }

    private func addToHistory(
        path: String, type: CaptureType, programName: String?, serviceName: String?,
        caption: String?, broadcastTime: Date?
    ) async -> CaptureHistoryItem {
        let item = CaptureHistoryItem(
            id: UUID().uuidString,
            date: Date(),
            filePath: path,
            type: type,
            programName: programName,
            serviceName: serviceName,
            caption: caption,
            broadcastTime: broadcastTime
        )
        await cacheStore?.cacheCaptureHistoryItem(item)
        return item
    }

    private func makePluginCaptureEvent(
        item: CaptureHistoryItem,
        playerID: String,
        overlayPluginManifestIDs: [String]
    ) -> PluginCaptureEvent {
        var references: [PluginCaptureBlobReference] = [
            PluginCaptureBlobReference(
                playerID: playerID,
                captureID: item.id,
                variant: .original,
                overlayPluginManifestIDs: []
            )
        ]

        if !item.variantPaths.isEmpty {
            references.append(
                PluginCaptureBlobReference(
                    playerID: playerID,
                    captureID: item.id,
                    variant: .composite,
                    overlayPluginManifestIDs: overlayPluginManifestIDs
                )
            )
        }

        return PluginCaptureEvent(
            playerID: playerID,
            captureID: item.id,
            capturedAt: item.date,
            references: references
        )
    }

    func loadHistory(searchText: String, limit: Int, offset: Int) async -> [CaptureHistoryItem] {
        return await cacheStore?.fetchCaptureHistory(
            searchText: searchText, limit: limit, offset: offset) ?? []
    }

    func clearHistory() async {
        let allItems =
            await cacheStore?.fetchCaptureHistory(searchText: "", limit: 10000, offset: 0) ?? []
        for item in allItems {
            for (index, url) in item.allFileURLs.enumerated() {
                let path = index == 0 ? item.filePath : item.variantPaths[index - 1]
                if !path.hasPrefix("/") {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        await cacheStore?.clearCaptureHistory()
        didClearHistory.send(())
    }

    func deleteHistoryItem(_ item: CaptureHistoryItem) async {
        for (index, url) in item.allFileURLs.enumerated() {
            let path = index == 0 ? item.filePath : item.variantPaths[index - 1]
            if !path.hasPrefix("/") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        await cacheStore?.deleteCaptureHistoryItem(id: item.id)
    }

    // MARK: - Sandbox Saving (iOS & Mac Default)

    private func saveToSandbox(
        tempURL: URL, programName: String?, serviceName: String?, extension ext: String
    ) throws -> String {
        let capturesDir = try getCapturesDirectory()
        let fileName = generateFileName(
            programName: programName, serviceName: serviceName, extension: ext)
        let destinationURL = capturesDir.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)

        return "Captures/\(fileName)"
    }

    private func getCapturesDirectory() throws -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        let capturesDir = documentsDirectory.appendingPathComponent("Captures")

        if !FileManager.default.fileExists(atPath: capturesDir.path) {
            try FileManager.default.createDirectory(
                at: capturesDir, withIntermediateDirectories: true)
        }
        return capturesDir
    }

    private func updateiCloudBackupExclusion() {
        do {
            let capturesDir = try getCapturesDirectory()
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = !shouldIncludeIniCloudBackup
            var capturesDirMutable = capturesDir
            try capturesDirMutable.setResourceValues(resourceValues)
        } catch {
            logger.error("Failed to update iCloud backup exclusion: \(error)")
        }
    }

    // MARK: - Folder (Mac Explicit Selection)

    func saveToFolder(
        tempURL: URL, programName: String?, serviceName: String?, extension ext: String
    ) throws -> String {
        guard let folderURL = try getCaptureFolderURL() else {
            throw CaptureError.folderNotFound
        }

        let fileName = generateFileName(
            programName: programName, serviceName: serviceName, extension: ext)
        let destinationURL = folderURL.appendingPathComponent(fileName)

        if folderURL.startAccessingSecurityScopedResource() {
            defer { folderURL.stopAccessingSecurityScopedResource() }

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            return destinationURL.path
        } else {
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            return destinationURL.path
        }
    }

    private func loadCaptureFolder() {
        captureFolder = try? getCaptureFolderURL()
    }

    private func getCaptureFolderURL() throws -> URL? {
        if let bookmarkData = UserDefaults.standard.data(forKey: folderBookmarkKey) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData, options: .securityScoped,
                bookmarkDataIsStale: &isStale)
            {
                return url
            }
        }
        return nil
    }

    func setCaptureFolder(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let bookmarkData = try url.bookmarkData(
            options: .securityScoped, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmarkData, forKey: folderBookmarkKey)

        loadCaptureFolder()
    }

    func resetToSandbox() {
        UserDefaults.standard.removeObject(forKey: folderBookmarkKey)
        loadCaptureFolder()
    }

    private func generateFileName(programName: String?, serviceName: String?, extension ext: String)
        -> String
    {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dateString = formatter.string(from: Date())

        var nameComponents: [String] = [dateString]
        if let serviceName = serviceName { nameComponents.append(serviceName) }
        if let programName = programName { nameComponents.append(programName) }

        let baseName = nameComponents.joined(separator: " - ")
        return "\(baseName).\(ext)"
    }

    private func saveCompositedCapturePath(
        savedPath: String,
        overlayImage: CGImage,
        programName: String?,
        serviceName: String?,
        caption: String?,
        broadcastTime: Date?,
        overlayPluginManifestIDs: [String]
    ) async throws -> String? {
        let baseURL: URL
        if savedPath.hasPrefix("/") {
            baseURL = URL(fileURLWithPath: savedPath)
        } else {
            let documentsURL = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask)[0]
            baseURL = documentsURL.appendingPathComponent(savedPath)
        }

        guard
            let tempURL = await Task.detached(
                priority: .userInitiated,
                operation: { () -> URL? in
                    guard let baseSource = CGImageSourceCreateWithURL(baseURL as CFURL, nil),
                        let baseImage = CGImageSourceCreateImageAtIndex(baseSource, 0, nil),
                        let compositeImage = CaptureService.compositeImages(
                            base: baseImage, overlay: overlayImage)
                    else { return nil }

                    let tempDir = FileManager.default.temporaryDirectory
                    let tempURL = tempDir.appendingPathComponent(UUID().uuidString + ".jpg")

                    guard
                        let dest = CGImageDestinationCreateWithURL(
                            tempURL as CFURL, "public.jpeg" as CFString, 1, nil)
                    else { return nil }
                    CGImageDestinationAddImage(dest, compositeImage, nil)
                    guard CGImageDestinationFinalize(dest) else { return nil }
                    return tempURL
                }
            ).value
        else { return nil }

        applyMetadata(
            to: tempURL,
            programName: programName,
            serviceName: serviceName,
            caption: caption,
            date: broadcastTime,
            overlayPluginManifestIDsCSV: joinedOverlayManifestIDs(overlayPluginManifestIDs)
        )

        let compositeProgramName = programName.map { "\($0) plugin_overlay" } ?? "plugin_overlay"
        let savedCompositePath: String
        if isExternalFolderSelected {
            do {
                savedCompositePath = try saveToFolder(
                    tempURL: tempURL, programName: compositeProgramName, serviceName: serviceName,
                    extension: "jpg")
            } catch {
                savedCompositePath = try saveToSandbox(
                    tempURL: tempURL, programName: compositeProgramName, serviceName: serviceName,
                    extension: "jpg")
            }
        } else {
            savedCompositePath = try saveToSandbox(
                tempURL: tempURL, programName: compositeProgramName, serviceName: serviceName,
                extension: "jpg")
        }

        return savedCompositePath
    }

    private nonisolated static func compositeImages(base: CGImage, overlay: CGImage) -> CGImage? {
        guard hasVisibleContent(in: overlay) else { return nil }
        let width = base.width
        let height = base.height
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(overlay, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private nonisolated static func hasVisibleContent(in image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return false }

        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return true
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return true }

        let bytesPerRow = context.bytesPerRow
        let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let alpha = buffer[rowStart + (x * 4) + 3]
                if alpha != 0 {
                    return true
                }
            }
        }

        return false
    }

    @discardableResult
    private func copyToClipboard(url: URL) -> Bool {
        #if os(iOS)
            guard let provider = NSItemProvider(contentsOf: url) else { return false }
            UIPasteboard.general.itemProviders = [provider]
            return true
        #elseif os(macOS)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.writeObjects([url as NSURL])
        #endif
    }

    private static func captureURL(for variant: PluginCaptureVariant, in item: CaptureHistoryItem)
        -> URL?
    {
        switch variant {
        case .original:
            return item.fileURL
        case .composite:
            guard !item.variantPaths.isEmpty else { return nil }
            return item.variantFileURL(at: 1)
        }
    }

    private static func mimeType(for url: URL) -> String {
        if let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType {
            return mimeType
        }
        return "application/octet-stream"
    }

    private func applyMetadata(
        to url: URL,
        programName: String?,
        serviceName: String?,
        caption: String?,
        date: Date?,
        overlayPluginManifestIDsCSV: String? = nil
    ) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let type = CGImageSourceGetType(source)
        else { return }

        let properties =
            (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let metadata = NSMutableDictionary(dictionary: properties)
        let iptc = (metadata[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
        let mutableIptc = NSMutableDictionary(dictionary: iptc)

        if let programName = programName {
            mutableIptc[kCGImagePropertyIPTCHeadline] = programName
        }
        if let serviceName = serviceName {
            mutableIptc[kCGImagePropertyIPTCCredit] = serviceName
        }
        if let caption = caption, !caption.isEmpty {
            mutableIptc[kCGImagePropertyIPTCCaptionAbstract] = caption
        }
        if let date = date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            mutableIptc[kCGImagePropertyIPTCDateCreated] = formatter.string(from: date)
            formatter.dateFormat = "HHmmss"
            mutableIptc[kCGImagePropertyIPTCTimeCreated] = formatter.string(from: date)
        }
        if let overlayPluginManifestIDsCSV {
            mutableIptc[kCGImagePropertyIPTCSpecialInstructions] =
                "overlay_plugin_manifest_ids=\(overlayPluginManifestIDsCSV)"
            mutableIptc[kCGImagePropertyIPTCKeywords] = [overlayPluginManifestIDsCSV]
        }

        metadata[kCGImagePropertyIPTCDictionary] = mutableIptc

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            return
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, metadata as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    private func joinedOverlayManifestIDs(_ ids: [String]) -> String? {
        var seen = Set<String>()
        var ordered: [String] = []
        for id in ids {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }
        }
        guard !ordered.isEmpty else { return nil }
        return ordered.joined(separator: ",")
    }
}

enum CaptureError: Error {
    case photosAccessDenied
    case folderAccessDenied
    case folderNotFound
}

enum CaptureClipboardTarget: String, Codable, CaseIterable, Sendable {
    case original
    case composite

    var localizedName: String {
        switch self {
        case .original: return "元のキャプチャ"
        case .composite: return "合成画像"
        }
    }
}
