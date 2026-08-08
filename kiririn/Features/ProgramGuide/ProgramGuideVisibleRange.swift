import Foundation

nonisolated struct ProgramGuideVisibleRange: Equatable, Sendable {
    let start: Date
    let end: Date

    static func make(
        timelineStart: Date,
        timelineEnd: Date,
        minuteHeight: CGFloat,
        verticalScrollOffset: CGFloat,
        viewportHeight: CGFloat,
        sectionHeaderHeight: CGFloat
    ) -> Self {
        guard timelineEnd > timelineStart, minuteHeight > 0 else {
            return Self(start: timelineStart, end: timelineEnd)
        }

        let timelineHeight =
            CGFloat(timelineEnd.timeIntervalSince(timelineStart) / 60) * minuteHeight
        let visibleHeight = max(viewportHeight - sectionHeaderHeight, 0)
        let visibleTop = min(
            max(verticalScrollOffset - sectionHeaderHeight, 0),
            timelineHeight
        )
        let quantum = 30 * minuteHeight
        let bufferedTop = max(visibleTop - visibleHeight, 0)
        let bufferedBottom = min(visibleTop + visibleHeight * 2, timelineHeight)
        let quantizedTop = floor(bufferedTop / quantum) * quantum
        let quantizedBottom = min(
            ceil(bufferedBottom / quantum) * quantum,
            timelineHeight
        )

        return Self(
            start: timelineStart.addingTimeInterval(
                TimeInterval(quantizedTop / minuteHeight) * 60
            ),
            end: timelineStart.addingTimeInterval(
                TimeInterval(quantizedBottom / minuteHeight) * 60
            )
        )
    }

    func intersects(
        programStart: Date,
        programEnd: Date,
        timelineEnd: Date
    ) -> Bool {
        let effectiveEnd = programEnd > programStart ? programEnd : timelineEnd
        return programStart < end && effectiveEnd > start
    }
}
