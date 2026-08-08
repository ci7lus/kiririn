import SwiftUI

final class HorizontalOffsetTracker {
    var horizontalOffset: CGFloat = 0
}

struct ProgramChannelColumnView: View, Equatable {
    let channelId: String
    let programs: [Program]
    let timelineStart: Date
    let timelineEnd: Date
    let minuteHeight: CGFloat
    let width: CGFloat
    let totalHeight: CGFloat
    let visibleRange: ProgramGuideVisibleRange
    let onProgramTapped: (Program) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.channelId == rhs.channelId && lhs.timelineStart == rhs.timelineStart
            && lhs.timelineEnd == rhs.timelineEnd && lhs.minuteHeight == rhs.minuteHeight
            && lhs.width == rhs.width && lhs.totalHeight == rhs.totalHeight
            && lhs.visibleRange == rhs.visibleRange
            && lhs.programs == rhs.programs
    }

    private func yOffset(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(timelineStart) / 60.0) * minuteHeight
    }

    private var visibleProgramIndices: [Int] {
        programs.indices.filter { index in
            let program = programs[index]
            return visibleRange.intersects(
                programStart: program.startAt,
                programEnd: program.endAt,
                timelineEnd: timelineEnd
            )
        }
    }

    var body: some View {
        let renderedProgramIndices = visibleProgramIndices

        ZStack(alignment: .topLeading) {
            // 絶対Y座標で配置する番組セルの原点を列の左上に固定する。
            Color.clear
                .frame(width: width, height: totalHeight)
                .allowsHitTesting(false)

            ForEach(renderedProgramIndices, id: \.self) { index in
                ProgramCellWrapper(
                    program: programs[index],
                    timelineStart: timelineStart,
                    timelineEnd: timelineEnd,
                    width: width,
                    minuteHeight: minuteHeight
                )
                .equatable()
            }
        }
        .frame(width: width, height: totalHeight, alignment: .topLeading)
        .clipped()
        .contentShape(.rect)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.kiririnSeparator.opacity(0.6))
                .frame(width: 1)
                .allowsHitTesting(false)
        }
        .onTapGesture(coordinateSpace: .local) { location in
            let tappedY = location.y
            if let index = renderedProgramIndices.first(where: { index in
                let program = programs[index]
                let start = max(program.startAt, timelineStart)
                let rawEnd = program.endAt > program.startAt ? program.endAt : timelineEnd
                let end = min(rawEnd, timelineEnd)
                guard end > start else { return false }
                return tappedY >= yOffset(for: start) && tappedY < yOffset(for: end)
            }) {
                onProgramTapped(programs[index])
            }
        }
    }
}

struct ProgramCellWrapper: View, Equatable {
    let program: Program
    let timelineStart: Date
    let timelineEnd: Date
    let width: CGFloat
    let minuteHeight: CGFloat

    static func == (lhs: ProgramCellWrapper, rhs: ProgramCellWrapper) -> Bool {
        lhs.program == rhs.program && lhs.timelineStart == rhs.timelineStart
            && lhs.timelineEnd == rhs.timelineEnd && lhs.width == rhs.width
            && lhs.minuteHeight == rhs.minuteHeight
    }

    private func yOffset(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(timelineStart) / 60.0) * minuteHeight
    }

    var body: some View {
        let start = max(program.startAt, timelineStart)
        let rawEnd = program.endAt > program.startAt ? program.endAt : timelineEnd
        let end = min(rawEnd, timelineEnd)
        let duration = end.timeIntervalSince(start) / 60.0

        let y = yOffset(for: start)
        let height = CGFloat(duration) * minuteHeight

        if height > 0 {
            ProgramCellView(program: program, availableHeight: height)
                .frame(width: width - 8, height: height, alignment: .topLeading)
                .offset(x: 4, y: y)
                .contentShape(.rect)
        }
    }
}

struct ProgramCellView: View, Equatable {
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .subheadline) private var minimumHeightForTimeRange: CGFloat = 68
    @ScaledMetric(relativeTo: .caption2) private var minimumHeightForDescription: CGFloat = 88
    let program: Program
    let availableHeight: CGFloat

    static func == (lhs: ProgramCellView, rhs: ProgramCellView) -> Bool {
        lhs.program == rhs.program && lhs.availableHeight == rhs.availableHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let programTitle {
                BroadcastText(programTitle, style: .subheadline, weight: .semibold)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("番組名なし")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if availableHeight >= minimumHeightForTimeRange {
                Text(timeRange)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if availableHeight >= minimumHeightForDescription,
                let desc = compactDescription
            {
                BroadcastText(desc, style: .caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(programBorderColor, lineWidth: 1)
        )
        .background(programColor)
    }

    private var programTitle: String? {
        let trimmed = program.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var timeRange: String {
        let start = Self.timeFormatter.string(from: program.startAt)
        if program.duration <= 0 || program.endAt <= program.startAt {
            return "\(start) - (終了時刻未定)"
        }
        let end = Self.timeFormatter.string(from: program.endAt)
        return "\(start) - \(end)"
    }

    private var compactDescription: String? {
        guard let desc = program.desc?.trimmingCharacters(in: .whitespacesAndNewlines),
            !desc.isEmpty
        else { return nil }
        return desc.compactedLines
    }

    private var programColor: Color {
        let base = program.genres.first?.genreColor ?? .gray
        if colorScheme == .light {
            return base.mix(with: .white, by: 0.85)
        } else {
            return base.mix(with: .white, by: 0.1).mix(with: .black, by: 0.5)
        }
    }

    private var programBorderColor: Color {
        let base = program.genres.first?.genreColor ?? .gray
        if colorScheme == .light {
            return base.mix(with: .white, by: 0.6)
        } else {
            return base.mix(with: .white, by: 0.2).mix(with: .black, by: 0.3)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
