import AppKit

/// Routes keyboard input to a `DataBroadcastSession`'s BML content.
/// Installed while the session is active (regardless of ARIB visibility,
/// which is checked per-event) by DetachedPlayerOverlayView_macOS - see
/// `syncBMLKeyMonitor()` there. While the content hides itself, keyDowns
/// pass through untouched; only keyUps of mapped keys are still delivered
/// (see the comment in `handle`).
///
/// Key ownership is split statically so it never depends on BML state:
/// plain arrows always belong to the player's volume/seek shortcuts, and
/// BML navigation is on ⌥+arrows instead. Keys the player leaves unbound
/// (Return/Delete/Esc, digits, b/r/g/y) go to BML unmodified. This
/// replaced an earlier design where plain arrows were swallowed while the
/// content was visible: visibility flaps across page transitions (ARIB
/// invisible), so arrow presses kept leaking into volume/seek.
///
/// Uses a *local* event monitor (fires before AppKit's own key-equivalent
/// dispatch) rather than making the BML WKWebView first responder: the
/// hidden-button `.keyboardShortcut` bindings in the player overlay would
/// otherwise win before a focused-view-based approach ever saw the event.
/// Returning `nil` from the monitor swallows the event ahead of both
/// mechanisms.
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
        guard event.modifierFlags.intersection([.command, .control]).isEmpty else {
            return event
        }
        guard let code = Self.aribKeyCode(for: event) else {
            return event
        }
        let contentVisible = session.status == .active && !session.isInvisible

        guard event.type == .keyDown else {
            // keyUp is always delivered for mapped keys: web-bml holds
            // keyProcessStatus from keyDown until the matching keyUp, and
            // the declared groups / visibility may have changed in between
            // (e.g. the press itself navigated or closed the content) -
            // dropping the up would wedge all subsequent key handling.
            session.sendKey(down: false, aribKeyCode: code)
            return contentVisible ? nil : event
        }

        guard contentVisible else {
            return event
        }

        // Delivery is limited to declared groups (matching receiver
        // behavior), but the swallow is unconditional: usedKeyList
        // arrives async from JS and is briefly empty/stale across page
        // transitions.
        if session.usedKeyGroups.contains(Self.keyGroup(for: code)) {
            if event.isARepeat {
                // web-bml ignores further keyDowns until the previous
                // press completes with a keyUp (keyProcessStatus), so
                // expand OS key repeats into full up->down cycles to get
                // hold-to-repeat navigation.
                session.sendKey(down: false, aribKeyCode: code)
            }
            session.sendKey(down: true, aribKeyCode: code)
        }
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
        // Plain arrows are the player's volume/seek keys, so BML
        // navigation requires ⌥ - see the type-level comment.
        let hasOption = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 126: return hasOption ? 1 : nil  // ⌥Up
        case 125: return hasOption ? 2 : nil  // ⌥Down
        case 123: return hasOption ? 3 : nil  // ⌥Left
        case 124: return hasOption ? 4 : nil  // ⌥Right
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
