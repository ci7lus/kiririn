#if os(macOS)
    import AppKit

    @MainActor
    final class PlayerWindowRemoteEndpoint_macOS: RemotePlayerWindowEndpoint {
        private let windowReference: WindowReference_macOS
        private let isAlwaysOnTopProvider: () -> Bool
        private let setAlwaysOnTopHandler: (Bool) -> Void
        private let showVolumeFeedbackHandler: () -> Void
        private let closeHandler: () -> Void

        init(
            windowReference: WindowReference_macOS,
            isAlwaysOnTop: @escaping () -> Bool,
            setAlwaysOnTop: @escaping (Bool) -> Void,
            showVolumeFeedback: @escaping () -> Void,
            close: @escaping () -> Void
        ) {
            self.windowReference = windowReference
            isAlwaysOnTopProvider = isAlwaysOnTop
            setAlwaysOnTopHandler = setAlwaysOnTop
            showVolumeFeedbackHandler = showVolumeFeedback
            closeHandler = close
        }

        var snapshot: RemoteWindowSnapshot {
            RemoteWindowSnapshot(
                isFullscreen: windowReference.window?.styleMask.contains(.fullScreen) ?? false,
                isAlwaysOnTop: isAlwaysOnTopProvider()
            )
        }

        func showVolumeFeedback() {
            showVolumeFeedbackHandler()
        }

        func setFullscreen(_ enabled: Bool) -> RemoteCommandError? {
            guard let window = windowReference.window else { return .unavailable }
            let isFullscreen = window.styleMask.contains(.fullScreen)
            guard enabled != isFullscreen else { return nil }
            window.toggleFullScreen(nil)
            return nil
        }

        func setAlwaysOnTop(_ enabled: Bool) -> RemoteCommandError? {
            guard windowReference.window != nil else { return .unavailable }
            guard !enabled || snapshot.isFullscreen == false else { return .unavailable }
            setAlwaysOnTopHandler(enabled)
            return nil
        }

        func close() -> RemoteCommandError? {
            guard windowReference.window != nil else { return .unavailable }
            closeHandler()
            return nil
        }
    }
#endif
