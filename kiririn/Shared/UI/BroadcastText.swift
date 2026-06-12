import ARIBStandardKit
import SwiftUI

struct BroadcastText: View {
    private let source: String
    private let badgeSpacing = "\u{2005}"

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        let segments = source.aribBroadcastDisplaySegments()

        if segments.count == 1,
            let segment = segments.first,
            !segment.isEnclosed
        {
            Text(segment.text)
        } else {
            renderedText(using: segments)
                .textRenderer(BroadcastBadgeTextRenderer())
        }
    }

    private func renderedText(using segments: [(text: String, isEnclosed: Bool)]) -> Text {
        guard !segments.isEmpty else { return Text("") }

        return segments.indices.reduce(Text("")) { partial, index in
            partial + leadingSpacingText(for: index, in: segments)
                + text(for: index, segment: segments[index])
                + trailingSpacingText(for: index, in: segments)
        }
    }

    private func text(for index: Int, segment: (text: String, isEnclosed: Bool)) -> Text {
        let text = Text(segment.text)
        if segment.isEnclosed {
            return text.customAttribute(
                BroadcastBadgeTextAttribute(
                    segmentIndex: index,
                    label: segment.text
                )
            )
        }
        return text
    }

    private func leadingSpacingText(for index: Int, in segments: [(text: String, isEnclosed: Bool)])
        -> Text
    {
        guard segments[index].isEnclosed,
            index > 0,
            !segments[index - 1].isEnclosed,
            let lastCharacter = segments[index - 1].text.last,
            !lastCharacter.isWhitespace
        else {
            return Text("")
        }
        return Text(badgeSpacing)
    }

    private func trailingSpacingText(
        for index: Int, in segments: [(text: String, isEnclosed: Bool)]
    ) -> Text {
        guard segments[index].isEnclosed,
            index + 1 < segments.count
        else {
            return Text("")
        }

        if segments[index + 1].isEnclosed {
            return Text(badgeSpacing)
        }

        guard let firstCharacter = segments[index + 1].text.first,
            !firstCharacter.isWhitespace
        else {
            return Text("")
        }

        return Text(badgeSpacing)
    }
}
