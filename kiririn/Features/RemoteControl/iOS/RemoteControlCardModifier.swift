#if os(iOS)
    import SwiftUI

    struct RemoteControlCardModifier: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    extension View {
        func remoteControlCard() -> some View {
            modifier(RemoteControlCardModifier())
        }
    }
#endif
