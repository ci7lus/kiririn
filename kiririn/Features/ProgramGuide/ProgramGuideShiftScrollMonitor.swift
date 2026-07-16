#if os(macOS)
    import SwiftUI

    struct ProgramGuideShiftScrollMonitor: NSViewRepresentable {
        let isEnabled: Bool
        let onLiveScale: (CGFloat, UnitPoint) -> Void
        let onScaleCommit: (CGFloat, UnitPoint) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(
                isEnabled: isEnabled, onLiveScale: onLiveScale, onScaleCommit: onScaleCommit)
        }

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            context.coordinator.startMonitoring(view: view)
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            context.coordinator.isEnabled = isEnabled
            context.coordinator.onLiveScale = onLiveScale
            context.coordinator.onScaleCommit = onScaleCommit
        }

        static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
            coordinator.stopMonitoring()
        }

        @MainActor
        final class Coordinator {
            var isEnabled: Bool
            var onLiveScale: (CGFloat, UnitPoint) -> Void
            var onScaleCommit: (CGFloat, UnitPoint) -> Void

            private weak var view: NSView?
            private var eventMonitor: Any?
            private var accumulatedFactor: CGFloat = 1.0
            private var lastAnchor: UnitPoint = .center
            private var debounceWorkItem: DispatchWorkItem?

            init(
                isEnabled: Bool,
                onLiveScale: @escaping (CGFloat, UnitPoint) -> Void,
                onScaleCommit: @escaping (CGFloat, UnitPoint) -> Void
            ) {
                self.isEnabled = isEnabled
                self.onLiveScale = onLiveScale
                self.onScaleCommit = onScaleCommit
            }

            func startMonitoring(view: NSView) {
                self.view = view
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                    [weak self] event in
                    self?.handleScrollEvent(event) ?? event
                }
            }

            func stopMonitoring() {
                guard let eventMonitor else { return }
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
                debounceWorkItem?.cancel()
            }

            private func handleScrollEvent(_ event: NSEvent) -> NSEvent? {
                guard isEnabled,
                    event.modifierFlags.contains(.shift),
                    let view,
                    event.window === view.window
                else {
                    return event
                }

                let location = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(location), view.bounds.width > 0, view.bounds.height > 0
                else {
                    return event
                }

                let delta =
                    abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
                    ? event.scrollingDeltaY : event.scrollingDeltaX
                guard delta != 0 else { return event }

                let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.006 : 0.08
                let factor = min(max(1 + delta * sensitivity, 0.8), 1.2)
                accumulatedFactor *= factor

                let anchor = UnitPoint(
                    x: min(max(location.x / view.bounds.width, 0), 1),
                    y: min(max(1 - location.y / view.bounds.height, 0), 1)
                )
                lastAnchor = anchor
                onLiveScale(accumulatedFactor, anchor)

                debounceWorkItem?.cancel()
                let committedFactor = accumulatedFactor
                let committedAnchor = anchor
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.onScaleCommit(committedFactor, committedAnchor)
                    self.accumulatedFactor = 1.0
                }
                debounceWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)

                return nil
            }
        }
    }
#endif
