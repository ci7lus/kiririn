#if os(macOS)
    import AppKit
    import VLCKit

    /// samplebufferdisplayが参照するdrawableの矩形をAppKitで有効な範囲に保つ。
    final class GeometrySafeVLCVideoView: VLCVideoView {
        override var frame: NSRect {
            get { super.frame }
            set { super.frame = Self.validated(newValue) }
        }

        override var bounds: NSRect {
            get { super.bounds }
            set { super.bounds = Self.validated(newValue) }
        }

        private static func validated(_ rect: NSRect) -> NSRect {
            guard rect.origin.x.isFinite, rect.origin.y.isFinite,
                rect.width.isFinite, rect.height.isFinite
            else { return .zero }
            return rect.standardized
        }
    }
#endif
