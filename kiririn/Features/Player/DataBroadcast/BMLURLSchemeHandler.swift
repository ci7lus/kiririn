import Foundation
import WebKit

final class BMLURLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "kiririn-bml"
    static let host = "app"
    static let contentURL = URL(string: "\(scheme)://\(host)/bml.html")

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
            requestURL.scheme == Self.scheme,
            requestURL.host == Self.host,
            let resourceURL = Self.resourceURL(for: requestURL)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        do {
            let data = try Data(contentsOf: resourceURL)
            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType(for: resourceURL.pathExtension),
                expectedContentLength: data.count,
                textEncodingName: resourceURL.pathExtension == "html" ? "utf-8" : nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    static func resourceURL(for requestURL: URL) -> URL? {
        let resourceName = requestURL.lastPathComponent
        guard !resourceName.isEmpty, resourceName == requestURL.path.dropFirst(),
            resourceName != ".", resourceName != ".."
        else { return nil }

        let name = (resourceName as NSString).deletingPathExtension
        let extensionName = (resourceName as NSString).pathExtension
        guard !name.isEmpty, !extensionName.isEmpty else { return nil }

        return Bundle.main.url(
            forResource: name,
            withExtension: extensionName,
            subdirectory: "Features/Player/DataBroadcast/Web/dist"
        ) ?? Bundle.main.url(forResource: name, withExtension: extensionName)
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": "text/html"
        case "js": "text/javascript"
        case "json", "map": "application/json"
        case "css": "text/css"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }
}
