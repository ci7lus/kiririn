import SwiftUI

struct ProgramGuideChannelGridView: View {
    let channels: [GuideChannel]
    let timelineStart: Date
    let timelineEnd: Date
    let minuteHeight: CGFloat
    let channelColumnWidth: CGFloat
    let timelineHeight: CGFloat
    let nowLineYOffset: CGFloat
    let nowLineOpacity: Double
    let nowLineWidth: CGFloat
    let viewportModel: ProgramGuideViewportModel
    @Binding var selectedProgram: ProgramSelection?

    var body: some View {
        let markerOffsets = timeMarkerOffsets

        ZStack(alignment: .topLeading) {
            Color.kiririnSystemBackground
                .frame(width: gridWidth, height: timelineHeight)

            Canvas { context, size in
                for y in markerOffsets {
                    context.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                        with: .color(Color.kiririnSeparator.opacity(0.25))
                    )
                }
            }
            .frame(width: gridWidth, height: timelineHeight)
            .allowsHitTesting(false)

            LazyHStack(alignment: .top, spacing: 0) {
                ForEach(channels) { channel in
                    ProgramChannelColumnView(
                        channelId: channel.id,
                        programs: channel.programs,
                        timelineStart: timelineStart,
                        timelineEnd: timelineEnd,
                        minuteHeight: minuteHeight,
                        width: channelColumnWidth,
                        totalHeight: timelineHeight,
                        visibleRange: viewportModel.visibleRange,
                        onProgramTapped: { program in
                            selectedProgram = ProgramSelection(
                                program: program,
                                service: channel.service
                            )
                        }
                    )
                    .equatable()
                    .id(channel.id)
                }
            }

            if nowLineYOffset >= 0 && nowLineYOffset < timelineHeight {
                Rectangle()
                    .fill(Color.accentColor)
                    .opacity(nowLineOpacity)
                    .frame(width: nowLineWidth, height: 3)
                    .offset(y: nowLineYOffset - 1.5)
                    .allowsHitTesting(false)
                    .zIndex(1800)
            }
        }
    }

    private var gridWidth: CGFloat {
        CGFloat(channels.count) * channelColumnWidth
    }

    private var timeMarkerOffsets: [CGFloat] {
        let count = Int((timelineEnd.timeIntervalSince(timelineStart) / 60) / 30)
        return (0...count).map { CGFloat($0 * 30) * minuteHeight }
    }
}
