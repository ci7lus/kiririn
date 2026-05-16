import SwiftUI

struct ProgramGuideSearchSheetView: View {
    let manager: BackendManager
    @Binding var sheetSearchText: String
    @Binding var searchQueryResults: [ProgramSearchResult]
    @Binding var searchScrollRestoreID: ProgramSearchResult.ID?
    @Binding var shouldRestoreSearchScrollOnNextPresentation: Bool
    @Binding var hasRestoredSearchScrollInCurrentPresentation: Bool
    let searchFieldFocused: FocusState<Bool>.Binding
    let onSelectResult: (ProgramSearchResult) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if os(macOS)
                    macSearchHeader
                    Divider()
                #endif

                Group {
                    if searchQueryResults.isEmpty {
                        searchEmptyStateView
                    } else {
                        ScrollViewReader { proxy in
                            List(searchQueryResults) { result in
                                Button {
                                    onSelectResult(result)
                                } label: {
                                    searchResultRow(result)
                                }
                                .buttonStyle(.plain)
                            }
                            .onAppear {
                                restoreSearchScrollIfNeeded(using: proxy)
                            }
                            #if os(macOS)
                                .listStyle(.inset(alternatesRowBackgrounds: true))
                            #else
                                .listStyle(.plain)
                            #endif
                        }
                    }
                }
            }
            .navigationTitle("番組検索")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $sheetSearchText, prompt: "番組名 / チャンネル名")
                .focused(searchFieldFocused)
            #endif
            .task(id: sheetSearchText) {
                await performDebouncedSearch()
            }
            .toolbar {
                #if os(macOS)
                    ToolbarItem(placement: .automatic) {
                        Button("閉じる") { onClose() }
                    }
                #else
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { onClose() }
                    }
                #endif
            }
        }
        #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #elseif os(macOS)
            .frame(minWidth: 560, minHeight: 460)
        #endif
    }

    #if os(macOS)
        private var macSearchHeader: some View {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("番組名 / チャンネル名", text: $sheetSearchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.kiririnSecondarySystemBackground)
        }
    #endif

    @ViewBuilder
    private func searchResultRow(_ result: ProgramSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            BroadcastText(result.program.name)
                .font(.body.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                BroadcastText(result.service.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("•")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text(
                    "\(result.program.startAt.formatted(.displayDateTime)) - \(result.program.endAt.formatted(.displayTime))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(macOS)
            .padding(.vertical, 6)
        #else
            .padding(.vertical, 2)
        #endif
    }

    private func restoreSearchScrollIfNeeded(using proxy: ScrollViewProxy) {
        guard let id = searchScrollRestoreID,
            searchQueryResults.contains(where: { $0.id == id }),
            shouldRestoreSearchScrollOnNextPresentation,
            !hasRestoredSearchScrollInCurrentPresentation
        else { return }

        hasRestoredSearchScrollInCurrentPresentation = true
        shouldRestoreSearchScrollOnNextPresentation = false

        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func performDebouncedSearch() async {
        let query = sheetSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchQueryResults = []
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }

        let servicesByCompositeKey = Dictionary(
            uniqueKeysWithValues: manager.services.map { service in
                ("\(service.backendId)-\(service.networkId)-\(service.serviceId)", service)
            }
        )

        let programs = await manager.searchCachedPrograms(query: query, limit: 200)
        guard !Task.isCancelled else { return }

        searchQueryResults = programs.compactMap { program in
            let key = "\(program.backendId)-\(program.networkId)-\(program.serviceId)"
            guard let service = servicesByCompositeKey[key] else { return nil }
            return ProgramSearchResult(program: program, service: service)
        }
    }

    @ViewBuilder
    private var searchEmptyStateView: some View {
        #if os(macOS)
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("検索結果なし")
                    .font(.title3.weight(.semibold))
                Text(sheetSearchText.isEmpty ? "番組名・チャンネル名で検索" : "条件に一致する番組がありません")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
            ContentUnavailableView(
                "検索結果なし",
                systemImage: "magnifyingglass",
                description: Text(sheetSearchText.isEmpty ? "番組名・チャンネル名で検索" : "条件に一致する番組がありません")
            )
        #endif
    }
}
