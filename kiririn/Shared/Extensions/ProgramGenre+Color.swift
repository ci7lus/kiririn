import ARIBStandardKit
import SwiftUI

extension ProgramGenre {
    var genreColor: Color {
        switch lv1 {
        case 0x0: return .blue
        case 0x1: return .green
        case 0x2: return .yellow
        case 0x3: return .pink
        case 0x4: return .purple
        case 0x5: return .orange
        case 0x6: return .indigo
        case 0x7: return .red
        case 0x8: return .teal
        case 0x9: return .pink
        case 0xA: return .green
        case 0xB: return .teal
        default: return .gray
        }
    }
}
