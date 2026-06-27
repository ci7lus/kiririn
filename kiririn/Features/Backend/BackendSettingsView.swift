import SwiftUI

struct BackendSettingsView: View {
    let configStore: BackendConfigStore
    let manager: BackendManager
    @State private var showingAddSheet = false
    @State private var editingConfig: BackendConfiguration?
    @State private var selectedBackendID: String?
    @State private var showingDeleteConfirmation = false
    @State private var backendIDsToDelete: [String] = []
    @Environment(\.isTabActive) private var isTabActive

    var body: some View {
        listView
            .navigationTitle("バックエンド")
            .toolbar {
                toolbarContent
            }
            .alert(
                "バックエンドを削除しますか？",
                isPresented: $showingDeleteConfirmation
            ) {
                deleteConfirmationButtons
            } message: {
                Text("この操作は取り消せません。")
            }
            .sheet(isPresented: $showingAddSheet) {
                BackendEditView(configStore: configStore, manager: manager)
            }
            .sheet(item: $editingConfig) { config in
                BackendEditView(configStore: configStore, manager: manager, existingConfig: config)
            }
            .onChange(of: configStore.configurations.map(\.id)) { _, ids in
                guard let selectedBackendID, !ids.contains(selectedBackendID) else { return }
                self.selectedBackendID = nil
            }
    }

    @ViewBuilder
    private var listView: some View {
        #if os(macOS)
            macosList
        #else
            iosList
        #endif
    }

    @ViewBuilder
    private var macosList: some View {
        if configStore.configurations.isEmpty {
            ContentUnavailableView(
                "バックエンドがありません",
                systemImage: "server.rack",
                description: Text("追加は")
                    + Text(Image(systemName: "plus")).foregroundStyle(Color.accentColor)
                    + Text("ボタンから行えます")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedBackendID) {
                ForEach(configStore.configurations) { config in
                    BackendRowView(
                        config: config,
                        state: manager.connectionStates[config.id],
                        isEnabled: configStore.isEnabled(config.id),
                        onToggle: { enabled in
                            configStore.setEnabled(enabled, for: config.id)
                            manager.connectionStates[config.id]?.isEnabled = enabled
                            if enabled {
                                Task { await manager.connect(backendId: config.id) }
                            } else {
                                manager.connectionStates[config.id]?.status = .disconnected
                                manager.backendAvailabilityDidChange()
                            }
                        },
                        onReconnect: {
                            Task { await manager.connect(backendId: config.id) }
                        },
                        onEdit: {
                            editingConfig = config
                        }
                    )
                    .tag(config.id)
                }
                .onMove(perform: moveConfigs)
            }
            .contextMenu(forSelectionType: String.self) { selectedIDs in
                if let firstID = selectedIDs.first,
                    let config = configStore.configurations.first(where: { $0.id == firstID })
                {
                    Button("編集") {
                        editingConfig = config
                    }

                    Divider()

                    Button("削除", role: .destructive) {
                        backendIDsToDelete = [firstID]
                        showingDeleteConfirmation = true
                    }
                }
            } primaryAction: { selectedIDs in
                if let firstID = selectedIDs.first,
                    let config = configStore.configurations.first(where: { $0.id == firstID })
                {
                    editingConfig = config
                }
            }
        }
    }

    @ViewBuilder
    private var iosList: some View {
        if configStore.configurations.isEmpty {
            ContentUnavailableView(
                "バックエンドがありません",
                systemImage: "server.rack",
                description: Text("追加は")
                    + Text(Image(systemName: "plus")).foregroundStyle(Color.accentColor)
                    + Text("ボタンから行えます")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedBackendID) {
                Section {
                    ForEach(configStore.configurations) { config in
                        BackendRowView(
                            config: config,
                            state: manager.connectionStates[config.id],
                            isEnabled: configStore.isEnabled(config.id),
                            onToggle: { enabled in
                                configStore.setEnabled(enabled, for: config.id)
                                manager.connectionStates[config.id]?.isEnabled = enabled
                                if enabled {
                                    Task { await manager.connect(backendId: config.id) }
                                } else {
                                    manager.connectionStates[config.id]?.status = .disconnected
                                    manager.backendAvailabilityDidChange()
                                }
                            },
                            onReconnect: {
                                Task { await manager.connect(backendId: config.id) }
                            },
                            onEdit: {
                                editingConfig = config
                            }
                        )
                    }
                    .onDelete { indexSet in
                        backendIDsToDelete = indexSet.map { configStore.configurations[$0].id }
                        showingDeleteConfirmation = true
                    }
                    .onMove(perform: moveConfigs)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isTabActive {
            ToolbarItem(placement: addButtonPlacement) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            #if !os(macOS)
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            #endif
        }
    }

    private var addButtonPlacement: ToolbarItemPlacement {
        #if os(macOS)
            return .automatic
        #else
            return .topBarTrailing
        #endif
    }

    private var deleteConfirmationButtons: some View {
        Group {
            Button("削除", role: .destructive) {
                confirmPendingDeletion()
            }
            Button("キャンセル", role: .cancel) {
                clearPendingDeletion()
            }
        }
    }

    private func confirmPendingDeletion() {
        let ids = backendIDsToDelete
        clearPendingDeletion()
        for id in ids {
            removeConfig(id: id)
        }
    }

    private func clearPendingDeletion() {
        showingDeleteConfirmation = false
        backendIDsToDelete = []
    }

    private func moveConfigs(from offsets: IndexSet, to destination: Int) {
        configStore.moveConfiguration(fromOffsets: offsets, toOffset: destination)
        manager.setupProviders()
    }

    private func removeConfig(id: String) {
        configStore.removeConfiguration(id: id)
        manager.setupProviders()
        if selectedBackendID == id {
            selectedBackendID = nil
        }
    }
}

struct BackendRowView: View {
    let config: BackendConfiguration
    let state: BackendConnectionState?
    let isEnabled: Bool
    let onToggle: (Bool) -> Void
    let onReconnect: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(config.name)
                            BackendBadge(typeName: config.type.displayName)
                        }
                        if let baseURL = config.baseURL {
                            Text(baseURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if let state {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(statusColor(state.status))
                                    .frame(width: 8, height: 8)
                                Text(statusText(state.status))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .multilineTextAlignment(.trailing)
                                    .truncationMode(.middle)

                                if let error = state.lastError {
                                    Text(error)
                                        .font(.caption2)
                                        .foregroundStyle(
                                            state.status == .error ? .red : .orange
                                        )
                                        .lineLimit(2)
                                }
                            }

                            if case .oauth2(_, _, let expiryDate) = config.auth,
                                let expiryDate = expiryDate
                            {
                                Text("認証情報期限: \(expiryDate.formatted(.displayDateTimeFull))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if state.status == .error {
                            Spacer()
                            Button("再接続") { onReconnect() }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                        }
                    }
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { isEnabled },
                        set: { onToggle($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        #if os(macOS)
            .padding(.vertical, 8)
        #else
            .onTapGesture {
                onEdit()
            }
        #endif
    }

    private func statusColor(_ status: ConnectionStatus) -> Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    private func statusText(_ status: ConnectionStatus) -> String {
        switch status {
        case .connected:
            if let version = state?.version, !version.isEmpty {
                return version
            }
            return "接続済み"
        case .connecting: return "接続中..."
        case .disconnected: return "未接続"
        case .error: return "エラー"
        }
    }
}
