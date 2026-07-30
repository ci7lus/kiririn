#if os(iOS)
    import SwiftUI

    struct RemoteTransportButton: View {
        let title: String
        let systemImage: String
        var isPrimary = false
        var isDisabled = false
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(spacing: 5) {
                    Image(systemName: systemImage)
                        .font(isPrimary ? .title : .title2)
                    Text(title)
                        .font(.caption)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: isPrimary ? 72 : 64)
                .foregroundStyle(isPrimary ? Color.white : Color.primary)
                .background(
                    isPrimary ? Color.accentColor : Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .overlay {
                    if !isPrimary {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(.secondary.opacity(0.3), lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.4 : 1)
        }
    }
#endif
