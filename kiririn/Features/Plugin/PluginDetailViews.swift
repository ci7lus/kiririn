import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

struct PluginEditSheet: View {
    @Bindable var appModel: AppModel
    @Bindable var pluginStore: PluginStore
    @Bindable var playerState: PlayerState
    let pluginID: UUID
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            PluginDetailView(
                appModel: appModel,
                pluginStore: pluginStore,
                playerState: playerState,
                pluginID: pluginID
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { onDismiss() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

struct PluginRowView: View {
    let plugin: PluginDefinition
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void

    var body: some View {
        #if os(macOS)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(plugin.name)
                        .font(.body)

                    if plugin.isBlocked {
                        blockedBadge
                    }

                    Spacer()

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { plugin.isEnabled },
                            set: { onToggle($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                if plugin.isBlocked {
                    blockedDescription
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        #else
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(plugin.name)
                        .font(.body)

                    if plugin.isBlocked {
                        blockedBadge
                    }

                    Spacer()

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { plugin.isEnabled },
                            set: { onToggle($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                if plugin.isBlocked {
                    blockedDescription
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onEdit()
            }
        #endif
    }

    private var blockedBadge: some View {
        Text("ブロック中")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.14), in: Capsule())
    }

    private var blockedDescription: some View {
        Text("内容確認が必要なため無効化されています")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}

struct PluginManifestPresentation {
    let sourceLabel: String?
    let manifestID: String
    let version: String?
    let author: String?
    let homepageURL: String?
    let summary: String?
    let displayAreas: [PluginDisplayArea]?
    let isBackgroundExists: Bool
    let manifestUpdateURL: String?
    let requestedPermissions: [String]
    let requestedHostPermissions: [String]

    init(plugin: PluginDefinition, manifest: ExtensionPluginManifest?) {
        sourceLabel = plugin.sourceType.localizedLabel
        manifestID = plugin.manifestID
        version = manifest?.version ?? plugin.manifestVersion
        author = manifest?.author ?? plugin.manifestAuthor
        homepageURL = manifest?.homepageURL ?? plugin.manifestLink
        summary = manifest?.summary
        displayAreas = manifest?.displayAreas ?? plugin.manifestSupportedAreas
        isBackgroundExists = manifest?.isBackgroundExists ?? false
        manifestUpdateURL = manifest?.manifestUpdateURL ?? plugin.manifestUpdateURL
        requestedPermissions = manifest?.requestedPermissions ?? []
        requestedHostPermissions = manifest?.requestedHostPermissions ?? []
    }

    init(preview: PluginInstallPreview) {
        sourceLabel = preview.sourceType.localizedLabel
        manifestID = preview.manifest.manifestID
        version = preview.manifest.version
        author = preview.manifest.author
        homepageURL = preview.manifest.homepageURL
        summary = preview.manifest.summary
        displayAreas = preview.manifest.displayAreas
        isBackgroundExists = preview.manifest.isBackgroundExists
        manifestUpdateURL = preview.manifest.manifestUpdateURL
        requestedPermissions = preview.manifest.requestedPermissions
        requestedHostPermissions = preview.manifest.requestedHostPermissions
    }
}

struct PluginManifestInfoSections: View {
    let info: PluginManifestPresentation

    var body: some View {
        metadataSection
        descriptionSection
        permissionsSection
        hostPermissionsSection
    }

    @ViewBuilder
    private var metadataSection: some View {
        Section {
            if let sourceLabel = info.sourceLabel {
                LabeledContent("ソース") {
                    Text(sourceLabel)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("ID") {
                Text(info.manifestID)
                    .foregroundStyle(.secondary)
                    .font(.system(.body, design: .monospaced))
            }
            if let version = info.version {
                LabeledContent("バージョン") {
                    Text(version).foregroundStyle(.secondary)
                }
            }
            if let author = info.author {
                LabeledContent("作者") {
                    Text(author).foregroundStyle(.secondary)
                }
            }
            if let link = info.homepageURL, let url = URL(string: link) {
                LabeledContent("リンク") {
                    Link(link, destination: url)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let updateURL = info.manifestUpdateURL,
                let url = URL(string: updateURL)
            {
                LabeledContent("更新 URL") {
                    Link(updateURL, destination: url)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            LabeledContent("対応エリア") {
                if let areas = info.displayAreas {
                    Text(areas.map(\.localizedName).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                } else {
                    Text("すべて").foregroundStyle(.secondary)
                }
            }
            LabeledContent("バックグラウンド") {
                Text(info.isBackgroundExists ? "あり" : "なし")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if let summary = info.summary {
            Section("説明") {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        Section("権限") {
            if !info.requestedPermissions.isEmpty {
                ForEach(info.requestedPermissions, id: \.self) { permission in
                    Text(permission)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("追加権限なし", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private var hostPermissionsSection: some View {
        Section("アクセス許可 URL") {
            if !info.requestedHostPermissions.isEmpty {
                ForEach(info.requestedHostPermissions, id: \.self) { pattern in
                    Text(pattern)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("外部 URL へのアクセスなし", systemImage: "network.slash")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
    }
}

private struct PluginDetailView: View {
    @State var appModel: AppModel
    @State var pluginStore: PluginStore
    @State var playerState: PlayerState
    let pluginID: UUID

    @State private var showingOverwriteImporter = false
    @State private var showingRemoteURLSheet = false
    @State private var showingClearWebDataConfirmation = false
    @State private var isClearingWebData = false
    @State private var isUpdatingFromRemoteURL = false
    @State private var manifestErrorMessage: String?
    @State private var webDataAlertMessage: String?
    @State private var remoteURLString = ""
    @State private var activeInstallConfirmation: PluginInstallConfirmationRequest?

    private var plugin: PluginDefinition? {
        pluginStore.plugin(id: pluginID)
    }

    var body: some View {
        Group {
            if let plugin {
                detailForm(for: plugin)
            } else {
                ContentUnavailableView("プラグインが見つかりません", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private func detailForm(for plugin: PluginDefinition) -> some View {
        Form {
            enabledSection(for: plugin)
            PluginManifestInfoSections(info: manifestInfo(for: plugin))
            actionsSection(for: plugin)
        }
        .formStyle(.grouped)
        .navigationTitle(plugin.name)
        .sheet(isPresented: $showingRemoteURLSheet) {
            PluginRemoteUpdateSheet(
                urlString: $remoteURLString,
                isImporting: isUpdatingFromRemoteURL,
                onCancel: {
                    remoteURLString = ""
                    showingRemoteURLSheet = false
                },
                onImport: {
                    Task {
                        await updatePluginFromRemoteURL()
                    }
                }
            )
        }
        .sheet(item: $activeInstallConfirmation) { request in
            PluginInstallConfirmationSheet(
                request: request,
                onCancel: {
                    activeInstallConfirmation = nil
                },
                onConfirm: {
                    confirmInstallConfirmation(request)
                }
            )
        }
        #if !os(macOS)
            .fileImporter(
                isPresented: $showingOverwriteImporter,
                allowedContentTypes: [UTType(filenameExtension: "kppx") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                overwriteSource(from: result)
            }
        #endif
        .alert(
            "マニフェストエラー",
            isPresented: Binding(
                get: { manifestErrorMessage != nil },
                set: { if !$0 { manifestErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { manifestErrorMessage = nil }
        } message: {
            Text(manifestErrorMessage ?? "")
        }
        .confirmationDialog(
            "プラグインのストレージを消去しますか？",
            isPresented: $showingClearWebDataConfirmation,
            titleVisibility: .visible
        ) {
            Button("消去", role: .destructive) {
                Task {
                    await clearWebData(for: plugin)
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(clearWebDataConfirmationMessage(for: plugin))
        }
        .alert(
            "ストレージ",
            isPresented: Binding(
                get: { webDataAlertMessage != nil },
                set: { if !$0 { webDataAlertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { webDataAlertMessage = nil }
        } message: {
            Text(webDataAlertMessage ?? "")
        }
    }

    private func enabledSection(for plugin: PluginDefinition) -> some View {
        Section {
            Toggle("有効", isOn: enabledBinding(for: plugin))

            if plugin.isBlocked {
                Label(
                    "内容確認が必要なためブロックしています。再有効化するには内容確認が必要です。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func actionsSection(for plugin: PluginDefinition) -> some View {
        Section {
            if plugin.manifestUpdateURL != nil {
                Button {
                    remoteURLString = plugin.manifestUpdateURL ?? ""
                    showingRemoteURLSheet = true
                } label: {
                    HStack(spacing: 8) {
                        if isUpdatingFromRemoteURL {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Label("更新 URL から更新", systemImage: "arrow.clockwise.circle")
                    }
                }
                .buttonStyle(.plain)
                .disabled(isUpdatingFromRemoteURL)
            }

            if plugin.sourceType != .localFolder {
                Button {
                    #if os(macOS)
                        overwriteFromOpenPanel()
                    #else
                        showingOverwriteImporter = true
                    #endif
                } label: {
                    Label("kkpxファイルから上書き", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.plain)
            }

            #if os(macOS)
                if plugin.sourceType == .localFolder {
                    Button {
                        replaceFolderFromOpenPanel()
                    } label: {
                        Label("ローカルフォルダを差し替え", systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                }
            #endif

            Button(role: .destructive) {
                showingClearWebDataConfirmation = true
            } label: {
                HStack(spacing: 8) {
                    if isClearingWebData {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Label("ストレージを消去", systemImage: "trash")
                }
            }
            .buttonStyle(.plain)
            .disabled(isClearingWebData)

            if plugin.manifestSupportedAreas?.contains(.options) == true {
                NavigationLink {
                    PluginOptionsScreen(
                        appModel: appModel,
                        plugin: plugin,
                        playerState: playerState
                    )
                } label: {
                    Label("プラグイン設定を開く", systemImage: "slider.horizontal.3")
                }
            }
        }
    }

    private func manifestInfo(for plugin: PluginDefinition) -> PluginManifestPresentation {
        PluginManifestPresentation(
            plugin: plugin,
            manifest: pluginStore.resolvedManifest(for: plugin.id)
        )
    }

    private func enabledBinding(for plugin: PluginDefinition) -> Binding<Bool> {
        Binding(
            get: { pluginStore.plugin(id: plugin.id)?.isEnabled ?? false },
            set: { newValue in
                guard let currentPlugin = pluginStore.plugin(id: plugin.id) else { return }
                if newValue, currentPlugin.isBlocked {
                    requestReenableConfirmation(for: currentPlugin)
                    return
                }
                pluginStore.setEnabled(newValue, for: currentPlugin.id)
            }
        )
    }

    private func requestReenableConfirmation(for plugin: PluginDefinition) {
        do {
            activeInstallConfirmation = PluginInstallConfirmationRequest(
                preview: try pluginStore.previewStoredPlugin(for: plugin.id),
                kind: .reenable(pluginID: plugin.id)
            )
        } catch {
            manifestErrorMessage = error.localizedDescription
        }
    }

    private func confirmInstallConfirmation(_ request: PluginInstallConfirmationRequest) {
        do {
            switch request.kind {
            case .install:
                break
            case .reenable(let pluginID):
                _ = try pluginStore.reenableBlockedPlugin(id: pluginID, with: request.preview)
                appModel.reloadPluginInAllPlayerStates(id: pluginID.uuidString)
            }
            activeInstallConfirmation = nil
        } catch {
            activeInstallConfirmation = nil
            manifestErrorMessage = error.localizedDescription
        }
    }

    private func overwriteSource(from result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first, let plugin = pluginStore.plugin(id: pluginID) else {
                return
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                try pluginStore.overwritePlugin(
                    plugin, withPackageData: data, sourceType: .localFile)
                Task { @MainActor in
                    await PluginWebsiteDataStore.unregisterServiceWorkers(for: plugin)
                    appModel.reloadPluginInAllPlayerStates(id: pluginID.uuidString)
                }
            } catch let error as PluginManifestValidationError {
                manifestErrorMessage = error.errorDescription
            } catch {
                manifestErrorMessage = error.localizedDescription
            }
        case .failure(let error):
            manifestErrorMessage = error.localizedDescription
        }
    }

    #if os(macOS)
        private func replaceLocalFolder(from result: Result<[URL], Error>) {
            switch result {
            case .success(let urls):
                guard let url = urls.first, let plugin = pluginStore.plugin(id: pluginID) else {
                    return
                }
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
                    try pluginStore.overwritePlugin(
                        plugin,
                        withLocalFolderURL: url,
                        bookmarkData: bookmarkData
                    )
                    Task { @MainActor in
                        await PluginWebsiteDataStore.unregisterServiceWorkers(for: plugin)
                        appModel.reloadPluginInAllPlayerStates(id: pluginID.uuidString)
                    }
                } catch let error as PluginManifestValidationError {
                    manifestErrorMessage = error.errorDescription
                } catch {
                    manifestErrorMessage = error.localizedDescription
                }
            case .failure(let error):
                manifestErrorMessage = error.localizedDescription
            }
        }

        private func overwriteFromOpenPanel() {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "kppx") ?? .data]
            panel.allowsMultipleSelection = false
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.canCreateDirectories = false
            panel.prompt = "上書き"
            guard panel.runModal() == .OK else { return }
            overwriteSource(from: .success(panel.urls))
        }

        private func replaceFolderFromOpenPanel() {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.folder]
            panel.allowsMultipleSelection = false
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = false
            panel.prompt = "選択"
            guard panel.runModal() == .OK else { return }
            replaceLocalFolder(from: .success(panel.urls))
        }
    #endif

    private func clearWebDataConfirmationMessage(for plugin: PluginDefinition) -> String {
        "プラグインの panel / overlay / options に紐づくストレージを消去します。消去後は再読み込みされます。"
    }

    @MainActor
    private func clearWebData(for plugin: PluginDefinition) async {
        guard !isClearingWebData else { return }

        isClearingWebData = true

        do {
            let removedAnyData = try await PluginWebsiteDataStore.removeAllData(
                for: plugin,
                store: pluginStore
            )

            guard removedAnyData else {
                webDataAlertMessage = "消去対象のストレージは見つかりませんでした。"
                isClearingWebData = false
                return
            }

            appModel.reloadPluginInAllPlayerStates(id: plugin.id.uuidString)
            webDataAlertMessage = "プラグインのストレージを消去しました。"
        } catch {
            webDataAlertMessage = "プラグインのストレージを消去できませんでした。"
        }

        isClearingWebData = false
    }

    @MainActor
    private func updatePluginFromRemoteURL() async {
        guard !isUpdatingFromRemoteURL, let plugin = pluginStore.plugin(id: pluginID) else {
            return
        }
        let trimmedURL = remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), !trimmedURL.isEmpty else {
            manifestErrorMessage = "有効な URL を入力してください。"
            return
        }

        isUpdatingFromRemoteURL = true
        defer { isUpdatingFromRemoteURL = false }

        do {
            try await pluginStore.overwritePlugin(fromUpdateManifestURL: url, previous: plugin)
            await PluginWebsiteDataStore.unregisterServiceWorkers(for: plugin)
            remoteURLString = ""
            showingRemoteURLSheet = false
            appModel.reloadPluginInAllPlayerStates(id: pluginID.uuidString)
        } catch let error as PluginManifestValidationError {
            manifestErrorMessage = error.errorDescription
        } catch {
            manifestErrorMessage = error.localizedDescription
        }
    }
}

private struct PluginOptionsScreen: View {
    @State var appModel: AppModel
    let plugin: PluginDefinition
    @State var playerState: PlayerState

    var body: some View {
        PluginOverlayView(
            pluginDefinition: plugin,
            appModel: appModel,
            reloadToken: playerState.pluginReloadToken
                + playerState.perPluginReloadTokens[plugin.id.uuidString, default: 0],
            displayArea: .options
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.kiririnSecondarySystemBackground)
        .navigationTitle("\(plugin.name) 設定")
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct PluginRemoteUpdateSheet: View {
    @Binding var urlString: String
    let isImporting: Bool
    let onCancel: () -> Void
    let onImport: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("URL") {
                    TextField("https://example.com/plugins/sample/update.json", text: $urlString)
                        #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                        #endif
                }
            }
            .navigationTitle("更新 URL から更新")
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
                            Text("更新")
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
