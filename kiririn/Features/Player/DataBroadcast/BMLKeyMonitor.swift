#if os(macOS)
    import AppKit

    /// Routes keyboard input to a `DataBroadcastSession`'s BML content while
    /// the content presents itself (not ARIB-invisible). Installed/removed by
    /// DetachedPlayerOverlayView_macOS around content-visibility/session
    /// status changes - see `syncBMLKeyMonitor()` there.
    ///
    /// Uses a *local* event monitor (fires before AppKit's own key-equivalent
    /// dispatch) rather than making the BML WKWebView first responder: the
    /// existing hidden-button `.keyboardShortcut(.leftArrow/...)` bindings in
    /// the player overlay would otherwise consume arrow keys for seek/volume
    /// before a focused-view-based approach ever saw them. Returning `nil`
    /// from the monitor swallows the event ahead of both mechanisms.
    @MainActor
    final class BMLKeyMonitor {
        private weak var session: DataBroadcastSession?
        private let targetWindow: () -> NSWindow?
        private var monitor: Any?

        init(session: DataBroadcastSession, targetWindow: @escaping () -> NSWindow?) {
            self.session = session
            self.targetWindow = targetWindow
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
                [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        /// Returns the event to let it fall through, or `nil` to swallow it.
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let session, let window = targetWindow(), event.window === window else {
                return event
            }
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                return event
            }
            guard let code = Self.aribKeyCode(for: event) else {
                return event
            }
            guard session.usedKeyGroups.contains(Self.keyGroup(for: code)) else {
                return event
            }
            session.sendKey(down: event.type == .keyDown, aribKeyCode: code)
            return nil
        }

        // MARK: - AribKeyCode mapping (see web-bml/client/content.ts's AribKeyCode)

        private static func keyGroup(for aribKeyCode: Int) -> String {
            switch aribKeyCode {
            case 1, 2, 3, 4, 18, 19:
                return "basic"
            case 5...17:
                return "numeric-tuning"
            case 20...26, 100:
                return "data-button"
            default:
                return ""
            }
        }

        private static func aribKeyCode(for event: NSEvent) -> Int? {
            switch event.keyCode {
            case 126: return 1  // Up
            case 125: return 2  // Down
            case 123: return 3  // Left
            case 124: return 4  // Right
            case 36: return 18  // Return -> Enter
            case 51, 53: return 19  // Delete/Escape -> Back
            default: break
            }
            guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
                event.charactersIgnoringModifiers?.unicodeScalars.count == 1
            else {
                return nil
            }
            switch Character(scalar).lowercased() {
            case "0": return 5
            case "1": return 6
            case "2": return 7
            case "3": return 8
            case "4": return 9
            case "5": return 10
            case "6": return 11
            case "7": return 12
            case "8": return 13
            case "9": return 14
            // "d" is intentionally not mapped to AribKeyCode.DataButton (20) -
            // it's reserved for the native overlay toggle (see
            // DetachedPlayerOverlayView_macOS's d-button/shortcut).
            case "b": return 21  // BlueButton
            case "r": return 22  // RedButton
            case "g": return 23  // GreenButton
            case "y": return 24  // YellowButton
            default: return nil
            }
        }
    }
#endif
