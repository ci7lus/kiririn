import SwiftUI

struct RecordsListView: View {
    let manager: BackendManager
    @Binding var searchText: String
    let showsNavigationTitle: Bool
    let showsSearch: Bool
    @State var playerState: PlayerState
    @AppStorage("records.lastSelectedBackendId") private var selectedBackendId = ""
    @State private var showingURLInput = false
    @State private var showingFilePicker = false
    @State private var urlInputText = ""
    @State private var refreshTrigger = 0
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    @Environment(\.isTabActive) private var isTabActive

    private var recordingBackendIds: [String] {
        let _ = manager.backendSyncCount
        var ids = ["local"]
        ids.append(
            contentsOf: manager.recordingBackendIds.filter {
                manager.isBackendEnabled($0) && manager.recordingProvider(for: $0) != nil
            })
        return ids
    }

    private var currentBackendId: String? {
        if !selectedBackendId.isEmpty, recordingBackendIds.contains(selectedBackendId) {
            return selectedBackendId
        }
        return recordingBackendIds.first
    }

    var body: some View {
        recordsContent
            .navigationTitle(showsNavigationTitle && isTabActive ? "録画" : "")
            .task {
                ensureSelectedBackend()
            }
            .onChange(of: recordingBackendIds) { _, _ in
                ensureSelectedBackend()
            }
            .toolbar {
                if isTabActive {
                    if !recordingBackendIds.isEmpty {
                        ToolbarItem(placement: .principal) {
                            HStack(spacing: 0) {
                                Picker("バックエンド", selection: selectedBackendBinding) {
                                    ForEach(recordingBackendIds, id: \.self) { backendId in
                                        if backendId == "local" {
                                            Text("ローカル保存")
                                                .tag(backendId)
                                        } else {
                                            Text(manager.backendName(backendId))
                                                .tag(backendId)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                if let backendId = currentBackendId {
                                    if backendId == "local" {
                                        BackendBadge(typeName: "Local")
                                    } else {
                                        BackendBadge(
                                            typeName: manager.backendTypeName(backendId))
                                    }
                                }
                            }
                        }
                    }
                    #if os(macOS)
                        ToolbarItem(placement: .automatic) {
                            Button {
                                refreshTrigger += 1
                            } label: {
                                Label("再読込", systemImage: "arrow.clockwise")
                            }
                            .help("録画一覧を再読込")
                        }
                    #endif
                    ToolbarItem(placement: addMenuPlacement) {
                        Menu {
                            Button {
                                showingFilePicker = true
                            } label: {
                                Label("ファイルから再生", systemImage: "doc")
                            }
                            Button {
                                urlInputText = ""
                                showingURLInput = true
                            } label: {
                                Label("URLから再生", systemImage: "link")
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: PlayableMediaUTTypes.allowedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .alert("URLから再生", isPresented: $showingURLInput) {
                TextField("https://...", text: $urlInputText)
                    .urlTextInputModifiers()
                    .autocorrectionDisabled()
                Button("再生") {
                    playFromURL(urlInputText)
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("動画のURLを入力してください")
            }
    }

    @ViewBuilder
    private var recordsContent: some View {
        if recordingBackendIds.isEmpty {
            ContentUnavailableView(
                "録画バックエンドなし",
                systemImage: "internaldrive",
                description: Text("録画対応バックエンドを追加すると録画を再生できます\nツールバーからファイルやURLを直接再生できます")
            )
        } else if let backendId = currentBackendId {
            if backendId == "local" {
                LocalRecordsView(
                    manager: manager,
                    playerState: playerState,
                    refreshTrigger: refreshTrigger,
                    searchText: $searchText,
                    showsNavigationTitle: showsNavigationTitle,
                    showsSearch: showsSearch
                )
                .id("local")
            } else {
                BackendRecordsView(
                    manager: manager,
                    playerState: playerState,
                    backendId: backendId,
                    refreshTrigger: refreshTrigger,
                    searchText: $searchText,
                    showsNavigationTitle: showsNavigationTitle,
                    showsSearch: showsSearch,
                    viewModel: AppModel.shared.recordingsViewModel(for: backendId)
                )
                .id(backendId)
            }
        } else {
            ContentUnavailableView("録画バックエンドなし", systemImage: "internaldrive")
        }
    }

    private var addMenuPlacement: ToolbarItemPlacement {
        recordingsAddMenuPlacement
    }

    private var selectedBackendBinding: Binding<String> {
        Binding(
            get: { currentBackendId ?? "" },
            set: { selectedBackendId = $0 }
        )
    }

    private func ensureSelectedBackend() {
        guard let first = recordingBackendIds.first else { return }
        if !selectedBackendId.isEmpty, recordingBackendIds.contains(selectedBackendId) { return }
        selectedBackendId = first
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result,
            let fileURL = urls.first
        else { return }

        let bookmarkData = try? fileURL.bookmarkData(
            options: .securityScoped, includingResourceValuesForKeys: nil, relativeTo: nil)

        let playable = Playable(
            streamURL: fileURL,
            source: .fileURL(fileURL, bookmarkData: bookmarkData)
        )
        startPlayback(playable)
    }

    private func playFromURL(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return }
        let playable = Playable(
            streamURL: url,
            source: .directURL(url)
        )
        startPlayback(playable)
    }

    private func startPlayback(_ playable: Playable) {
        #if os(macOS)
            openWindow(id: AppWindowID.player.rawValue, value: playable)
        #else
            playerState.play(playable: playable)
        #endif
    }
}
