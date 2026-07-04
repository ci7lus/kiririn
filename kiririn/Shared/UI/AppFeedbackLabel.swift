import SwiftUI

struct AppFeedbackLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    let text: String
    var systemImage: String? = nil
    var iconTint: Color?
    var showsProgress = false

    var body: some View {
        let foregroundColor = feedbackForegroundColor
        let label = HStack(spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(foregroundColor)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconTint ?? foregroundColor)
            }

            Text(text)
                .lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 34)
        .shadow(color: .black.opacity(0.28), radius: 4, y: 1)

        #if os(macOS)
            if #available(macOS 26, *) {
                label
                    .glassEffect(.regular.tint(.black.opacity(0.18)), in: .capsule)
            } else {
                materialLabel(label)
            }
        #else
            if #available(iOS 26, *) {
                label
                    .glassEffect(.regular, in: .capsule)
            } else {
                materialLabel(label)
            }
        #endif
    }

    private func materialLabel(_ label: some View) -> some View {
        label
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
    }

    private var feedbackForegroundColor: Color {
        colorScheme == .light ? .primary : .white
    }
}
