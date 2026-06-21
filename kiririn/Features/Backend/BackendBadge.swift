import SwiftUI

struct BackendBadge: View {
    let typeName: String

    var body: some View {
        HStack(spacing: 6) {
            Text(typeName)
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.3))
                .clipShape(.capsule)
                .lineLimit(1)
        }
    }
}
