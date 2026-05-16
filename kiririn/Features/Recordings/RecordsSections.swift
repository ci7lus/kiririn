import SwiftUI

struct BackendRecordsView: View {
    let manager: BackendManager
    @State var playerState: PlayerState
    let backendId: String
    let refreshTrigger: Int
    @Binding var searchText: String
    let showsNavigationTitle: Bool
    let showsSearch: Bool

    @State private var viewModel = RecordsViewModel()
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var hasCompletedInitialLoad = false
    private let localRecordManager = LocalRecordManager.shared
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    private var visibleRecords: [Recorded] {
        viewModel.records.filter {
            $0.backendId == backendId && manager.isBackendEnabled($0.backendId)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if viewModel.isLoading && visibleRecords.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleRecords.isEmpty {
                    if let error = viewModel.errorMessage {
                        ContentUnavailableView(
                            "エラー",
                            systemImage: "exclamationmark.triangle",
                            description: Text(error)
                        )
                    } else {
                        ContentUnavailableView(
                            "録画番組なし",
                            systemImage: "film.stack",
                            description: Text("録画された番組がありません")
                        )
                    }
                } else {
                    List {
                        ForEach(visibleRecords) { record in
                            let localRecordID = LocalRecordManager.localRecordID(
                                backendId: record.backendId,
                                recordID: record.id
                            )
                            RecordRowView(
                                record: record,
                                thumbnailData: viewModel.thumbnailData(for: record),
                                isThumbnailFailed: viewModel.isThumbnailFailed(for: record),
                                playbackPosition: viewModel.playbackPosition(for: record),
                                localSaveProgress: localRecordManager.downloadProgressByItemId[
                                    localRecordID],
                                onCancelLocalSave: {
                                    localRecordManager.cancelDownload(id: localRecordID)
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
            if viewModel.records.isEmpty {
                await loadRecords(reset: true)
            }
            if let cacheStore = AppModel.shared.cacheStore {
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

    private func playRecord(_ record: Recorded) {
        guard let variant = record.variants.first,
            let provider = manager.recordingProvider(for: record.backendId)
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
            backendId: backendId,
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
            backendId: backendId,
            reset: true,
            force: true
        )
    }
}

private struct RecordsSearchableModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var searchText: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $searchText, prompt: "検索")
        } else {
            content
        }
    }
}

struct LocalRecordsView: View {
    let manager: BackendManager
    @State var playerState: PlayerState
    let refreshTrigger: Int
    @Binding var searchText: String
    let showsNavigationTitle: Bool
    let showsSearch: Bool

    private let localRecordManager = LocalRecordManager.shared
    @State private var playbackPositionById: [String: Float] = [:]
    @State private var deletingRecordIDs: Set<String> = []
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    var visibleRecords: [LocalRecordItem] {
        if searchText.isEmpty {
            return localRecordManager.localRecords
        }
        return localRecordManager.localRecords.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if localRecordManager.isLoadingLocalRecords
                    && localRecordManager.localRecords.isEmpty
                {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleRecords.isEmpty {
                    ContentUnavailableView(
                        "ローカル保存データなし",
                        systemImage: "folder",
                        description: Text("ダウンロードした録画番組がありません")
                    )
                } else {
                    List {
                        ForEach(visibleRecords) { item in
                            if let record = item.recorded {
                                LocalRecordRowView(
                                    item: item,
                                    record: record,
                                    playbackPosition: playbackPositionById[item.id],
                                    downloadProgress: localRecordManager.downloadProgressByItemId[
                                        item.id],
                                    isDeleting: deletingRecordIDs.contains(item.id),
                                    manager: manager,
                                    onTap: { playLocalRecord(item) },
                                    onCancel: { localRecordManager.cancelDownload(id: item.id) },
                                    onDelete: { deleteLocalRecord(item) }
                                )
                            }
                        }
                    }
                    .refreshable {
                        await localRecordManager.reloadLocalRecords()
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
                await localRecordManager.reloadLocalRecords()
                await loadPlaybackPositions()
            }
        }
        .task {
            if localRecordManager.localRecords.isEmpty {
                await localRecordManager.reloadLocalRecords()
            }
            await loadPlaybackPositions()
        }
    }

    private func playLocalRecord(_ item: LocalRecordItem) {
        guard let url = LocalRecordManager.shared.localVideoURL(for: item) else { return }
        let playable = Playable(
            streamURL: url,
            source: .fileURL(url, bookmarkData: nil)
        )
        #if os(macOS)
            openWindow(id: AppWindowID.player.rawValue, value: playable)
        #else
            playerState.play(playable: playable)
        #endif
    }

    private func deleteLocalRecord(_ item: LocalRecordItem) {
        guard !deletingRecordIDs.contains(item.id) else { return }
        deletingRecordIDs.insert(item.id)
        Task { @MainActor in
            defer { deletingRecordIDs.remove(item.id) }
            await localRecordManager.deleteLocalRecord(item)
        }
    }

    private func loadPlaybackPositions() async {
        guard let cacheStore = AppModel.shared.cacheStore else { return }
        let downloadedItems = localRecordManager.localRecords.filter {
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
            let item = localRecordManager.localRecords.first(where: {
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
