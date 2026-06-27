import SwiftUI

private struct PlaybackBackendSelectionDialogModifier: ViewModifier {
    let service: TVService
    @Binding var selectedService: TVService?
    let manager: BackendManager
    let onSelect: (TVService) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "再生するバックエンドを選択",
            isPresented: Binding(
                get: { selectedService?.id == service.id },
                set: { isPresented in
                    guard !isPresented, selectedService?.id == service.id else { return }
                    selectedService = nil
                }
            ),
            titleVisibility: .visible
        ) {
            let candidates = manager.playbackCandidates(for: service)
            ForEach(candidates, id: \.backendId) { candidate in
                Button(manager.backendFullDisplayName(candidate.backendId)) {
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

extension View {
    func playbackBackendSelectionDialog(
        service: TVService,
        selectedService: Binding<TVService?>,
        manager: BackendManager,
        onSelect: @escaping (TVService) -> Void
    ) -> some View {
        modifier(
            PlaybackBackendSelectionDialogModifier(
                service: service,
                selectedService: selectedService,
                manager: manager,
                onSelect: onSelect
            )
        )
    }
}
