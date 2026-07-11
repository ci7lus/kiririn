import SwiftUI

struct ServerRecordsView: View {
    let manager: ServerManager
    @State var playerState: PlayerState
    let serverId: String
    let refreshTrigger: Int
    @Binding var searchText: String
    let showsNavigationTitle: Bool
    let showsSearch: Bool

    let viewModel: RecordsViewModel
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var hasCompletedInitialLoad = false
    @State private var visibleIds: Set<String> = []
    private let recordDownloadManager = RecordDownloadManager.shared
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    private var visibleRecords: [Recorded] {
        viewModel.records.filter {
            $0.serverId == serverId && manager.isServerEnabled($0.serverId)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if viewModel.isLoading && visibleRecords.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleRecords.isEmpty {
                    if let errorTitle = viewModel.errorTitle,
                        let errorMessage = viewModel.errorMessage
                    {
                        ContentUnavailableView {
                            Label(errorTitle, systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(errorMessage)
                        } actions: {
                            Button("再接続", action: reloadRecords)
                        }
                    } else {
                        ContentUnavailableView {
                            Label("録画番組がありません", systemImage: "film.stack")
                        } description: {
                            Text("録画番組がある場合はここに表示されます")
                        } actions: {
                            Button("再読み込み", action: reloadRecords)
                        }
                    }
                } else {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(visibleRecords) { record in
                                let recordDownloadID = RecordDownloadManager.localRecordID(
                                    serverId: record.serverId,
                                    recordID: record.id
                                )
                                RecordRowView(
                                    record: record,
                                    thumbnailData: viewModel.thumbnailData(for: record),
                                    isThumbnailFailed: viewModel.isThumbnailFailed(for: record),
                                    playbackPosition: viewModel.playbackPosition(for: record),
                                    downloadProgress:
                                        recordDownloadManager.downloadProgressByItemId[
                                            recordDownloadID],
                                    onCancelDownload: {
                                        recordDownloadManager.cancelDownload(id: recordDownloadID)
                                    },
                                    manager: manager
                                ) {
                                    playRecord(record)
                                }
                                .onAppear {
                                    Task {
                                        await viewModel.loadThumbnailIfNeeded(
                                            for: record, manager: manager)
                                    }
                                    if record.id == visibleRecords.last?.id {
                                        Task {
                                            await loadRecords(reset: false)
                                        }
                                    }
                                    visibleIds.insert(record.id)
                                    if viewModel.hasRestoredScroll { updateTopVisible() }
                                }
                                .onDisappear {
                                    visibleIds.remove(record.id)
                                    if viewModel.hasRestoredScroll { updateTopVisible() }
                                }
                            }

                            if viewModel.isLoading {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                    Spacer()
                                }
                                .listRowSeparator(.hidden)
                            }
                        }
                        .refreshable {
                            await refreshRecords()
                        }
                        .task {
                            guard !viewModel.hasRestoredScroll else { return }
                            if let id = viewModel.scrolledRecordId {
                                proxy.scrollTo(id, anchor: .top)
                            }
                            viewModel.hasRestoredScroll = true
                        }
                    }
                }
            }
        }
        .modifier(
            RecordsSearchableModifier(
                isEnabled: showsSearch,
                searchText: $searchText
            )
        )
        .onChange(of: searchText) { _, _ in
            scheduleSearch()
        }
        .onChange(of: AppModel.shared.cacheStore?.playbackPositionSaveToken) { _, _ in
            guard let entry = AppModel.shared.cacheStore?.lastSavedPlaybackPosition else { return }
            viewModel.playbackPositionByPlayableId[entry.playableID] = entry.position
        }
        .onChange(of: refreshTrigger) { _, _ in
            Task {
                await refreshRecords()
            }
        }
        .task {
            viewModel.searchText = searchText
            guard !hasCompletedInitialLoad else { return }
            await loadRecords(reset: true)
            if !viewModel.records.isEmpty, let cacheStore = AppModel.shared.cacheStore {
                await viewModel.loadPlaybackPositions(
                    for: viewModel.records, cacheStore: cacheStore)
            }
            hasCompletedInitialLoad = true
        }
        .onDisappear {
            searchDebounceTask?.cancel()
            searchDebounceTask = nil
        }
    }

    private func reloadRecords() {
        Task {
            await refreshRecords()
        }
    }

    private func playRecord(_ record: Recorded) {
        guard let variant = record.variants.first,
            let provider = manager.recordingProvider(for: record.serverId)
        else { return }
        guard let playable = try? provider.buildRecordedPlayable(record: record, variant: variant)
        else {
            return
        }
        startPlayback(playable)
    }

    private func startPlayback(_ playable: Playable) {
        #if os(macOS)
            openWindow(id: AppWindowID.player.rawValue, value: playable)
        #else
            playerState.play(playable: playable)
        #endif
    }

    private func updateTopVisible() {
        guard let top = visibleRecords.first(where: { visibleIds.contains($0.id) }) else { return }
        viewModel.scrolledRecordId = top.id
    }

    private func scheduleSearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await loadRecords(reset: true)
            } catch {}
        }
    }

    private func loadRecords(reset: Bool) async {
        viewModel.searchText = searchText
        await viewModel.loadRecords(
            manager: manager,
            serverId: serverId,
            reset: reset
        )
        if let cacheStore = AppModel.shared.cacheStore {
            await viewModel.loadPlaybackPositions(for: viewModel.records, cacheStore: cacheStore)
        }
    }

    private func refreshRecords() async {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        viewModel.searchText = searchText
        await viewModel.loadRecords(
            manager: manager,
            serverId: serverId,
            reset: true,
            force: true
        )
    }
}

private struct RecordsSearchableModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var searchText: String
    @Environment(\.isTabActive) private var isTabActive

    func body(content: Content) -> some View {
        ZStack {
            if isEnabled && isTabActive {
                Color.clear
                    .allowsHitTesting(false)
                    .searchable(text: $searchText, prompt: "検索")
            }
            content
        }
    }
}

struct RecordDownloadView: View {
    let manager: ServerManager
    @State var playerState: PlayerState
    let refreshTrigger: Int
    @Binding var searchText: String
    let showsNavigationTitle: Bool
    let showsSearch: Bool

    private let recordDownloadManager = RecordDownloadManager.shared
    @State private var playbackPositionById: [String: Float] = [:]
    @State private var deletingRecordIDs: Set<String> = []
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    var visibleRecords: [LocalRecordItem] {
        if searchText.isEmpty {
            return recordDownloadManager.localRecords
        }
        return recordDownloadManager.localRecords.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if recordDownloadManager.isLoadingLocalRecords
                    && recordDownloadManager.localRecords.isEmpty
                {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleRecords.isEmpty {
                    ContentUnavailableView(
                        "録画番組がありません",
                        systemImage: "folder",
                        description: Text("録画番組をダウンロードすると、ここに表示されます")
                    )
                } else {
                    List {
                        ForEach(visibleRecords) { item in
                            if let record = item.recorded {
                                RecordDownloadRowView(
                                    item: item,
                                    record: record,
                                    playbackPosition: playbackPositionById[item.id],
                                    downloadProgress:
                                        recordDownloadManager.downloadProgressByItemId[
                                            item.id],
                                    isDeleting: deletingRecordIDs.contains(item.id),
                                    manager: manager,
                                    onTap: { playDownloadRecord(item) },
                                    onCancel: { recordDownloadManager.cancelDownload(id: item.id) },
                                    onDelete: { deleteDownloadRecord(item) }
                                )
                            }
                        }
                    }
                    .refreshable {
                        await recordDownloadManager.reloadLocalRecords()
                        await loadPlaybackPositions()
                    }
                }
            }
        }
        .modifier(
            RecordsSearchableModifier(
                isEnabled: showsSearch,
                searchText: $searchText
            )
        )
        .onChange(of: AppModel.shared.cacheStore?.playbackPositionSaveToken) { _, _ in
            applyPlaybackPositionUpdateFromCacheStore()
        }
        .onChange(of: refreshTrigger) { _, _ in
            Task {
                await recordDownloadManager.reloadLocalRecords()
                await loadPlaybackPositions()
            }
        }
        .task {
            if recordDownloadManager.localRecords.isEmpty {
                await recordDownloadManager.reloadLocalRecords()
            }
            await loadPlaybackPositions()
        }
    }

    private func playDownloadRecord(_ item: LocalRecordItem) {
        guard let url = RecordDownloadManager.shared.localVideoURL(for: item) else { return }
        let recorded = item.recorded
        var playable = Playable(
            streamURL: url,
            source: .fileURL(url, bookmarkData: nil),
            program: recorded?.toProgram(),
            service: recorded?.synthesizedService()
        )
        playable.normalizeIdentity()
        #if os(macOS)
            openWindow(id: AppWindowID.player.rawValue, value: playable)
        #else
            playerState.play(playable: playable)
        #endif
    }

    private func deleteDownloadRecord(_ item: LocalRecordItem) {
        guard !deletingRecordIDs.contains(item.id) else { return }
        deletingRecordIDs.insert(item.id)
        Task { @MainActor in
            defer { deletingRecordIDs.remove(item.id) }
            await recordDownloadManager.deleteLocalRecord(item)
        }
    }

    private func loadPlaybackPositions() async {
        guard let cacheStore = AppModel.shared.cacheStore else { return }
        let downloadedItems = recordDownloadManager.localRecords.filter {
            $0.downloadState == .downloaded
        }
        await withTaskGroup(of: (String, Float?).self) { group in
            for item in downloadedItems {
                let playableId = item.playableID
                let itemId = item.id
                group.addTask {
                    let position = await cacheStore.loadPlaybackPosition(playableID: playableId)
                    return (itemId, position)
                }
            }
            for await (itemId, position) in group {
                if let position {
                    playbackPositionById[itemId] = position
                }
            }
        }
    }

    private func applyPlaybackPositionUpdateFromCacheStore() {
        guard let entry = AppModel.shared.cacheStore?.lastSavedPlaybackPosition else { return }
        guard
            let item = recordDownloadManager.localRecords.first(where: {
                $0.playableID == entry.playableID
            })
        else {
            return
        }
        if let position = entry.position {
            playbackPositionById[item.id] = position
        } else {
            playbackPositionById.removeValue(forKey: item.id)
        }
    }
}
