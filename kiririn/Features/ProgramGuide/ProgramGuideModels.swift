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
}

struct ProgramSearchResult: Identifiable {
    let program: Program
    let service: TVService

    var id: String { "\(service.id)-\(program.id)" }
}
