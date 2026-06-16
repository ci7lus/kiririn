import KppxKit
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

struct PluginInstallConfirmationRequest: Identifiable {
    enum Kind {
        case install
        case update(pluginID: UUID, signerMismatch: Bool)
        case reenable(pluginID: UUID)
    }

    let id = UUID()
    let preview: PluginInstallPreview
    let kind: Kind

    init(preview: PluginInstallPreview, kind: Kind) {
        self.preview = preview
        self.kind = kind
    }

    init(preview: PluginInstallPreview, routing: PluginInstallRouting) {
        switch routing {
        case .install:
            self.init(preview: preview, kind: .install)
        case .update(let pluginID, let signerMismatch):
            self.init(
                preview: preview,
                kind: .update(pluginID: pluginID, signerMismatch: signerMismatch)
            )
        }
    }

    var title: String {
        switch kind {
        case .install:
            return "プラグインを追加"
        case .update:
            return "プラグインを更新"
        case .reenable:
            return "プラグインを再有効化"
        }
    }

    var descriptionText: String {
        switch kind {
        case .install:
            return "以下のプラグインをインストールしますか？"
        case .update(_, let signerMismatch):
            if signerMismatch {
                return "既存プラグインと署名元が一致しません。内容を確認してから更新してください"
            }
            return "プラグインを以下の内容で更新しますか？"
        case .reenable:
            return "内容確認が必要なためブロック中です。内容を確認してから再有効化してください"
        }
    }

    var confirmButtonTitle: String {
        switch kind {
        case .install:
            return "追加"
        case .update:
            return "更新"
        case .reenable:
            return "再有効化"
        }
    }

    var warningMessages: [String] {
        preview.installWarnings
    }
}

struct PluginsSettingsView: View {
    @State var appModel: AppModel
    @State var pluginStore: PluginStore
    @State var playerState: PlayerState

    @State private var showingPackageImporter = false
    @State private var showingURLInput = false
    @State private var showingPluginSettingsSheet = false
    @State private var importErrorMessage: String?
    @State private var selectedPluginID: UUID?
    @State private var editingPlugin: PluginDefinition?
    @State private var showingDeleteConfirmation = false
    @State private var pluginIDsToDelete: [UUID] = []
    @State private var urlInputText = ""
    @State private var downloadProgress = 0.0
    @State private var downloadedBytes: Int64 = 0
    @State private var totalBytes: Int64 = -1
    @State private var downloadError: String?
    @State private var downloadTask: Task<Void, Never>?
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
        .sheet(isPresented: downloadSheetBinding) {
            PluginDownloadProgressSheet(
                progress: downloadProgress,
                downloadedBytes: downloadedBytes,
                totalBytes: totalBytes,
                error: downloadError,
                onCancel: { cancelDownload() }
            )
        }
        #if os(macOS) || DEBUG
            .sheet(isPresented: $showingPluginSettingsSheet) {
                PluginSettingsSheet(
                    appModel: appModel,
                    pluginStore: pluginStore,
                    onDismiss: {
                        showingPluginSettingsSheet = false
                    }
                )
            }
        #endif
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
            Text("この操作は取り消せません")
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
        .alert("URLから追加", isPresented: $showingURLInput) {
            TextField("https://...", text: $urlInputText)
                .autocorrectionDisabled()
                #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                #endif
            Button("追加") {
                startRemotePluginImport()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("kppxのURLを入力してください")
        }
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
                        Button("kppxファイルから追加") {
                            importPackagesFromOpenPanel()
                        }

                        Button("URLから追加") {
                            showingURLInput = true
                        }

                        if pluginStore.isDeveloperModeEnabled {
                            Button("ローカルフォルダを参照") {
                                importLocalFolderFromOpenPanel()
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                #else
                    Menu {
                        Button("kppxファイルから追加") {
                            showingPackageImporter = true
                        }

                        Button("URLから追加") {
                            showingURLInput = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                #endif
            }
            #if !os(macOS)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    #if DEBUG
                        Button {
                            showingPluginSettingsSheet = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    #endif
                    EditButton()
                }
            #endif
            #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingPluginSettingsSheet = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("プラグイン設定")
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
        guard activeInstallConfirmation == nil else { return }

        if !pendingInstallPreviews.isEmpty {
            let preview = pendingInstallPreviews.removeFirst()
            do {
                activeInstallConfirmation = try PluginInstallConfirmationRequest(
                    preview: preview,
                    routing: pluginStore.installRouting(for: preview)
                )
            } catch {
                pluginStore.discardPreviewInstall(preview)
                importErrorMessage = error.localizedDescription
            }
        } else if !deferredImportErrorMessages.isEmpty {
            importErrorMessage = deferredImportErrorMessages.joined(separator: "\n")
            deferredImportErrorMessages = []
        }
    }

    private func cancelInstallConfirmation() {
        if let request = activeInstallConfirmation {
            pluginStore.discardPreviewInstall(request.preview)
        }
        activeInstallConfirmation = nil
        presentNextInstallPreviewIfPossible()
    }

    private func confirmInstallConfirmation(_ request: PluginInstallConfirmationRequest) {
        do {
            let plugin: PluginDefinition
            var replacedPlugin: PluginDefinition?
            switch request.kind {
            case .install:
                plugin = try pluginStore.installPlugin(from: request.preview)
            case .update(let pluginID, _):
                guard let previous = pluginStore.plugin(id: pluginID) else {
                    throw PluginManifestValidationError(messages: ["プラグインが見つかりません"])
                }
                replacedPlugin = previous
                plugin = try pluginStore.overwritePlugin(previous, with: request.preview)
            case .reenable(let pluginID):
                plugin = try pluginStore.reenableBlockedPlugin(
                    id: pluginID,
                    with: request.preview
                )
            }
            selectedPluginID = plugin.id
            activeInstallConfirmation = nil
            if let replacedPlugin {
                Task { @MainActor in
                    await PluginWebsiteDataStore.unregisterServiceWorkers(for: replacedPlugin)
                    appModel.reloadPluginsInAllPlayerStates()
                }
            } else {
                appModel.reloadPluginsInAllPlayerStates()
            }
            presentNextInstallPreviewIfPossible()
        } catch {
            activeInstallConfirmation = nil
            importErrorMessage = error.localizedDescription
        }
    }

    private func handleToggle(_ plugin: PluginDefinition, _ enabled: Bool) {
        guard enabled, plugin.isBlocked else {
            do {
                try pluginStore.setEnabled(enabled, for: plugin.id)
            } catch {
                importErrorMessage = error.localizedDescription
            }
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
                    let preview = try pluginStore.previewPlugin(
                        packageURL: url,
                        sourceType: .kppx
                    )
                    previews.append(preview)
                } catch {
                    errors.append(error.localizedDescription)
                }
            }

            if previews.isEmpty {
                importErrorMessage =
                    errors.isEmpty
                    ? "kppxの読み込みに失敗しました。形式を確認してください"
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
    private func startRemotePluginImport() {
        let trimmed = urlInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            importErrorMessage = "有効なURLを入力してください"
            return
        }

        urlInputText = ""
        downloadProgress = 0
        downloadedBytes = 0
        totalBytes = -1
        downloadError = nil

        downloadTask = Task { @MainActor [url] in
            do {
                let tempURL = try await pluginStore.downloadPackage(from: url) {
                    totalWritten, totalExpected in
                    downloadedBytes = totalWritten
                    totalBytes = totalExpected
                    if totalExpected > 0 {
                        downloadProgress = Double(totalWritten) / Double(totalExpected)
                    }
                }
                defer {
                    try? FileManager.default.removeItem(at: tempURL)
                }
                try Task.checkCancellation()
                let preview = try pluginStore.previewPlugin(
                    packageURL: tempURL, sourceType: .kppx)

                downloadTask = nil
                queueInstallPreviews([preview])
            } catch is CancellationError {
                downloadTask = nil
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    private var downloadSheetBinding: Binding<Bool> {
        Binding(
            get: { downloadTask != nil },
            set: { if !$0 { cancelDownload() } }
        )
    }

    private func syncPluginsToPlayerState() {
        appModel.syncPluginsToPlayer()
    }
}

#if os(macOS) || DEBUG
    private struct PluginSettingsSheet: View {
        let appModel: AppModel
        let pluginStore: PluginStore
        let onDismiss: () -> Void

        var body: some View {
            NavigationStack {
                Form {
                    Section("開発") {
                        Toggle(
                            "開発者モードを有効にする",
                            isOn: Binding(
                                get: { pluginStore.isDeveloperModeEnabled },
                                set: { newValue in
                                    pluginStore.setDeveloperModeEnabled(newValue)
                                    appModel.reloadPluginsInAllPlayerStates()
                                }
                            )
                        )
                    }
                }
                .formStyle(.grouped)
                .navigationTitle("プラグイン設定")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") {
                            onDismiss()
                        }
                    }
                }
            }
            #if os(macOS)
                .frame(minWidth: 420, minHeight: 220)
            #endif
        }
    }
#endif

private struct PluginDownloadProgressSheet: View {
    let progress: Double
    let downloadedBytes: Int64
    let totalBytes: Int64
    let error: String?
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let error {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    Text("プラグインの追加に失敗しました")
                        .font(.headline)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                } else {
                    Spacer()
                    ProgressView(value: totalBytes > 0 ? progress : 0, total: 1.0) {
                        Text("ダウンロード中")
                    } currentValueLabel: {
                        Text(progressLabel)
                            .font(.subheadline.monospacedDigit())
                    }
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 40)

                    Text(downloadSpeedLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .frame(minHeight: 200)
            .navigationTitle("プラグインを追加")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        onCancel()
                    }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 400, minHeight: 220)
        #endif
    }

    private var progressLabel: String {
        let written = ByteCountFormatter.string(
            fromByteCount: downloadedBytes, countStyle: .file)
        if totalBytes > 0 {
            let total = ByteCountFormatter.string(
                fromByteCount: totalBytes, countStyle: .file)
            return "\(written) / \(total)"
        }
        return written
    }

    private var downloadSpeedLabel: String {
        guard totalBytes > 0 else { return "" }
        let percentage = Int(progress * 100)
        return "\(percentage)% 完了"
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

                if !request.warningMessages.isEmpty {
                    Section("警告") {
                        ForEach(request.warningMessages, id: \.self) { warning in
                            Label {
                                Text(warning)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                            .foregroundStyle(.orange)
                        }
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
