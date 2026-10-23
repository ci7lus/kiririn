#if os(macOS)
    import AppKit
    import CoreText

    nonisolated struct PlayerTitlebarContent_macOS: Equatable, Sendable {
        let title: String
        let subtitle: String

        init(title: String?, serviceName: String?, timeRange: String?, description: String?) {
            self.title = Self.singleLine(title) ?? "プレイヤー"
            var seen = Set([Self.comparisonKey(self.title)])
            let candidate = [serviceName, timeRange, description]
                .compactMap(Self.singleLine)
                .filter { seen.insert(Self.comparisonKey($0)).inserted }
                .joined(separator: "｜")
            subtitle =
                Self.comparisonKey(candidate) == Self.comparisonKey(self.title) ? "" : candidate
        }

        private static func comparisonKey(_ value: String) -> String {
            value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .folding(
                    options: [.caseInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "ja_JP"))
        }

        private static func singleLine(_ value: String?) -> String? {
            guard let value else { return nil }
            let normalized = value.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return normalized.isEmpty ? nil : normalized
        }
    }

    @MainActor
    final class PlayerTitlebarController_macOS {
        private final class Field {
            var observation: NSKeyValueObservation?
            var appliedValue: NSAttributedString?
        }

        private weak var window: NSWindow?
        private var content = PlayerTitlebarContent_macOS(
            title: nil, serviceName: nil, timeRange: nil, description: nil
        )
        private var notifications: [NSObjectProtocol] = []
        private var fields: [ObjectIdentifier: Field] = [:]
        private var generation = 0
        private var refreshScheduled = false
        private let visibility = PlayerTitlebarVisibility_macOS()

        isolated deinit {
            detach()
        }

        func attach(to window: NSWindow, onTitlebarHover: @escaping (Bool) -> Void = { _ in }) {
            guard self.window !== window else { return }
            detach()
            self.window = window
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            if window.toolbar == nil {
                window.toolbar = NSToolbar(identifier: "PlayerTitlebar")
            }
            visibility.attach(to: window, onHoverChange: onTitlebarHover)
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(type)?.isHidden = false
            }
            let currentGeneration = generation
            for name in [
                NSWindow.didUpdateNotification, NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                NSWindow.willCloseNotification,
            ] {
                notifications.append(
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main)
                    {
                        [weak self] notification in
                        guard let candidate = notification.object as? NSWindow else { return }
                        Task { @MainActor [weak self, weak candidate] in
                            guard let self, let candidate, self.generation == currentGeneration
                            else {
                                return
                            }
                            if name == NSWindow.willCloseNotification, candidate === self.window {
                                self.detach()
                            } else if candidate === self.window || self.ownsToolbarWindow(candidate)
                            {
                                self.visibility.handleWindowEvent(name)
                                self.scheduleRefresh()
                            }
                        }
                    }
                )
            }
            applyContent()
        }

        func update(_ content: PlayerTitlebarContent_macOS) {
            self.content = content
            applyContent()
        }

        func setControlsVisible(_ visible: Bool) {
            visibility.setControlsVisible(visible)
        }

        func detach() {
            generation += 1
            refreshScheduled = false
            for token in notifications { NotificationCenter.default.removeObserver(token) }
            notifications.removeAll()
            fields.removeAll()
            visibility.detach()
            window = nil
        }

        private func applyContent() {
            guard let window else { return }
            if window.title != content.title { window.title = content.title }
            if window.subtitle != content.subtitle { window.subtitle = content.subtitle }
            let style: NSWindow.ToolbarStyle = content.subtitle.isEmpty ? .unifiedCompact : .unified
            if window.toolbarStyle != style { window.toolbarStyle = style }
            scheduleRefresh()
        }

        private func scheduleRefresh() {
            guard window != nil, !refreshScheduled else { return }
            refreshScheduled = true
            let currentGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.refreshScheduled = false
                self.refreshFields()
            }
        }

        private func ownsToolbarWindow(_ candidate: NSWindow) -> Bool {
            guard let window, candidate !== window,
                candidate.className == "NSToolbarFullScreenWindow"
            else { return false }
            if candidate.parent === window { return true }
            guard candidate.parent == nil, candidate.isOnActiveSpace, window.isOnActiveSpace,
                window.styleMask.contains(.fullScreen), let screen = window.screen,
                candidate.screen === screen
            else { return false }
            // AppKit can detach the full-screen toolbar from its parent window.
            let owners = NSApplication.shared.windows.filter {
                $0.styleMask.contains(.fullScreen) && $0.isOnActiveSpace && $0.screen === screen
            }
            return owners.count == 1 && owners.first === window
        }

        private func titleFields() -> [NSTextField] {
            guard let window else { return [] }
            let windows = [window] + NSApplication.shared.windows.filter(ownsToolbarWindow)
            var result: [NSTextField] = []
            for candidate in windows {
                guard let root = candidate.contentView?.superview else { continue }
                var pending = [root]
                while let view = pending.popLast() {
                    guard view !== candidate.contentView else { continue }
                    if view.className == "NSTitlebarContainerView" {
                        var titleViews = [view]
                        while let titleView = titleViews.popLast() {
                            titleViews.append(contentsOf: titleView.subviews)
                            guard let field = titleView as? NSTextField, !field.isEditable,
                                !field.stringValue.isEmpty,
                                field.stringValue == content.title
                                    || field.stringValue == content.subtitle
                                    || field.stringValue == "\(content.title) – \(content.subtitle)"
                            else { continue }
                            result.append(field)
                        }
                    } else {
                        pending.append(contentsOf: view.subviews)
                    }
                }
            }
            return result
        }

        private func refreshFields() {
            let views = titleFields()
            let liveIDs = Set(views.map(ObjectIdentifier.init))
            fields = fields.filter { liveIDs.contains($0.key) }
            for view in views {
                let id = ObjectIdentifier(view)
                let field: Field
                if let existing = fields[id] {
                    field = existing
                } else {
                    field = Field()
                    fields[id] = field
                    let currentGeneration = generation
                    field.observation = view.observe(\.attributedStringValue) { [weak self] _, _ in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == currentGeneration else { return }
                            self.scheduleRefresh()
                        }
                    }
                }
                let current = view.attributedStringValue
                if let applied = field.appliedValue, current.isEqual(to: applied) { continue }
                guard let font = SourceHanSansFont.shared else { continue }
                let styled = font.styled(
                    current, defaultFont: view.font ?? .titleBarFont(ofSize: 13)
                )
                field.appliedValue = styled
                if !current.isEqual(to: styled) { view.attributedStringValue = styled }
            }
        }
    }
#endif
