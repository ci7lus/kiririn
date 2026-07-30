import Foundation

nonisolated enum BMLKeyGroup: String, Codable, Hashable, Sendable {
    case basic
    case numericTuning = "numeric-tuning"
    case dataButton = "data-button"
}

nonisolated enum ARIBRemoteKey: Int, Codable, Hashable, Sendable {
    case up = 1
    case down = 2
    case left = 3
    case right = 4
    case digit0 = 5
    case digit1 = 6
    case digit2 = 7
    case digit3 = 8
    case digit4 = 9
    case digit5 = 10
    case digit6 = 11
    case digit7 = 12
    case digit8 = 13
    case digit9 = 14
    case digit10 = 15
    case digit11 = 16
    case digit12 = 17
    case enter = 18
    case back = 19
    case data = 20
    case blue = 21
    case red = 22
    case green = 23
    case yellow = 24
    case reserved25 = 25
    case reserved26 = 26
    case special = 100

    var requiredGroup: BMLKeyGroup? {
        switch self {
        case .up, .down, .left, .right, .enter, .back:
            .basic
        case .digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6,
            .digit7, .digit8, .digit9, .digit10, .digit11, .digit12:
            .numericTuning
        case .data:
            nil
        case .blue, .red, .green, .yellow, .reserved25, .reserved26, .special:
            .dataButton
        }
    }

    static func digit(_ number: Int) -> ARIBRemoteKey? {
        guard (0...12).contains(number) else { return nil }
        return ARIBRemoteKey(rawValue: number + 5)
    }
}
