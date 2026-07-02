import SwiftUI

struct RecordsListView: View {
    let manager: ServerManager
    @Binding var searchText: String
    let showsNavigationTitle: Bool
    let showsSearch: Bool
    @State var playerState: PlayerState
    @AppStorage("records.lastSelectedServerId") private var selectedServerId = ""
    @State private var showingURLInput = false
    @State private var showingFilePicker = false
    @State private var urlInputText = ""
    @State private var refreshTrigger = 0
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    @Environment(\.isTabActive) private var isTabActive

    private var recordingServerIds: [String] {
        let _ = manager.serverSyncCount
        var ids = ["download"]
        ids.append(
            contentsOf: manager.recordingServerIds.filter {
                manager.isServerEnabled($0) && manager.recordingProvider(for: $0) != nil
            })
        return ids
    }

    private var currentServerId: String? {
        if !selectedServerId.isEmpty, recordingServerIds.contains(selectedServerId) {
            return selectedServerId
        }
        return recordingServerIds.first
    }

    var body: some View {
        recordsContent
            .navigationTitle(showsNavigationTitle && isTabActive ? "録画" : "")
            .task {
                ensureSelectedServer()
            }
            .onChange(of: recordingServerIds) { _, _ in
                ensureSelectedServer()
            }
            .toolbar {
                if isTabActive {
                    if !recordingServerIds.isEmpty {
                        ToolbarItem(placement: .principal) {
                            HStack(spacing: 2) {
                                Picker("サーバー", selection: selectedServerBinding) {
                                    ForEach(recordingServerIds, id: \.self) { serverId in
                                        if serverId == "download" {
                                            Text("ダウンロード")
                                                .tag(serverId)
                                        } else {
                                            Text(manager.serverName(serverId))
                                                .tag(serverId)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                if let serverId = currentServerId, serverId != "download" {
                                    ServerBadge(
                                        typeName: manager.serverTypeName(serverId))
                                }
                            }
                            .padding(.horizontal, 2)
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
                                Label {
                                    Text("ファイルから再生")
                                } icon: {
                                    accentMenuIcon(systemName: "doc")
                                }
                            }
                            Button {
                                urlInputText = ""
                                showingURLInput = true
                            } label: {
                                Label {
                                    Text("URLから再生")
                                } icon: {
                                    accentMenuIcon(systemName: "link")
                                }
                            }
                        } label: {
                            Image(systemName: "plus")
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
        if let serverId = currentServerId {
            if serverId == "download" {
                RecordDownloadView(
                    manager: manager,
                    playerState: playerState,
                    refreshTrigger: refreshTrigger,
                    searchText: $searchText,
                    showsNavigationTitle: showsNavigationTitle,
                    showsSearch: showsSearch
                )
                .id("download")
            } else {
                ServerRecordsView(
                    manager: manager,
                    playerState: playerState,
                    serverId: serverId,
                    refreshTrigger: refreshTrigger,
                    searchText: $searchText,
                    showsNavigationTitle: showsNavigationTitle,
                    showsSearch: showsSearch,
                    viewModel: AppModel.shared.recordingsViewModel(for: serverId)
                )
                .id(serverId)
                .refreshable {
                    refreshTrigger += 1
                }
            }
        } else {
            ContentUnavailableView("録画サーバーがありません", systemImage: "internaldrive")
        }
    }

    private var addMenuPlacement: ToolbarItemPlacement {
        recordingsAddMenuPlacement
    }

    private var selectedServerBinding: Binding<String> {
        Binding(
            get: { currentServerId ?? "" },
            set: { selectedServerId = $0 }
        )
    }

    private func ensureSelectedServer() {
        guard let first = recordingServerIds.first else { return }
        if !selectedServerId.isEmpty, recordingServerIds.contains(selectedServerId) { return }
        selectedServerId = first
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
