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
    let onProgramTapped: (Program) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.channelId == rhs.channelId && lhs.timelineStart == rhs.timelineStart
            && lhs.timelineEnd == rhs.timelineEnd && lhs.minuteHeight == rhs.minuteHeight
            && lhs.width == rhs.width && lhs.totalHeight == rhs.totalHeight
            && lhs.programs == rhs.programs
    }

    private func yOffset(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(timelineStart) / 60.0) * minuteHeight
    }

    private var timeMarkerOffsets: [CGFloat] {
        let count = Int((timelineEnd.timeIntervalSince(timelineStart) / 60) / 30)
        return (0...count).map { CGFloat($0 * 30) * minuteHeight }
    }

    var body: some View {
        let markerOffsets = timeMarkerOffsets

        ZStack(alignment: .topLeading) {
            Color.kiririnSystemBackground

            Canvas { context, size in
                for y in markerOffsets {
                    context.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                        with: .color(Color.kiririnSeparator.opacity(0.25))
                    )
                }
                context.fill(
                    Path(CGRect(x: 0, y: 0, width: 1, height: size.height)),
                    with: .color(Color.kiririnSeparator.opacity(0.6))
                )
            }
            .allowsHitTesting(false)

            ForEach(programs) { program in
                ProgramCellWrapper(
                    program: program,
                    timelineStart: timelineStart,
                    timelineEnd: timelineEnd,
                    width: width,
                    minuteHeight: minuteHeight
                )
                .equatable()
            }
        }
        .frame(width: width, height: totalHeight)
        .clipped()
        .drawingGroup()
        .onTapGesture(coordinateSpace: .local) { location in
            let tappedY = location.y
            if let program = programs.first(where: { program in
                let start = max(program.startAt, timelineStart)
                let rawEnd = program.endAt > program.startAt ? program.endAt : timelineEnd
                let end = min(rawEnd, timelineEnd)
                guard end > start else { return false }
                return tappedY >= yOffset(for: start) && tappedY < yOffset(for: end)
            }) {
                onProgramTapped(program)
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
        lhs.program.id == rhs.program.id && lhs.timelineStart == rhs.timelineStart
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
            ProgramCellView(program: program)
                .frame(width: width - 8, height: height, alignment: .topLeading)
                .offset(x: 4, y: y)
                .contentShape(.rect)
        }
    }
}

struct ProgramCellView: View, Equatable {
    @Environment(\.colorScheme) private var colorScheme
    let program: Program

    static func == (lhs: ProgramCellView, rhs: ProgramCellView) -> Bool {
        lhs.program.id == rhs.program.id && lhs.program.name == rhs.program.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let programTitle {
                BroadcastText(programTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("番組名なし")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(timeRange)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let desc = compactDescription {
                BroadcastText(desc)
                    .font(.caption2)
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
