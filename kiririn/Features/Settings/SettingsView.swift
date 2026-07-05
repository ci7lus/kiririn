import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

private enum CacheDeletionAlert: Identifiable {
    case firstConfirmation
    case finalConfirmation
    case result(String)

    var id: String {
        switch self {
        case .firstConfirmation:
            "firstConfirmation"
        case .finalConfirmation:
            "finalConfirmation"
        case .result(let message):
            "result-\(message)"
        }
    }
}

private struct CacheRecoverySectionContent: View {
    let isDeletingCache: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.yellow)

                Text("キャッシュの破損を検知しました")
                    .font(.headline)
            }

            Text(
                "キャッシュの一部データの読み込みに失敗しています。キャッシュを削除しますか？\n削除すると、再生位置履歴・キャプチャ履歴（元ファイル除く）などが削除されます。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive, action: onDelete) {
                Label(
                    isDeletingCache ? "キャッシュを削除中" : "キャッシュを削除",
                    systemImage: "trash"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDeletingCache)
        }
        .padding(.vertical, 6)
    }
}

struct SettingsView: View {
    let configStore: ServerConfigStore
    let manager: ServerManager
    let appModel: AppModel
    @State var pluginStore: PluginStore
    @State var playerState: PlayerState
    @ObservedObject private var captureService = CaptureService.shared
    @State private var isFolderPickerPresented = false
    @State private var cacheDeletionAlert: CacheDeletionAlert?
    @State private var isDeletingCache = false
    @Environment(\.isTabActive) private var isTabActive
    private let buildInfo = AppBuildInfo.current

    private var shouldShowCacheRecoverySection: Bool {
        appModel.cacheStore?.databaseFailureFeedback != nil
    }

    private var displayedAppVersionDescription: String {
        #if os(macOS)
            buildInfo.appVersionWithGitCommitHashDescription
        #else
            buildInfo.appVersionDescription
        #endif
    }

    var body: some View {
        Form {
            if shouldShowCacheRecoverySection {
                Section {
                    CacheRecoverySectionContent(
                        isDeletingCache: isDeletingCache,
                        onDelete: {
                            cacheDeletionAlert = .firstConfirmation
                        }
                    )
                }
            }

            Section {
                NavigationLink {
                    ServerSettingsView(
                        configStore: configStore,
                        manager: manager
                    )
                } label: {
                    Label("サーバー設定", systemImage: "server.rack")
                }

                NavigationLink {
                    PluginsSettingsView(
                        appModel: appModel, pluginStore: pluginStore, playerState: playerState)
                } label: {
                    Label("プラグイン設定", systemImage: "puzzlepiece.extension")
                }

                NavigationLink {
                    CaptureSettingsView(appModel: appModel)
                } label: {
                    Label("キャプチャ設定", systemImage: "photo.on.rectangle.angled")
                }

                NavigationLink {
                    AboutAppView()
                } label: {
                    Label("このアプリについて", systemImage: "info.circle")
                }
            } footer: {
                Text(displayedAppVersionDescription)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }

            #if DEBUG
                Section {
                    Button {
                        triggerCacheFailureQuery()
                    } label: {
                        Label("失敗クエリを発行", systemImage: "exclamationmark.triangle")
                    }
                    .disabled(appModel.cacheStore == nil)
                }
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle(isTabActive ? "設定" : "")
        .alert(item: $cacheDeletionAlert) { alert in
            cacheDeletionAlertContent(alert)
        }
        .fileImporter(
            isPresented: $isFolderPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    do {
                        try captureService.setCaptureFolder(url)
                    } catch {
                        print("Failed to set folder: \(error)")
                    }
                }
            case .failure(let error):
                print("Folder selection failed: \(error)")
            }
        }
    }

    private func cacheDeletionAlertContent(_ alert: CacheDeletionAlert) -> Alert {
        switch alert {
        case .firstConfirmation:
            Alert(
                title: Text("キャッシュを削除しますか？"),
                message: Text("削除するとキャッシュデータが失われます。この操作は取り消せません。"),
                primaryButton: .destructive(Text("削除")) {
                    cacheDeletionAlert = nil
                    DispatchQueue.main.async {
                        cacheDeletionAlert = .finalConfirmation
                    }
                },
                secondaryButton: .cancel(Text("キャンセル"))
            )
        case .finalConfirmation:
            Alert(
                title: Text("本当にキャッシュを削除しますか？"),
                message: Text("削除後はキャッシュを再作成します。必要なデータは再取得されます。"),
                primaryButton: .destructive(Text("完全に削除")) {
                    deleteCacheDatabase()
                },
                secondaryButton: .cancel(Text("キャンセル"))
            )
        case .result(let message):
            Alert(
                title: Text("キャッシュの削除"),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func deleteCacheDatabase() {
        guard !isDeletingCache else { return }
        isDeletingCache = true
        Task { @MainActor in
            do {
                let didDeleteFile = try await appModel.deleteCacheDatabase()
                cacheDeletionAlert = .result(
                    didDeleteFile
                        ? "キャッシュを削除しました。"
                        : "キャッシュは見つかりませんでした。"
                )
            } catch {
                cacheDeletionAlert = .result("キャッシュを削除できませんでした。")
            }
            isDeletingCache = false
        }
    }

    #if DEBUG
        private func triggerCacheFailureQuery() {
            Task {
                await appModel.cacheStore?.triggerDatabaseFailureFeedbackForDebug()
            }
        }
    #endif
}
