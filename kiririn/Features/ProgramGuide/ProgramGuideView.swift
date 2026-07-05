import OrderedCollections
import SwiftUI

struct ProgramGuideView: View {
    let manager: ServerManager
    @State var playerState: PlayerState
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    @State private var selectedBroadcastType = "all"
    @State private var isSearchSheetPresented = false
    @State private var sheetSearchText = ""
    @State private var pendingProgramSelection: ProgramSelection? = nil
    @State private var shouldRestoreSearchSheetAfterProgramDismiss = false
    @State private var shouldRestoreSearchScrollOnNextPresentation = false
    @State private var searchScrollRestoreID: ProgramSearchResult.ID? = nil
    @State private var hasRestoredSearchScrollInCurrentPresentation = false
    @State private var searchQueryResults: [ProgramSearchResult] = []
    @State private var isLoading = false
    @State private var hasAttemptedLoad = false
    @State private var channels: [GuideChannel] = []
    @State private var timelineOffsetHours = 0
    @State private var nowLineDate = Date()
    @State private var displayChannels: [GuideChannel] = []
    @State private var scrollPosition = ScrollPosition()
    @State private var viewportHeight: CGFloat = 600
    @State private var viewportWidth: CGFloat = 0
    @State private var offsetTracker = HorizontalOffsetTracker()
    @State private var horizontalScrollResetToken = 0
    @State private var horizontalScrollController = ProgramGuideHorizontalScrollController()
    @State private var selectedProgram: ProgramSelection? = nil
    @State private var serviceSelectionForPlayback: TVService? = nil
    @State private var lastAnchorTime: Date? = nil
    @FocusState private var isSearchFieldFocused: Bool
    @Namespace private var glassNamespace

    private let channelColumnWidth: CGFloat = 220
    private let timeRulerWidth: CGFloat = 45
    private let minuteHeight: CGFloat = 2.5
    private let timelineHours = 24
    private let minimumPastDays = -1
    private let maximumFutureDays = 7
    private let favoriteBroadcastType = "favorites"
    private let horizontalScrollLeadingAnchorID = "programGuideHorizontalLeadingAnchor"

    #if os(macOS)
        private var openPlayerWindow: ((Playable) -> Void) {
            { playable in
                openWindow(id: AppWindowID.player.rawValue, value: playable)
            }
        }
    #endif

    private var programGuideOpenWindowAction: ((Playable) -> Void)? {
        #if os(macOS)
            openPlayerWindow
        #else
            nil
        #endif
    }

    private var anchorTime: Date {
        anchorTime(for: nowLineDate)
    }

    private func anchorTime(for referenceDate: Date) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour], from: referenceDate)
        if let hour = components.hour, hour < 4 {
            let yesterday =
                calendar.date(byAdding: .day, value: -1, to: referenceDate) ?? referenceDate
            components = calendar.dateComponents([.year, .month, .day], from: yesterday)
        }
        components.hour = 4
        components.minute = 0
        components.second = 0
        return calendar.date(from: components) ?? referenceDate
    }

    private var timelineStart: Date {
        Calendar.current.date(byAdding: .hour, value: timelineOffsetHours, to: anchorTime)
            ?? anchorTime
    }

    private var timelineEnd: Date {
        Calendar.current.date(byAdding: .hour, value: timelineHours, to: timelineStart)
            ?? timelineStart
    }

    private var timelineHeight: CGFloat {
        CGFloat(timelineHours * 60) * minuteHeight
    }

    private var contentWidth: CGFloat {
        timeRulerWidth + CGFloat(displayChannels.count) * channelColumnWidth
    }

    private var nowLineYOffset: CGFloat {
        let deltaMinutes = nowLineDate.timeIntervalSince(anchorTime) / 60.0
        return CGFloat(deltaMinutes) * minuteHeight
    }

    private var dateOffsets: [Int] {
        Array(
            stride(from: minimumPastDays * 24, through: maximumFutureDays * 24, by: timelineHours))
    }

    init(manager: ServerManager, playerState: PlayerState) {
        self.manager = manager
        self._playerState = State(initialValue: playerState)
    }

    var body: some View {
        GeometryReader { geo in
            mainView()
                .safeAreaInset(edge: .top, spacing: 0) {
                    controlsView()
                }
                .onAppear {
                    viewportWidth = geo.size.width
                }
                .onChange(of: geo.size.width) { _, newValue in
                    viewportWidth = newValue
                }
                .onAppear {
                    let currentDate = Date()
                    nowLineDate = currentDate
                    lastAnchorTime = anchorTime(for: currentDate)
                    if manager.hasFavoriteServices {
                        selectedBroadcastType = favoriteBroadcastType
                    }
                    updateDisplayChannels()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        scrollToNow(animated: false)
                    }
                }
                .programGuideTitle()
                .task {
                    await reloadPrograms()
                    updateDisplayChannels()
                }
                .onChange(of: channels) { _, _ in updateDisplayChannels() }
                .onChange(of: manager.isCacheReady) { _, isReady in
                    guard isReady else { return }
                    Task {
                        await reloadPrograms()
                        updateDisplayChannels()
                    }
                }
                .onChange(of: manager.services) { _, _ in
                    if selectedBroadcastType == favoriteBroadcastType
                        && !manager.hasFavoriteServices
                    {
                        selectedBroadcastType = "all"
                    }
                    Task {
                        await reloadPrograms()
                        updateDisplayChannels()
                    }
                }
                .onChange(of: timelineOffsetHours) { _, _ in
                    Task {
                        await reloadPrograms()
                        updateDisplayChannels()
                    }
                }
                .onChange(of: selectedBroadcastType) { _, _ in
                    updateDisplayChannels()
                    horizontalScrollResetToken &+= 1
                }
                .task {
                    await runCurrentTimeUpdates()
                }
                .programGuideRefreshable {
                    await reloadPrograms()
                    updateDisplayChannels()
                }
        }
        .programGuidePlatformActions(
            isSearchSheetPresented: $isSearchSheetPresented,
            timelineOffsetHours: $timelineOffsetHours,
            onScrollToNow: {
                scrollToNow(animated: true)
            },
            glassNamespace: glassNamespace
        )
        .sheet(
            isPresented: $isSearchSheetPresented,
            onDismiss: {
                if let pending = pendingProgramSelection {
                    pendingProgramSelection = nil
                    selectedProgram = pending
                }
            },
            content: {
                searchSheetView
            }
        )
        .onChange(of: isSearchSheetPresented) { _, newValue in
            if newValue {
                hasRestoredSearchScrollInCurrentPresentation = false
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { @MainActor in
                await refreshCurrentTime()
            }
        }
        .sheet(
            item: $selectedProgram,
            onDismiss: {
                guard shouldRestoreSearchSheetAfterProgramDismiss else { return }
                shouldRestoreSearchSheetAfterProgramDismiss = false
                Task { @MainActor in
                    await programGuideRestoreSearchSheetPresentation {
                        isSearchSheetPresented = true
                    }
                }
            },
            content: { selection in
                ProgramGuideProgramDetailSheetView(
                    selection: selection,
                    onClose: { selectedProgram = nil }
                )
            }
        )
    }

    @ViewBuilder
    private func mainView() -> some View {
        if isLoading && channels.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayChannels.isEmpty {
            ContentUnavailableView(
                "番組情報がありません",
                systemImage: "calendar",
                description: Text("番組情報があると、ここに表示されます")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        Section {
                            gridSectionContent
                        } header: {
                            headerSectionContent
                        }
                    }
                    .programGuideHorizontalScrollController(horizontalScrollController)
                }
                .coordinateSpace(name: "guideScroll")
                .scrollPosition($scrollPosition)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.containerSize.height
                } action: { _, new in
                    viewportHeight = new
                }
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.x
                } action: { _, new in
                    offsetTracker.horizontalOffset = new
                }
                .onChange(of: horizontalScrollResetToken) { _, _ in
                    resetHorizontalScrollPosition(proxy: proxy)
                }
                .background(Color.kiririnSystemBackground)
            }
        }
    }

    @ViewBuilder
    private var headerSectionContent: some View {
        HStack(spacing: 0) {
            // 左上角：「時刻」ラベル（水平方向のみ固定、垂直方向は Sticky）
            Rectangle()
                .fill(Color.kiririnSecondarySystemBackground)
                .frame(width: timeRulerWidth, height: 52)
                .overlay {
                    Text("時刻").font(.caption).foregroundStyle(.secondary)
                }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.kiririnSeparator.opacity(0.6)).frame(width: 1)
                }
                .visualEffect { content, geometryProxy in
                    // 左端オーバースクロール時にルーラーが飛ばないよう x を 0 以下にクランプ
                    let scrollX = min(0, geometryProxy.frame(in: .named("guideScroll")).minX)
                    return content.offset(x: -scrollX)
                }
                .zIndex(3000)

            HStack(spacing: 0) {
                ForEach(displayChannels) { channel in
                    serviceHeaderCell(for: channel.service)
                        .id(channel.id)
                }
            }
            // チャンネル数がビューポートを埋めない場合の右側余白
            Color.kiririnSecondarySystemBackground
                .frame(width: max(0, viewportWidth - contentWidth), height: 52)
        }
        .background(Color.kiririnSecondarySystemBackground)
    }

    @ViewBuilder
    private var gridSectionContent: some View {
        HStack(alignment: .top, spacing: 0) {
            // 時刻ルーラー（水平方向のみ固定、垂直方向はスクロール）
            timeRuler
                .id(horizontalScrollLeadingAnchorID)
                .visualEffect { content, geometryProxy in
                    let scrollX = min(0, geometryProxy.frame(in: .named("guideScroll")).minX)
                    return content.offset(x: -scrollX)
                }
                .zIndex(1500)

            ZStack(alignment: .topLeading) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(displayChannels) { channel in
                        ProgramChannelColumnView(
                            channelId: channel.id,
                            programs: channel.programs,
                            timelineStart: timelineStart,
                            timelineEnd: timelineEnd,
                            minuteHeight: minuteHeight,
                            width: channelColumnWidth,
                            totalHeight: timelineHeight,
                            onProgramTapped: { program in
                                selectedProgram = ProgramSelection(
                                    program: program, service: channel.service)
                            }
                        )
                        .equatable()
                        .id(channel.id)
                    }
                }
                if nowLineYOffset >= 0 && nowLineYOffset < timelineHeight {
                    Rectangle()
                        .fill(Color.accentColor)
                        .opacity(timelineOffsetHours == 0 ? 1.0 : 0.5)
                        .frame(width: max(viewportWidth, contentWidth) - timeRulerWidth, height: 3)
                        .offset(y: nowLineYOffset - 1.5)
                        .allowsHitTesting(false)
                        .zIndex(1800)
                }
            }
        }
    }

    @ViewBuilder
    private func controlsView() -> some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(dateOffsets, id: \.self) { offset in
                            dateChipButton(for: offset)
                                .id(offset)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity)
                .onChange(of: timelineOffsetHours) { _, new in
                    withAnimation { proxy.scrollTo(new, anchor: .center) }
                }
                .onAppear {
                    proxy.scrollTo(timelineOffsetHours, anchor: .center)
                }
            }

            Divider()
                .padding(.vertical, 10)

            Picker("絞り込み", selection: $selectedBroadcastType) {
                ForEach(broadcastFilterOptions, id: \.id) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            .padding(.horizontal, 8)
            .help("放送種別を絞り込む")

            programGuideCurrentTimeControl(timelineOffsetHours: timelineOffsetHours) {
                if timelineOffsetHours != 0 {
                    timelineOffsetHours = 0
                }
                scrollToNow(animated: true)
            }
        }
        .frame(height: 52)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func dateChipButton(for offset: Int) -> some View {
        let label = dateChipLabel(for: offset)
        let isSelected = timelineOffsetHours == offset

        Button {
            timelineOffsetHours = offset
        } label: {
            Text(label)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    isSelected ? Color.accentColor : Color.kiririnSecondarySystemBackground,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func dateChipLabel(for offset: Int) -> String {
        let date =
            Calendar.current.date(byAdding: .hour, value: offset, to: anchorTime) ?? anchorTime
        switch offset / timelineHours {
        case -1: return "昨日 \(Self.monthDayFormatter.string(from: date))"
        case 0: return "今日 \(Self.monthDayFormatter.string(from: date))"
        case 1: return "明日 \(Self.monthDayFormatter.string(from: date))"
        default:
            return
                "\(Self.monthDayFormatter.string(from: date))"
        }
    }

    @MainActor
    private func runCurrentTimeUpdates() async {
        await refreshCurrentTime()

        while !Task.isCancelled {
            let now = Date()
            let nextUpdate = nextMinuteBoundary(after: now)
            let sleepInterval = max(nextUpdate.timeIntervalSince(now), 0.001)
            let sleepNanoseconds = UInt64((sleepInterval * 1_000_000_000).rounded(.up))

            do {
                try await Task.sleep(nanoseconds: sleepNanoseconds)
            } catch {
                return
            }

            await refreshCurrentTime()
        }
    }

    @MainActor
    private func refreshCurrentTime(at date: Date = Date()) async {
        nowLineDate = date

        let currentAnchorTime = anchorTime(for: date)
        if let lastAnchorTime, currentAnchorTime != lastAnchorTime {
            self.lastAnchorTime = currentAnchorTime
            await reloadPrograms()
            updateDisplayChannels()
        } else if lastAnchorTime == nil {
            lastAnchorTime = currentAnchorTime
        }
    }

    private func nextMinuteBoundary(after date: Date) -> Date {
        Calendar.current.dateInterval(of: .minute, for: date)?.end ?? date.addingTimeInterval(60)
    }

    private func scrollToNow(animated: Bool) {
        let now = Date()
        let maxX = max(contentWidth - viewportWidth, 0)
        let x = min(max(offsetTracker.horizontalOffset, 0), maxX)

        func updateScrollPosition(toY y: CGFloat) {
            if maxX > 0 {
                scrollPosition = ScrollPosition(x: x, y: y)
            } else {
                scrollPosition = ScrollPosition(y: y)
            }
        }

        let sectionHeaderHeight: CGFloat = 52
        if now >= timelineStart && now < timelineEnd {
            let targetY = max(0, sectionHeaderHeight + yOffset(for: now) - viewportHeight * 0.2)
            if animated {
                withAnimation { updateScrollPosition(toY: targetY) }
            } else {
                updateScrollPosition(toY: targetY)
            }
        } else {
            if animated {
                withAnimation { updateScrollPosition(toY: 0) }
            } else {
                updateScrollPosition(toY: 0)
            }
        }
    }

    private func resetHorizontalScrollPosition(proxy: ScrollViewProxy) {
        offsetTracker.horizontalOffset = 0
        #if os(iOS)
            horizontalScrollController.scrollToLeading(animated: true)
        #else
            withAnimation {
                proxy.scrollTo(horizontalScrollLeadingAnchorID)
            }
        #endif
    }

    private func updateDisplayChannels() {
        displayChannels =
            channels
            .filter { channel in
                if selectedBroadcastType == "all" {
                    return true
                }
                if selectedBroadcastType == favoriteBroadcastType {
                    return manager.isFavorite(channel.service)
                }
                return (channel.service.channel?.type ?? "その他") == selectedBroadcastType
            }
            .compactMap { channel in
                guard !channel.programs.isEmpty else { return nil }
                return GuideChannel(
                    id: channel.id, service: channel.service, programs: channel.programs)
            }

        // サーバー切断等でお気に入りチャンネルの番組が取得できない場合は「すべて」にフォールバック
        if displayChannels.isEmpty && selectedBroadcastType == favoriteBroadcastType
            && hasAttemptedLoad
        {
            selectedBroadcastType = "all"
            displayChannels = channels.compactMap { channel in
                guard !channel.programs.isEmpty else { return nil }
                return GuideChannel(
                    id: channel.id, service: channel.service, programs: channel.programs)
            }
        }
    }

    @ViewBuilder
    private var searchSheetView: some View {
        ProgramGuideSearchSheetView(
            manager: manager,
            sheetSearchText: $sheetSearchText,
            searchQueryResults: $searchQueryResults,
            searchScrollRestoreID: $searchScrollRestoreID,
            shouldRestoreSearchScrollOnNextPresentation:
                $shouldRestoreSearchScrollOnNextPresentation,
            hasRestoredSearchScrollInCurrentPresentation:
                $hasRestoredSearchScrollInCurrentPresentation,
            searchFieldFocused: $isSearchFieldFocused,
            onSelectResult: { result in
                searchScrollRestoreID = result.id
                closeSearchSheet(
                    selecting: ProgramSelection(program: result.program, service: result.service)
                )
            },
            onClose: {
                closeSearchSheet()
            }
        )
    }

    private func closeSearchSheet(selecting selection: ProgramSelection? = nil) {
        pendingProgramSelection = selection
        shouldRestoreSearchSheetAfterProgramDismiss = (selection != nil)
        shouldRestoreSearchScrollOnNextPresentation = (selection != nil)
        isSearchFieldFocused = false
        Task { @MainActor in
            #if os(iOS)
                try? await Task.sleep(nanoseconds: 120_000_000)
            #endif
            isSearchSheetPresented = false
        }
    }

    @ViewBuilder
    private func serviceHeaderCell(for service: TVService) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await playService(service) }
            } label: {
                HStack(spacing: 8) {
                    programGuideServiceLogo(for: service, manager: manager)
                    Text(service.name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .playbackServerSelectionDialog(
                service: service,
                selectedService: $serviceSelectionForPlayback,
                manager: manager,
                onSelect: { candidate in
                    Task { await playCandidate(candidate) }
                }
            )

            favoriteButton(for: service)
        }
        .padding(.horizontal, 10)
        .frame(width: channelColumnWidth, height: 52, alignment: .leading)
        .background(Color.kiririnSecondarySystemBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.kiririnSeparator.opacity(0.6))
                .frame(width: 1)
        }
    }

    private var timeRuler: some View {
        let markers = timeMarkers()

        return VStack(spacing: 0) {
            ForEach(markers, id: \.self) { mark in
                let isHour = Calendar.current.component(.minute, from: mark) == 0

                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.kiririnSeparator.opacity(isHour ? 0.65 : 0.3))
                        .frame(height: 1)

                    if isHour {
                        VStack(alignment: .center, spacing: 0) {
                            Text(Self.hourFormatter.string(from: mark))
                                .font(.title3)
                                .fontWeight(.bold)
                                .monospacedDigit()
                            Text("時")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 8)
                        .padding(.top, 4)
                    }
                }
                .frame(width: timeRulerWidth, height: 30 * minuteHeight, alignment: .topLeading)
                .background(Color.kiririnSecondarySystemBackground)
            }
        }
    }

    private var broadcastFilterOptions: [(id: String, name: String)] {
        let types = Set(channels.map { $0.service.channel?.type ?? "その他" })
        let ordered = ["GR", "BS", "CS", "SKY", "CATV"]
        let sortedTypes = types.sorted { lhs, rhs in
            let li = ordered.firstIndex(of: lhs) ?? ordered.count
            let ri = ordered.firstIndex(of: rhs) ?? ordered.count
            if li != ri { return li < ri }
            return lhs < rhs
        }

        var options: [(id: String, name: String)] = []
        if manager.hasFavoriteServices || selectedBroadcastType == favoriteBroadcastType {
            options.append((favoriteBroadcastType, "お気に入り"))
        }
        options.append(("all", "すべて"))
        options.append(contentsOf: sortedTypes.map { ($0, broadcastTypeDisplayName($0)) })
        return options
    }

    private func reloadPrograms() async {
        defer { hasAttemptedLoad = true }
        guard manager.isCacheReady else {
            channels = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        // @MainActor 上でスナップショットを取ってから await へ進む
        let fetchStart = timelineStart
        let fetchEnd = timelineEnd
        let allServices = manager.services

        // GRDB の async read: バックグラウンドスレッドで実行され主アクターは解放される
        let fetchedPrograms = await manager.fetchCachedPrograms(from: fetchStart, until: fetchEnd)

        // ソート・辞書構築・重複除去は CPU を消費するため主アクターから切り離して実行
        let result = await Task.detached(priority: .userInitiated) {
            Self.buildChannels(
                services: allServices,
                programs: fetchedPrograms,
                timelineStart: fetchStart,
                timelineEnd: fetchEnd
            )
        }.value

        channels = result
    }

    /// ソート・グルーピング・重複除去をメインアクター外で行うための純粋な変換関数。
    /// 引数はすべて Sendable な値型のため Task.detached から安全に呼び出せる。
    private nonisolated static func buildChannels(
        services: [TVService],
        programs: [Program],
        timelineStart: Date,
        timelineEnd: Date
    ) -> [GuideChannel] {
        let typeOrder = ["GR", "BS", "CS", "SKY"]
        let sorted =
            services
            .sorted { lhs, rhs in
                let lhsFavorite = lhs.favoritedAt != nil
                let rhsFavorite = rhs.favoritedAt != nil
                if lhsFavorite != rhsFavorite { return lhsFavorite }

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

        let serviceByKey = Dictionary(
            uniqueKeysWithValues: sorted.map { ("\($0.networkId)-\($0.serviceId)", $0) })
        var groupedPrograms: [String: [Program]] = [:]

        for program in programs {
            let trimmedName = program.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty { continue }
            let key = "\(program.networkId)-\(program.serviceId)"
            guard serviceByKey[key] != nil else { continue }
            // タイムライン重複チェック（インライン展開）
            let clipStart = max(program.startAt, timelineStart)
            let clipEnd = min(
                program.endAt > program.startAt ? program.endAt : timelineEnd, timelineEnd)
            guard clipEnd > clipStart else { continue }
            groupedPrograms[key, default: []].append(program)
        }

        // 各物理放送局のメインサービス番組を収集（サブチャンネル重複フィルタ用）
        var mainProgramsByBroadcaster: [String: [Program]] = [:]
        for service in sorted {
            let broadcasterKey =
                "\(service.networkId)-\(service.remoteControlKeyId ?? service.serviceId)"
            let serviceKey = "\(service.networkId)-\(service.serviceId)"
            let isMain =
                sorted
                .filter {
                    $0.networkId == service.networkId
                        && $0.remoteControlKeyId == service.remoteControlKeyId
                }
                .map(\.serviceId).min() == service.serviceId
            if isMain {
                mainProgramsByBroadcaster[broadcasterKey] = groupedPrograms[serviceKey]
            }
        }

        return sorted.compactMap { service in
            let key = "\(service.networkId)-\(service.serviceId)"
            let broadcasterKey =
                "\(service.networkId)-\(service.remoteControlKeyId ?? service.serviceId)"
            let isMain =
                sorted
                .filter {
                    $0.networkId == service.networkId
                        && $0.remoteControlKeyId == service.remoteControlKeyId
                }
                .map(\.serviceId).min() == service.serviceId

            var grouped = groupedPrograms[key, default: []]
                .sorted { $0.startAt != $1.startAt ? $0.startAt < $1.startAt : $0.name < $1.name }

            if !isMain, let mainPrograms = mainProgramsByBroadcaster[broadcasterKey] {
                grouped = grouped.filter { sub in
                    !mainPrograms.contains {
                        $0.startAt == sub.startAt && $0.endAt == sub.endAt && $0.name == sub.name
                    }
                }
            }

            guard !grouped.isEmpty else { return nil }
            return GuideChannel(id: key, service: service, programs: grouped)
        }
    }

    private func yOffset(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(timelineStart) / 60.0) * minuteHeight
    }

    private func timeMarkers() -> [Date] {
        var markers: [Date] = []
        let calendar = Calendar(identifier: .gregorian)
        var cursor = timelineStart
        while cursor < timelineEnd {
            markers.append(cursor)
            cursor =
                calendar.date(byAdding: .minute, value: 30, to: cursor)
                ?? timelineEnd.addingTimeInterval(1)
        }
        return markers
    }

    @ViewBuilder
    private func favoriteButton(for service: TVService) -> some View {
        let isFavorite = manager.isFavorite(service)

        Button {
            Task { await manager.toggleFavorite(service) }
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .imageScale(.medium)
                .foregroundStyle(isFavorite ? .yellow : .secondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "お気に入り解除" : "お気に入り追加")
        .help(isFavorite ? "お気に入り解除" : "お気に入り追加")
    }

    private func broadcastTypeDisplayName(_ type: String) -> String {
        switch type {
        case "all": return "すべて"
        case favoriteBroadcastType: return "お気に入り"
        case "GR": return "地デジ"
        case "BS": return "BS"
        case "CS": return "CS"
        case "SKY": return "SKY"
        case "CATV": return "CATV"
        default: return type
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
        guard let provider = manager.liveProvider(for: service.serverId) else { return }
        let currentProgram = await manager.currentProgram(for: service)
        guard
            let playable = try? provider.buildLiveStreamPlayable(
                service: service, currentProgram: currentProgram)
        else {
            return
        }
        programGuideStartPlayback(
            playable,
            playerState: playerState,
            openWindow: programGuideOpenWindowAction
        )
    }

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "HH"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d(EEE)"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d (EEE)"
        return formatter
    }()
}
