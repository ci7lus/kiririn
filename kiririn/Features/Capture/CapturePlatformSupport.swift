import SwiftUI

#if os(macOS)
    import AppKit

    let captureRevealButtonTitle: LocalizedStringKey = "Finderで表示"

    @MainActor
    func copyCaptureItemToClipboard(url: URL, isImage _: Bool) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    func revealCaptureItemInSystemFiles(_ url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    func loadCapturePlatformImage(from url: URL) async -> PlatformImage? {
        await CaptureService.shared.loadCaptureImage(from: url)
    }

    func captureImage(_ image: PlatformImage) -> Image {
        Image(nsImage: image)
    }
#elseif os(iOS)
    import UIKit

    let captureRevealButtonTitle: LocalizedStringKey = "ファイルアプリで開く"

    @MainActor
    func copyCaptureItemToClipboard(url: URL, isImage _: Bool) async {
        if let provider = NSItemProvider(contentsOf: url) {
            UIPasteboard.general.itemProviders = [provider]
        }
    }

    func revealCaptureItemInSystemFiles(_ url: URL) {
        if let targetURL = URL(string: "shareddocuments://\(url.path)"),
            UIApplication.shared.canOpenURL(targetURL)
        {
            UIApplication.shared.open(targetURL, options: [:], completionHandler: nil)
        }
    }

    func loadCapturePlatformImage(from url: URL) async -> PlatformImage? {
        await CaptureService.shared.loadCaptureImage(from: url)
    }

    func captureImage(_ image: PlatformImage) -> Image {
        Image(uiImage: image)
    }
#endif
