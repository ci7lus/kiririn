import SwiftUI
import WebKit

#if os(macOS)
    /// Thin host for a `DataBroadcastSession`'s WKWebView. The session owns
    /// and drives the web view directly (SSE, module fetches, bridge
    /// messages); this view's only job is placing it in the SwiftUI tree at
    /// the same rect as the video plane.
    struct BMLOverlayView_macOS: NSViewRepresentable {
        let session: DataBroadcastSession

        func makeNSView(context: Context) -> WKWebView {
            session.webView
        }

        func updateNSView(_ nsView: WKWebView, context: Context) {}
    }
#endif
