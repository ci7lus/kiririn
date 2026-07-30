#if os(iOS)
    import SwiftUI

    struct RemoteActionButton: View {
        let title: String
        let systemImage: String
        var isActive = false
        var isDisabled = false
        var role: ButtonRole?
        let action: () -> Void

        var body: some View {
            Button(role: role, action: action) {
                VStack(spacing: 5) {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .frame(height: 22)
                        .overlay(alignment: .topTrailing) {
                            if isActive {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.accentColor)
                                    .offset(x: 8, y: -5)
                            }
                        }
                    Text(title)
                        .font(.caption)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 58)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .tint(role == .destructive ? .red : nil)
            .disabled(isDisabled)
        }
    }
#endif
