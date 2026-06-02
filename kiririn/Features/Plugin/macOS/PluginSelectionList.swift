#if os(macOS)
    import SwiftUI

    struct PluginList_macOS: View {
        @Bindable var appModel: AppModel
        @Bindable var pluginStore: PluginStore
        @Bindable var playerState: PlayerState
        @Binding var selectedID: UUID?
        @Binding var editingPlugin: PluginDefinition?
        @Binding var showingDeleteConfirmation: Bool
        @Binding var pluginIDsToDelete: [UUID]
        let onToggleEnabled: (PluginDefinition, Bool) -> Void
        let onOpenWindow: (UUID) -> Void

        var body: some View {
            if pluginStore.plugins.isEmpty {
                ContentUnavailableView(
                    "プラグインなし",
                    systemImage: "puzzlepiece.extension",
                    description: Text("プラグインがインストールされていません")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(pluginStore.plugins) { plugin in
                        PluginRowView(
                            plugin: plugin,
                            onToggle: { enabled in
                                onToggleEnabled(plugin, enabled)
                            },
                            onEdit: {
                                editingPlugin = plugin
                            }
                        )
                        .tag(plugin.id)
                        .contextMenu {
                            contextMenuItems(for: plugin)
                        }
                    }
                    .onMove { from, to in
                        pluginStore.movePlugins(from: from, to: to)
                        appModel.reloadPluginsInAllPlayerStates()
                    }
                }
                .onChange(of: pluginStore.plugins.map(\.id)) { _, ids in
                    if let selectedID, !ids.contains(selectedID) {
                        self.selectedID = nil
                    }
                }
            }
        }

        @ViewBuilder
        private func contextMenuItems(for plugin: PluginDefinition) -> some View {
            Button("別ウィンドウで開く") {
                onOpenWindow(plugin.id)
            }

            Divider()

            Button("再読み込み") {
                appModel.reloadPluginInAllPlayerStates(id: plugin.id.uuidString)
            }

            Divider()

            Button("編集") {
                editingPlugin = plugin
            }

            Divider()

            Button("上へ移動") {
                movePlugin(id: plugin.id, delta: -1)
            }
            .disabled(!canMove(id: plugin.id, delta: -1))

            Button("下へ移動") {
                movePlugin(id: plugin.id, delta: 1)
            }
            .disabled(!canMove(id: plugin.id, delta: 1))

            Divider()

            Button("削除", role: .destructive) {
                pluginIDsToDelete = [plugin.id]
                showingDeleteConfirmation = true
            }
        }

        private func canMove(id: UUID, delta: Int) -> Bool {
            guard let index = pluginStore.plugins.firstIndex(where: { $0.id == id }) else {
                return false
            }
            let newIndex = index + delta
            return newIndex >= 0 && newIndex < pluginStore.plugins.count
        }

        private func movePlugin(id: UUID, delta: Int) {
            if pluginStore.movePlugin(id: id, delta: delta) {
                selectedID = id
                appModel.reloadPluginsInAllPlayerStates()
            }
        }
    }
#endif
