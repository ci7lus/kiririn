import SwiftUI

struct WrappingFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 0
    var verticalSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = makeRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height =
            rows.reduce(CGFloat.zero) { partialResult, row in
                partialResult + row.height
            } + max(0, CGFloat(rows.count - 1)) * verticalSpacing

        return CGSize(
            width: proposal.width ?? width,
            height: height
        )
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let rows = makeRows(maxWidth: bounds.width, subviews: subviews)
        var currentY = bounds.minY

        for row in rows {
            var currentX = bounds.minX

            for index in row.indices {
                let subview = subviews[index]
                let size = row.sizes[index] ?? subview.sizeThatFits(.unspecified)
                subview.place(
                    at: CGPoint(x: currentX, y: currentY),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                currentX += size.width + horizontalSpacing
            }

            currentY += row.height + verticalSpacing
        }
    }

    private func makeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        guard !subviews.isEmpty else { return [] }

        let effectiveMaxWidth = maxWidth.isFinite ? maxWidth : .greatestFiniteMagnitude
        var rows: [Row] = []
        var currentIndices: [Int] = []
        var currentSizes: [Int: CGSize] = [:]
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        func flushCurrentRow() {
            guard !currentIndices.isEmpty else { return }
            rows.append(
                Row(
                    indices: currentIndices,
                    sizes: currentSizes,
                    width: currentWidth,
                    height: currentHeight
                )
            )
            currentIndices.removeAll(keepingCapacity: true)
            currentSizes.removeAll(keepingCapacity: true)
            currentWidth = 0
            currentHeight = 0
        }

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let nextWidth =
                currentIndices.isEmpty ? size.width : currentWidth + horizontalSpacing + size.width

            if !currentIndices.isEmpty && nextWidth > effectiveMaxWidth {
                flushCurrentRow()
            }

            currentIndices.append(index)
            currentSizes[index] = size
            currentWidth =
                currentIndices.count == 1
                ? size.width : currentWidth + horizontalSpacing + size.width
            currentHeight = max(currentHeight, size.height)
        }

        flushCurrentRow()
        return rows
    }
}

private struct Row {
    let indices: [Int]
    let sizes: [Int: CGSize]
    let width: CGFloat
    let height: CGFloat
}
