import SwiftUI

struct BackendSettingsView: View {
    let configStore: BackendConfigStore
    let manager: BackendManager
    @State private var showingAddSheet = false
    @State private var editingConfig: BackendConfiguration?
    @State private var selectedBackendID: String?
    @State private var showingDeleteConfirmation = false
    @State private var backendIDsToDelete: [String] = []

    var body: some View {
        listView
            .toolbar {
                toolbarContent
            }
            .confirmationDialog(
                "バックエンドを削除しますか？",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) {
                    for id in backendIDsToDelete {
                        removeConfig(id: id)
                    }
                    backendIDsToDelete = []
                }
                Button("キャンセル", role: .cancel) {
                    backendIDsToDelete = []
                }
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

    private var macosList: some View {
        List(configStore.configurations, id: \.self.id, selection: $selectedBackendID) { config in
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
            .contextMenu {
                Button("編集") {
                    editingConfig = config
                }

                Divider()

                Button("上へ移動") {
                    moveConfig(id: config.id, delta: -1)
                }
                .disabled(!canMove(id: config.id, delta: -1))

                Button("下へ移動") {
                    moveConfig(id: config.id, delta: 1)
                }
                .disabled(!canMove(id: config.id, delta: 1))

                Divider()

                Button("削除", role: .destructive) {
                    backendIDsToDelete = [config.id]
                    showingDeleteConfirmation = true
                }
            }
        }
        .navigationTitle("バックエンド")
    }

    private var iosList: some View {
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
                    .contextMenu {
                        Button("編集") {
                            editingConfig = config
                        }

                        Divider()

                        Button("上へ移動") {
                            moveConfig(id: config.id, delta: -1)
                        }
                        .disabled(!canMove(id: config.id, delta: -1))

                        Button("下へ移動") {
                            moveConfig(id: config.id, delta: 1)
                        }
                        .disabled(!canMove(id: config.id, delta: 1))

                        Divider()

                        Button("削除", role: .destructive) {
                            backendIDsToDelete = [config.id]
                            showingDeleteConfirmation = true
                        }
                    }
                }
                .onDelete { indexSet in
                    backendIDsToDelete = indexSet.map { configStore.configurations[$0].id }
                    showingDeleteConfirmation = true
                }
                .onMove(perform: moveConfigs)
            } footer: {
                if configStore.configurations.isEmpty {
                    Text("右上の＋ボタンからMirakurunやEPGStationを追加してください")
                }
            }
        }
        .navigationTitle("バックエンド")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
        #if os(macOS)
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if let id = selectedBackendID {
                        editingConfig = configStore.configurations.first { $0.id == id }
                    }
                } label: {
                    Image(systemName: "info.circle")
                }
                .help("選択したバックエンドを編集")
                .disabled(selectedBackendID == nil)

                Button {
                    if let id = selectedBackendID {
                        moveConfig(id: id, delta: -1)
                    }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .help("選択したバックエンドを上へ移動")
                .disabled(!canMoveSelected(delta: -1))

                Button {
                    if let id = selectedBackendID {
                        moveConfig(id: id, delta: 1)
                    }
                } label: {
                    Image(systemName: "arrow.down")
                }
                .help("選択したバックエンドを下へ移動")
                .disabled(!canMoveSelected(delta: 1))

                Button(role: .destructive) {
                    if let id = selectedBackendID {
                        backendIDsToDelete = [id]
                        showingDeleteConfirmation = true
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .help("選択したバックエンドを削除")
                .disabled(selectedBackendID == nil)
            }
        #endif
    }

    private var addButtonPlacement: ToolbarItemPlacement {
        #if os(macOS)
            return .automatic
        #else
            return .topBarTrailing
        #endif
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

    private func canMoveSelected(delta: Int) -> Bool {
        guard let id = selectedBackendID else { return false }
        return canMove(id: id, delta: delta)
    }

    private func canMove(id: String, delta: Int) -> Bool {
        guard let index = configStore.configurations.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let newIndex = index + delta
        return newIndex >= 0 && newIndex < configStore.configurations.count
    }

    private func moveConfig(id: String, delta: Int) {
        guard configStore.moveConfiguration(id: id, delta: delta) else { return }
        manager.setupProviders()
        selectedBackendID = id
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
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor(state.status))
                                .frame(width: 8, height: 8)
                            Text(statusText(state.status))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if case .oauth2(_, _, let expiryDate) = config.auth,
                                let expiryDate = expiryDate
                            {
                                Text("(認証情報期限: \(expiryDate.formatted(.displayDateTimeFull)))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            if state.status == .error {
                                Spacer()
                                Button("再接続") { onReconnect() }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                            }
                        }

                        if let error = state.lastError {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(state.status == .error ? .red : .orange)
                                .lineLimit(2)
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
        case .connected: return "接続済み"
        case .connecting: return "接続中..."
        case .disconnected: return "未接続"
        case .error: return "エラー"
        }
    }
}
