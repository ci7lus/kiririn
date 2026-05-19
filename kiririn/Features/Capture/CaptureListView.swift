import AVKit
import QuickLook
import SwiftUI

struct CaptureListView: View {
    let showsNavigationTitle: Bool
    let showsSearch: Bool
    let playerState: PlayerState
    @StateObject private var service = CaptureService.shared
    @State private var items: [CaptureHistoryItem] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var offset = 0
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var previewURL: URL?
    @State private var isSelectionMode = false
    @State private var selectedIDs: Set<String> = []
    @State private var captureScrollProxy: ScrollViewProxy?
    @State private var isAtScrollTop = true
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    @Environment(\.isTabActive) private var isTabActive

    private let limit = 20

    #if os(macOS)
        private let gridMinimumWidth: CGFloat = 280
    #else
        private let gridMinimumWidth: CGFloat = 160
    #endif
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: gridMinimumWidth, maximum: 320), spacing: 12, alignment: .top)]
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            searchText.isEmpty ? "キャプチャ履歴なし" : "検索結果なし",
            systemImage: "photo.on.rectangle.angled",
            description: Text(searchText.isEmpty ? "撮影された項目はありません" : "キーワードに一致する項目が見つかりませんでした")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        Group {
            if items.isEmpty {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyStateView
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(items) { item in
                                CaptureHistoryItemView(
                                    item: item,
                                    previewURL: $previewURL,
                                    isSelectionMode: isSelectionMode,
                                    isSelected: selectedIDs.contains(item.id),
                                    onSelectionToggle: { toggleSelection(for: item.id) },
                                    onPlay: { playItem(item) },
                                    onDelete: {
                                        await service.deleteHistoryItem(item)
                                        if let index = items.firstIndex(where: { $0.id == item.id })
                                        {
                                            items.remove(at: index)
                                        }
                                    }
                                )
                                .id(item.id)
                                .onAppear {
                                    if item.id == items.first?.id {
                                        isAtScrollTop = true
                                    }
                                    if item == items.last && hasMore && !isLoading {
                                        Task { await loadMore() }
                                    }
                                }
                                .onDisappear {
                                    if item.id == items.first?.id {
                                        isAtScrollTop = false
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                        if isLoading {
                            ProgressView()
                                .padding()
                        }
                    }
                    .padding(.vertical, 16)
                    #if os(macOS)
                        .onAppear { captureScrollProxy = proxy }
                    #endif
                }
                #if os(macOS)
                    .overlay(alignment: .bottomTrailing) {
                        if !items.isEmpty && !isAtScrollTop {
                            Button {
                                withAnimation {
                                    captureScrollProxy?.scrollTo(items.first?.id, anchor: .top)
                                }
                            } label: {
                                Image(systemName: "arrow.up")
                                .font(.title3.weight(.semibold))
                                .frame(width: 52, height: 52)
                                .background(.ultraThinMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                            .padding(.trailing, 20)
                            .padding(.bottom, 24)
                            .help("先頭に戻る")
                        }
                    }
                #endif
            }
        }
        .navigationTitle(showsNavigationTitle && isTabActive ? "キャプチャ履歴" : "")
        .toolbar {
            if isTabActive {
                if !items.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(isSelectionMode ? "完了" : "選択") {
                            withAnimation {
                                if isSelectionMode {
                                    isSelectionMode = false
                                    selectedIDs.removeAll()
                                } else {
                                    isSelectionMode = true
                                }
                            }
                        }
                    }
                }
                if isSelectionMode, !selectedIDs.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive) {
                            Task { await deleteSelectedItems() }
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .modifier(CaptureSearchableModifier(isEnabled: showsSearch, searchText: $searchText))
        .onChange(of: searchText) {
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await loadInitial()
            }
        }
        .onReceive(service.didAddCapture) { newItem in
            if searchText.isEmpty
                || (newItem.programName?.lowercased().contains(searchText.lowercased()) == true)
                || (newItem.serviceName?.lowercased().contains(searchText.lowercased()) == true)
            {
                withAnimation {
                    items.insert(newItem, at: 0)
                    offset += 1
                }
            }
        }
        .onReceive(service.didClearHistory) { _ in
            withAnimation {
                items.removeAll()
                offset = 0
                hasMore = false
                selectedIDs.removeAll()
                isSelectionMode = false
            }
        }
        .onReceive(service.didUpdateCapture) { updatedItem in
            if let index = items.firstIndex(where: { $0.id == updatedItem.id }) {
                items[index] = updatedItem
            }
        }
        .onChange(of: items) {
            let ids = Set(items.map(\.id))
            selectedIDs = selectedIDs.intersection(ids)
        }
        .quickLookPreview($previewURL)
        .task {
            await loadInitial()
        }
    }

    private func playItem(_ item: CaptureHistoryItem) {
        let playable = Playable(
            streamURL: item.fileURL,
            source: .fileURL(item.fileURL, bookmarkData: nil),
            program: nil,
            service: nil
        )
        var updatedPlayable = playable
        if let programName = item.programName {
            updatedPlayable.overriddenProgram = PlayableProgramOverride(name: programName)
        }
        if let serviceName = item.serviceName {
            updatedPlayable.overriddenService = PlayableServiceOverride(name: serviceName)
        }
        startPlayback(updatedPlayable)
    }

    private func startPlayback(_ playable: Playable) {
        #if os(macOS)
            openWindow(id: AppWindowID.player.rawValue, value: playable)
        #else
            playerState.play(playable: playable)
        #endif
    }

    private func toggleSelection(for id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func deleteSelectedItems() async {
        let targetIDs = selectedIDs
        guard !targetIDs.isEmpty else { return }

        let targets = items.filter { targetIDs.contains($0.id) }
        for item in targets {
            await service.deleteHistoryItem(item)
        }

        withAnimation {
            items.removeAll { targetIDs.contains($0.id) }
            selectedIDs.removeAll()
            isSelectionMode = false
            offset = max(0, offset - targets.count)
        }
    }

    private func loadInitial() async {
        isLoading = true
        isAtScrollTop = true
        offset = 0
        let results = await service.loadHistory(searchText: searchText, limit: limit, offset: 0)
        items = results
        hasMore = results.count == limit
        offset = results.count
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoading && hasMore else { return }
        isLoading = true
        let results = await service.loadHistory(
            searchText: searchText, limit: limit, offset: offset)
        items.append(contentsOf: results)
        hasMore = results.count == limit
        offset += results.count
        isLoading = false
    }
}

private struct CaptureHistoryItemView: View {
    let item: CaptureHistoryItem
    @Binding var previewURL: URL?
    let isSelectionMode: Bool
    let isSelected: Bool
    let onSelectionToggle: () -> Void
    let onPlay: () -> Void
    let onDelete: () async -> Void

    @State private var selectedVariantIndex = 0

    private var selectedURL: URL {
        item.variantFileURL(at: selectedVariantIndex)
    }

    private var variantCount: Int {
        item.variantPaths.count + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnailArea
                .frame(minHeight: 100, maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelectionMode {
                        onSelectionToggle()
                    } else if item.type == .video {
                        onPlay()
                    } else {
                        previewURL = selectedURL
                    }
                }
                .gesture(
                    variantCount > 1
                        ? DragGesture(minimumDistance: 30, coordinateSpace: .local)
                            .onEnded { value in
                                if value.translation.width < 0 {
                                    if selectedVariantIndex < variantCount - 1 {
                                        selectedVariantIndex += 1
                                    }
                                } else if value.translation.width > 0 {
                                    if selectedVariantIndex > 0 {
                                        selectedVariantIndex -= 1
                                    }
                                }
                            }
                        : nil
                )
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { overlayArea }
                .overlay(alignment: .bottomLeading) {
                    if isSelectionMode {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : .white.opacity(0.9))
                            .shadow(radius: 2)
                            .padding(6)
                    }
                }
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                BroadcastText(item.programName ?? "名称未設定")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(item.displayDate)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                if let serviceName = item.serviceName {
                    Text(serviceName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .contextMenu {
            Button {
                copyCurrentVariantToClipboard()
            } label: {
                Label("コピー", systemImage: "doc.on.doc")
            }

            Button {
                revealCaptureItemInSystemFiles(selectedURL)
            } label: {
                Label(captureRevealButtonTitle, systemImage: "folder")
            }

            Button(role: .destructive) {
                Task { await onDelete() }
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
        .onChange(of: item.variantPaths) {
            selectedVariantIndex = min(selectedVariantIndex, item.variantPaths.count)
        }
    }

    @ViewBuilder
    private var thumbnailArea: some View {
        if item.type == .image {
            CaptureImageThumbnailView(url: selectedURL)
        } else {
            VideoThumbnailView(url: item.fileURL)
        }
    }

    @ViewBuilder
    private var overlayArea: some View {
        VStack {
            if variantCount > 1 {
                HStack(spacing: 0) {
                    Button {
                        if selectedVariantIndex > 0 { selectedVariantIndex -= 1 }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(selectedVariantIndex > 0 ? 1 : 0.3)

                    Spacer()

                    Text("\(selectedVariantIndex + 1) / \(variantCount)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.45), in: Capsule())

                    Spacer()

                    Button {
                        if selectedVariantIndex < variantCount - 1 { selectedVariantIndex += 1 }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(selectedVariantIndex < variantCount - 1 ? 1 : 0.3)
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
            }

            Spacer()

            HStack(alignment: .bottom, spacing: 4) {
                if item.type == .video {
                    Image(systemName: "video.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
                ShareLink(item: selectedURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(6)
        }
    }

    private func copyCurrentVariantToClipboard() {
        let url = selectedURL
        let isImage = item.type == .image
        Task(priority: .userInitiated) {
            await copyCaptureItemToClipboard(url: url, isImage: isImage)
        }
    }
}

private struct CaptureImageThumbnailView: View {
    let url: URL
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                captureImage(image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .background(.gray)
            } else {
                Rectangle()
                    .fill(Color.kiririnSecondarySystemFill)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .task(id: url) {
            image = await loadCapturePlatformImage(from: url)
        }
    }
}

private struct VideoThumbnailView: View {
    let url: URL
    @State private var image: PlatformImage?
    @State private var isLoading = false
    private var isTSFile: Bool {
        url.pathExtension.lowercased() == "ts"
    }

    var body: some View {
        ZStack {
            if let image {
                captureImage(image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .background(.black)
            } else if isLoading {
                Rectangle()
                    .fill(Color.kiririnSecondarySystemFill)
                ProgressView()
            } else {
                videoPlaceholder
            }

            if image != nil || isTSFile {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .task {
            guard image == nil && !isTSFile else { return }
            isLoading = true
            image = await generateThumbnail(at: url)
            isLoading = false
        }
    }

    private var videoPlaceholder: some View {
        Rectangle()
            .fill(Color.kiririnTertiarySystemFill)
    }

    private func generateThumbnail(at url: URL) async -> PlatformImage? {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 1, preferredTimescale: 60)
        do {
            let (cgImage, _) = try await imageGenerator.image(at: time)
            return makeCaptureVideoImage(from: cgImage)
        } catch {
            return nil
        }
    }
}

private struct CaptureSearchableModifier: ViewModifier {
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
