import Foundation

struct ProgramSelection: Identifiable {
    let program: Program
    let service: TVService

    var id: String { program.id }
}

struct GuideChannel: Identifiable, Equatable {
    let id: String
    let service: TVService
    let programs: [Program]

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.service.contentSnapshot == rhs.service.contentSnapshot
            && lhs.programs == rhs.programs
    }
}

struct ProgramSearchResult: Identifiable {
    let program: Program
    let service: TVService

    var id: String { "\(service.id)-\(program.id)" }
}
