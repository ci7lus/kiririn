#if os(iOS)
    import SwiftUI

    struct PlayerProgramScheduleView: View {
        let service: TVService?
        let manager: ServerManager
        let reservedBottomHeight: CGFloat

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var rows: [PlayerProgramSchedule.Row] = []
        @State private var loadedServiceKey: ProgramServiceKey?
        @State private var selectedProgram: ProgramSelection?
        @State private var isLoading = true

        private struct ReloadKey: Equatable {
            let serviceId: Int?
            let networkId: Int?
            let revision: Int
            let isCacheReady: Bool
        }

        private var reloadKey: ReloadKey {
            ReloadKey(
                serviceId: service?.serviceId,
                networkId: service?.networkId,
                revision: manager.programCatalogRevision,
                isCacheReady: manager.isCacheReady
            )
        }

        var body: some View {
            Group {
                if isLoading && rows.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    ContentUnavailableView("番組情報がありません", systemImage: "calendar")
                } else {
                    List(rows) { row in
                        if let service {
                            Button {
                                selectedProgram = ProgramSelection(
                                    program: row.program, service: service)
                            } label: {
                                programRow(row)
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                            .listRowBackground(
                                row.state == .current ? Color.primary.opacity(0.06) : Color.clear
                            )
                        }
                    }
                    .listStyle(.plain)
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: reservedBottomHeight / 2)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedProgram) { selection in
                ProgramGuideProgramDetailSheetView(selection: selection) {
                    selectedProgram = nil
                }
            }
            .task(id: reloadKey) {
                let serviceKey = service.map {
                    ProgramServiceKey(serviceId: $0.serviceId, networkId: $0.networkId)
                }
                if loadedServiceKey != serviceKey {
                    rows = []
                    loadedServiceKey = serviceKey
                }
                isLoading = rows.isEmpty
                guard let service else {
                    isLoading = false
                    return
                }
                while !Task.isCancelled {
                    let now = Date()
                    let programs = await manager.fetchPlayerSchedulePrograms(
                        for: service, at: now, until: now.addingTimeInterval(24 * 60 * 60))
                    guard !Task.isCancelled else { return }
                    let updatedRows = PlayerProgramSchedule.make(
                        programs: programs, service: service, at: now
                    ).rows
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                        rows = updatedRows
                    }
                    isLoading = false
                    let nextBoundary = rows.flatMap { [$0.program.startAt, $0.program.endAt] }
                        .filter { $0 > now }.min()
                    let delay = min(max(nextBoundary?.timeIntervalSince(now) ?? 60, 0.1), 60)
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                }
            }
        }

        private func programRow(_ row: PlayerProgramSchedule.Row) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.program.name.isEmpty ? "番組情報がありません" : row.program.name)
                    .broadcastFont(.headline, weight: .semibold)
                if let description = row.program.desc, !description.isEmpty {
                    Text(description)
                        .broadcastFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(timeRange(row.program))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .opacity(row.state == .previous ? 0.5 : 1)
            .contentShape(Rectangle())
        }

        private func timeRange(_ program: Program) -> String {
            let start = program.startAt.formatted(
                .dateTime.month().day().weekday(.abbreviated).hour().minute())
            guard program.duration > 0, program.endAt > program.startAt, program.duration != 604_065
            else {
                return "\(start)〜"
            }
            let end = program.endAt.formatted(.dateTime.hour().minute())
            return "\(start)〜\(end)"
        }
    }
#endif
