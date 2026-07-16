import SwiftUI

struct ProgramGuideVerticalScaleModifier: ViewModifier {
    let currentMinuteHeight: CGFloat
    let minuteHeightRange: ClosedRange<CGFloat>
    let onScale: (CGFloat, UnitPoint) -> Void

    #if os(iOS)
        @GestureState private var magnificationState: (factor: CGFloat, anchor: UnitPoint) =
            (1, .center)
    #elseif os(macOS)
        @Environment(\.isTabActive) private var isTabActive
        @State private var liveScaleFactor: CGFloat = 1.0
        @State private var liveScaleAnchor: UnitPoint = .center
    #endif

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .scaleEffect(
                    x: 1,
                    y: magnificationState.factor,
                    anchor: magnificationState.anchor
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($magnificationState) { value, state, _ in
                            state = (
                                factor: clampedFactor(value.magnification),
                                anchor: value.startAnchor
                            )
                        }
                        .onEnded { value in
                            onScale(clampedFactor(value.magnification), value.startAnchor)
                        }
                )
                .accessibilityZoomAction(performAccessibilityZoom)
        #elseif os(macOS)
            content
                .scaleEffect(x: 1, y: clampedFactor(liveScaleFactor), anchor: liveScaleAnchor)
                .background {
                    ProgramGuideShiftScrollMonitor(
                        isEnabled: isTabActive,
                        onLiveScale: { factor, anchor in
                            liveScaleFactor = factor
                            liveScaleAnchor = anchor
                        },
                        onScaleCommit: { factor, anchor in
                            liveScaleFactor = 1.0
                            liveScaleAnchor = .center
                            onScale(factor, anchor)
                        }
                    )
                }
                .accessibilityZoomAction(performAccessibilityZoom)
        #else
            content
        #endif
    }

    private func clampedFactor(_ factor: CGFloat) -> CGFloat {
        guard currentMinuteHeight > 0 else { return 1 }
        let updatedMinuteHeight = min(
            max(currentMinuteHeight * factor, minuteHeightRange.lowerBound),
            minuteHeightRange.upperBound
        )
        return updatedMinuteHeight / currentMinuteHeight
    }

    private func performAccessibilityZoom(_ action: AccessibilityZoomGestureAction) {
        #if os(macOS)
            liveScaleFactor = 1.0
            liveScaleAnchor = .center
        #endif
        switch action.direction {
        case .zoomIn:
            onScale(1.2, action.location)
        case .zoomOut:
            onScale(1 / 1.2, action.location)
        @unknown default:
            break
        }
    }
}

extension View {
    func programGuideVerticalScale(
        currentMinuteHeight: CGFloat,
        minuteHeightRange: ClosedRange<CGFloat>,
        onScale: @escaping (CGFloat, UnitPoint) -> Void
    ) -> some View {
        modifier(
            ProgramGuideVerticalScaleModifier(
                currentMinuteHeight: currentMinuteHeight,
                minuteHeightRange: minuteHeightRange,
                onScale: onScale
            )
        )
    }
}
