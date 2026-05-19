import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

#if os(macOS)
    let recordingsAddMenuPlacement: ToolbarItemPlacement = .primaryAction
#else
    let recordingsAddMenuPlacement: ToolbarItemPlacement = .topBarTrailing
#endif

func recordingsImage(from data: Data) -> Image? {
    #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
    #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
    #else
        return nil
    #endif
}

func decodeRecordingsImage(from data: Data) async -> Image? {
    #if canImport(UIKit)
        let image = await Task.detached(priority: .utility) { UIImage(data: data) }.value
        guard let image else { return nil }
        return Image(uiImage: image)
    #elseif canImport(AppKit)
        let image = await Task.detached(priority: .utility) { NSImage(data: data) }.value
        guard let image else { return nil }
        return Image(nsImage: image)
    #else
        return nil
    #endif
}

extension View {
    @ViewBuilder
    fileprivate func recordingsURLTextInputModifiers() -> some View {
        #if os(iOS)
            self.textInputAutocapitalization(.never)
        #else
            self
        #endif
    }
}

extension View {
    func urlTextInputModifiers() -> some View {
        recordingsURLTextInputModifiers()
    }
}

@ViewBuilder
func localRecordRevealContextMenuItem(for item: LocalRecordItem) -> some View {
    #if os(macOS)
        Button("Finderで表示") {
            _ = item.revealInFinder()
        }
        .disabled(item.downloadState != .downloaded)
    #else
        EmptyView()
    #endif
}
