import SwiftUI

extension Notification.Name {
    static let requestOpenFile = Notification.Name("requestOpenFile")
    static let requestOpenPlayable = Notification.Name("requestOpenPlayable")
    static let requestOpenPluginWindow = Notification.Name("requestOpenPluginWindow")
    static let pluginOpenURLRequested = Notification.Name("pluginOpenURLRequested")
}

#if canImport(UIKit) && !os(macOS)
    import UIKit

    class AppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>
        ) {
            if application.connectedScenes.isEmpty {
                exit(0)
            }
        }
    }
#endif

@main
struct kiririnApp: App {
    @State private var appModel = AppModel.shared

    #if canImport(UIKit) && !os(macOS)
        @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        #if os(iOS)
            WindowGroup {
                ContentView(appModel: appModel)
            }
        #else
            Window("kiririn", id: AppWindowID.main.rawValue) {
                ContentView(appModel: appModel)
            }
            .commands {
                AppCommands(appModel: appModel)
            }
            DocumentGroup(viewing: KiririnMediaDocument.self) { file in
                DocumentPlaybackView(
                    fileURL: file.fileURL,
                    appModel: appModel
                )
            }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1280, height: 720)

            WindowGroup("プレイヤー", id: AppWindowID.player.rawValue, for: Playable.self) { $playable in
                PlayerWindowView_macOS(appModel: appModel, initialPlayable: playable)
            }
            .defaultSize(width: 1280, height: 720)
            .windowStyle(.hiddenTitleBar)

            WindowGroup("プラグイン", id: AppWindowID.plugin.rawValue, for: UUID.self) { $pluginID in
                if let pluginID {
                    PluginWindowView_macOS(appModel: appModel, pluginID: pluginID)
                }
            }
            .defaultSize(width: 960, height: 640)

            Window("字幕履歴", id: AppWindowID.caption.rawValue) {
                CaptionWindowView_macOS(appModel: appModel)
            }
            .defaultSize(width: 400, height: 600)

            Window("番組情報", id: AppWindowID.programInfo.rawValue) {
                ProgramInfoWindowView_macOS(appModel: appModel)
            }
            .defaultSize(width: 480, height: 560)
        #endif
    }
}

private struct AppCommands: Commands {
    let appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        #if os(macOS)
            CommandMenu("プラグイン") {
                let enabledPlugins = appModel.pluginStore.plugins.filter {
                    $0.isEnabled && !$0.htmlContent.isEmpty
                }

                if enabledPlugins.isEmpty {
                    Text("有効なプラグインなし")
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
