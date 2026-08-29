import ARIBStandardKit
import SwiftUI

struct BroadcastText: View {
    private let segments: [(text: String, isEnclosed: Bool)]
    private let font: Font
    private static let badgeSpacing = "\u{2005}"

    init(
        _ source: String,
        style: Font.TextStyle = .body,
        weight: Font.Weight = .regular
    ) {
        segments = source.aribBroadcastDisplaySegments()
        font = .systemWithARIBFallback(for: source, style, weight: weight)
    }

    init(_ source: String, size: CGFloat, weight: Font.Weight = .regular) {
        segments = source.aribBroadcastDisplaySegments()
        font = .systemWithARIBFallback(for: source, size: size, weight: weight)
    }

    var body: some View {
        if segments.count == 1,
            let segment = segments.first,
            !segment.isEnclosed
        {
            Text(segment.text)
                .font(font)
        } else {
            renderedText(using: segments)
                .textRenderer(BroadcastBadgeTextRenderer())
                .font(font)
        }
    }

    private func renderedText(using segments: [(text: String, isEnclosed: Bool)]) -> Text {
        guard !segments.isEmpty else { return Text("") }

        var rendered = Text("")
        for segment in Self.displaySegmentsForRendering(segments) {
            if segment.isEnclosed {
                rendered = rendered + text(for: segment)
                continue
            }

            rendered = rendered + Text(segment.text)
        }
        return rendered
    }

    static func displaySegmentsForRendering(
        _ segments: [(text: String, isEnclosed: Bool)]
    ) -> [(text: String, isEnclosed: Bool)] {
        var renderedSegments: [(text: String, isEnclosed: Bool)] = []
        renderedSegments.reserveCapacity(segments.count)

        for index in segments.indices {
            let segment = segments[index]
            if segment.isEnclosed {
                if index > 0, segments[index - 1].isEnclosed {
                    renderedSegments.append((text: Self.badgeSpacing, isEnclosed: false))
                }
                renderedSegments.append(segment)
                continue
            }

            var plainText = segment.text
            if index > 0,
                segments[index - 1].isEnclosed,
                let firstCharacter = plainText.first,
                !firstCharacter.isWhitespace
            {
                plainText.insert(contentsOf: Self.badgeSpacing, at: plainText.startIndex)
            }
            if index + 1 < segments.count,
                segments[index + 1].isEnclosed,
                let lastCharacter = plainText.last,
                !lastCharacter.isWhitespace
            {
                plainText.append(contentsOf: Self.badgeSpacing)
            }
            renderedSegments.append((text: plainText, isEnclosed: false))
        }

        return renderedSegments
    }

    private func text(for segment: (text: String, isEnclosed: Bool)) -> Text {
        let text = Text(segment.text)
        if segment.isEnclosed {
            return text.customAttribute(
                BroadcastBadgeTextAttribute(isSingleCharacter: segment.text.count == 1)
            )
        }
        return text
    }
}
