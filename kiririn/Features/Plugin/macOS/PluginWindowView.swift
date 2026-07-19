import AppKit
import KppxKit
import SwiftUI

struct PluginWindowView_macOS: View {
    @Environment(AppModel.self) private var appModel
    let pluginID: UUID
    @State private var isAlwaysOnTop = false
    @State private var windowReference = WindowReference_macOS()

    private var plugin: PluginDefinition? {
        appModel.pluginStore.plugins.first { $0.id == pluginID }
    }

    private var window: NSWindow? {
        windowReference.window
    }

    var body: some View {
        Group {
            if let plugin {
                ZStack {
                    WindowConfigurator_macOS { nsWindow in
                        windowReference.window = nsWindow
                        nsWindow.level = isAlwaysOnTop ? .floating : .normal
                    }
                    .frame(width: 0, height: 0)

                    PluginOverlayView(
                        pluginDefinition: plugin,
                        appModel: appModel,
                        reloadToken: appModel.playerState.pluginReloadToken
                            + appModel.playerState.perPluginReloadTokens[
                                plugin.id.uuidString, default: 0],
                        displayArea: .panel
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .onDisappear {
                    windowReference.window = nil
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
