import OrderedCollections
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

@Observable
class ServiceListViewModel {
    var searchText = ""
}

struct ServiceListView: View {
    let manager: BackendManager
    @State var playerState: PlayerState
    let showsNavigationTitle: Bool
    let showsSearch: Bool
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    @State private var serviceSelectionForPlayback: TVService?
    @State private var viewModel = ServiceListViewModel()
    @State private var minuteRefreshTick = Date()
    @State private var groupedServices: [(String, [ServiceListItem])] = []
    @State private var rebuildTask: Task<Void, Never>?
    @State private var isBuildingList = true
    @State private var rebuildGeneration = 0

    private struct ServiceDisplayGroup {
        let id: String
        let primary: TVService
        let secondary: [TVService]
    }

    private struct ServiceListItem: Identifiable {
        let id: String
        let service: TVService
        let currentProgram: Program?
        let nextProgram: Program?
        let hasDifferentChildProgram: Bool
        let children: [ServiceListItem]?
    }

    private var serviceTypeFilteredServices: [TVService] {
        let typeOrder = ["GR", "BS", "CS", "SKY"]
        return manager.services
            .filter { $0.type == .digitalTelevision || $0.type == .uhdtv }
            .sorted { lhs, rhs in
                let lt = lhs.channel?.type ?? "その他"
                let rt = rhs.channel?.type ?? "その他"
                let li = typeOrder.firstIndex(of: lt) ?? typeOrder.count
                let ri = typeOrder.firstIndex(of: rt) ?? typeOrder.count
                if li != ri { return li < ri }
                if (lhs.remoteControlKeyId ?? Int.max) != (rhs.remoteControlKeyId ?? Int.max) {
                    return (lhs.remoteControlKeyId ?? Int.max) < (rhs.remoteControlKeyId ?? Int.max)
                }
                if lhs.serviceId != rhs.serviceId { return lhs.serviceId < rhs.serviceId }
                return lhs.name < rhs.name
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if manager.isCacheReady && manager.services.isEmpty {
                    emptyStateView
                } else if groupedServices.isEmpty {
                    if isBuildingList {
                        ProgressView()
                    } else {
                        emptyStateView
                    }
                } else {
                    listView
                }
            }
        }
        .modifier(ServiceListTitleModifier(isEnabled: showsNavigationTitle))
        .modifier(
            ServiceListSearchableModifier(
                isEnabled: showsSearch,
                searchText: Bindable(viewModel).searchText
            )
        )
        .task {
            triggerRebuild()
            await startMinuteAlignedRefreshLoop()
        }
        .onChange(of: viewModel.searchText) {
            triggerRebuild()
        }
        .onChange(of: manager.isCacheReady) { _, isReady in
            guard isReady else { return }
            triggerRebuild()
        }
        .onChange(of: manager.services) {
            triggerRebuild()
        }
        .confirmationDialog(
            "再生するバックエンドを選択",
            isPresented: Binding(
                get: { serviceSelectionForPlayback != nil },
                set: { if !$0 { serviceSelectionForPlayback = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let service = serviceSelectionForPlayback {
                let candidates = manager.playbackCandidates(for: service)
                ForEach(candidates, id: \.backendId) { candidate in
                    Button(manager.backendFullDisplayName(candidate.backendId)) {
                        Task { await playCandidate(candidate) }
                    }
                }
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    init(
        manager: BackendManager,
        playerState: PlayerState,
        showsNavigationTitle: Bool = true,
        showsSearch: Bool = true
    ) {
        self.manager = manager
        self._playerState = State(initialValue: playerState)
        self.showsNavigationTitle = showsNavigationTitle
        self.showsSearch = showsSearch
    }

    @ViewBuilder
    private var emptyStateView: some View {
        if viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "チャンネルなし",
                systemImage: "tv",
                description: Text("バックエンドに接続してチャンネルを取得してください")
            )
        } else {
            ContentUnavailableView(
                "検索結果なし",
                systemImage: "magnifyingglass",
                description: Text("別のキーワードで試してください")
            )
        }
    }

    @ViewBuilder
    private var listView: some View {
        List {
            ForEach(groupedServices, id: \.0) { channelType, serviceItems in
                Section(channelType) {
                    OutlineGroup(serviceItems, children: \.children) { item in
                        ServiceRowView(
                            service: item.service,
                            currentProgram: item.currentProgram,
                            nextProgram: item.nextProgram,
                            hasDifferentChildProgram: item.hasDifferentChildProgram,
                            isFavorite: manager.isFavorite(item.service),
                            logoImage: manager.logoImage(for: item.service)
                        ) {
                            Task { await playService(item.service) }
                        } onToggleFavorite: {
                            Task { await manager.toggleFavorite(item.service) }
                        }
                    }
                }
            }
        }
    }

    private func playService(_ service: TVService) async {
        let candidates = manager.playbackCandidates(for: service)
        if candidates.count > 1 {
            serviceSelectionForPlayback = service
            return
        }
        await playCandidate(candidates.first ?? service)
    }

    private func playCandidate(_ service: TVService) async {
        guard let provider = manager.liveProvider(for: service.backendId) else { return }
        let currentProgram = await manager.currentProgram(for: service)
        guard
            let playable = try? provider.buildLiveStreamPlayable(
                service: service, currentProgram: currentProgram)
        else {
            return
        }
        #if os(macOS)
            openWindow(id: AppWindowID.player.rawValue, value: playable)
        #else
            playerState.play(playable: playable)
            playerState.startPeriodicRefresh()
        #endif
        serviceSelectionForPlayback = nil
    }

    private func buildServiceDisplayGroups(from services: [TVService]) -> [ServiceDisplayGroup] {
        let grouped = Dictionary(grouping: services, by: displayGroupKey(for:))
        return grouped.compactMap { groupKey, groupedServices in
            let sorted = groupedServices.sorted { lhs, rhs in
                if lhs.serviceId != rhs.serviceId {
                    return lhs.serviceId < rhs.serviceId
                }
                return lhs.name < rhs.name
            }
            guard let primary = sorted.first else { return nil }
            return ServiceDisplayGroup(
                id: groupKey,
                primary: primary,
                secondary: Array(sorted.dropFirst())
            )
        }
        .sorted { lhs, rhs in
            if (lhs.primary.remoteControlKeyId ?? Int.max)
                != (rhs.primary.remoteControlKeyId ?? Int.max)
            {
                return (lhs.primary.remoteControlKeyId ?? Int.max)
                    < (rhs.primary.remoteControlKeyId ?? Int.max)
            }
            if lhs.primary.serviceId != rhs.primary.serviceId {
                return lhs.primary.serviceId < rhs.primary.serviceId
            }
            return lhs.primary.name < rhs.primary.name
        }
    }

    private func displayGroupKey(for service: TVService) -> String {
        switch service.channel?.type {
        case "GR":
            // 区域外再放送などで別な放送局が同じリモコンキー ID を使う可能性があるので、ネットワーク ID とリモコンキー ID で纏める
            return String("\(service.networkId)\(service.remoteControlKeyId ?? -1)")
        case "BS":
            return
                "\(service.channel?.id ?? "\(service.serviceId)")\(service.transportStreamId ?? -1)"
        default:
            return "\(service.serviceId)"
        }
    }

    private func matchesSearch(
        service: TVService, program: Program?, nextProgram: Program?, keyword: String
    ) -> Bool {
        guard !keyword.isEmpty else { return true }

        if service.name.normalizedForJapaneseSearch().contains(keyword) {
            return true
        }

        for candidate in [program, nextProgram] {
            guard let candidate else { continue }
            if candidate.name.normalizedForJapaneseSearch().contains(keyword) {
                return true
            }
            if let desc = candidate.desc, desc.normalizedForJapaneseSearch().contains(keyword) {
                return true
            }
            if let extended = candidate.extended {
                for value in extended.values
                where value.normalizedForJapaneseSearch().contains(keyword) {
                    return true
                }
            }
        }
        return false
    }

    private func isKnownProgram(_ program: Program?) -> Bool {
        guard let name = program?.name.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !name.isEmpty
    }

    private func isSameProgram(_ lhs: Program, _ rhs: Program) -> Bool {
        if let lhsEvent = lhs.eventId, let rhsEvent = rhs.eventId, lhsEvent == rhsEvent {
            return true
        }

        let lhsName = lhs.name.normalizedForJapaneseSearch()
        let rhsName = rhs.name.normalizedForJapaneseSearch()
        guard !lhsName.isEmpty, lhsName == rhsName else { return false }

        let startDiff = abs(lhs.startAt.timeIntervalSince(rhs.startAt))
        let endDiff = abs(lhs.endAt.timeIntervalSince(rhs.endAt))
        return startDiff <= 60 && endDiff <= 60
    }

    @MainActor
    private func triggerRebuild() {
        rebuildTask?.cancel()
        rebuildGeneration += 1
        let generation = rebuildGeneration
        isBuildingList = true
        rebuildTask = Task {
            await buildGroupedServices(generation: generation)
        }
    }

    @MainActor
    private func buildGroupedServices(generation: Int) async {
        if !manager.isCacheReady {
            return
        }
        let keyword = viewModel.searchText.normalizedForJapaneseSearch()
        let currentServices = serviceTypeFilteredServices
        let favoriteServices = currentServices.filter { $0.favoritedAt != nil }
        let grouped = Dictionary(grouping: currentServices) { $0.channel?.type ?? "その他" }
        let order = ["お気に入り", "GR", "BS", "CS", "SKY"]

        var newGroups: [(String, [ServiceListItem])] = []

        // 大量のawaitによるスレッドホップを防ぐため、全サービスの現在の番組情報を一括で取得する
        var programCache: [String: Program] = [:]
        var nextProgramCache: [String: Program] = [:]
        async let allCurrentProgramsTask = manager.fetchAllCurrentPrograms()
        async let allNextProgramsTask = manager.fetchAllNextPrograms()
        let allCurrentPrograms = await allCurrentProgramsTask
        let allNextPrograms = await allNextProgramsTask
        for program in allCurrentPrograms {
            let key = "\(program.networkId)-\(program.serviceId)"
            programCache[key] = program
        }
        for program in allNextPrograms {
            let key = "\(program.networkId)-\(program.serviceId)"
            if nextProgramCache[key] == nil {
                nextProgramCache[key] = program
            }
        }

        // ServiceListItemの生成時に引き当てるためのキーをサービス側でも用意する
        func serviceKey(_ s: TVService) -> String { "\(s.networkId)-\(s.serviceId)" }

        func buildItems(from services: [TVService]) -> [ServiceListItem] {
            let displayGroups = buildServiceDisplayGroups(from: services)

            var items: [ServiceListItem] = []
            for group in displayGroups {
                if Task.isCancelled { return [] }

                var children: [ServiceListItem] = []
                for secondary in group.secondary {
                    if Task.isCancelled { return [] }
                    let program = programCache[serviceKey(secondary)]
                    children.append(
                        ServiceListItem(
                            id: "\(group.id)-\(secondary.id)",
                            service: secondary,
                            currentProgram: program,
                            nextProgram: nextProgramCache[serviceKey(secondary)],
                            hasDifferentChildProgram: false,
                            children: nil
                        ))
                }

                let primaryProgram = programCache[serviceKey(group.primary)]
                let hasDifferentChildProgram: Bool = {
                    guard let primaryProgram, isKnownProgram(primaryProgram) else { return false }
                    for child in children {
                        guard let childProgram = child.currentProgram, isKnownProgram(childProgram)
                        else { continue }
                        if !isSameProgram(primaryProgram, childProgram) {
                            return true
                        }
                    }
                    return false
                }()
                let filteredChildren: [ServiceListItem] =
                    keyword.isEmpty
                    ? children
                    : children.filter {
                        matchesSearch(
                            service: $0.service, program: $0.currentProgram,
                            nextProgram: $0.nextProgram, keyword: keyword)
                    }
                let primaryMatches = matchesSearch(
                    service: group.primary,
                    program: primaryProgram,
                    nextProgram: nextProgramCache[serviceKey(group.primary)],
                    keyword: keyword
                )
                guard keyword.isEmpty || primaryMatches || !filteredChildren.isEmpty else {
                    continue
                }
                items.append(
                    ServiceListItem(
                        id: group.id,
                        service: group.primary,
                        currentProgram: primaryProgram,
                        nextProgram: nextProgramCache[serviceKey(group.primary)],
                        hasDifferentChildProgram: hasDifferentChildProgram,
                        children: filteredChildren.isEmpty ? nil : filteredChildren
                    ))
            }

            return items
        }

        if !favoriteServices.isEmpty {
            let favoriteItems = buildItems(from: favoriteServices)
            if !favoriteItems.isEmpty {
                newGroups.append(("お気に入り", favoriteItems))
            }
        }

        for channelType in grouped.keys.sorted() {
            guard let servicesInType = grouped[channelType] else { continue }
            let items = buildItems(from: servicesInType)
            newGroups.append((channelType, items))
        }

        guard generation == rebuildGeneration else { return }

        self.groupedServices =
            newGroups
            .filter { !$0.1.isEmpty }
            .sorted { a, b in
                let ai = order.firstIndex(of: a.0) ?? order.count
                let bi = order.firstIndex(of: b.0) ?? order.count
                return ai < bi
            }

        isBuildingList = false
        rebuildTask = nil
    }

    @MainActor
    private func startMinuteAlignedRefreshLoop() async {
        while !Task.isCancelled {
            guard
                let nextMinute = Calendar.current.nextDate(
                    after: Date(),
                    matching: DateComponents(second: 0),
                    matchingPolicy: .nextTime
                )
            else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            let wait = max(nextMinute.timeIntervalSinceNow, 0.1)
            try? await Task.sleep(for: .seconds(wait))
            if Task.isCancelled { break }

            await playerState.refreshProgramInfo()
            minuteRefreshTick = Date()
            triggerRebuild()
        }
    }
}

private struct ServiceListTitleModifier: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.navigationTitle("放送中")
        } else {
            content
        }
    }
}

private struct ServiceListSearchableModifier: ViewModifier {
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

struct ServiceRowView: View {
    let service: TVService
    let currentProgram: Program?
    let nextProgram: Program?
    let hasDifferentChildProgram: Bool
    let isFavorite: Bool
    let logoImage: PlatformImage?
    let onTap: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                rowContent
            }
            .buttonStyle(.plain)

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .imageScale(.medium)
                    .foregroundStyle(isFavorite ? .yellow : .secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "お気に入り解除" : "お気に入り追加")
            .help(isFavorite ? "お気に入り解除" : "お気に入り追加")
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let program = currentProgram,
                        !program.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        BroadcastText(program.name)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        if let programDescriptionText = programDescriptionText {
                            BroadcastText(programDescriptionText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text("番組情報なし")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let timeRangeText {
                        Text(timeRangeText)
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    if let nextProgramText {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                            BroadcastText(nextProgramText)
                                .lineLimit(1)
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    HStack(alignment: .center, spacing: 8) {
                        serviceLogoView

                        Text(service.name)
                            .font(.footnote)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if hasDifferentChildProgram {
                            HStack(spacing: 2) {
                                Image(systemName: "rectangle.split.2x1.fill")
                                    .imageScale(.small)
                                Text("サブチャンネル放送中")
                            }
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.16), in: Capsule())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            Spacer(minLength: 0)
        }
    }

    private func swiftUIImage(from image: PlatformImage) -> Image {
        #if canImport(UIKit)
            return Image(uiImage: image)
        #elseif canImport(AppKit)
            return Image(nsImage: image)
        #else
            return Image(systemName: "tv")
        #endif
    }

    private var timeRangeText: String? {
        guard let program = currentProgram else { return nil }
        let start = Self.timeFormatter.string(from: program.startAt)
        if isUnknownEndTime(program) {
            return "\(start) - (終了時刻未定)"
        }
        let end = Self.timeFormatter.string(from: program.endAt)
        return "\(start) - \(end)"
    }

    private var nextProgramText: String? {
        guard let program = nextProgram else { return nil }
        let name = program.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isUnknownEndTime(program) else { return nil }
        let start = Self.timeFormatter.string(from: program.startAt)
        let end = Self.timeFormatter.string(from: program.endAt)
        return "\(start)-\(end) \(name)"
    }

    private func isUnknownEndTime(_ program: Program) -> Bool {
        program.duration <= 0 || program.duration == 604_065 || program.endAt <= program.startAt
    }

    @ViewBuilder
    private var serviceLogoView: some View {
        if let logoImage {
            Color.kiririnSecondarySystemBackground
                .frame(width: 32, height: 24)
                .overlay {
                    swiftUIImage(from: logoImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                .allowsHitTesting(false)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.kiririnTertiarySystemFill)
                .frame(width: 32, height: 24)
                .overlay {
                    Text(service.remoteControlKeyId.map { "\($0)" } ?? "")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var programDescriptionText: String? {
        guard
            let description = currentProgram?.desc?.trimmingCharacters(in: .whitespacesAndNewlines),
            !description.isEmpty
        else { return nil }
        return description.compactedLines
    }
}
