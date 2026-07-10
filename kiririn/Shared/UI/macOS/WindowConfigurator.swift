import AppKit
import SwiftUI

struct WindowConfigurator_macOS: NSViewRepresentable {
    let onWindowReady: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.configureWhenReady(view: view, onWindowReady: onWindowReady)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.configureWhenReady(view: nsView, onWindowReady: onWindowReady)
    }

    final class Coordinator {
        private weak var configuredWindow: NSWindow?
        private weak var scheduledWindow: NSWindow?

        func configureWhenReady(view: NSView, onWindowReady: @escaping (NSWindow) -> Void) {
            guard let window = view.window else {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let window = view?.window else { return }
                    self?.configure(window: window, onWindowReady: onWindowReady)
                }
                return
            }

            configure(window: window, onWindowReady: onWindowReady)
        }

        private func configure(
            window: NSWindow,
            onWindowReady: @escaping (NSWindow) -> Void
        ) {
            guard configuredWindow !== window, scheduledWindow !== window else {
                return
            }

            scheduledWindow = window
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                guard self.configuredWindow !== window else {
                    return
                }
                self.scheduledWindow = nil
                self.configuredWindow = window
                onWindowReady(window)
            }
        }
    }
}
