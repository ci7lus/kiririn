import SwiftUI

#if os(iOS)
    import UIKit
#endif

@MainActor
final class ProgramGuideHorizontalScrollController {
    #if os(iOS)
        weak var resolverView: UIView?
        weak var scrollView: UIScrollView?
    #endif

    func scrollToLeading(animated: Bool) {
        #if os(iOS)
            DispatchQueue.main.async { [weak self] in
                self?.performScrollToLeading(animated: animated)
            }
        #endif
    }

    #if os(iOS)
        private func performScrollToLeading(animated: Bool) {
            guard let scrollView = resolvedScrollView() else { return }
            scrollView.layoutIfNeeded()

            var offset = scrollView.contentOffset
            offset.x = -scrollView.adjustedContentInset.left
            if animated {
                UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
                    scrollView.contentOffset = offset
                }
            } else {
                scrollView.setContentOffset(offset, animated: false)
            }
        }

        private func resolvedScrollView() -> UIScrollView? {
            if let scrollView, scrollView.isHorizontallyScrollable {
                return scrollView
            }

            guard let resolverView else { return nil }
            if let scrollView = resolverView.enclosingHorizontallyScrollableScrollView() {
                self.scrollView = scrollView
                return scrollView
            }
            if let scrollView = resolverView.window?.bestHorizontallyScrollableScrollView(
                containing: resolverView)
            {
                self.scrollView = scrollView
                return scrollView
            }
            return nil
        }
    #endif
}

extension View {
    @ViewBuilder
    func programGuideHorizontalScrollController(
        _ controller: ProgramGuideHorizontalScrollController
    ) -> some View {
        #if os(iOS)
            background(ProgramGuideScrollViewResolver(controller: controller))
        #else
            self
        #endif
    }
}

#if os(iOS)
    private struct ProgramGuideScrollViewResolver: UIViewRepresentable {
        let controller: ProgramGuideHorizontalScrollController

        func makeUIView(context: Context) -> ResolverView {
            ResolverView(controller: controller)
        }

        func updateUIView(_ uiView: ResolverView, context: Context) {
            uiView.controller = controller
            uiView.resolveScrollView()
        }

        final class ResolverView: UIView {
            var controller: ProgramGuideHorizontalScrollController

            init(controller: ProgramGuideHorizontalScrollController) {
                self.controller = controller
                super.init(frame: .zero)
                isUserInteractionEnabled = false
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            override func didMoveToSuperview() {
                super.didMoveToSuperview()
                resolveScrollView()
            }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                resolveScrollView()
            }

            func resolveScrollView() {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.controller.resolverView = self
                    self.controller.scrollView = self.enclosingHorizontallyScrollableScrollView()
                }
            }
        }
    }

    extension UIView {
        fileprivate func enclosingHorizontallyScrollableScrollView() -> UIScrollView? {
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView,
                    scrollView.isHorizontallyScrollable
                {
                    return scrollView
                }
                view = current.superview
            }
            return nil
        }

        fileprivate func bestHorizontallyScrollableScrollView(containing target: UIView)
            -> UIScrollView?
        {
            let candidates = descendantScrollViews().filter { scrollView in
                guard scrollView.isHorizontallyScrollable else { return false }
                let targetFrame = target.convert(target.bounds, to: scrollView)
                return scrollView.bounds.intersects(targetFrame)
            }
            return candidates.max { lhs, rhs in
                lhs.contentSize.height < rhs.contentSize.height
            }
        }

        private func descendantScrollViews() -> [UIScrollView] {
            var result: [UIScrollView] = []
            for subview in subviews {
                if let scrollView = subview as? UIScrollView {
                    result.append(scrollView)
                }
                result.append(contentsOf: subview.descendantScrollViews())
            }
            return result
        }
    }

    extension UIScrollView {
        fileprivate var isHorizontallyScrollable: Bool {
            contentSize.width > bounds.width + 1
        }
    }
#endif
