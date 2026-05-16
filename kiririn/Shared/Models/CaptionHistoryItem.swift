import Foundation

nonisolated struct CaptionHistoryItem: Identifiable, Sendable {
    let id: UUID = UUID()
    let text: String
    let time: Double
    let position: Float
    let broadcastTime: Date?
}
