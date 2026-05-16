import Foundation

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

@MainActor
func copyTextToClipboard(_ text: String) {
    #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    #elseif os(iOS)
        UIPasteboard.general.string = text
    #endif
}
