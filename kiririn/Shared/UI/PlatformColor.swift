import SwiftUI

extension Color {
    static var kiririnSystemBackground: Color {
        #if canImport(UIKit)
            return Color(.systemBackground)
        #else
            return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var kiririnSecondarySystemBackground: Color {
        #if canImport(UIKit)
            return Color(.secondarySystemBackground)
        #else
            return Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var kiririnTertiarySystemFill: Color {
        #if canImport(UIKit)
            return Color(.tertiarySystemFill)
        #else
            return Color(nsColor: .quaternaryLabelColor).opacity(0.2)
        #endif
    }

    static var kiririnSecondarySystemFill: Color {
        #if canImport(UIKit)
            return Color(.secondarySystemFill)
        #else
            return Color(nsColor: .quaternaryLabelColor).opacity(0.3)
        #endif
    }

    static var kiririnSystemGroupedBackground: Color {
        #if canImport(UIKit)
            return Color(.systemGroupedBackground)
        #else
            return Color(nsColor: .underPageBackgroundColor)
        #endif
    }

    static var kiririnSeparator: Color {
        #if canImport(UIKit)
            return Color(.separator)
        #else
            return Color(nsColor: .separatorColor)
        #endif
    }

    static var kiririnTertiaryLabel: Color {
        #if canImport(UIKit)
            return Color(.tertiaryLabel)
        #else
            return Color(nsColor: .tertiaryLabelColor)
        #endif
    }
}
