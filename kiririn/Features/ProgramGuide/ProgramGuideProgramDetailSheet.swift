import SwiftUI

struct ProgramGuideProgramDetailSheetView: View {
    let selection: ProgramSelection
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                ProgramInfoContentView(
                    program: selection.program,
                    serviceName: selection.service.name,
                    showsCopyContextMenu: true
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("番組詳細")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if #available(iOS 26, macOS 26, *) {
                        Button(role: .close) {
                            onClose()
                        }
                    } else {
                        Button("閉じる") {
                            onClose()
                        }
                    }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 320)
        #endif
        #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #endif
    }
}
