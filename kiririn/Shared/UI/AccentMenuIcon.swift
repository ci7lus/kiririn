import SwiftUI

// SwiftUI で Menu にネストした Image に色がつかない Workaround

#if canImport(UIKit) && !os(macOS)
    import UIKit

    @MainActor
    private enum AccentMenuIconResources {
        static let accentColor = UIColor(named: "AccentColor") ?? .tintColor
    }
#endif

@ViewBuilder
func accentMenuIcon(systemName: String) -> some View {
    #if canImport(UIKit) && !os(macOS)
        if let image = UIImage(systemName: systemName)?
            .withTintColor(AccentMenuIconResources.accentColor, renderingMode: .alwaysOriginal)
        {
            Image(uiImage: image)
                .renderingMode(.original)
        } else {
            Image(systemName: systemName)
        }
    #else
        Image(systemName: systemName)
            .foregroundStyle(Color.accentColor)
    #endif
}
