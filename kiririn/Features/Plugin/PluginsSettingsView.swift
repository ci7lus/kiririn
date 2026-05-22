import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

struct PluginInstallConfirmationRequest: Identifiable {
    enum Kind {
        case install
        case reenable(pluginID: UUID)
    }

    let id = UUID()
    let preview: PluginInstallPreview
    let kind: Kind

    var title: String {
        switch kind {
        case .install:
            return "プラグインを追加"
        case .reenable:
            return "プラグインを再有効化"
        }
    }

    var descriptionText: String {
        switch kind {
        case .install:
            return "以下の内容を確認してから追加してください。"
        case .reenable:
            return "内容確認が必要なためブロック中です。内容を確認してから再有効化してください。"
        }
    }

    var confirmButtonTitle: String {
        switch kind {
        case .install:
            return "追加"
        case .reenable:
            return "再有効化"
        }
    }
}

struct PluginsSettingsView: View {
    @State var appModel: AppModel
    @State var pluginStore: PluginStore
    @State var playerState: PlayerState

    @State private var showingImportMethodChooser = false
    @State private var showingPackageImporter = false
    @State private var showingRemoteURLSheet = false
    @State private var importErrorMessage: String?
    @State private var selectedPluginID: UUID?
    @State private var editingPlugin: PluginDefinition?
    @State private var showingDeleteConfirmation = false
    @State private var pluginIDsToDelete: [UUID] = []
    @State private var remoteURLString = ""
    @State private var isImportingFromRemoteURL = false
    @State private var pendingInstallPreviews: [PluginInstallPreview] = []
    @State private var activeInstallConfirmation: PluginInstallConfirmationRequest?
    @State private var deferredImportErrorMessages: [String] = []

    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    @Environment(\.isTabActive) private var isTabActive

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
                    onToggleEnabled: handleToggle,
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
                    pluginIDsToDelete: $pluginIDsToDelete,
                    onToggleEnabled: handleToggle
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
        .sheet(item: $activeInstallConfirmation) { request in
            PluginInstallConfirmationSheet(
                request: request,
                onCancel: {
                    cancelInstallConfirmation()
                },
                onConfirm: {
                    confirmInstallConfirmation(request)
                }
            )
        }
        .sheet(isPresented: $showingRemoteURLSheet) {
            RemotePluginImportSheet(
                urlString: $remoteURLString,
                isImporting: isImportingFromRemoteURL,
                onCancel: {
                    remoteURLString = ""
                    showingRemoteURLSheet = false
                },
                onImport: {
                    Task {
                        await importPluginFromRemoteURL()
                    }
                }
            )
        }
        .toolbar {
            settingsToolbar
        }
        #if !os(macOS)
            .confirmationDialog(
                "追加方法",
                isPresented: $showingImportMethodChooser,
                titleVisibility: .visible
            ) {
                Button("URL から追加") {
                    showingRemoteURLSheet = true
                }

                Button("ファイルから追加 (.kppx)") {
                    showingPackageImporter = true
                }

                Button("キャンセル", role: .cancel) {}
            }
        #endif
        .confirmationDialog(
            "プラグインを削除しますか？",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            deleteConfirmationButtons
        } message: {
            Text("この操作は取り消せません。")
        }
        #if !os(macOS)
            .fileImporter(
                isPresented: $showingPackageImporter,
                allowedContentTypes: [UTType(filenameExtension: "kppx") ?? .data],
                allowsMultipleSelection: true
            ) { result in
                importPackages(from: result)
            }
        #endif
        .alert(
            "読み込みエラー",
            isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { newValue in
                    if !newValue {
                        importErrorMessage = nil
                        pluginStore.clearFileReadErrorMessage()
                        presentNextInstallPreviewIfPossible()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                importErrorMessage = nil
                pluginStore.clearFileReadErrorMessage()
                presentNextInstallPreviewIfPossible()
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
        if isTabActive {
            ToolbarItem(placement: .automatic) {
                #if os(macOS)
                    Menu {
                        Button("URL から追加") {
                            showingRemoteURLSheet = true
                        }

                        Button("ファイルから追加 (.kppx)") {
                            importPackagesFromOpenPanel()
                        }

                        Button("ローカルフォルダを参照") {
                            importLocalFolderFromOpenPanel()
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                #else
                    Button {
                        showingImportMethodChooser = true
                    } label: {
                        Image(systemName: "plus")
                    }
                #endif
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

    private func queueInstallPreviews(
        _ previews: [PluginInstallPreview],
        deferredErrors: [String] = []
    ) {
        deferredImportErrorMessages.append(contentsOf: deferredErrors)
        pendingInstallPreviews.append(contentsOf: previews)
        presentNextInstallPreviewIfPossible()
    }

    private func presentNextInstallPreviewIfPossible() {
        guard importErrorMessage == nil, activeInstallConfirmation == nil else {
            return
        }

        if !pendingInstallPreviews.isEmpty {
            activeInstallConfirmation = PluginInstallConfirmationRequest(
                preview: pendingInstallPreviews.removeFirst(),
                kind: .install
            )
        } else if !deferredImportErrorMessages.isEmpty {
            importErrorMessage = deferredImportErrorMessages.joined(separator: "\n")
            deferredImportErrorMessages = []
        }
    }

    private func cancelInstallConfirmation() {
        activeInstallConfirmation = nil
        presentNextInstallPreviewIfPossible()
    }

    private func confirmInstallConfirmation(_ request: PluginInstallConfirmationRequest) {
        do {
            let plugin: PluginDefinition
            switch request.kind {
            case .install:
                plugin = try pluginStore.installPlugin(from: request.preview)
            case .reenable(let pluginID):
                plugin = try pluginStore.reenableBlockedPlugin(
                    id: pluginID,
                    with: request.preview
                )
            }
            selectedPluginID = plugin.id
            activeInstallConfirmation = nil
            appModel.reloadPluginsInAllPlayerStates()
            presentNextInstallPreviewIfPossible()
        } catch {
            activeInstallConfirmation = nil
            importErrorMessage = error.localizedDescription
        }
    }

    private func handleToggle(_ plugin: PluginDefinition, _ enabled: Bool) {
        guard enabled, plugin.isBlocked else {
            pluginStore.setEnabled(enabled, for: plugin.id)
            return
        }

        do {
            activeInstallConfirmation = PluginInstallConfirmationRequest(
                preview: try pluginStore.previewStoredPlugin(for: plugin.id),
                kind: .reenable(pluginID: plugin.id)
            )
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private func importPackages(from result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        case .success(let urls):
            var previews: [PluginInstallPreview] = []
            var errors: [String] = []
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let data = try Data(contentsOf: url)
                    let preview = try pluginStore.previewPlugin(
                        packageData: data,
                        sourceType: .localFile
                    )
                    previews.append(preview)
                } catch {
                    errors.append(error.localizedDescription)
                }
            }

            if previews.isEmpty {
                importErrorMessage =
                    errors.isEmpty
                    ? "kkpxの読み込みに失敗しました。形式を確認してください。"
                    : errors.joined(separator: "\n")
                return
            }

            queueInstallPreviews(previews, deferredErrors: errors)
        }
    }

    #if os(macOS)
        private func importPackagesFromOpenPanel() {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "kppx") ?? .data]
            panel.allowsMultipleSelection = true
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.canCreateDirectories = false
            panel.prompt = "追加"

            guard panel.runModal() == .OK else { return }
            importPackages(from: .success(panel.urls))
        }

        private func importLocalFolderFromOpenPanel() {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.folder]
            panel.allowsMultipleSelection = false
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = false
            panel.prompt = "選択"

            guard panel.runModal() == .OK else { return }
            importLocalFolder(from: .success(panel.urls))
        }

        private func importLocalFolder(from result: Result<[URL], Error>) {
            switch result {
            case .failure(let error):
                importErrorMessage = error.localizedDescription
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let bookmarkData = try url.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    let preview = try pluginStore.previewPlugin(
                        localFolderURL: url,
                        bookmarkData: bookmarkData
                    )
                    queueInstallPreviews([preview])
                } catch {
                    importErrorMessage = error.localizedDescription
                }
            }
        }
    #endif

    @MainActor
    private func importPluginFromRemoteURL() async {
        guard !isImportingFromRemoteURL else { return }
        let trimmedURL = remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), !trimmedURL.isEmpty else {
            importErrorMessage = "有効な URL を入力してください。"
            return
        }

        isImportingFromRemoteURL = true
        defer { isImportingFromRemoteURL = false }

        do {
            let preview = try await pluginStore.previewPlugin(fromRemoteURL: url)
            remoteURLString = ""
            showingRemoteURLSheet = false
            queueInstallPreviews([preview])
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private func syncPluginsToPlayerState() {
        appModel.syncPluginsToPlayer()
    }
}

private struct RemotePluginImportSheet: View {
    @Binding var urlString: String
    let isImporting: Bool
    let onCancel: () -> Void
    let onImport: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("URL") {
                    TextField("https://example.com/plugin.kppx", text: $urlString)
                        #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                        #endif
                }
            }
            .formStyle(.grouped)
            .navigationTitle("URL から追加")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onImport()
                    } label: {
                        if isImporting {
                            ProgressView()
                        } else {
                            Text("追加")
                        }
                    }
                    .disabled(isImporting)
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 160)
        #endif
    }
}

struct PluginInstallConfirmationSheet: View {
    let request: PluginInstallConfirmationRequest
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            request.preview.manifest.displayName,
                            systemImage: "puzzlepiece.extension"
                        )
                        .font(.headline)
                        Text(request.descriptionText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                PluginManifestInfoSections(
                    info: PluginManifestPresentation(preview: request.preview)
                )
            }
            .formStyle(.grouped)
            .navigationTitle(request.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.confirmButtonTitle) {
                        onConfirm()
                    }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 480, minHeight: 520)
        #endif
    }
}
