import KppxKit
import Logging
import WebKit

@MainActor
private final class PluginExtensionControllerDelegate: NSObject, WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        completionHandler(matchPatterns, nil)
    }
}

@MainActor
final class ExtensionPluginRuntime {
    let pluginID: UUID
    let manifest: ExtensionPluginManifest
    let resourceBaseURL: URL
    let webExtension: WKWebExtension
    let context: WKWebExtensionContext
    let controller: WKWebExtensionController
    let webViewConfiguration: WKWebViewConfiguration
    private let controllerDelegate: PluginExtensionControllerDelegate
    private let logger = Logger(label: "ExtensionPluginRuntime")
    private var isInvalidated = false

    init(
        plugin: PluginDefinition,
        manifest: ExtensionPluginManifest,
        resourceBaseURL: URL
    ) async throws {
        let normalizedResourceBaseURL = resourceBaseURL.standardizedFileURL
        guard normalizedResourceBaseURL.isFileURL else {
            throw NSError(
                domain: "PluginRuntime",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "プラグインのリソース URL が不正です: \(resourceBaseURL.absoluteString)"
                ]
            )
        }
        let webExtension = try await WKWebExtension(resourceBaseURL: normalizedResourceBaseURL)
        let context = try ExtensionPluginContextConfiguration.makeContext(
            for: webExtension,
            pluginID: plugin.id,
            manifestID: plugin.manifestID,
            requestedPermissions: manifest.requestedPermissions,
            requestedHostPermissions: manifest.requestedHostPermissions
        )
        context.isInspectable = true
        let delegate = PluginExtensionControllerDelegate()
        let controller = WKWebExtensionController()
        controller.delegate = delegate
        try controller.load(context)
        guard let webViewConfiguration = context.webViewConfiguration else {
            do {
                try controller.unload(context)
            } catch {
                Logger(label: "ExtensionPluginRuntime").error(
                    "Failed to unload incomplete plugin runtime: \(error)"
                )
            }
            throw NSError(
                domain: "PluginRuntime",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "プラグインの WebView configuration を取得できませんでした"
                ]
            )
        }

        self.pluginID = plugin.id
        self.manifest = manifest
        self.resourceBaseURL = normalizedResourceBaseURL
        self.webExtension = webExtension
        self.context = context
        self.controllerDelegate = delegate
        self.controller = controller
        self.webViewConfiguration = webViewConfiguration
    }

    func pageURL(for area: PluginDisplayArea) -> URL? {
        guard let pagePath = manifest.pagePath(for: area) else {
            return nil
        }
        return context.baseURL.appending(path: pagePath)
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        do {
            try controller.unload(context)
        } catch {
            logger.error("Failed to unload plugin runtime: \(error)")
        }
    }
}
