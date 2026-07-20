import SwiftUI

struct ServerEditView: View {
    private enum ScrollTarget {
        static let lastConnectionError = "lastConnectionError"
    }

    let configStore: ServerConfigStore
    let manager: ServerManager
    var existingConfig: ServerConfiguration?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var type: ServerType = .mirakurun
    @State private var baseURL: String = ""
    @State private var auth: ServerAuth = .none
    @State private var liveEnabled: Bool = true
    @State private var recordingEnabled: Bool = true
    @State private var isTesting = false
    @State private var connectionTestSuccessMessage: String?
    @State private var isRefreshingPrograms = false
    @State private var transientErrorDetail: ServerOperationFeedbackContent?

    private var isEditing: Bool { existingConfig != nil }
    private var displayedErrorDetail: ServerOperationFeedbackContent? {
        guard let existingConfig else { return transientErrorDetail }
        return manager.connectionStates[existingConfig.id]?.lastErrorDetail ?? transientErrorDetail
    }
    private var manualProgramRefreshServerID: String? {
        guard let existingConfig, type.supportsLive, liveEnabled else { return nil }
        return existingConfig.id
    }
    private var hasUnsavedChanges: Bool {
        guard let existingConfig else { return false }
        return buildConfig() != existingConfig
    }
    private var isManualProgramRefreshDisabled: Bool {
        guard let serverId = manualProgramRefreshServerID else { return true }
        return isTesting || isRefreshingPrograms || hasUnsavedChanges
            || !configStore.isEnabled(serverId)
    }
    private var typeSelection: Binding<ServerType> {
        Binding {
            type
        } set: { newType in
            type = newType
            syncFeatureTogglesForType()
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    if let displayedErrorDetail {
                        Section("前回の接続エラー") {
                            ServerOperationFeedbackView(
                                iconName: "xmark.circle.fill",
                                color: .red,
                                usesPrimaryText: false,
                                content: displayedErrorDetail
                            )
                        }
                        .id(ScrollTarget.lastConnectionError)
                    }

                    Section("基本設定") {
                        TextField("名前", text: $name)
                            .textContentType(.name)
                        Picker("タイプ", selection: typeSelection) {
                            ForEach(ServerType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        if type.requiresBaseURL {
                            TextField("ベースURL", text: $baseURL)
                                .textContentType(.URL)
                                .autocorrectionDisabled()
                                .kiririnURLInputModifiers()
                        }
                    }

                    authSection

                    Section("機能") {
                        Toggle("放送", isOn: $liveEnabled)
                            .disabled(!type.supportsLive)
                        Toggle("録画", isOn: $recordingEnabled)
                            .disabled(!type.supportsRecording)
                    }

                    Section {
                        Button {
                            Task { await testConnection(scrollProxy: proxy) }
                        } label: {
                            HStack {
                                if isTesting {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text("接続テスト")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled((type.requiresBaseURL && baseURL.isEmpty) || isTesting)

                        if let connectionTestSuccessMessage {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(connectionTestSuccessMessage)
                                    .font(.caption)
                                    .foregroundStyle(Color.primary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }

                        if manualProgramRefreshServerID != nil {
                            Button {
                                Task { await refreshPrograms(scrollProxy: proxy) }
                            } label: {
                                HStack {
                                    if isRefreshingPrograms {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                    Text("番組情報再取得")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isManualProgramRefreshDisabled)

                            if hasUnsavedChanges {
                                Text("番組情報の再取得は、変更を保存してから実行してください")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.top, 4)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .navigationTitle(isEditing ? "サーバー編集" : "サーバー追加")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if #available(iOS 26, macOS 26, *) {
                        Button(role: .cancel) {
                            dismiss()
                        }
                    } else {
                        Button("キャンセル", role: .cancel) {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if #available(iOS 26, macOS 26, *) {
                        Button(role: .confirm) {
                            save()
                        }
                        .disabled(name.isEmpty || (type.requiresBaseURL && baseURL.isEmpty))
                    } else {
                        Button("保存") {
                            save()
                        }
                        .disabled(name.isEmpty || (type.requiresBaseURL && baseURL.isEmpty))
                    }

                }
            }
            .onAppear {
                if let config = existingConfig {
                    name = config.name
                    type = config.type
                    baseURL = config.baseURL ?? ""
                    auth = config.auth
                    liveEnabled = config.liveEnabled
                    recordingEnabled = config.recordingEnabled
                } else {
                    syncFeatureTogglesForType()
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 480, minHeight: 520)
        #endif
    }

    @ViewBuilder
    private var authSection: some View {
        switch type {
        case .mirakurun, .epgstation, .konomitv:
            ServerAuthEditor(auth: $auth)
        case .googledrive:
            GoogleDriveAuthEditor(auth: $auth, name: $name)
        }
    }

    private func buildConfig() -> ServerConfiguration {
        ServerConfiguration(
            id: existingConfig?.id ?? UUID().uuidString,
            name: name,
            type: type,
            baseURL: type.requiresBaseURL ? baseURL : nil,
            auth: auth,
            liveEnabled: liveEnabled,
            recordingEnabled: recordingEnabled
        )
    }

    private func syncFeatureTogglesForType() {
        liveEnabled = type.supportsLive
        recordingEnabled = type.supportsRecording
    }

    private func testConnection(scrollProxy: ScrollViewProxy) async {
        isTesting = true
        connectionTestSuccessMessage = nil
        let config = buildConfig()
        let provider: any ServerProvider = {
            switch config.type {
            case .mirakurun: return MirakurunProvider(configuration: config)
            case .epgstation: return EPGStationProvider(configuration: config)
            case .googledrive: return GoogleDriveProvider(configuration: config)
            case .konomitv: return KonomiTVProvider(configuration: config)
            }
        }()

        do {
            let version = try await provider.checkConnection()
            connectionTestSuccessMessage = connectionSuccessMessage(version: version)
            clearConnectionError(for: config)
        } catch {
            connectionTestSuccessMessage = nil
            recordConnectionError(error, for: config)
        }
        isTesting = false
        await scrollToLastConnectionErrorIfNeeded(using: scrollProxy)
    }

    private func refreshPrograms(scrollProxy: ScrollViewProxy) async {
        guard let serverId = manualProgramRefreshServerID else { return }

        isRefreshingPrograms = true
        _ = await manager.refreshProgramsManually(serverId: serverId)
        isRefreshingPrograms = false
        await scrollToLastConnectionErrorIfNeeded(using: scrollProxy)
    }

    private func clearConnectionError(for config: ServerConfiguration) {
        transientErrorDetail = nil
        if let state = manager.connectionStates[config.id] {
            state.lastError = nil
            state.lastErrorDetail = nil
            if state.status == .error {
                state.status = .disconnected
            }
        }
    }

    private func connectionSuccessMessage(version: String?) -> String {
        guard let version, !version.isEmpty else { return "接続成功" }
        return version
    }

    private func recordConnectionError(_ error: Error, for config: ServerConfiguration) {
        let feedback = errorFeedback(for: error)
        transientErrorDetail = feedback.detail
        if let state = manager.connectionStates[config.id] {
            state.status = .error
            state.lastError = feedback.brief
            state.lastErrorDetail = feedback.detail
            state.version = nil
        }
    }

    private func errorFeedback(for error: Error) -> (
        brief: String, detail: ServerOperationFeedbackContent
    ) {
        if let apiError = error as? APIError {
            return (apiError.briefDescription, apiError.feedbackContent)
        }
        return (
            error.localizedDescription,
            ServerOperationFeedbackContent(title: error.localizedDescription)
        )
    }

    private func scrollToLastConnectionErrorIfNeeded(using proxy: ScrollViewProxy) async {
        guard displayedErrorDetail != nil else { return }
        await Task.yield()
        withAnimation {
            proxy.scrollTo(ScrollTarget.lastConnectionError, anchor: .top)
        }
    }

    private func save() {
        let config = buildConfig()
        if isEditing {
            configStore.updateConfiguration(config)
        } else {
            configStore.addConfiguration(config)
        }
        manager.setupProviders()
        if configStore.isEnabled(config.id) {
            Task {
                await manager.connect(serverId: config.id, programRefreshPolicy: .automaticIfDue)
            }
        } else {
            manager.connectionStates[config.id]?.status = .disconnected
            manager.connectionStates[config.id]?.lastError = nil
            manager.connectionStates[config.id]?.lastErrorDetail = nil
        }
        manager.serverAvailabilityDidChange()
        dismiss()
    }
}

private struct ServerOperationFeedbackView: View {
    let iconName: String
    let color: Color
    let usesPrimaryText: Bool
    let content: ServerOperationFeedbackContent

    private var detailLeadingPadding: CGFloat { 28 }
    private var responseDisplayLimit: Int { 2_000 }
    private var responseScrollThreshold: Int { 600 }
    private var responseMaxHeight: CGFloat { 160 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: iconName)
                    .foregroundStyle(color)
                    .frame(width: 22, alignment: .center)
                Text(content.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(usesPrimaryText ? Color.primary : color)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }

            if let message = content.message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(usesPrimaryText ? Color.primary : color)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(.leading, detailLeadingPadding)
            }

            if !content.fields.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(content.fields.enumerated()), id: \.offset) { _, field in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(field.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            fieldValueText(field)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, detailLeadingPadding)
            }

            if let response = content.response, !response.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("レスポンス")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    responseCodeBlock(response)
                }
                .padding(.leading, detailLeadingPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func fieldValueText(_ field: ServerOperationFeedbackContent.Field) -> some View {
        Text(field.value)
            .font(field.label == "URL" ? .caption.monospaced() : .caption)
            .foregroundStyle(Color.primary)
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func responseCodeBlock(_ response: String) -> some View {
        let displayedResponse = displayedResponse(response)
        let needsScroll = response.count > responseScrollThreshold

        Group {
            if needsScroll {
                ScrollView(.vertical) {
                    responseCodeText(displayedResponse)
                }
                .frame(maxHeight: responseMaxHeight)
            } else {
                responseCodeText(displayedResponse)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
    }

    private func responseCodeText(_ response: String) -> some View {
        Text(response)
            .font(.caption2.monospaced())
            .foregroundStyle(Color.primary)
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private func displayedResponse(_ response: String) -> String {
        guard response.count > responseDisplayLimit else { return response }
        return String(response.prefix(responseDisplayLimit)) + "\n…（表示上限に達したため省略しました）"
    }
}

private enum ServerAuthMethod: String, CaseIterable, Identifiable {
    case none
    case basic
    case bearer
    case cookie

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "なし"
        case .basic: return "Basic"
        case .bearer: return "Bearer"
        case .cookie: return "Cookie"
        }
    }
}

private struct ServerAuthEditor: View {
    @Binding var auth: ServerAuth
    @State private var method: ServerAuthMethod = .none
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var token: String = ""
    @State private var cookie: String = ""

    var body: some View {
        Section("認証") {
            Picker("方式", selection: $method) {
                ForEach(ServerAuthMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .onChange(of: method) { _, _ in
                updateAuth()
            }

            if method == .basic {
                TextField("ユーザー名", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .kiririnPlainTextInputModifiers()
                    .onChange(of: username) { _, _ in updateAuth() }
                SecureField("パスワード", text: $password)
                    .textContentType(.password)
                    .onChange(of: password) { _, _ in updateAuth() }
            }

            if method == .bearer {
                SecureField("アクセストークン", text: $token)
                    .textContentType(.password)
                    .onChange(of: token) { _, _ in updateAuth() }
            }

            if method == .cookie {
                TextField("Cookie", text: $cookie)
                    .autocorrectionDisabled()
                    .kiririnPlainTextInputModifiers()
                    .onChange(of: cookie) { _, _ in updateAuth() }
            }
        }
        .onAppear {
            switch auth {
            case .basic(let u, let p):
                method = .basic
                username = u
                password = p
            case .bearer(let token):
                method = .bearer
                self.token = token
            case .cookie(let cookie):
                method = .cookie
                self.cookie = cookie
            default:
                method = .none
            }
        }
    }

    private func updateAuth() {
        switch method {
        case .none:
            auth = .none
        case .basic:
            if username.isEmpty && password.isEmpty {
                auth = .none
            } else {
                auth = .basic(username: username, password: password)
            }
        case .bearer:
            if token.isEmpty {
                auth = .none
            } else {
                auth = .bearer(token: token)
            }
        case .cookie:
            if cookie.isEmpty {
                auth = .none
            } else {
                auth = .cookie(cookie: cookie)
            }
        }
    }
}

extension View {
    @ViewBuilder
    fileprivate func kiririnURLInputModifiers() -> some View {
        #if os(iOS)
            self
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
        #else
            self
        #endif
    }

    @ViewBuilder
    fileprivate func kiririnPlainTextInputModifiers() -> some View {
        #if os(iOS)
            self.textInputAutocapitalization(.never)
        #else
            self
        #endif
    }
}
