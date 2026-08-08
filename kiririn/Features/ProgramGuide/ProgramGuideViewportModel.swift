import SwiftUI

@MainActor
@Observable
final class ProgramGuideViewportModel {
    private(set) var visibleRange: ProgramGuideVisibleRange
    @ObservationIgnored
    private(set) var verticalOffset: CGFloat = 0

    init(visibleRange: ProgramGuideVisibleRange) {
        self.visibleRange = visibleRange
    }

    func updateVerticalOffset(
        _ offset: CGFloat,
        timelineStart: Date,
        timelineEnd: Date,
        minuteHeight: CGFloat,
        viewportHeight: CGFloat,
        sectionHeaderHeight: CGFloat
    ) {
        verticalOffset = offset
        guard
            visibleRange.needsRefresh(
                timelineStart: timelineStart,
                timelineEnd: timelineEnd,
                minuteHeight: minuteHeight,
                verticalScrollOffset: verticalOffset,
                viewportHeight: viewportHeight,
                sectionHeaderHeight: sectionHeaderHeight
            )
        else { return }
        updateVisibleRange(
            timelineStart: timelineStart,
            timelineEnd: timelineEnd,
            minuteHeight: minuteHeight,
            viewportHeight: viewportHeight,
            sectionHeaderHeight: sectionHeaderHeight
        )
    }

    func updateVisibleRange(
        timelineStart: Date,
        timelineEnd: Date,
        minuteHeight: CGFloat,
        viewportHeight: CGFloat,
        sectionHeaderHeight: CGFloat
    ) {
        guard viewportHeight > sectionHeaderHeight else { return }
        let updatedRange = ProgramGuideVisibleRange.make(
            timelineStart: timelineStart,
            timelineEnd: timelineEnd,
            minuteHeight: minuteHeight,
            verticalScrollOffset: verticalOffset,
            viewportHeight: viewportHeight,
            sectionHeaderHeight: sectionHeaderHeight
        )
        guard updatedRange != visibleRange else { return }
        visibleRange = updatedRange
    }
}
