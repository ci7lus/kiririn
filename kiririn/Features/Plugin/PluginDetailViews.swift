import SwiftUI
import UniformTypeIdentifiers

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
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        #else
            HStack(spacing: 12) {
                Text(plugin.name)
                    .font(.body)

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
            .contentShape(Rectangle())
            .onTapGesture {
                onEdit()
            }
        #endif
    }
}

private struct PluginDetailView: View {
    @State var appModel: AppModel
    @State var pluginStore: PluginStore
    @State var playerState: PlayerState
    let pluginID: UUID

    @State private var showingOverwriteImporter = false
    @State private var showingClearWebDataConfirmation = false
    @State private var isClearingWebData = false
    @State private var manifestErrorMessage: String?
    @State private var webDataAlertMessage: String?

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
            metadataSection(for: plugin)
            allowedURLPatternsSection(for: plugin)
            actionsSection(for: plugin)
        }
        .formStyle(.grouped)
        .navigationTitle(plugin.name)
        .fileImporter(
            isPresented: $showingOverwriteImporter,
            allowedContentTypes: [.html, .plainText],
            allowsMultipleSelection: false
        ) { result in
            overwriteSource(from: result)
        }
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
            "プラグインの Web データを削除しますか？",
            isPresented: $showingClearWebDataConfirmation,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                Task {
                    await clearWebData(for: plugin)
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(clearWebDataConfirmationMessage(for: plugin))
        }
        .alert(
            "Web データ",
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
        }
    }

    @ViewBuilder
    private func metadataSection(for plugin: PluginDefinition) -> some View {
        Section {
            LabeledContent("ID") {
                Text(plugin.manifestID)
                    .foregroundStyle(.secondary)
                    .font(.system(.body, design: .monospaced))
            }
            if let version = plugin.manifestVersion {
                LabeledContent("バージョン") {
                    Text(version).foregroundStyle(.secondary)
                }
            }
            if let author = plugin.manifestAuthor {
                LabeledContent("作者") {
                    Text(author).foregroundStyle(.secondary)
                }
            }
            if let link = plugin.manifestLink, let url = URL(string: link) {
                LabeledContent("リンク") {
                    Link(link, destination: url)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            LabeledContent("対応エリア") {
                if let areas = plugin.manifestSupportedAreas {
                    Text(areas.map(\.localizedName).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                } else {
                    Text("すべて").foregroundStyle(.secondary)
                }
            }
            if let contextId = plugin.manifestContextId {
                LabeledContent("コンテキストID") {
                    Text(contextId)
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
    }

    @ViewBuilder
    private func allowedURLPatternsSection(for plugin: PluginDefinition) -> some View {
        Section("アクセス許可 URL") {
            if let patterns = plugin.manifestAllowedURLPatterns, !patterns.isEmpty {
                ForEach(patterns, id: \.self) { pattern in
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

    @ViewBuilder
    private func actionsSection(for plugin: PluginDefinition) -> some View {
        Section {
            Button {
                showingOverwriteImporter = true
            } label: {
                Label("ファイルから上書き", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                showingClearWebDataConfirmation = true
            } label: {
                HStack(spacing: 8) {
                    if isClearingWebData {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Label("プラグインの Web データを削除", systemImage: "trash")
                }
            }
            .buttonStyle(.plain)
            .disabled(isClearingWebData)

            if plugin.manifestSupportedAreas?.contains(.pluginSettings) == true {
                NavigationLink {
                    PluginAreaScreen(
                        appModel: appModel,
                        plugin: plugin,
                        playerState: playerState,
                        displayArea: .pluginSettings,
                        title: "\(plugin.name) 設定"
                    )
                } label: {
                    Label("プラグイン設定を開く", systemImage: "slider.horizontal.3")
                }
            }
        }
    }

    private func enabledBinding(for plugin: PluginDefinition) -> Binding<Bool> {
        Binding(
            get: { pluginStore.plugin(id: plugin.id)?.isEnabled ?? false },
            set: { newValue in
                guard var updated = pluginStore.plugin(id: plugin.id) else { return }
                updated.isEnabled = newValue
                pluginStore.updatePlugin(updated)
            }
        )
    }

    private func overwriteSource(from result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                guard let html = String(data: data, encoding: .utf8), !html.isEmpty else { return }
                let manifest = try PluginStore.parseManifest(from: html)
                if var plugin = pluginStore.plugin(id: pluginID) {
                    let newID = manifest.identifier
                    if plugin.manifestID != newID {
                        throw PluginManifestValidationError(messages: [
                            "プラグインIDが一致しません。別のプラグインファイルです（既存: \"\(plugin.manifestID)\" / マニフェスト: \"\(newID)\""
                        ])
                    }
                    plugin.htmlContent = html
                    plugin.name = manifest.name
                    plugin.manifestVersion = manifest.version
                    plugin.manifestAuthor = manifest.author
                    plugin.manifestLink = manifest.url
                    plugin.manifestSupportedAreas = manifest.displayAreas
                    plugin.manifestID = newID
                    plugin.manifestContextId = manifest.contextId
                    plugin.manifestAllowedURLPatterns = manifest.allowedURLPatterns
                    pluginStore.updatePlugin(plugin)
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

    private func originHost(for plugin: PluginDefinition) -> String {
        PluginWebOrigin.host(for: plugin)
    }

    private func clearWebDataConfirmationMessage(for plugin: PluginDefinition) -> String {
        if let contextId = plugin.manifestContextId, !contextId.isEmpty {
            return "削除されたデータは復元できません。対象コンテキストID: \(contextId)"
        }
        return "削除されたデータは復元できません。"
    }

    @MainActor
    private func clearWebData(for plugin: PluginDefinition) async {
        guard !isClearingWebData else { return }

        isClearingWebData = true
        let host = originHost(for: plugin)

        do {
            try await PluginWebsiteDataStore.removeAllData(forHost: host)
            appModel.reloadPluginInAllPlayerStates(id: plugin.id.uuidString)
            if let contextId = plugin.manifestContextId, !contextId.isEmpty {
                webDataAlertMessage = "プラグインの Web データを削除しました。対象コンテキストID: \(contextId)"
            } else {
                webDataAlertMessage = "プラグインの Web データを削除しました。"
            }
        } catch {
            webDataAlertMessage = "プラグインの Web データを削除できませんでした。"
        }

        isClearingWebData = false
    }
}

private struct PluginAreaScreen: View {
    @State var appModel: AppModel
    let plugin: PluginDefinition
    @State var playerState: PlayerState
    let displayArea: PluginDisplayArea
    let title: String

    var body: some View {
        GeometryReader { geo in
            PluginOverlayView(
                pluginID: plugin.id.uuidString,
                manifestPluginID: plugin.manifestID,
                htmlContent: plugin.htmlContent,
                appModel: appModel,
                reloadToken: playerState.pluginReloadToken
                    + playerState.perPluginReloadTokens[plugin.id.uuidString, default: 0],
                displayArea: displayArea,
                playerID: playerState.id,
                manifestContextId: plugin.manifestContextId,
                allowedURLPatterns: plugin.manifestAllowedURLPatterns,
                viewSize: geo.size,
                onReloadRequested: {
                    appModel.reloadPluginInAllPlayerStates(id: plugin.id.uuidString)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.kiririnSecondarySystemBackground)
        }
        .navigationTitle(title)
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
