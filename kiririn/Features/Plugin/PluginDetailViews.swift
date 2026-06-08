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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plugin.name)
                            .font(.body)

                        if plugin.isBlocked {
                            blockedBadge
                        }
                    }

                    pluginSubtitle
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
        #if os(macOS)
            .padding(.vertical, 8)
        #endif
        .contentShape(Rectangle())
        #if !os(macOS)
            .onTapGesture {
                onEdit()
            }
        #endif
    }

    @ViewBuilder
    private var pluginSubtitle: some View {
        if let version = plugin.manifestVersion, let author = plugin.manifestAuthor {
            Text("v\(version) / \(author)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if let version = plugin.manifestVersion {
            Text("v\(version)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let author = plugin.manifestAuthor {
            Text(author)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
    let packageAuthentication: PluginPackageAuthentication

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
        packageAuthentication = plugin.packageAuthentication
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
        packageAuthentication = preview.packageAuthentication
    }
}

struct PluginManifestInfoSections: View {
    let info: PluginManifestPresentation

    var body: some View {
        metadataSection
        signatureSection
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
                LabeledContent("更新URL") {
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
    private var signatureSection: some View {
        Section("署名") {
            HStack(alignment: .firstTextBaseline) {
                Text(info.packageAuthentication.state.localizedTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(signatureColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(signatureColor.opacity(0.12), in: Capsule())

                Spacer(minLength: 12)

                if let signatureSummaryText {
                    Text(signatureSummaryText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }

            if !info.packageAuthentication.warnings.isEmpty {
                ForEach(info.packageAuthentication.warnings, id: \.self) { warning in
                    Label {
                        Text(warning)
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(signatureWarningColor)
                }
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
        Section("アクセス許可URL") {
            if !info.requestedHostPermissions.isEmpty {
                ForEach(info.requestedHostPermissions, id: \.self) { pattern in
                    Text(pattern)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("外部URLへのアクセスなし", systemImage: "network.slash")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
    }

    private var signatureColor: Color {
        switch info.packageAuthentication.state {
        case .unsigned:
            return .secondary
        case .verified:
            return .green
        case .selfSigned:
            return .secondary
        case .revoked:
            return .secondary
        }
    }

    private var signatureWarningColor: Color {
        switch info.packageAuthentication.state {
        case .revoked:
            return .red
        default:
            return .orange
        }
    }

    private var signatureSummaryText: String? {
        guard let signer = info.packageAuthentication.signers.first else {
            return nil
        }

        let commonName =
            signerCommonName(from: signer.distinguishedName) ?? signer.distinguishedName
        let fingerprint = abbreviatedFingerprint(signer.publicKeySHA256)
        let extraSignerSuffix: String
        if info.packageAuthentication.signers.count > 1 {
            extraSignerSuffix = " +\(info.packageAuthentication.signers.count - 1)"
        } else {
            extraSignerSuffix = ""
        }
        return "\(commonName) (\(fingerprint))\(extraSignerSuffix)"
    }

    private func signerCommonName(from distinguishedName: String) -> String? {
        distinguishedName
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("CN=") }
            .map { String($0.dropFirst(3)) }
    }

    private func abbreviatedFingerprint(_ fingerprint: String) -> String {
        guard fingerprint.count > 24 else {
            return fingerprint
        }
        return "\(fingerprint.prefix(12))...\(fingerprint.suffix(12))"
    }
}

private struct PluginDetailView: View {
    @State var appModel: AppModel
    @State var pluginStore: PluginStore
    @State var playerState: PlayerState
    let pluginID: UUID

    @State private var showingOverwriteImporter = false
    @State private var showingUpdateCheckSheet = false
    @State private var showingClearWebDataConfirmation = false
    @State private var isClearingWebData = false
    @State private var isCheckingForUpdates = false
    @State private var manifestErrorMessage: String?
    @State private var webDataAlertMessage: String?
    @State private var activeInstallConfirmation: PluginInstallConfirmationRequest?
    @State private var completedUpdateSheet: PluginUpdateCompletionSheetState?
    @State private var pendingUpdateConfirmation: PluginInstallConfirmationRequest?
    @State private var pendingCompletedUpdateSheet: PluginUpdateCompletionSheetState?

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
        .sheet(isPresented: $showingUpdateCheckSheet) {
            PluginUpdateCheckSheet()
                .interactiveDismissDisabled(isCheckingForUpdates)
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
        .sheet(item: $completedUpdateSheet) { state in
            PluginUpdateCompletionSheet(
                state: state,
                onDismiss: {
                    completedUpdateSheet = nil
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
            "プラグイン",
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
        .onChange(of: showingUpdateCheckSheet) { _, isPresented in
            guard !isPresented, let pendingUpdateConfirmation else { return }
            activeInstallConfirmation = pendingUpdateConfirmation
            self.pendingUpdateConfirmation = nil
        }
        .onChange(of: activeInstallConfirmation?.id) { _, requestID in
            guard requestID == nil, let pendingCompletedUpdateSheet else { return }
            completedUpdateSheet = pendingCompletedUpdateSheet
            self.pendingCompletedUpdateSheet = nil
        }
    }

    private func enabledSection(for plugin: PluginDefinition) -> some View {
        Section {
            Toggle("有効", isOn: enabledBinding(for: plugin))

            if plugin.isBlocked {
                Label(
                    "内容確認が必要なためブロックしています。再有効化するには内容の確認が必要です",
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
            if plugin.canCheckForUpdates {
                Button {
                    Task {
                        await checkForUpdates()
                    }
                } label: {
                    Label("アップデートを確認する", systemImage: "arrow.clockwise.circle")
                }
                .buttonStyle(.plain)
                .disabled(isCheckingForUpdates)
            }

            if plugin.sourceType != .localFolder {
                Button {
                    #if os(macOS)
                        overwriteFromOpenPanel()
                    #else
                        showingOverwriteImporter = true
                    #endif
                } label: {
                    Label("kppxファイルから上書き", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.plain)
            }

            #if os(macOS)
                if plugin.sourceType == .localFolder, pluginStore.isDeveloperModeEnabled {
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
                do {
                    try pluginStore.setEnabled(newValue, for: currentPlugin.id)
                } catch {
                    manifestErrorMessage = error.localizedDescription
                }
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
            case .update(let pluginID, _):
                guard let previous = pluginStore.plugin(id: pluginID) else {
                    throw PluginManifestValidationError(messages: ["プラグインが見つかりません"])
                }
                _ = try pluginStore.overwritePlugin(previous, with: request.preview)
                pendingCompletedUpdateSheet = PluginUpdateCompletionSheetState(
                    pluginName: request.preview.manifest.displayName,
                    version: request.preview.manifest.version,
                    updateInfoURL: request.preview.updateInfoURL
                )
                Task { @MainActor in
                    await PluginWebsiteDataStore.unregisterServiceWorkers(for: previous)
                    appModel.reloadPluginInAllPlayerStates(id: pluginID.uuidString)
                }
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
                let preview = try pluginStore.previewPlugin(
                    packageURL: url, sourceType: .kppx)
                activeInstallConfirmation = try PluginInstallConfirmationRequest(
                    preview: preview,
                    routing: pluginStore.updateRouting(replacing: plugin, with: preview)
                )
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
        "プラグインのパネル/オーバーレイ/設定に紐づくストレージを消去します。消去後は再読み込みされます"
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
                webDataAlertMessage = "消去対象のストレージは見つかりませんでした"
                isClearingWebData = false
                return
            }

            appModel.reloadPluginInAllPlayerStates(id: plugin.id.uuidString)
            webDataAlertMessage = "プラグインのストレージを消去しました"
        } catch {
            webDataAlertMessage = "プラグインのストレージを消去できませんでした"
        }

        isClearingWebData = false
    }

    @MainActor
    private func checkForUpdates() async {
        guard !isCheckingForUpdates, let plugin = pluginStore.plugin(id: pluginID) else {
            return
        }
        let trimmedURL = (plugin.manifestUpdateURL ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let url = URL(string: trimmedURL), !trimmedURL.isEmpty else {
            manifestErrorMessage = "有効な更新URLが設定されていません"
            return
        }

        isCheckingForUpdates = true
        showingUpdateCheckSheet = true
        pendingUpdateConfirmation = nil
        defer { isCheckingForUpdates = false }

        do {
            let preview = try await pluginStore.previewPlugin(
                fromUpdateManifestURL: url,
                previous: plugin
            )
            pendingUpdateConfirmation = try PluginInstallConfirmationRequest(
                preview: preview,
                routing: pluginStore.updateRouting(replacing: plugin, with: preview)
            )
            showingUpdateCheckSheet = false
        } catch let error as PluginManifestValidationError {
            showingUpdateCheckSheet = false
            manifestErrorMessage = error.errorDescription
        } catch {
            showingUpdateCheckSheet = false
            manifestErrorMessage = error.localizedDescription
        }
    }
}

private struct PluginOptionsScreen: View {
    @State var appModel: AppModel
    let plugin: PluginDefinition
    @State var playerState: PlayerState

    var body: some View {
        GeometryReader { geometry in
            PluginOverlayView(
                pluginDefinition: plugin,
                appModel: appModel,
                reloadToken: playerState.pluginReloadToken
                    + playerState.perPluginReloadTokens[plugin.id.uuidString, default: 0],
                displayArea: .options,
                safeAreaInsets: PluginSafeAreaInsets(
                    top: geometry.safeAreaInsets.top,
                    right: geometry.safeAreaInsets.trailing,
                    bottom: geometry.safeAreaInsets.bottom,
                    left: geometry.safeAreaInsets.leading
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.kiririnSecondarySystemBackground)
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("\(plugin.name) 設定")
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct PluginUpdateCheckSheet: View {

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)

                Text("更新を確認中")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .navigationTitle("アップデートを確認中")
        }
        #if os(macOS)
            .frame(minWidth: 360, minHeight: 180)
        #endif
    }
}

private struct PluginUpdateCompletionSheetState: Identifiable {
    let id = UUID()
    let pluginName: String
    let version: String?
    let updateInfoURL: URL?
}

private struct PluginUpdateCompletionSheet: View {
    @Environment(\.openURL) private var openURL

    let state: PluginUpdateCompletionSheetState
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.pluginName)
                            .font(.headline)

                        if let version = state.version {
                            Text("バージョン\(version)へのアップデートが完了しました")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("アップデートが完了しました")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let updateInfoURL = state.updateInfoURL {
                    Section {
                        Button {
                            openURL(updateInfoURL)
                        } label: {
                            Label("更新情報を開く", systemImage: "safari")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("アップデート完了")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
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
