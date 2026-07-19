import Combine
import KppxKit
import SwiftUI
import WebKit

extension PluginDisplayArea {
    var localizedName: String {
        switch self {
        case .overlay: return "オーバーレイ"
        case .options: return "プラグイン設定"
        case .panel: return "パネル"
        }
    }
}

struct PluginSafeAreaInsets: Sendable, Equatable {
    let top: CGFloat
    let right: CGFloat
    let bottom: CGFloat
    let left: CGFloat

    static let zero = PluginSafeAreaInsets(top: 0, right: 0, bottom: 0, left: 0)

    var asDictionary: [String: Double] {
        [
            "top": Double(top),
            "right": Double(right),
            "bottom": Double(bottom),
            "left": Double(left),
        ]
    }
}

struct PluginOverlayView: View {
    private struct RuntimeLoadKey: Hashable {
        let pluginID: UUID
        let reloadKey: PluginReloadKey
        let resourceBasePath: String
    }

    private struct LoadedRuntime {
        let runtime: ExtensionPluginRuntime
        let webViewConfiguration: WKWebViewConfiguration
    }

    let pluginDefinition: PluginDefinition
    let appModel: AppModel
    let reloadToken: Int
    let displayArea: PluginDisplayArea
    let playerID: String?
    let safeAreaInsets: PluginSafeAreaInsets

    init(
        pluginDefinition: PluginDefinition,
        appModel: AppModel,
        reloadToken: Int,
        displayArea: PluginDisplayArea,
        playerID: String? = nil,
        safeAreaInsets: PluginSafeAreaInsets = .zero
    ) {
        self.pluginDefinition = pluginDefinition
        self.appModel = appModel
        self.reloadToken = reloadToken
        self.displayArea = displayArea
        self.playerID = playerID
        self.safeAreaInsets = safeAreaInsets
    }

    @State private var isCrashed = false
    @State private var lastError: String?
    @State private var isDetailsExpanded = false
    @State private var pendingDeeplinkURL: URL?
    @State private var deeplinkToken = 0
    @State private var manualReloadToken = 0
    @State private var loadedRuntime: LoadedRuntime?

    private var reloadKey: PluginReloadKey {
        PluginReloadKey(external: reloadToken, manual: manualReloadToken)
    }

    private var runtimeLoadKey: RuntimeLoadKey {
        RuntimeLoadKey(
            pluginID: pluginDefinition.id,
            reloadKey: reloadKey,
            resourceBasePath: pluginDefinition.resourceBasePath
        )
    }

    var body: some View {
        // アクティブな全プレイヤーの状態を追跡するハッシュを生成し、これを元に再描画と同期をトリガーさせる。
        // 再生位置(time)は頻繁すぎるため除外するが、番組変更や再生/停止、シーク可否の変化は網羅する。
        let stateHash =
            appModel.activePlayerStates.map {
                "\($0.id):\($0.currentPlayable?.id ?? "none"):\($0.playbackStatus.isPlaying):\($0.currentPlayable?.isSeekable ?? false)"
            }.joined(separator: "|") + (appModel.focusedPlayerID ?? "")
        ZStack {
            if let loadedRuntime {
                PluginWebView(
                    pluginDefinition: pluginDefinition,
                    extensionRuntime: loadedRuntime.runtime,
                    webViewConfiguration: loadedRuntime.webViewConfiguration,
                    appModel: appModel,
                    reloadKey: reloadKey,
                    displayArea: displayArea,
                    playerID: playerID,
                    safeAreaInsets: safeAreaInsets,
                    deeplinkURL: pendingDeeplinkURL,
                    deeplinkToken: deeplinkToken,
                    stateHash: stateHash,
                    onCrash: handleWebContentProcessCrash
                )
                .allowsHitTesting(!isCrashed)
            } else if displayArea != .overlay {
                ProgressView()
            }

            if isCrashed {
                crashView
            }
        }
        .onChange(of: reloadToken) {
            handleExternalReload()
        }
        .onDisappear {
            releaseExtensionRuntime()
        }
        .onAppear {
            consumeQueuedDeeplinkIfNeeded()
        }
        .task(id: runtimeLoadKey) {
            await loadExtensionRuntime()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pluginDeeplinkOpened)) {
            notification in
            let manifestPluginID = pluginDefinition.manifestID
            guard let userInfo = notification.userInfo,
                let targetManifestID = userInfo["manifestID"] as? String,
                targetManifestID == manifestPluginID,
                let urlString = userInfo["deeplinkURL"] as? String,
                let url = URL(string: urlString)
            else {
                return
            }
            queueDeeplinkEvent(url)
        }
    }

    private func consumeQueuedDeeplinkIfNeeded() {
        let manifestPluginID = pluginDefinition.manifestID
        let queuedURLs = appModel.consumePendingPluginDeeplinks(manifestID: manifestPluginID)
        guard !queuedURLs.isEmpty else { return }
        for queuedURL in queuedURLs {
            queueDeeplinkEvent(queuedURL)
        }
    }

    private func queueDeeplinkEvent(_ url: URL) {
        pendingDeeplinkURL = url
        deeplinkToken += 1
    }

    @MainActor
    private func loadExtensionRuntime() async {
        let expectedLoadKey = runtimeLoadKey

        do {
            let runtime = try await ExtensionPluginRuntimeRegistry.shared.acquireRuntime(
                for: pluginDefinition,
                store: appModel.pluginStore
            )
            let webViewConfiguration: WKWebViewConfiguration
            do {
                webViewConfiguration = try runtime.makeWebViewConfiguration()
            } catch {
                ExtensionPluginRuntimeRegistry.shared.releaseRuntime(runtime)
                throw error
            }
            guard !Task.isCancelled, runtimeLoadKey == expectedLoadKey else {
                ExtensionPluginRuntimeRegistry.shared.releaseRuntime(runtime)
                return
            }
            replaceLoadedRuntime(
                with: LoadedRuntime(
                    runtime: runtime,
                    webViewConfiguration: webViewConfiguration
                )
            )
        } catch {
            guard !Task.isCancelled, runtimeLoadKey == expectedLoadKey else {
                return
            }
            releaseExtensionRuntime()
            lastError = error.localizedDescription
            if displayArea != .overlay {
                isCrashed = true
            }
        }
    }

    @MainActor
    private func releaseExtensionRuntime() {
        guard let loadedRuntime else { return }
        self.loadedRuntime = nil
        ExtensionPluginRuntimeRegistry.shared.releaseRuntime(loadedRuntime.runtime)
    }

    @MainActor
    private func replaceLoadedRuntime(with newRuntime: LoadedRuntime) {
        if loadedRuntime?.runtime === newRuntime.runtime {
            // 同じ View が追加取得した分だけを解放し、既存の利用権は維持する。
            ExtensionPluginRuntimeRegistry.shared.releaseRuntime(newRuntime.runtime)
            return
        }

        let previousRuntime = loadedRuntime
        loadedRuntime = newRuntime
        if let previousRuntime {
            ExtensionPluginRuntimeRegistry.shared.releaseRuntime(previousRuntime.runtime)
        }
    }

    @MainActor
    private func handleExternalReload() {
        resetCrashState()
        releaseExtensionRuntime()
    }

    @MainActor
    private func reloadAfterCrash() {
        resetCrashState()
        releaseExtensionRuntime()
        manualReloadToken += 1
    }

    private func handleWebContentProcessCrash() {
        isDetailsExpanded = false
        isCrashed = true
    }

    private func resetCrashState() {
        isCrashed = false
        lastError = nil
        isDetailsExpanded = false
    }

    @ViewBuilder
    private var crashView: some View {
        if displayArea == .overlay {
            // オーバーレイの場合はエラーを表示しない
            Color.clear
        } else {
            ZStack {
                Color.black.opacity(0.24)

                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    VStack(spacing: 4) {
                        Text("プラグインがクラッシュしました")
                            .font(.headline)
                        Text("レンダープロセスが停止したか、予期しないエラーが発生しました")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let lastError {
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                withAnimation {
                                    isDetailsExpanded.toggle()
                                }
                            } label: {
                                HStack {
                                    Text("スタックトレースを表示")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .rotationEffect(.degrees(isDetailsExpanded ? 90 : 0))
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)

                            if isDetailsExpanded {
                                ScrollView {
                                    Text(lastError)
                                        .font(.system(.caption, design: .monospaced))
                                        .multilineTextAlignment(.leading)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.black.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .frame(maxHeight: 200)
                            }
                        }
                        .padding(.horizontal)
                        .frame(maxWidth: 400)
                    }

                    Button("再読み込み", action: reloadAfterCrash)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: 440)
                .background(
                    .regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                }
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
