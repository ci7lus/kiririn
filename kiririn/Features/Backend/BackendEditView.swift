import SwiftUI

struct BackendEditView: View {
    let configStore: BackendConfigStore
    let manager: BackendManager
    var existingConfig: BackendConfiguration?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var type: BackendType = .mirakurun
    @State private var baseURL: String = ""
    @State private var auth: BackendAuth = .none
    @State private var liveEnabled: Bool = true
    @State private var recordingEnabled: Bool = true
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSuccess = false
    @State private var isRefreshingPrograms = false
    @State private var programRefreshResult: ManualProgramCatalogRefreshResult?

    private var isEditing: Bool { existingConfig != nil }
    private var manualProgramRefreshBackendID: String? {
        guard let existingConfig, type.supportsLive, liveEnabled else { return nil }
        return existingConfig.id
    }
    private var hasUnsavedChanges: Bool {
        guard let existingConfig else { return false }
        return buildConfig() != existingConfig
    }
    private var isManualProgramRefreshDisabled: Bool {
        guard let backendId = manualProgramRefreshBackendID else { return true }
        return isTesting || isRefreshingPrograms || hasUnsavedChanges
            || !configStore.isEnabled(backendId)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本設定") {
                    TextField("名前", text: $name)
                        .textContentType(.name)
                    Picker("タイプ", selection: $type) {
                        ForEach(BackendType.allCases, id: \.self) { type in
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
                        Task { await testConnection() }
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

                    if let testResult {
                        HStack(spacing: 6) {
                            Image(
                                systemName: testSuccess
                                    ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .foregroundStyle(testSuccess ? .green : .red)
                            Text(testResult)
                                .font(.caption)
                                .foregroundStyle(testSuccess ? Color.primary : Color.red)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                    }

                    if manualProgramRefreshBackendID != nil {
                        Button {
                            Task { await refreshPrograms() }
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
                        } else if let programRefreshResult {
                            let feedback = programRefreshFeedback(for: programRefreshResult)
                            HStack(spacing: 6) {
                                Image(systemName: feedback.iconName)
                                    .foregroundStyle(feedback.color)
                                Text(feedback.message)
                                    .font(.caption)
                                    .foregroundStyle(
                                        feedback.color == .green ? Color.primary : feedback.color)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 4)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "バックエンド編集" : "バックエンド追加")
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
                }
                syncFeatureTogglesForType()
            }
            .onChange(of: type) { _, _ in
                enableSupportedFeaturesForCurrentType()
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
            BackendAuthEditor(auth: $auth)
        case .googledrive:
            GoogleDriveAuthEditor(auth: $auth, name: $name)
        }
    }

    private func buildConfig() -> BackendConfiguration {
        BackendConfiguration(
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
        if !type.supportsLive {
            liveEnabled = false
        }
        if !type.supportsRecording {
            recordingEnabled = false
        }
    }

    private func enableSupportedFeaturesForCurrentType() {
        liveEnabled = type.supportsLive
        recordingEnabled = type.supportsRecording
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        let config = buildConfig()
        let provider: any BackendProvider = {
            switch config.type {
            case .mirakurun: return MirakurunProvider(configuration: config)
            case .epgstation: return EPGStationProvider(configuration: config)
            case .googledrive: return GoogleDriveProvider(configuration: config)
            case .konomitv: return KonomiTVProvider(configuration: config)
            }
        }()

        do {
            let version = try await provider.checkConnection()
            testSuccess = true
            if let version, !version.isEmpty {
                testResult = version
            } else {
                testResult = "接続成功"
            }
        } catch {
            testSuccess = false
            testResult = error.localizedDescription
        }
        isTesting = false
    }

    private func refreshPrograms() async {
        guard let backendId = manualProgramRefreshBackendID else { return }

        isRefreshingPrograms = true
        programRefreshResult = nil
        programRefreshResult = await manager.refreshProgramsManually(backendId: backendId)
        isRefreshingPrograms = false
    }

    private func programRefreshFeedback(
        for result: ManualProgramCatalogRefreshResult
    ) -> (iconName: String, color: Color, message: String) {
        switch result {
        case .refreshed:
            return ("checkmark.circle.fill", .green, "番組情報を再取得しました")
        case .queuedUntilWiFi:
            return ("wifi.slash", .orange, "WiFi 接続時に番組情報を再取得します")
        case .unavailable:
            return ("xmark.circle.fill", .red, "このバックエンドでは番組情報を再取得できません")
        case .failed(let message):
            return ("xmark.circle.fill", .red, message)
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
                await manager.connect(backendId: config.id, programRefreshPolicy: .automaticIfDue)
            }
        } else {
            manager.connectionStates[config.id]?.status = .disconnected
            manager.connectionStates[config.id]?.lastError = nil
        }
        manager.backendAvailabilityDidChange()
        dismiss()
    }
}

private enum BackendAuthMethod: String, CaseIterable, Identifiable {
    case none
    case basic
    case bearer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "なし"
        case .basic: return "Basic"
        case .bearer: return "Bearer"
        }
    }
}

private struct BackendAuthEditor: View {
    @Binding var auth: BackendAuth
    @State private var method: BackendAuthMethod = .none
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var token: String = ""

    var body: some View {
        Section("認証") {
            Picker("方式", selection: $method) {
                ForEach(BackendAuthMethod.allCases) { method in
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
