import Foundation

nonisolated struct PlayerProgramSchedule {
    enum State: Equatable {
        case previous
        case current
        case upcoming
    }

    struct Row: Identifiable {
        let program: Program
        let state: State

        var id: String { program.id }
    }

    let rows: [Row]

    static func make(programs: [Program], service: TVService, at now: Date) -> Self {
        let sorted = programs.filter {
            $0.serviceId == service.serviceId && $0.networkId == service.networkId
        }.sorted { $0.startAt < $1.startAt }
        let past = sorted.filter { $0.startAt <= now }
        let latest = past.last
        let current = latest.flatMap { program in
            program.duration <= 0 || program.duration == 604_065
                || program.endAt <= program.startAt || program.endAt > now ? program : nil
        }
        let previous = current == nil ? latest : past.dropLast().last
        let limit = now.addingTimeInterval(24 * 60 * 60)
        var rows: [Row] = []
        if let previous {
            rows.append(Row(program: previous, state: .previous))
        }
        if let current {
            rows.append(Row(program: current, state: .current))
        }
        rows.append(
            contentsOf: sorted.lazy.filter { $0.startAt > now && $0.startAt < limit }.map {
                Row(program: $0, state: .upcoming)
            })
        return Self(rows: rows)
    }
}
