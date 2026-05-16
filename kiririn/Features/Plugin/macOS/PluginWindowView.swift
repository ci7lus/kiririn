#if os(macOS)
    import SwiftUI

    struct PluginWindowView_macOS: View {
        let appModel: AppModel
        let pluginID: UUID

        private var plugin: PluginDefinition? {
            appModel.pluginStore.plugins.first { $0.id == pluginID }
        }

        @State private var isAlwaysOnTop = false
        @State private var window: NSWindow?

        var body: some View {
            Group {
                if let plugin {
                    ZStack {
                        WindowConfigurator_macOS { nsWindow in
                            self.window = nsWindow
                            nsWindow.level = isAlwaysOnTop ? .floating : .normal
                        }
                        .frame(width: 0, height: 0)

                        GeometryReader { geo in
                            PluginOverlayView(
                                pluginID: plugin.id.uuidString,
                                manifestPluginID: plugin.manifestID,
                                htmlContent: plugin.htmlContent,
                                appModel: appModel,
                                reloadToken: appModel.playerState.pluginReloadToken
                                    + appModel.playerState.perPluginReloadTokens[
                                        plugin.id.uuidString, default: 0],
                                displayArea: .pluginScreen,
                                playerID: nil,
                                manifestContextId: plugin.manifestContextId,
                                allowedURLPatterns: plugin.manifestAllowedURLPatterns,
                                viewSize: geo.size,
                                onReloadRequested: {
                                    appModel.playerState.reloadPlugin(id: plugin.id.uuidString)
                                }
                            )
                        }
                    }
                    .navigationTitle(plugin.name)
                    .contextMenu {
                        Button {
                            isAlwaysOnTop.toggle()
                            window?.level = isAlwaysOnTop ? .floating : .normal
                        } label: {
                            HStack {
                                if isAlwaysOnTop {
                                    Image(systemName: "checkmark")
                                }
                                Text("最前面に固定")
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "プラグインが見つかりません",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
        }
    }
#endif
