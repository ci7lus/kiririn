import SwiftUI

private struct PlaybackServerSelectionDialogModifier: ViewModifier {
    let service: TVService
    @Binding var selectedService: TVService?
    let manager: ServerManager
    let showsOnlyConnectedCandidates: Bool
    let onSelect: (TVService) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "再生するサーバーを選択",
            isPresented: Binding(
                get: { selectedService?.id == service.id },
                set: { isPresented in
                    guard !isPresented, selectedService?.id == service.id else { return }
                    selectedService = nil
                }
            ),
            titleVisibility: .visible
        ) {
            let candidates =
                showsOnlyConnectedCandidates
                ? manager.connectedPlaybackCandidates(for: service)
                : manager.playbackCandidates(for: service)
            ForEach(candidates, id: \.serverId) { candidate in
                Button(manager.serverFullDisplayName(candidate.serverId)) {
                    selectedService = nil
                    onSelect(candidate)
                }
            }
            Button("キャンセル", role: .cancel) {
                selectedService = nil
            }
        }
    }
}

private struct ReconnectionServerSelectionDialogModifier: ViewModifier {
    let service: TVService
    @Binding var selectedService: TVService?
    let manager: ServerManager
    let onSelect: (String) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "再接続するサーバーを選択",
            isPresented: Binding(
                get: { selectedService?.id == service.id },
                set: { isPresented in
                    guard !isPresented, selectedService?.id == service.id else { return }
                    selectedService = nil
                }
            ),
            titleVisibility: .visible
        ) {
            let candidates = manager.reconnectionCandidates(for: service)
            ForEach(candidates, id: \.serverId) { candidate in
                Button(manager.serverFullDisplayName(candidate.serverId)) {
                    selectedService = nil
                    onSelect(candidate.serverId)
                }
            }
            Button("キャンセル", role: .cancel) {
                selectedService = nil
            }
        }
    }
}

extension View {
    func playbackServerSelectionDialog(
        service: TVService,
        selectedService: Binding<TVService?>,
        manager: ServerManager,
        showsOnlyConnectedCandidates: Bool = false,
        onSelect: @escaping (TVService) -> Void
    ) -> some View {
        modifier(
            PlaybackServerSelectionDialogModifier(
                service: service,
                selectedService: selectedService,
                manager: manager,
                showsOnlyConnectedCandidates: showsOnlyConnectedCandidates,
                onSelect: onSelect
            )
        )
    }

    func reconnectionServerSelectionDialog(
        service: TVService,
        selectedService: Binding<TVService?>,
        manager: ServerManager,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        modifier(
            ReconnectionServerSelectionDialogModifier(
                service: service,
                selectedService: selectedService,
                manager: manager,
                onSelect: onSelect
            )
        )
    }
}
