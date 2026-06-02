#if os(iOS)
    import SwiftUI

    struct PluginList_iOS: View {
        @Bindable var appModel: AppModel
        @Bindable var pluginStore: PluginStore
        @Bindable var playerState: PlayerState
        @Binding var selectedID: UUID?
        @Binding var editingPlugin: PluginDefinition?
        @Binding var showingDeleteConfirmation: Bool
        @Binding var pluginIDsToDelete: [UUID]
        let onToggleEnabled: (PluginDefinition, Bool) -> Void

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
                    Section {
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
                            .contextMenu {
                                contextMenuItems(for: plugin)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pluginIDsToDelete = [plugin.id]
                                    showingDeleteConfirmation = true
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }

                                Button {
                                    appModel.reloadPluginInAllPlayerStates(id: plugin.id.uuidString)
                                } label: {
                                    Label("再読み込み", systemImage: "arrow.clockwise")
                                }
                                .tint(.blue)
                            }
                        }
                        .onDelete { indexSet in
                            pluginIDsToDelete = indexSet.map { pluginStore.plugins[$0].id }
                            showingDeleteConfirmation = true
                        }
                        .onMove { from, to in
                            pluginStore.movePlugins(from: from, to: to)
                            appModel.reloadPluginsInAllPlayerStates()
                        }
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
