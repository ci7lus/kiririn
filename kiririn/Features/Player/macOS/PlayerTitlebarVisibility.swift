#if os(macOS)
    import AppKit

    @MainActor
    final class PlayerTitlebarVisibility_macOS: NSObject {
        private final class Background: NSVisualEffectView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }

        private weak var window: NSWindow?
        private weak var titlebar: NSView?
        private var background: Background?
        private weak var trackingView: NSView?
        private var trackingArea: NSTrackingArea?
        private var trackingRect: CGRect?
        private var onHoverChange: ((Bool) -> Void)?
        private var controlsVisible = true
        private var appliedVisibility: Bool?
        private var isHovered = false
        private var isChangingFullScreen = false
        private var generation = 0

        func attach(to window: NSWindow, onHoverChange: @escaping (Bool) -> Void) {
            detach()
            self.window = window
            self.onHoverChange = onHoverChange
            window.styleMask.insert(.fullSizeContentView)
            refresh()
        }

        func setControlsVisible(_ visible: Bool) {
            controlsVisible = visible
            refresh()
        }

        func handleWindowEvent(_ name: Notification.Name) {
            switch name {
            case NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification:
                isChangingFullScreen = true
            case NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification:
                isChangingFullScreen = false
            default:
                break
            }
            refresh()
        }

        func detach() {
            generation += 1
            removeTrackingArea()
            titlebar?.isHidden = false
            titlebar?.alphaValue = 1
            window?.titlebarAppearsTransparent = false
            background?.removeFromSuperview()
            background = nil
            titlebar = nil
            window = nil
            appliedVisibility = nil
            isHovered = false
            isChangingFullScreen = false
            onHoverChange = nil
        }

        static func containsPointer(in window: NSWindow?) -> Bool {
            guard let window, window.frame.contains(NSEvent.mouseLocation),
                let titlebar = container(in: window)
            else { return false }
            let location = titlebar.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            return titlebar.bounds.contains(location)
        }

        static func container(in window: NSWindow) -> NSView? {
            guard let root = window.contentView?.superview else { return nil }
            var pending = [root]
            while let view = pending.popLast() {
                guard view !== window.contentView else { continue }
                if view.className == "NSTitlebarContainerView" { return view }
                pending.append(contentsOf: view.subviews)
            }
            return nil
        }

        private func refresh() {
            guard let window else { return }
            let isFullScreen = isChangingFullScreen || window.styleMask.contains(.fullScreen)
            if isFullScreen {
                removeTrackingArea()
                updateHover(false)
            }
            guard let view = Self.container(in: window) else { return }
            if titlebar !== view {
                background?.removeFromSuperview()
                let background = Background(frame: view.bounds)
                background.autoresizingMask = [.width, .height]
                background.material = .titlebar
                background.blendingMode = .withinWindow
                background.state = .followsWindowActiveState
                view.addSubview(background, positioned: .below, relativeTo: nil)
                self.background = background
                titlebar = view
                appliedVisibility = nil
            }
            window.titlebarAppearsTransparent = !isFullScreen
            background?.isHidden = isFullScreen
            if !isFullScreen { updateTrackingArea(for: view, window: window) }
            let visible = isFullScreen || controlsVisible || isHovered
            guard appliedVisibility != visible else { return }
            appliedVisibility = visible
            generation += 1
            let currentGeneration = generation
            if visible {
                view.isHidden = false
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                view.animator().alphaValue = visible ? 1 : 0
            } completionHandler: { [weak self, weak view] in
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view,
                        self.generation == currentGeneration, self.titlebar === view,
                        self.appliedVisibility == false
                    else { return }
                    view.isHidden = true
                }
            }
        }

        private func updateTrackingArea(for titlebar: NSView, window: NSWindow) {
            guard let root = window.contentView?.superview else { return }
            let rect = titlebar.convert(titlebar.bounds, to: root)
            guard trackingView !== root || trackingRect != rect else { return }
            removeTrackingArea()
            let area = NSTrackingArea(
                rect: rect, options: [.mouseEnteredAndExited, .activeInActiveApp],
                owner: self, userInfo: nil
            )
            trackingView = root
            trackingRect = rect
            trackingArea = area
            root.addTrackingArea(area)
            updateHover(Self.containsPointer(in: window))
        }

        private func removeTrackingArea() {
            if let trackingArea { trackingView?.removeTrackingArea(trackingArea) }
            trackingArea = nil
            trackingView = nil
            trackingRect = nil
        }

        private func updateHover(_ isHovered: Bool) {
            guard self.isHovered != isHovered else { return }
            self.isHovered = isHovered
            onHoverChange?(isHovered)
        }

        @objc private func mouseEntered(_ event: NSEvent) {
            updateHover(true)
            refresh()
        }

        @objc private func mouseExited(_ event: NSEvent) {
            updateHover(false)
            refresh()
        }
    }
#endif
