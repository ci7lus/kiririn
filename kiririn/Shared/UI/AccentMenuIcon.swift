import SwiftUI

// SwiftUI で Menu にネストした Image に色がつかない Workaround

#if canImport(UIKit) && !os(macOS)
    import UIKit
#endif

@ViewBuilder
func accentMenuIcon(systemName: String) -> some View {
    #if canImport(UIKit) && !os(macOS)
        let accentColor = UIColor(named: "AccentColor") ?? .tintColor
        if let image = UIImage(systemName: systemName)?
            .withTintColor(accentColor, renderingMode: .alwaysOriginal)
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
