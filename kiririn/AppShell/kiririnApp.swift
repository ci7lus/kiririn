import CoreText
import SwiftUI

#if !DEBUG
    import Sentry
#endif

extension Notification.Name {
    static let requestOpenFile = Notification.Name("requestOpenFile")
    static let requestOpenPlayable = Notification.Name("requestOpenPlayable")
    static let requestOpenPluginWindow = Notification.Name("requestOpenPluginWindow")
    static let requestOpenSettings = Notification.Name("requestOpenSettings")
    static let requestOpenAboutApp = Notification.Name("requestOpenAboutApp")
    static let pluginDeeplinkOpened = Notification.Name("pluginDeeplinkOpened")
}

#if canImport(UIKit) && !os(macOS)
    import UIKit

    @MainActor
    final class PlayerOrientationController {
        static let shared = PlayerOrientationController()

        private(set) var supportedOrientations: UIInterfaceOrientationMask =
            PlayerOrientationController.defaultSupportedOrientations

        var isLandscapeLocked: Bool {
            supportedOrientations == .landscape
        }

        var canRotateCurrentWindow: Bool {
            guard UIDevice.current.userInterfaceIdiom == .pad else { return true }
            guard let scene = activeWindowScene(), let keyWindow = scene.keyWindow else {
                return false
            }

            let tolerance: CGFloat = 2
            let windowSides = [keyWindow.bounds.width, keyWindow.bounds.height].sorted()
            let screenSides = [scene.screen.bounds.width, scene.screen.bounds.height].sorted()

            return abs(windowSides[0] - screenSides[0]) <= tolerance
                && abs(windowSides[1] - screenSides[1]) <= tolerance
        }

        @discardableResult
        func lockLandscape() -> Bool {
            guard canRotateCurrentWindow else { return false }
            supportedOrientations = .landscape
            refreshSupportedOrientations()
            requestOrientation(.landscape)
            return true
        }

        func unlockAndReturnToPortrait() {
            supportedOrientations = Self.defaultSupportedOrientations
            refreshSupportedOrientations()
            if canRotateCurrentWindow || UIDevice.current.userInterfaceIdiom != .pad {
                requestOrientation(.portrait)
            }
        }

        private func requestOrientation(_ orientations: UIInterfaceOrientationMask) {
            guard let scene = activeWindowScene() else { return }
            refreshSupportedOrientations(in: scene)
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
                #if DEBUG
                    debugPrint(
                        "PlayerOrientationController requestGeometryUpdate failed:",
                        error.localizedDescription
                    )
                #endif
            }
        }

        private func refreshSupportedOrientations() {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                refreshSupportedOrientations(in: scene)
            }
        }

        private func refreshSupportedOrientations(in scene: UIWindowScene) {
            for window in scene.windows {
                refreshSupportedOrientations(in: window.rootViewController)
            }
        }

        private func refreshSupportedOrientations(in viewController: UIViewController?) {
            guard let viewController else { return }
            viewController.setNeedsUpdateOfSupportedInterfaceOrientations()
            for child in viewController.children {
                refreshSupportedOrientations(in: child)
            }
            refreshSupportedOrientations(in: viewController.presentedViewController)
        }

        private func activeWindowScene() -> UIWindowScene? {
            let windowScenes = UIApplication.shared.connectedScenes.compactMap {
                $0 as? UIWindowScene
            }
            if let keyWindowScene = windowScenes.first(where: { scene in
                scene.activationState == .foregroundActive
                    && scene.windows.contains(where: { $0.isKeyWindow })
            }) {
                return keyWindowScene
            }
            return windowScenes.first(where: { $0.activationState == .foregroundActive })
        }

        private static var defaultSupportedOrientations: UIInterfaceOrientationMask {
            UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
        }
    }

    extension UIWindowScene {
        fileprivate var keyWindow: UIWindow? {
            windows.first(where: \.isKeyWindow)
        }
    }

    class AppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _: UIApplication,
            supportedInterfaceOrientationsFor _: UIWindow?
        ) -> UIInterfaceOrientationMask {
            PlayerOrientationController.shared.supportedOrientations
        }

        func application(
            _ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>
        ) {
            if application.connectedScenes.isEmpty {
                exit(0)
            }
        }
    }
#endif

#if os(macOS)
    import AppKit

    class AppDelegate_macOS: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            true
        }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            let appModel = AppModel.shared
            for state in appModel.activePlayerStates {
                state.close()
            }
            return .terminateNow
        }
    }
#endif

private func registerFonts() {
    guard
        let fontURL = Bundle.main.url(
            forResource: "rounded-mplus-1m-wadalab-comp-arib", withExtension: "ttf")
    else {
        return
    }
    var error: Unmanaged<CFError>?
    if !CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error) {
        if let error = error?.takeRetainedValue() {
            #if DEBUG
                debugPrint("font registration failed: \(error)")
            #endif
        }
    }
}

@main
struct KiririnApp: App {
    @State private var appModel = AppModel.shared

    init() {
        #if !DEBUG
            SentryBootstrap.initializeIfAvailable()
        #endif
        registerFonts()
    }

    #if os(macOS)
        @NSApplicationDelegateAdaptor(AppDelegate_macOS.self) var appDelegate
    #elseif canImport(UIKit)
        @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        #if os(iOS)
            WindowGroup {
                ContentView()
            }
            .environment(appModel)
        #else
            Group {
                Window("kiririn", id: AppWindowID.main.rawValue) {
                    ContentView()
                }
                .commands {
                    AppCommands(appModel: appModel)
                }

                DocumentGroup(viewing: KiririnMediaDocument.self) { file in
                    DocumentPlaybackView(fileURL: file.fileURL)
                }
                .windowStyle(.hiddenTitleBar)
                .defaultSize(width: 1280, height: 720)

                WindowGroup("プレイヤー", id: AppWindowID.player.rawValue, for: Playable.self) {
                    $playable in
                    PlayerWindowView_macOS(initialPlayable: playable)
                }
                .defaultSize(width: 1280, height: 720)
                .windowStyle(.hiddenTitleBar)
                .commandsRemoved()

                WindowGroup("プラグイン", id: AppWindowID.plugin.rawValue, for: UUID.self) {
                    $pluginID in
                    if let pluginID {
                        PluginWindowView_macOS(pluginID: pluginID)
                    }
                }
                .defaultSize(width: 960, height: 640)
                .commandsRemoved()

                Window("字幕履歴", id: AppWindowID.caption.rawValue) {
                    CaptionWindowView_macOS()
                }
                .defaultSize(width: 400, height: 600)

                Window("番組情報", id: AppWindowID.programInfo.rawValue) {
                    ProgramInfoWindowView_macOS()
                }
                .defaultSize(width: 480, height: 560)
            }
            .environment(appModel)
        #endif
    }
}

#if !DEBUG
    private enum SentryBootstrap {
        static let dsn =
            "https://f85557a0b48501e363aa402ebf5e2c74@o481625.ingest.us.sentry.io/4511399987183616"

        static func initializeIfAvailable() {
            let buildInfo = AppBuildInfo.current
            SentrySDK.start { options in
                options.dsn = dsn
                options.enableNetworkBreadcrumbs = false
                options.enableCaptureFailedRequests = false
                options.enableNetworkTracking = false
            }
            SentrySDK.configureScope { scope in
                scope.setTag(value: buildInfo.gitCommitHash, key: "revision")
            }
        }
    }
#endif

private struct AppCommands: Commands {
    let appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        #if os(macOS)
            CommandGroup(replacing: .appInfo) {
                Button("kiririnについて") {
                    openWindow(id: AppWindowID.main.rawValue)
                    NotificationCenter.default.post(
                        name: .requestOpenAboutApp, object: nil
                    )
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("設定") {
                    openWindow(id: AppWindowID.main.rawValue)
                    NotificationCenter.default.post(
                        name: .requestOpenSettings, object: nil
                    )
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("プラグイン") {
                let enabledPlugins = appModel.pluginStore.plugins.filter {
                    $0.isEnabled
                }

                if enabledPlugins.isEmpty {
                    Text("なし")
                        .disabled(true)
                } else {
                    ForEach(enabledPlugins) { plugin in
                        Button(plugin.name) {
                            openWindow(id: AppWindowID.plugin.rawValue, value: plugin.id)
                        }
                    }
                }
            }

            CommandGroup(after: .windowArrangement) {
                Button("字幕履歴") {
                    openWindow(id: AppWindowID.caption.rawValue)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("番組情報") {
                    openWindow(id: AppWindowID.programInfo.rawValue)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        #else
            CommandGroup(replacing: .newItem) {
                Button("ファイルを開く...") {
                    NotificationCenter.default.post(name: .requestOpenFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        #endif
    }
}
