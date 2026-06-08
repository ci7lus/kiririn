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
                        .contentShape(Rectangle())
                    }
                    .onMove { from, to in
                        pluginStore.movePlugins(from: from, to: to)
                        appModel.reloadPluginsInAllPlayerStates()
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { selectedIDs in
                    if let firstID = selectedIDs.first,
                        let plugin = pluginStore.plugins.first(where: { $0.id == firstID })
                    {
                        contextMenuItems(for: plugin)
                    }
                } primaryAction: { selectedIDs in
                    if let firstID = selectedIDs.first,
                        let plugin = pluginStore.plugins.first(where: { $0.id == firstID })
                    {
                        editingPlugin = plugin
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
            Button("編集") {
                editingPlugin = plugin
            }

            Divider()

            Button("プラグインウィンドウを開く") {
                onOpenWindow(plugin.id)
            }

            Divider()

            Button("再読み込み") {
                appModel.reloadPluginInAllPlayerStates(id: plugin.id.uuidString)
            }

            Divider()

            Button("削除", role: .destructive) {
                pluginIDsToDelete = [plugin.id]
                showingDeleteConfirmation = true
            }
        }
    }
#endif
