import Foundation

@MainActor
final class ServiceListRefreshState {
    var rebuildTask: Task<Void, Never>?
    var rebuildGeneration = 0
    var latestSnapshot: ProgramDisplaySnapshot?
}
