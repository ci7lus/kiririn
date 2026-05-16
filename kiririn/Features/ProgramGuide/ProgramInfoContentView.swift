import Foundation
import OrderedCollections
import SwiftUI

struct ProgramInfoContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    let program: Program
    let serviceName: String?
    var showsCopyContextMenu: Bool = false

    private struct ExtendedEntry: Identifiable {
        let id: String
        let key: String
        let value: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BroadcastText(program.name)
                .font(.title3)
                .fontWeight(.bold)
                .contextMenu {
                    if showsCopyContextMenu {
                        copyMenuButton("タイトルをコピー", text: program.name)
                    }
                }

            if let serviceName = rawServiceName {
                Text(serviceName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if program.duration == 604_065 {
                Text(
                    "\(program.startAt.formatted(.displayDateTimeFull)) - (終了時刻未定)"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                Text(
                    "\(program.startAt.formatted(.displayDateTimeFull)) - \(program.endAt.formatted(.displayTime))"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if !program.genres.isEmpty {
                WrappingFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(Array(program.genres.prefix(3).enumerated()), id: \.offset) {
                        _, genre in
                        Text(genre.displayName)
                            .font(.caption2)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                genre.genreColor.opacity(colorScheme == .light ? 0.18 : 0.28),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .stroke(
                                        genre.genreColor.opacity(colorScheme == .light ? 0.4 : 0.6),
                                        lineWidth: 1
                                    )
                            }
                    }
                }
            }

            if let rawDescription = program.desc,
                !rawDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                BroadcastText(rawDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contextMenu {
                        if showsCopyContextMenu {
                            copyMenuButton("番組説明をコピー", text: rawDescription)
                        }
                    }
            }

            let extendedEntries = Self.normalizedExtendedEntries(
                extended: program.extended
            )
            if !extendedEntries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(extendedEntries, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.key)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(linkedAttributedString(for: entry.value))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyMenuButton(_ title: String, text: String) -> some View {
        Button {
            copyTextToClipboard(text)
        } label: {
            Label(title, systemImage: "doc.on.doc")
        }
    }

    private var rawServiceName: String? {
        guard let serviceName else { return nil }
        let trimmedName = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? nil : trimmedName
    }

    private func linkedAttributedString(for text: String) -> AttributedString {
        let mutable = NSMutableAttributedString(string: text)
        let fullRange = NSRange(location: 0, length: mutable.length)
        var linkRanges: [NSRange] = []

        if let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue)
        {
            detector.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                guard let match, let url = match.url else { return }
                mutable.addAttribute(.link, value: url, range: match.range)
                linkRanges.append(match.range)
            }
        }

        if let handleRegex = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_])@([A-Za-z0-9_]{1,15})")
        {
            handleRegex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                guard let match,
                    match.numberOfRanges > 1,
                    !linkRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }
                    ),
                    let handleRange = Range(match.range(at: 1), in: text)
                else {
                    return
                }

                let handle = String(text[handleRange])
                guard let url = URL(string: "https://x.com/\(handle)") else { return }
                mutable.addAttribute(.link, value: url, range: match.range)
                linkRanges.append(match.range)
            }
        }

        return AttributedString(mutable)
    }
    private static func normalizedExtendedEntries(
        extended: OrderedDictionary<String, String>?
    ) -> [ExtendedEntry] {
        guard let extended else { return [] }
        return extended.elements.enumerated().compactMap { index, item in
            let trimmedKey = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return nil }
            let normalizedKey = trimmedKey.isEmpty ? "詳細" : item.key
            return ExtendedEntry(
                id: "\(index)|\(normalizedKey)",
                key: normalizedKey,
                value: item.value
            )
        }
    }
}
