import SwiftUI
import UniformTypeIdentifiers

struct PluginSettingsView: View {
    @State var appModel: AppModel
    @State var pluginStore: PluginStore
    @State var playerState: PlayerState

    @State private var showingImporter = false
    @State private var importErrorMessage: String?
    @State private var selectedPluginID: UUID?
    @State private var editingPlugin: PluginDefinition?
    @State private var showingDeleteConfirmation = false
    @State private var pluginIDsToDelete: [UUID] = []

    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        Group {
            #if os(macOS)
                PluginList_macOS(
                    appModel: appModel,
                    pluginStore: pluginStore,
                    playerState: playerState,
                    selectedID: $selectedPluginID,
                    editingPlugin: $editingPlugin,
                    showingDeleteConfirmation: $showingDeleteConfirmation,
                    pluginIDsToDelete: $pluginIDsToDelete,
                    onOpenWindow: { id in
                        openWindow(id: AppWindowID.plugin.rawValue, value: id)
                    }
                )
                .listStyle(.inset)
            #else
                PluginList_iOS(
                    appModel: appModel,
                    pluginStore: pluginStore,
                    playerState: playerState,
                    selectedID: $selectedPluginID,
                    editingPlugin: $editingPlugin,
                    showingDeleteConfirmation: $showingDeleteConfirmation,
                    pluginIDsToDelete: $pluginIDsToDelete
                )
            #endif
        }
        .navigationTitle("プラグイン")
        .sheet(item: $editingPlugin) { plugin in
            PluginEditSheet(
                appModel: appModel,
                pluginStore: pluginStore,
                playerState: playerState,
                pluginID: plugin.id,
                onDismiss: { editingPlugin = nil }
            )
        }
        .toolbar {
            settingsToolbar
        }
        .confirmationDialog(
            "プラグインを削除しますか？",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            deleteConfirmationButtons
        } message: {
            Text("この操作は取り消せません。")
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.html, .plainText],
            allowsMultipleSelection: true
        ) { result in
            importPlugins(from: result)
        }
        .alert(
            "読み込みエラー",
            isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { newValue in
                    if !newValue {
                        importErrorMessage = nil
                        pluginStore.clearFileReadErrorMessage()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                importErrorMessage = nil
                pluginStore.clearFileReadErrorMessage()
            }
        } message: {
            Text(importErrorMessage ?? "")
        }
        .onAppear {
            syncPluginsToPlayerState()
            if let readError = pluginStore.fileReadErrorMessage {
                importErrorMessage = readError
            }
        }
        .onChange(of: pluginStore.plugins) { _, _ in
            syncPluginsToPlayerState()
        }
        .onChange(of: pluginStore.fileReadErrorMessage) { _, newValue in
            if let newValue {
                importErrorMessage = newValue
            }
        }
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button {
                showingImporter = true
            } label: {
                Image(systemName: "plus")
            }
        }
        #if !os(macOS)
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        #endif
        #if os(macOS)
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    NSWorkspace.shared.open(pluginStore.pluginDirectoryURL)
                } label: {
                    Image(systemName: "folder")
                }
                .help("プラグインフォルダを開く")

                Button {
                    if let id = selectedPluginID {
                        openWindow(id: AppWindowID.plugin.rawValue, value: id)
                    }
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .help("選択したプラグインを別ウィンドウで開く")
                .disabled(selectedPluginID == nil)

                Button {
                    if let id = selectedPluginID {
                        editingPlugin = pluginStore.plugin(id: id)
                    }
                } label: {
                    Image(systemName: "info.circle")
                }
                .help("選択したプラグインを編集")
                .disabled(selectedPluginID == nil)

                Button {
                    if let id = selectedPluginID {
                        movePlugin(id: id, delta: -1)
                    }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .help("選択したプラグインを上へ移動")
                .disabled(!canMoveSelected(delta: -1))

                Button {
                    if let id = selectedPluginID {
                        movePlugin(id: id, delta: 1)
                    }
                } label: {
                    Image(systemName: "arrow.down")
                }
                .help("選択したプラグインを下へ移動")
                .disabled(!canMoveSelected(delta: 1))

                Button {
                    if let id = selectedPluginID {
                        appModel.reloadPluginInAllPlayerStates(id: id.uuidString)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("選択したプラグインを再読み込み")
                .disabled(selectedPluginID == nil)

                Button(role: .destructive) {
                    if let id = selectedPluginID {
                        pluginIDsToDelete = [id]
                        showingDeleteConfirmation = true
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .help("選択したプラグインを削除")
                .disabled(selectedPluginID == nil)
            }
        #endif
    }

    @ViewBuilder
    private var deleteConfirmationButtons: some View {
        Button("削除", role: .destructive) {
            for id in pluginIDsToDelete {
                pluginStore.removePlugin(id: id)
            }
            pluginIDsToDelete = []
            appModel.reloadPluginsInAllPlayerStates()
        }
        Button("キャンセル", role: .cancel) {
            pluginIDsToDelete = []
        }
    }

    private func canMoveSelected(delta: Int) -> Bool {
        guard let id = selectedPluginID else { return false }
        return canMove(id: id, delta: delta)
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
            selectedPluginID = id
            appModel.reloadPluginsInAllPlayerStates()
        }
    }

    private func importPlugins(from result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        case .success(let urls):
            var loadedCount = 0
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let data = try Data(contentsOf: url)
                    guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
                        continue
                    }
                    try pluginStore.addPlugin(htmlContent: html)
                    loadedCount += 1
                } catch {
                    importErrorMessage = error.localizedDescription
                }
            }
            if loadedCount > 0 {
                appModel.reloadPluginsInAllPlayerStates()
            }
            if loadedCount == 0, importErrorMessage == nil {
                importErrorMessage = "ファイルの読み込みに失敗しました。形式を確認してください。"
            }
        }
    }

    private func syncPluginsToPlayerState() {
        appModel.syncPluginsToPlayer()
    }
}
