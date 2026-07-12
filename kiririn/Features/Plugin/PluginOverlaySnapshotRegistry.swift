import CoreGraphics
import WebKit

@MainActor
final class PluginOverlaySnapshotRegistry {
    static let shared = PluginOverlaySnapshotRegistry()

    private var registry: [String: WKWebView] = [:]

    private init() {}

    func register(_ webView: WKWebView, playerID: String, pluginID: String) {
        registry[registryKey(playerID: playerID, pluginID: pluginID)] = webView
    }

    func unregister(playerID: String, pluginID: String) {
        registry.removeValue(forKey: registryKey(playerID: playerID, pluginID: pluginID))
    }

    func takeCompositeSnapshot(
        for playerID: String,
        targetSize: CGSize,
        targetAspectRatio: Double,
        targetFrame: CGRect? = nil
    ) async -> CGImage? {
        let webViews =
            registry
            .filter { $0.key.hasPrefix("\(playerID):") }
            .values
        guard !webViews.isEmpty else { return nil }

        let normalizedAspectRatio =
            targetAspectRatio.isFinite && targetAspectRatio > 0 ? targetAspectRatio : (16.0 / 9.0)
        var cgImages: [CGImage] = []
        for webView in webViews {
            if let image = await takeSnapshotAsCGImage(from: webView),
                let cropped = centerCrop(image: image, toAspectRatio: normalizedAspectRatio)
            {
                cgImages.append(cropped)
            }
        }
        guard !cgImages.isEmpty else { return nil }
        return composite(
            images: cgImages,
            targetSize: targetSize,
            targetFrame: targetFrame ?? CGRect(origin: .zero, size: targetSize)
        )
    }

    private func takeSnapshotAsCGImage(from webView: WKWebView) async -> CGImage? {
        await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in
                #if os(macOS)
                    continuation.resume(
                        returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
                #else
                    continuation.resume(returning: image?.cgImage)
                #endif
            }
        }
    }

    private func composite(images: [CGImage], targetSize: CGSize, targetFrame: CGRect) -> CGImage? {
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)
        guard width > 0, height > 0 else { return nil }

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

        let rect = CaptureImageGeometry.bitmapFrame(
            fromTopLeft: targetFrame,
            canvasHeight: CGFloat(height)
        )
        for image in images {
            context.draw(image, in: rect)
        }
        return context.makeImage()
    }

    private func centerCrop(image: CGImage, toAspectRatio aspectRatio: Double) -> CGImage? {
        let sourceWidth = image.width
        let sourceHeight = image.height
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let sourceAspectRatio = Double(sourceWidth) / Double(sourceHeight)
        let cropRect: CGRect

        if sourceAspectRatio > aspectRatio {
            let targetWidth = Double(sourceHeight) * aspectRatio
            let originX = (Double(sourceWidth) - targetWidth) / 2.0
            cropRect =
                CGRect(x: originX, y: 0, width: targetWidth, height: Double(sourceHeight)).integral
        } else if sourceAspectRatio < aspectRatio {
            let targetHeight = Double(sourceWidth) / aspectRatio
            let originY = (Double(sourceHeight) - targetHeight) / 2.0
            cropRect =
                CGRect(x: 0, y: originY, width: Double(sourceWidth), height: targetHeight).integral
        } else {
            cropRect = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        }

        return image.cropping(to: cropRect)
    }

    private func registryKey(playerID: String, pluginID: String) -> String {
        "\(playerID):\(pluginID)"
    }
}
