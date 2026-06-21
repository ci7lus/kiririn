import SwiftUI

@ViewBuilder
func programGuideCurrentTimeControl(
    timelineOffsetHours: Int,
    onActivate: @escaping () -> Void
) -> some View {
    #if os(macOS)
        Button {
            onActivate()
        } label: {
            Label("現在", systemImage: "clock.arrow.circlepath")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.trailing, 8)
        .help("現在の時刻にスクロール")
    #else
        let _ = timelineOffsetHours
        EmptyView()
    #endif
}

@ViewBuilder
func programGuideServiceLogo(for service: TVService, manager: BackendManager) -> some View {
    if let image = manager.logoImage(for: service) {
        #if canImport(UIKit)
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 20)
        #elseif canImport(AppKit)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 20)
        #endif
    } else {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.kiririnTertiarySystemFill)
            .frame(width: 28, height: 20)
    }
}

@MainActor
func programGuideRestoreSearchSheetPresentation(
    setPresented: @escaping () -> Void
) async {
    #if os(iOS)
        try? await Task.sleep(nanoseconds: 120_000_000)
    #endif
    setPresented()
}

func programGuideStartPlayback(
    _ playable: Playable,
    playerState: PlayerState,
    openWindow: ((Playable) -> Void)?
) {
    if let openWindow {
        openWindow(playable)
    } else {
        playerState.play(playable: playable)
        playerState.startPeriodicRefresh()
    }
}
