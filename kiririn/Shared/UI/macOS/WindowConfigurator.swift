import AppKit
import SwiftUI

struct WindowConfigurator_macOS: NSViewRepresentable {
    let onWindowReady: (NSWindow) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindowReady(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onWindowReady(window)
            }
        }
    }
}
